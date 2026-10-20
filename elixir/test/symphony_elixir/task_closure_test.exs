defmodule SymphonyElixir.TaskClosureTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.{NativeWork, RunJournal, TaskClosure, TaskWorkflow, WorkRef}

  defp flow(binding, overrides \\ %{}) do
    Map.merge(
      %{
        "closeable" => true,
        "phase" => "completed",
        "outcome" => "delivered",
        "execution" => "idle",
        "restrictions" => %{},
        "candidate" => TaskWorkflow.digest("candidate"),
        "contract_sha" => binding["contract_sha"],
        "plan_revision" => binding["plan_revision"],
        "authority" => binding["authority"]
      },
      overrides
    )
  end

  defp fixture(provider) do
    work = %{"provider" => provider, "host" => provider <> ".test", "repository_id" => "10", "kind" => "issue", "number" => 2}
    parent = %{work | "number" => 1}
    prefix = if provider == "github", do: "/repos/team/repo", else: "/projects/team%2Frepo"
    suffix = if provider == "github", do: "/comments", else: "/notes"
    url = "https://" <> work["host"] <> "/team/repo"
    path = prefix <> "/issues/2"

    repository =
      Map.take(work, ~w(provider host repository_id))
      |> Map.merge(%{
        "path" => "team/repo",
        "api_url" => "https://" <> work["host"] <> if(provider == "github", do: "/api/v3", else: "/api/v4"),
        "credential" => "$UNUSED_CLOSURE_FIXTURE"
      })

    native = fn state ->
      base = %{"id" => 102, "title" => "Member", "state" => state, "assignees" => [%{"id" => 1}]}

      if provider == "github",
        do: Map.merge(base, %{"number" => 2, "body" => "body", "html_url" => url <> "/issues/2"}),
        else: Map.merge(base, %{"iid" => 2, "description" => "body", "project_id" => 10, "web_url" => url <> "/-/issues/2"})
    end

    repository_object =
      if provider == "github",
        do: %{"id" => 10, "full_name" => "team/repo", "html_url" => url},
        else: %{"id" => 10, "path_with_namespace" => "team/repo", "web_url" => url}

    objects = %{prefix => repository_object, path => native.("open"), (path <> suffix) => []}
    state = start_supervised!({Agent, fn -> %{objects: objects, reads: 0, writes: []} end}, id: make_ref())

    request = fn ^provider, "GET", requested, _query, _settings ->
      read_and_count(state, path, requested)
    end

    write = fn ^provider, method, requested, query, body, _settings ->
      Agent.get_and_update(state, fn current ->
        closed = Map.merge(current.objects[requested], %{"state" => "closed"})
        entry = %{"method" => method, "path" => requested, "query" => query, "body" => body}
        {{:ok, %{status: 200, body: closed}}, %{current | objects: Map.put(current.objects, requested, closed), writes: current.writes ++ [entry]}}
      end)
    end

    root = Path.join(System.tmp_dir!(), "task-closure-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    revision = TaskWorkflow.digest("plan")

    binding = %{
      "work" => work,
      "role" => "developer",
      "plan_revision" => revision,
      "contract_sha" => TaskWorkflow.digest("contract"),
      "authority" => %{"work" => parent, "source" => "note:1", "actor" => "1", "revision" => revision},
      "inputs" => [],
      "candidate" => nil,
      "policy_sha" => TaskWorkflow.digest("policy")
    }

    {:ok, record} = RunJournal.admit(root, WorkRef.key(work), execution_binding: binding)
    :ok = RunJournal.complete(record, "completed")
    {:ok, record} = RunJournal.read(record["directory"])

    %{
      provider: provider,
      work: work,
      path: path,
      state: state,
      record: record,
      binding: binding,
      root: root,
      opts: [repositories: [repository], request: request, write_request: write]
    }
  end

  defp read_and_count(state, path, requested) do
    Agent.get_and_update(state, fn current ->
      reads = if requested == path, do: current.reads + 1, else: current.reads
      {{:ok, %{status: 200, body: Map.fetch!(current.objects, requested)}}, %{current | reads: reads}}
    end)
  end

  # A released bound record is only writable by a reconciler that announces
  # itself, exactly like the delivery reconciler does.
  defp stage(record, changes) do
    lock = Path.join(record["directory"], "executor.lock")
    File.mkdir_p!(lock)
    File.write!(Path.join(lock, "reconcile-owner"), System.pid())
    File.write!(Path.join(lock, "reconcile-owner.json"), Jason.encode!(owner_record(record)))

    try do
      {:ok, updated} = RunJournal.checkpoint(record, changes)
      updated
    after
      File.rm(Path.join(lock, "reconcile-owner"))
      File.rm(Path.join(lock, "reconcile-owner.json"))
      File.rmdir(lock)
    end
  end

  defp owner_record(record, overrides \\ %{}) do
    Map.merge(
      %{
        "kind" => "closure-reconciler",
        "os_pid" => System.pid(),
        "node" => to_string(node()),
        "vm_started_at" => :erlang.system_info(:start_time),
        "erlang_pid" => self() |> :erlang.pid_to_list() |> to_string(),
        "attempt_id" => record["attempt_id"],
        "issue_id" => record["issue_id"]
      },
      overrides
    )
  end

  # Re-derive the assessment the fence is required to make: the native snapshot
  # and the journal record are read again, exactly like the production caller.
  defp assess(f, overrides, journal \\ nil) do
    {:ok, snapshot} = NativeWork.read(f.work, f.opts)
    {:ok, record} = journal || RunJournal.read(f.record["directory"])
    {:ok, %{flow: flow(f.binding, overrides), record: record, snapshot: snapshot}}
  end

  defp counting_assess(f, flows) do
    counter = start_supervised!({Agent, fn -> 0 end}, id: make_ref())

    fn ->
      index = Agent.get_and_update(counter, &{&1, &1 + 1})
      assess(f, Enum.at(flows, min(index, length(flows) - 1)))
    end
  end

  defp with_assess(f, overrides \\ %{}), do: Keyword.put(f.opts, :reobserve, fn -> assess(f, overrides) end)
  defp writes(fixture), do: Agent.get(fixture.state, & &1.writes)
  defp object(fixture), do: Agent.get(fixture.state, & &1.objects[fixture.path])
  defp set_object(fixture, changes), do: Agent.update(fixture.state, &put_in(&1.objects[fixture.path], Map.merge(&1.objects[fixture.path], changes)))
  defp current(f), do: elem(RunJournal.read(f.record["directory"]), 1)

  defp locked(record, overrides \\ %{}) do
    lock = Path.join(record["directory"], "executor.lock")
    File.mkdir_p!(lock)
    File.write!(Path.join(lock, "reconcile-owner.json"), Jason.encode!(owner_record(record, overrides)))
    lock
  end

  defp dead_pid do
    {out, 0} = System.cmd("sh", ["-c", "sleep 60 >/dev/null 2>&1 & echo $!"])
    pid = String.trim(out)
    _ = System.cmd("kill", ["-9", pid], stderr_to_stdout: true)

    _ =
      Enum.find(1..200, pid, fn _ ->
        if File.dir?("/proc/" <> pid) do
          Process.sleep(10)
          nil
        else
          pid
        end
      end)

    pid
  end

  test "a delivered member closes its native Issue once and records intent and receipt" do
    for provider <- ["github", "gitlab"] do
      f = fixture(provider)

      assert {:ok, %{record: confirmed, closure: closure}} =
               TaskClosure.reconcile(f.record, flow(f.binding), with_assess(f))

      assert confirmed["closure_status"] == "published"
      assert confirmed["closure_intent"]["digest"] == confirmed["closure_confirmed"]["digest"]
      assert confirmed["closure_intent"]["candidate"] == TaskWorkflow.digest("candidate")
      assert confirmed["closure_confirmed"]["source"] =~ "issue:"
      assert confirmed["closure_current"]["state"] == "closed"
      assert closure["status"] == "confirmed"
      assert closure["native_state"] == "closed"
      assert object(f)["state"] == "closed"

      {method, body} = if provider == "github", do: {"PATCH", %{"state" => "closed"}}, else: {"PUT", %{"state_event" => "close"}}
      path = f.path
      assert [%{"method" => ^method, "path" => ^path, "query" => %{}, "body" => ^body}] = writes(f)
    end
  end

  test "a confirmed closure is never written twice and reports the current state" do
    f = fixture("github")
    assert {:ok, %{record: confirmed}} = TaskClosure.reconcile(f.record, flow(f.binding), with_assess(f))

    assert {:ok, %{record: ^confirmed, closure: closure}} =
             TaskClosure.reconcile(confirmed, flow(f.binding), with_assess(f))

    assert closure["status"] == "confirmed"
    assert length(writes(f)) == 1
  end

  # A projection can race the reconciler: it reads the journal before the
  # receipt lands, then takes the lock after another poll already published.
  # The locked read must adopt the durable receipt instead of writing again.
  test "a stale projection adopts a confirmed receipt without a second write" do
    f = fixture("github")
    assert {:ok, %{record: confirmed}} = TaskClosure.reconcile(f.record, flow(f.binding), with_assess(f))
    stale = Map.put(f.record, "closure_status", "sending")
    assert {:ok, %{record: adopted, closure: closure}} = TaskClosure.reconcile(stale, flow(f.binding), with_assess(f))
    assert adopted["closure_confirmed"] == confirmed["closure_confirmed"]
    assert closure["status"] == "confirmed"
    assert length(writes(f)) == 1
  end

  test "a delivered record that does not bind the tracked Issue stays open" do
    f = fixture("github")
    foreign = Map.put(f.record, "issue_id", "issue:other")
    assert TaskClosure.reconcile(foreign, flow(f.binding), with_assess(f)) == :not_applicable
    wrongly_typed = put_in(f.record, ["execution_binding", "work", "kind"], "mr")
    assert TaskClosure.reconcile(wrongly_typed, flow(f.binding), with_assess(f)) == :not_applicable
    assert writes(f) == []
  end

  test "an undelivered or unbound member is never closed" do
    f = fixture("github")
    assert TaskClosure.reconcile(f.record, flow(f.binding, %{"closeable" => false}), with_assess(f)) == :not_applicable
    assert TaskClosure.reconcile(f.record, flow(f.binding, %{"phase" => "verified"}), with_assess(f)) == :not_applicable
    assert TaskClosure.reconcile(f.record, flow(f.binding, %{"outcome" => "open"}), with_assess(f)) == :not_applicable
    assert TaskClosure.reconcile(f.record, flow(f.binding, %{"execution" => "active"}), with_assess(f)) == :not_applicable
    assert TaskClosure.reconcile(f.record, "not-a-flow", with_assess(f)) == :not_applicable
    assert TaskClosure.reconcile(%{"execution_binding" => %{}}, flow(f.binding), with_assess(f)) == :not_applicable
    assert writes(f) == []
  end

  # C1: the assessment that produced the conclusion is rebuilt inside the fence.
  test "a conclusion that moved before the fence is never written under the old intent" do
    f = fixture("github")
    changed = %{"candidate" => TaskWorkflow.digest("changed after observation")}

    assert {:error, :member_closure_conclusion_changed} =
             TaskClosure.reconcile(f.record, flow(f.binding), with_assess(f, changed))

    assert writes(f) == []
    refute current(f)["closure_confirmed"]
  end

  test "an assessment that cannot be rebuilt is never treated as a conclusion" do
    f = fixture("github")
    unavailable = Keyword.put(f.opts, :reobserve, fn -> {:error, :native_read_failed} end)

    assert {:error, {:member_closure_assessment_unavailable, :native_read_failed}} =
             TaskClosure.reconcile(f.record, flow(f.binding), unavailable)

    assert writes(f) == []
  end

  # C1: a durable intent is recovered against itself, never against a newer one.
  test "a sending intent is never repaired with a newer conclusion" do
    f = fixture("github")
    superseded = Map.merge(flow(f.binding), %{"candidate" => TaskWorkflow.digest("older candidate")})
    pending = stage(f.record, %{"closure_intent" => Map.put(superseded, "digest", TaskWorkflow.digest(superseded)), "closure_status" => "sending"})

    assert {:error, :member_closure_intent_superseded} = TaskClosure.reconcile(pending, flow(f.binding), with_assess(f))
    assert writes(f) == []
    refute current(f)["closure_confirmed"]
    assert current(f)["closure_status"] == "inconsistent"
  end

  # C1: drift during the write keeps the native fact and withholds the receipt.
  test "a conclusion that moved during the write is recorded as an inconsistency" do
    f = fixture("github")
    drifted = %{"candidate" => TaskWorkflow.digest("changed during write")}
    opts = Keyword.put(f.opts, :reobserve, counting_assess(f, [%{}, drifted]))

    assert {:error, :member_closure_conclusion_changed} = TaskClosure.reconcile(f.record, flow(f.binding), opts)
    assert object(f)["state"] == "closed"
    assert length(writes(f)) == 1

    after_write = current(f)
    refute after_write["closure_confirmed"]
    assert after_write["closure_status"] == "inconsistent"
    assert after_write["closure_current"]["state"] == "closed"
  end

  test "post-write restrictions or lost closeability leave the closed fact without a business receipt" do
    for {provider, drifted} <- [
          {"github", %{"closeable" => false}},
          {"gitlab", %{"restrictions" => %{"native:pause" => %{"kind" => "pause", "native" => true}}}}
        ] do
      f = fixture(provider)
      opts = Keyword.put(f.opts, :reobserve, counting_assess(f, [%{}, drifted]))

      assert {:error, :member_closure_conclusion_changed} = TaskClosure.reconcile(f.record, flow(f.binding), opts)
      assert object(f)["state"] == "closed"
      assert length(writes(f)) == 1

      after_write = current(f)
      assert after_write["closure_status"] == "inconsistent"
      assert after_write["closure_current"]["state"] == "closed"
      refute after_write["closure_confirmed"]
    end
  end

  test "an uncertain send keeps the durable intent without recording closure" do
    f = fixture("github")

    uncertain = fn "github", "PATCH", path, _query, _body, _settings ->
      Agent.update(f.state, &update_in(&1.objects[path], fn issue -> Map.put(issue, "state", "closed") end))
      {:error, :lost_response}
    end

    assert {:error, {:member_closure_send_unconfirmed, :native_write_failed}} =
             TaskClosure.reconcile(f.record, flow(f.binding), Keyword.put(with_assess(f), :write_request, uncertain))

    assert {:ok, pending} = RunJournal.read(f.record["directory"])
    assert pending["closure_status"] == "sending"
    refute pending["closure_confirmed"]

    assert {:ok, %{record: confirmed, closure: closure}} =
             TaskClosure.reconcile(pending, flow(f.binding), with_assess(f))

    assert confirmed["closure_status"] == "published"
    assert confirmed["closure_confirmed"]["digest"] == pending["closure_intent"]["digest"]
    assert closure["status"] == "confirmed"
  end

  test "a send that provably never left stays resendable" do
    f = fixture("github")

    drifting = fn provider, method, path, query, settings ->
      if path == f.path and Agent.get(f.state, & &1.reads) >= 2, do: drift_title(f, path)
      f.opts[:request].(provider, method, path, query, settings)
    end

    assert {:error, {:member_closure_not_sent, :native_snapshot_changed}} =
             TaskClosure.reconcile(f.record, flow(f.binding), Keyword.put(with_assess(f), :request, drifting))

    assert current(f)["closure_status"] == "prepared"
    refute current(f)["closure_confirmed"]
    assert writes(f) == []
  end

  defp drift_title(f, path) do
    Agent.update(f.state, &update_in(&1.objects[path], fn issue -> Map.put(issue, "title", "changed") end))
  end

  test "a read-back that does not show closure records no receipt" do
    f = fixture("github")
    pending = lost_write(f, false)
    assert {:error, :member_closure_unconfirmed} = TaskClosure.reconcile(pending, flow(f.binding), with_assess(f))
    refute current(f)["closure_confirmed"]
    assert writes(f) == []
  end

  test "an already closed native Issue is never re-closed and an unstarted intent is never adopted" do
    f = fixture("github")
    set_object(f, %{"state" => "closed"})

    assert {:error, :member_closure_issue_already_closed} =
             TaskClosure.reconcile(f.record, flow(f.binding), with_assess(f))

    assert writes(f) == []
    refute current(f)["closure_confirmed"]
  end

  # C2: an abandoned fence is recovered only with proof, and never with a write.
  test "a fence abandoned by a provably dead reconciler is recovered by reading back" do
    f = fixture("github")
    pending = lost_write(f, true)
    lock = locked(pending, %{"os_pid" => dead_pid()})
    File.write!(Path.join(lock, "reconcile-owner"), "1")

    assert {:ok, %{record: confirmed, closure: closure}} =
             TaskClosure.reconcile(pending, flow(f.binding), with_assess(f))

    assert confirmed["closure_status"] == "published"
    assert confirmed["closure_confirmed"]["digest"] == confirmed["closure_intent"]["digest"]
    assert closure["status"] == "confirmed"
    assert writes(f) == []
    refute File.exists?(Path.join(f.record["directory"], "executor.lock"))
  end

  test "a killed reconciler in the same VM releases its fence for read-back recovery" do
    f = fixture("github")
    pending = lost_write(f, true)
    parent = self()

    {owner, monitor} =
      spawn_monitor(fn ->
        TaskClosure.with_fence(pending, f.opts, fn ->
          send(parent, {:fence_held, self()})

          receive do
            :release -> :ok
          end
        end)
      end)

    assert_receive {:fence_held, ^owner}
    assert {:error, :member_closure_executor_locked} = TaskClosure.reconcile(pending, flow(f.binding), with_assess(f))

    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}

    assert {:ok, %{record: confirmed, closure: closure}} =
             TaskClosure.reconcile(pending, flow(f.binding), with_assess(f))

    assert confirmed["closure_status"] == "published"
    assert closure["status"] == "confirmed"
    assert writes(f) == []
    refute File.exists?(Path.join(f.record["directory"], "executor.lock"))
  end

  test "a fence whose owner is live or unprovable is never taken over" do
    f = fixture("github")
    lock = locked(f.record)
    assert {:error, :member_closure_executor_locked} = TaskClosure.reconcile(f.record, flow(f.binding), with_assess(f))

    File.rm!(Path.join(lock, "reconcile-owner.json"))

    assert {:error, :member_closure_owner_unconfirmed} =
             TaskClosure.reconcile(f.record, flow(f.binding), with_assess(f))

    File.write!(Path.join(lock, "reconcile-owner.json"), Jason.encode!(%{"kind" => "closure-reconciler", "os_pid" => "1", "node" => "other@host"}))

    assert {:error, :member_closure_owner_unconfirmed} =
             TaskClosure.reconcile(f.record, flow(f.binding), with_assess(f))

    assert writes(f) == []
  end

  test "a malformed local Erlang PID cannot prove the fence owner has died" do
    f = fixture("github")
    lock = locked(f.record, %{"erlang_pid" => "not-a-pid"})

    assert {:error, :member_closure_owner_unconfirmed} =
             TaskClosure.with_fence(f.record, f.opts, fn -> flunk("malformed owner took the fence") end)

    assert File.exists?(Path.join(lock, "reconcile-owner.json"))
    assert writes(f) == []
  end

  test "a stale fence with a durable sending intent is taken over without a second write" do
    f = fixture("github")
    pending = lost_write(f, true)
    lock = locked(pending, %{"os_pid" => "1", "node" => "other@host"})
    File.write!(Path.join(lock, "reconcile-owner"), "1")

    opts = Keyword.put(with_assess(f), :closure_lock_stale_ms, 0)
    assert {:ok, %{record: confirmed}} = TaskClosure.reconcile(pending, flow(f.binding), opts)
    assert confirmed["closure_status"] == "published"
    assert writes(f) == []
  end

  # A reconciler killed between the fence and its ownership record never wrote
  # the durable intent, so no native side effect can have been lost.
  test "an ownerless stale fence is taken over and the member is closed exactly once" do
    f = fixture("github")
    lock = Path.join(f.record["directory"], "executor.lock")
    File.mkdir_p!(lock)
    opts = Keyword.put(with_assess(f), :closure_lock_stale_ms, 0)

    assert {:ok, %{record: confirmed, closure: closure}} = TaskClosure.reconcile(f.record, flow(f.binding), opts)
    assert confirmed["closure_status"] == "published"
    assert closure["status"] == "confirmed"
    assert length(writes(f)) == 1
    refute File.exists?(lock)
  end

  # A lost response: the native object moved, but the response never arrived.
  defp lost_response(f, path, true) do
    Agent.update(f.state, &%{&1 | objects: Map.put(&1.objects, path, Map.put(&1.objects[path], "state", "closed"))})
    {:error, :lost_response}
  end

  defp lost_response(_f, _path, false), do: {:error, :lost_response}

  # A lost response with the durable intent already saved: `close` proves the
  # native write happened, `open` proves this attempt never left.
  defp lost_write(f, close?) do
    writer = fn "github", "PATCH", path, _query, _body, _settings -> lost_response(f, path, close?) end

    assert {:error, {:member_closure_send_unconfirmed, :native_write_failed}} =
             TaskClosure.reconcile(f.record, flow(f.binding), Keyword.put(with_assess(f), :write_request, writer))

    pending = current(f)
    assert pending["closure_status"] == "sending"
    refute pending["closure_confirmed"]
    pending
  end

  test "the held execution lock, a foreign attempt or a missing journal never closes anything" do
    f = fixture("github")

    lock = Path.join(f.record["directory"], "executor.lock")
    File.mkdir_p!(lock)
    File.write!(Path.join(lock, "executor-owner.json"), Jason.encode!(%{"attempt_id" => f.record["attempt_id"]}))
    assert {:error, :member_closure_executor_locked} = TaskClosure.reconcile(f.record, flow(f.binding), with_assess(f))
    File.rm!(Path.join(lock, "executor-owner.json"))
    File.rmdir!(lock)

    foreign = Map.put(f.record, "execution_generation", (f.record["execution_generation"] || 0) + 1)
    assert {:error, :member_closure_attempt_changed} = TaskClosure.reconcile(foreign, flow(f.binding), with_assess(f))

    missing = %{f.record | "directory" => Path.join(f.root, "missing")}

    assert {:error, {:member_closure_lock_failed, :enoent}} =
             TaskClosure.reconcile(missing, flow(f.binding), with_assess(f))

    empty = Path.join(f.root, "empty")
    File.mkdir_p!(empty)
    empty_record = %{f.record | "directory" => empty}

    assert {:error, :member_closure_attempt_unavailable} =
             TaskClosure.reconcile(empty_record, flow(f.binding), with_assess(f))

    assert writes(f) == []
  end

  # C3: a receipt is history, not the current native fact.
  test "a manual reopen is reported instead of being masked by the receipt" do
    f = fixture("github")
    assert {:ok, %{record: confirmed}} = TaskClosure.reconcile(f.record, flow(f.binding), with_assess(f))
    set_object(f, %{"state" => "open"})

    assert {:ok, %{record: ^confirmed, closure: closure}} =
             TaskClosure.reconcile(confirmed, flow(f.binding), with_assess(f))

    assert closure["status"] == "reopened"
    assert closure["native_state"] == "open"
    assert closure["receipt"] == confirmed["closure_confirmed"]
    assert length(writes(f)) == 1
  end

  test "an unreadable current state stays unknown and never claims closure" do
    f = fixture("github")
    assert {:ok, %{record: confirmed}} = TaskClosure.reconcile(f.record, flow(f.binding), with_assess(f))
    failing = Keyword.put(f.opts, :request, fn _p, _m, _path, _q, _s -> {:ok, %{status: 500, body: %{}}} end)

    assert {:ok, %{closure: closure}} = TaskClosure.reconcile(confirmed, flow(f.binding), failing)
    assert closure["status"] == "unconfirmed"
    assert closure["native_state"] == "unknown"
    assert closure["receipt"] == confirmed["closure_confirmed"]
  end

  test "the fence releases after exceptions and preserves replacement ownership" do
    f = fixture("github")
    lock = Path.join(f.record["directory"], "executor.lock")

    assert_raise RuntimeError, "interrupted", fn ->
      TaskClosure.with_fence(f.record, f.opts, fn -> raise "interrupted" end)
    end

    refute File.exists?(lock)

    assert :replaced =
             TaskClosure.with_fence(f.record, f.opts, fn ->
               File.write!(Path.join(lock, "reconcile-owner.json"), Jason.encode!(%{"os_pid" => "replacement"}))
               :replaced
             end)

    assert File.exists?(lock)

    assert {:error, :member_closure_owner_unconfirmed} =
             TaskClosure.with_fence(f.record, f.opts, fn -> flunk("unowned callback ran") end)
  end

  test "missing and malformed assessments cannot authorize a native close" do
    f = fixture("github")

    for opts <- [f.opts, Keyword.put(f.opts, :reobserve, fn -> {:ok, %{flow: %{}, record: nil, snapshot: %{}}} end)] do
      assert {:error, :member_closure_assessment_unavailable} =
               TaskClosure.reconcile(f.record, flow(f.binding), opts)
    end

    assert writes(f) == []
  end

  test "a missing durable intent preserves an unreadable native fact as unknown" do
    f = fixture("gitlab")
    record = stage(f.record, %{"closure_status" => "sending"})
    {:ok, assessment} = assess(f, %{})

    opts =
      f.opts
      |> Keyword.put(:reobserve, fn -> {:ok, assessment} end)
      |> Keyword.put(:request, fn _, _, _, _, _ -> {:error, :offline} end)

    assert {:error, :member_closure_intent_missing} = TaskClosure.reconcile(record, flow(f.binding), opts)
    assert current(f)["closure_status"] == "inconsistent"
    assert current(f)["closure_current"]["state"] == "unknown"
    assert writes(f) == []
  end

  test "a lost journal owner after native close cannot publish a receipt" do
    for provider <- ["github", "gitlab"] do
      f = fixture(provider)
      counter = start_supervised!({Agent, fn -> 0 end}, id: make_ref())

      reobserve = fn ->
        result = assess(f, %{})
        call = Agent.get_and_update(counter, &{&1, &1 + 1})
        if call == 1, do: File.rm!(Path.join([f.record["directory"], "executor.lock", "reconcile-owner"]))
        result
      end

      assert {:error, {:member_closure_receipt_unavailable, _reason}} =
               TaskClosure.reconcile(f.record, flow(f.binding), Keyword.put(f.opts, :reobserve, reobserve))

      assert object(f)["state"] == "closed"
      assert length(writes(f)) == 1
      assert current(f)["closure_status"] == "sending"
      refute current(f)["closure_confirmed"]
    end
  end

  test "corrupt abandoned ownership can recover but an unwritable claim cannot run" do
    f = fixture("github")
    lock = locked(f.record)
    File.write!(Path.join(lock, "reconcile-owner.json"), "invalid json")
    opts = Keyword.put(f.opts, :closure_lock_stale_ms, 0)
    assert :recovered = TaskClosure.with_fence(f.record, opts, fn -> :recovered end)
    refute File.exists?(lock)

    File.mkdir_p!(Path.join(lock, "reconcile-owner.json.claim"))

    assert {:error, :member_closure_lock_not_owned} =
             TaskClosure.with_fence(f.record, opts, fn -> flunk("failed claim ran") end)

    assert writes(f) == []
  end

  test "fresh or invalid-age fences and a different live process remain protected" do
    f = fixture("gitlab")
    lock = Path.join(f.record["directory"], "executor.lock")
    File.mkdir_p!(lock)

    for age <- [-1, 86_400_000] do
      assert {:error, :member_closure_owner_unconfirmed} =
               TaskClosure.with_fence(f.record, [closure_lock_stale_ms: age], fn -> flunk("fresh fence ran") end)
    end

    File.write!(Path.join(lock, "reconcile-owner.json"), Jason.encode!(owner_record(f.record, %{"os_pid" => "1"})))

    assert {:error, :member_closure_owner_unconfirmed} =
             TaskClosure.with_fence(f.record, [], fn -> flunk("live process fence ran") end)

    assert File.exists?(lock)
  end

  test "projection preserves closed native evidence without a valid flow" do
    assert %{"status" => "not_applicable", "native_state" => "closed"} =
             TaskClosure.project(nil, nil, %{raw: %{"state" => "closed"}}, [])
  end

  describe "read-only projection" do
    test "reports the versioned state of a member without touching the tracker" do
      f = fixture("github")
      {:ok, snapshot} = NativeWork.read(f.work, f.opts)

      assert TaskClosure.project(nil, flow(f.binding), snapshot, f.opts)["status"] == "unconfirmed"
      assert TaskClosure.project(nil, flow(f.binding), snapshot, f.opts)["reason"] == "member_closure_journal_missing"
      assert TaskClosure.project(f.record, flow(f.binding, %{"closeable" => false}), snapshot, f.opts)["status"] == "not_applicable"
      assert TaskClosure.project(f.record, flow(f.binding), snapshot, f.opts)["status"] == "unconfirmed"
      assert TaskClosure.project(f.record, flow(f.binding), nil, f.opts)["native_state"] == "unknown"

      assert {:ok, %{record: confirmed}} = TaskClosure.reconcile(f.record, flow(f.binding), with_assess(f))
      project = TaskClosure.project(confirmed, flow(f.binding), snapshot, f.opts)
      assert project["status"] == "confirmed"
      assert project["native_state"] == "closed"
      assert writes(f) == [%{"method" => "PATCH", "path" => f.path, "query" => %{}, "body" => %{"state" => "closed"}}]
    end
  end
end
