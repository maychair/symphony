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

    try do
      {:ok, updated} = RunJournal.checkpoint(record, changes)
      updated
    after
      File.rm(Path.join(lock, "reconcile-owner"))
      File.rmdir(lock)
    end
  end

  defp writes(fixture), do: Agent.get(fixture.state, & &1.writes)
  defp object(fixture), do: Agent.get(fixture.state, & &1.objects[fixture.path])
  defp set_object(fixture, changes), do: Agent.update(fixture.state, &put_in(&1.objects[fixture.path], Map.merge(&1.objects[fixture.path], changes)))

  defp drifting_request(fixture) do
    fn provider, method, path, query, settings ->
      if path == fixture.path and Agent.get(fixture.state, & &1.reads) >= 2,
        do: drift_title(fixture, path)

      fixture.opts[:request].(provider, method, path, query, settings)
    end
  end

  defp drift_title(fixture, path) do
    update = fn issue -> Map.put(issue, "title", "changed") end
    Agent.update(fixture.state, &update_in(&1.objects[path], update))
  end

  test "a delivered member closes its native Issue once and records intent and receipt" do
    for provider <- ["github", "gitlab"] do
      f = fixture(provider)
      assert {:ok, confirmed} = TaskClosure.reconcile(f.record, flow(f.binding), f.opts)
      assert confirmed["closure_status"] == "published"
      assert confirmed["closure_intent"]["digest"] == confirmed["closure_confirmed"]["digest"]
      assert confirmed["closure_intent"]["candidate"] == TaskWorkflow.digest("candidate")
      assert confirmed["closure_confirmed"]["source"] =~ "issue:"
      assert object(f)["state"] == "closed"

      {method, body} = if provider == "github", do: {"PATCH", %{"state" => "closed"}}, else: {"PUT", %{"state_event" => "close"}}
      path = f.path
      assert [%{"method" => ^method, "path" => ^path, "query" => %{}, "body" => ^body}] = writes(f)
    end
  end

  test "a confirmed closure is never written twice" do
    f = fixture("github")
    assert {:ok, confirmed} = TaskClosure.reconcile(f.record, flow(f.binding), f.opts)
    assert {:ok, ^confirmed} = TaskClosure.reconcile(confirmed, flow(f.binding), f.opts)
    assert length(writes(f)) == 1
  end

  # A projection can race the reconciler: it reads the journal before the
  # receipt lands, then takes the lock after another poll already published.
  # The locked read must adopt the durable receipt instead of writing again.
  test "a stale projection adopts a confirmed receipt without a second write" do
    f = fixture("github")
    assert {:ok, confirmed} = TaskClosure.reconcile(f.record, flow(f.binding), f.opts)
    stale = Map.put(f.record, "closure_status", "sending")
    assert {:ok, adopted} = TaskClosure.reconcile(stale, flow(f.binding), f.opts)
    assert adopted["closure_confirmed"] == confirmed["closure_confirmed"]
    assert length(writes(f)) == 1
  end

  test "a delivered record that does not bind the tracked Issue stays open" do
    f = fixture("github")
    foreign = Map.put(f.record, "issue_id", "issue:other")
    assert TaskClosure.reconcile(foreign, flow(f.binding), f.opts) == :not_applicable
    wrongly_typed = put_in(f.record, ["execution_binding", "work", "kind"], "mr")
    assert TaskClosure.reconcile(wrongly_typed, flow(f.binding), f.opts) == :not_applicable
    assert writes(f) == []
  end

  test "an undelivered or unbound member is never closed" do
    f = fixture("github")
    assert TaskClosure.reconcile(f.record, flow(f.binding, %{"closeable" => false}), f.opts) == :not_applicable
    assert TaskClosure.reconcile(f.record, flow(f.binding, %{"phase" => "verified"}), f.opts) == :not_applicable
    assert TaskClosure.reconcile(f.record, flow(f.binding, %{"outcome" => "open"}), f.opts) == :not_applicable
    assert TaskClosure.reconcile(f.record, flow(f.binding, %{"execution" => "active"}), f.opts) == :not_applicable
    assert TaskClosure.reconcile(f.record, "not-a-flow", f.opts) == :not_applicable
    assert TaskClosure.reconcile(%{"execution_binding" => %{}}, flow(f.binding), f.opts) == :not_applicable
    assert writes(f) == []
  end

  test "an uncertain send keeps the durable intent without recording closure" do
    f = fixture("github")

    uncertain = fn "github", "PATCH", path, _query, _body, _settings ->
      Agent.update(f.state, &update_in(&1.objects[path], fn issue -> Map.put(issue, "state", "closed") end))
      {:error, :lost_response}
    end

    assert {:error, {:member_closure_send_unconfirmed, :native_write_failed}} =
             TaskClosure.reconcile(f.record, flow(f.binding), Keyword.put(f.opts, :write_request, uncertain))

    assert {:ok, pending} = RunJournal.read(f.record["directory"])
    assert pending["closure_status"] == "sending"
    refute pending["closure_confirmed"]

    assert {:ok, confirmed} = TaskClosure.reconcile(pending, flow(f.binding), f.opts)
    assert confirmed["closure_status"] == "published"
    assert confirmed["closure_confirmed"]["digest"] == pending["closure_intent"]["digest"]
  end

  test "a send that provably never left stays resendable" do
    f = fixture("github")

    assert {:error, {:member_closure_not_sent, :native_snapshot_changed}} =
             TaskClosure.reconcile(f.record, flow(f.binding), Keyword.put(f.opts, :request, drifting_request(f)))

    assert {:ok, current} = RunJournal.read(f.record["directory"])
    assert current["closure_status"] == "prepared"
    refute current["closure_confirmed"]
    assert writes(f) == []
  end

  test "a read-back that does not show closure records no receipt" do
    f = fixture("github")
    current = stage(f.record, %{"closure_status" => "sending"})
    assert {:error, :member_closure_unconfirmed} = TaskClosure.reconcile(current, flow(f.binding), f.opts)
    assert {:ok, after_read} = RunJournal.read(f.record["directory"])
    refute after_read["closure_confirmed"]
    assert writes(f) == []
  end

  test "an already closed native Issue is never re-closed and an unstarted intent is never adopted" do
    f = fixture("github")
    set_object(f, %{"state" => "closed"})
    assert {:error, :member_closure_issue_already_closed} = TaskClosure.reconcile(f.record, flow(f.binding), f.opts)
    assert writes(f) == []
    assert {:ok, current} = RunJournal.read(f.record["directory"])
    refute current["closure_confirmed"]
  end

  test "the held execution lock, a foreign attempt or a missing journal never closes anything" do
    f = fixture("github")

    lock = Path.join(f.record["directory"], "executor.lock")
    File.mkdir_p!(lock)
    assert {:error, :member_closure_executor_locked} = TaskClosure.reconcile(f.record, flow(f.binding), f.opts)
    File.rmdir!(lock)

    foreign = Map.put(f.record, "execution_generation", (f.record["execution_generation"] || 0) + 1)
    assert {:error, :member_closure_attempt_changed} = TaskClosure.reconcile(foreign, flow(f.binding), f.opts)

    missing = %{f.record | "directory" => Path.join(f.root, "missing")}
    assert {:error, {:member_closure_lock_failed, :enoent}} = TaskClosure.reconcile(missing, flow(f.binding), f.opts)

    empty = Path.join(f.root, "empty")
    File.mkdir_p!(empty)
    empty_record = %{f.record | "directory" => empty}
    assert {:error, :member_closure_attempt_unavailable} = TaskClosure.reconcile(empty_record, flow(f.binding), f.opts)
    assert writes(f) == []
  end

  test "the native close primitive refuses a non-Issue, a closed snapshot and a drifted snapshot" do
    f = fixture("gitlab")
    assert {:ok, snapshot} = NativeWork.read(f.work, f.opts)
    assert {:not_sent, :native_issue_not_open} = NativeWork.close(%{snapshot | raw: Map.put(snapshot.raw, "state", "closed")}, f.opts)
    assert {:not_sent, :expected_issue} = NativeWork.close(%{snapshot | work: Map.put(snapshot.work, "kind", "mr")}, f.opts)
    assert {:not_sent, :invalid_native_closure} = NativeWork.close(%{snapshot | raw: nil}, f.opts)
    assert {:not_sent, :invalid_native_closure} = NativeWork.close("not-a-snapshot", f.opts)
    assert {:not_sent, :invalid_native_closure} = NativeWork.close("not-a-snapshot")
    assert {:not_sent, :unregistered_plan_repository} = NativeWork.close(snapshot, Keyword.put(f.opts, :repositories, []))

    set_object(f, %{"title" => "changed"})
    assert {:not_sent, :native_snapshot_changed} = NativeWork.close(snapshot, f.opts)
    assert {:ok, current} = NativeWork.read(f.work, f.opts)
    assert :sent = NativeWork.close(current, f.opts)
    assert [%{"method" => "PUT", "body" => %{"state_event" => "close"}}] = writes(f)

    other = fixture("gitlab")
    assert {:ok, live} = NativeWork.read(other.work, other.opts)
    rejected = fn _, _, _, _, _, _ -> {:ok, %{status: 409, body: %{}}} end

    assert {:uncertain, {:native_write_status, 409}} =
             NativeWork.close(live, Keyword.put(other.opts, :write_request, rejected))
  end
end
