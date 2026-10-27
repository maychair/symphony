defmodule SymphonyElixir.ReviewLaneLifecycleTest do
  use SymphonyElixir.TestSupport, runtime: false
  alias SymphonyElixir.ReviewLane.{Listener, Runner}
  alias SymphonyElixir.Taskboard.Reviews
  alias SymphonyElixirWeb.WebhookController

  defmodule FencedBackend do
    def start_session(root, opts) do
      :ok = opts[:on_thread_intent].()
      :ok = opts[:on_thread_started].("fenced-fixture-thread")
      {:ok, %{workspace: root}}
    end

    def run_turn(_session, _prompt, issue, opts) do
      :ok = opts[:before_turn].()
      opts[:on_message].(%{event: :session_started, turn_id: "fenced-fixture-turn"})
      :ok = Listener.checkpoint(issue.id, issue.native_ref["execution_owner"], %{"phase" => "fenced"})
      SymphonyElixir.WorkflowSession.execute_agent_tool("workflow_submit", %{"result" => %{"opaque" => true}}, [])
      {:ok, %{}}
    end

    def confirm_session(_), do: :ok
    def stop_session(_), do: send(self(), :backend_stopped)
  end

  setup test_context do
    root = Path.dirname(Workflow.workflow_file_path())
    Supervisor.terminate_child(SymphonyElixir.Supervisor, Listener)

    on_exit(fn ->
      write_workflow_file!(Path.join(root, "WORKFLOW.md"), tracker_kind: "memory")
      Supervisor.restart_child(SymphonyElixir.Supervisor, Listener)
    end)

    fixture = Path.join(root, "fixture")
    File.mkdir_p!(Path.join(root, "source"))
    File.write!(Path.join(root, "instructions"), "## Common\nRead all evidence.\n## Standards\nRead standards.\n## Spec\nVerify requirements.\n")
    File.write!(Path.join(root, "discussions.json"), "[]")

    File.write!(fixture, """
    #!/usr/bin/env python3
    import sys,json,pathlib,time
    r=pathlib.Path(#{inspect(root)});a=sys.argv[1:];name=pathlib.Path(sys.argv[0]).name
    path=a[a.index('--method')+2];method=a[a.index('--method')+1]
    if method=='GET' and (r/'hold-scan').exists():
      (r/'scan-held').write_text('ready');deadline=time.monotonic()+15
      while not (r/'release-scan').exists() and time.monotonic()<deadline:time.sleep(0.01)
      assert (r/'release-scan').exists()
    if (r/'responses.json').exists():
      responses=json.loads((r/'responses.json').read_text())
      key=method+' '+path
      if key in responses:
        if responses[key]=='EXIT':sys.exit(3)
        print(json.dumps(responses[key]));sys.exit(0)
    if method=='GET' and '/discussions' in path and (r/'fail-read').exists():
      (r/'fail-read').unlink();sys.exit(3)
    ds=json.loads((r/'discussions.json').read_text())
    if path=='user':out={'id':20,'username':'reviewer'}
    elif '/discussions' in path:
      assert method=='GET', 'Scheduler attempted publication'
      out=ds
    else:out={'id':1001,'project_id':10,'iid':1,'state':'opened','sha':('c' if (r/'changed-head').exists() else 'a')*40,'diff_refs':{'base_sha':'b'*40},'target_branch':('release' if (r/'changed-target').exists() else 'main'),'author':{'id':30},'reviewers':[{'id':20,'username':'reviewer'}],'web_url':'https://review.invalid/team/repo/-/merge_requests/1'}
    if path=='projects/team%2Frepo':out={'id':10,'path_with_namespace':'team/repo','web_url':'https://review.invalid/team/repo'}
    elif '/merge_requests?' in path:out=[out]
    print(json.dumps(out))
    """)

    File.chmod!(fixture, 0o755)
    File.ln_s!(fixture, Path.join(root, "glab"))

    if test_context[:native_review] do
      File.write!(Path.join(root, "responses.json"), Jason.encode!(%{"GET projects/team%2Frepo/merge_requests?reviewer_id=20&scope=all&state=opened&per_page=100&page=1" => []}))
    end

    config = %{
      "enabled" => true,
      "publish_results" => test_context[:local_review] != true,
      "host" => "review.invalid",
      "provider" => "gitlab",
      "reviewer_id" => 20,
      "publisher_id" => 20,
      "projects" => %{"team/repo" => %{"id" => 10, "checkout" => Path.join(root, "source")}},
      "state_dir" => Path.join(root, "state"),
      "instruction_files" => [Path.join(root, "instructions")],
      "result_command" => SymphonyElixir.TestSupport.workflow_result_command(),
      "glab_bin" => Path.join(root, "glab")
    }

    File.write!(Workflow.workflow_file_path(), """
    ---
    tracker:
      kind: memory
      required_labels: [symphony]
      active_states: [open, in_progress]
      terminal_states: [closed]
    ---
    Review task
    """)

    :ok = WorkflowStore.force_reload()
    start_supervised!({Listener, config: config})
    await_listener()
    {:ok, root: root, config: config}
  end

  test "a current canonical review does not requeue after its shared policy changes", c do
    {:ok, [issue]} = Listener.issues()
    {:ok, _, _} = Listener.begin_run(issue.id)
    :ok = owned_submit(issue.id, %{"findings" => []})
    :ok = owned_checkpoint(issue.id, %{"native_stop_confirmed" => true})
    File.write!(hd(c.config["instruction_files"]), "\nUpdated current criteria.\n", [:append])
    assert {:ok, [retained]} = Listener.issues()
    assert retained.native_ref["round"] == 1
    assert retained.native_ref["eligibility"] == "superseded"
    refute retained.dispatchable
  end

  test "board reads never discover, requeue or publish a review", c do
    [_record] = await_board_records()
    journal = File.read!(Path.join(c.root, "state/review-lane.json"))
    File.write!(Path.join(c.root, "changed-head"), "new version")

    for _ <- 1..3 do
      assert {:ok, %{records: [record]}} = Listener.board_snapshot()
      assert record["round"] == 1
      assert record["head"] == String.duplicate("a", 40)
    end

    assert File.read!(Path.join(c.root, "state/review-lane.json")) == journal
    refute File.exists?(Path.join(c.root, "posts.json"))
    start_supervised!({SymphonyElixir.HttpServer, port: 0})
    conn = SymphonyElixirWeb.TaskboardApiController.state(Plug.Test.conn(:get, "/api/v1/taskboard"), %{})
    payload = Jason.decode!(conn.resp_body)
    assert [card] = Enum.filter(payload["cards"], &(&1["item_type"] == "review"))
    assert card["review"]["round"] == 1
    assert card["column"] == "Todo"
    assert File.read!(Path.join(c.root, "state/review-lane.json")) == journal
    {:ok, _} = Listener.issues()
    assert {:ok, %{records: [record]}} = Listener.board_snapshot()
    assert record["round"] == 1
    assert record["eligibility"] == "superseded"
  end

  test "live disabled suppresses MR discovery and queued admission without disabling Issue discovery", c do
    {:ok, [issue]} = Listener.issues()
    pid = Process.whereis(Listener)
    live_disabled(c, true)
    assert Process.whereis(Listener) == pid
    assert %{health: :disabled} = Listener.health()
    ordinary = %Issue{id: "ordinary", identifier: "ISSUE-1", state: "open", title: "Ordinary Issue"}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [ordinary])
    assert {:ok, candidates} = Tracker.fetch_issues_by_states(["open", "in_progress"])
    assert ordinary in candidates
    assert [queued] = Enum.filter(candidates, &(&1.id == issue.id))
    refute queued.dispatchable
    assert {:error, :review_discovery_disabled} = Listener.begin_run(issue.id)
    assert :ok = Listener.request_review("team/repo", 2)
    send(pid, :poll)
    assert %{health: :disabled, pending_hints: 0, error: nil} = Listener.health()
    assert {:ok, %{records: [record]}} = Listener.board_snapshot()
    assert record["id"] == issue.native_ref["id"]
    refute record["thread_allocation_intent"]

    live_disabled(c, false, true)
    assert {:ok, [enabled]} = Listener.issues()
    assert enabled.dispatchable
    assert Process.whereis(Listener) == pid
    assert {:ok, _, _} = Listener.begin_run(issue.id)
  end

  test "MR disabled retains running ownership and result recording but does not queue a follow-up", c do
    {:ok, [issue]} = Listener.issues()
    assert {:ok, started, _} = Listener.begin_run(issue.id)
    live_disabled(c, true)
    assert {:ok, [running]} = Listener.issues()
    assert running.dispatchable
    assert running.native_ref["execution_owner"] == started["execution_owner"]
    refute_received :symphony_stop
    assert :ok = owned_submit(issue.id, %{"findings" => []})
    assert :ok = owned_checkpoint(issue.id, %{"native_stop_confirmed" => true})
    assert {:ok, [completed]} = Listener.issues()
    assert completed.native_ref["phase"] == "completed"
    refute File.exists?(Path.join(c.root, "posts.json"))
    File.write!(Path.join(c.root, "changed-head"), "new revision")
    assert {:ok, [retained]} = Listener.issues()
    assert retained.native_ref["round"] == 1
    refute retained.dispatchable
    refute File.exists?(Path.join(c.root, "posts.json"))
    live_disabled(c, false)
    assert {:ok, [still_retained]} = Listener.issues()
    assert still_retained.native_ref["round"] == 1
    refute still_retained.dispatchable
  end

  defp live_disabled(c, disabled, tracker_disabled \\ false) do
    config = Map.put(c.config, "disabled", disabled)

    File.write!(Workflow.workflow_file_path(), """
    ---
    tracker:
      kind: memory
      disabled: #{tracker_disabled}
      required_labels: [symphony]
      active_states: [open, in_progress]
      terminal_states: [closed]
      provider:
        review_lane: #{Jason.encode!(config)}
    ---
    Review fixture
    """)

    :ok = WorkflowStore.force_reload()
  end

  test "a slow listener produces a board error without killing its controller" do
    records = await_board_records()
    pid = Process.whereis(Listener)
    :sys.suspend(pid)

    try do
      assert {:error, :automatic_review_snapshot_unavailable} = Reviews.snapshot()
    after
      :sys.resume(pid)
    end

    assert {:ok, %{records: ^records}} = Listener.board_snapshot()
    assert Process.alive?(pid)
  end

  test "a board read refuses changed configuration without suspending execution", c do
    await_board_records()
    before = :sys.get_state(Listener)
    :sys.replace_state(Listener, &%{&1 | initial_config: nil})
    assert {:error, :review_lane_configuration_changed_restart_required} = Listener.board_snapshot()
    after_read = :sys.get_state(Listener)
    assert after_read.health == before.health
    assert after_read.records == before.records
    :sys.replace_state(Listener, &%{&1 | initial_config: c.config})
  end

  defp await_board_records(attempts \\ 500)
  defp await_board_records(0), do: flunk("initial automatic discovery did not finish")

  defp await_board_records(attempts) do
    case Listener.board_snapshot() do
      {:ok, %{records: []}} ->
        Process.sleep(10)
        await_board_records(attempts - 1)

      {:ok, %{records: records}} ->
        records
    end
  end

  test "worker checkpoints reject axis internals and preserve the native session identity", c do
    {:ok, [issue]} = Listener.issues()
    {:ok, record, _} = Listener.begin_run(issue.id)
    owner = record["execution_owner"]
    assert {:error, :invalid_review_checkpoint} = Listener.checkpoint(issue.id, owner, %{"axes" => %{}})
    assert :ok = Listener.checkpoint(issue.id, owner, %{"thread_allocation_intent" => true})
    assert :ok = Listener.checkpoint(issue.id, owner, %{"thread_id" => "pinned", "workspace" => c.root})
    assert {:error, :invalid_review_checkpoint} = Listener.checkpoint(issue.id, owner, %{"thread_id" => "foreign"})
    assert :ok = Listener.checkpoint(issue.id, owner, %{"native_stop_confirmed" => true})
    assert {:error, :invalid_review_checkpoint} = Listener.checkpoint(issue.id, owner, %{"native_stop_confirmed" => false})
  end

  @tag native_review: true
  test "an unavailable Listener eventually fences its worker without allocating replacements", c do
    %{issue: issue} = runner_fixture(c)
    File.write!(Path.join(c.root, "hang"), "true")
    recipient = self()
    {pid, ref} = spawn_monitor(fn -> Runner.run(issue, recipient) end)
    assert_receive {:codex_worker_update, _, %{event: :session_started}}, 5_000
    stop_supervised!(Listener)
    send(pid, :symphony_stop)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 8_000
    start_supervised!({Listener, config: c.config})
    await_listener()
    assert {:ok, [fenced]} = Listener.issues()
    assert fenced.native_ref["phase"] == "fenced"
    refute fenced.native_ref["native_stop_confirmed"]
    refute "thread/resume" in native_methods(c)
  end

  test "a second Listener cannot discover or write through an already owned journal", c do
    {:ok, [_]} = Listener.issues()
    path = Path.join(c.config["state_dir"], "review-lane.json")
    before = File.read!(path)
    options = [config: c.config, name: :review_contender]
    contender = start_supervised!(Supervisor.child_spec({Listener, options}, id: :review_contender))
    send(contender, :configure)
    assert %{health: :failed, error: error} = GenServer.call(contender, :health)
    assert error =~ "review_journal_locked"
    assert {:ok, []} = GenServer.call(contender, :issues)
    assert File.read!(path) == before
    copied = :sys.get_state(Listener)

    assert {:stop, {:review_journal_lost, :review_journal_not_owned}, {:error, :review_journal_not_owned}, ^copied} =
             Listener.handle_call(:issues, self(), copied)

    assert catch_exit(Listener.handle_info(:poll, copied)) == {:review_journal_lost, :review_journal_not_owned}
    assert :ok = Listener.request_review("team/repo", 1)
    assert Listener.health().health == :listening
    send(Listener, :configure)
    assert Listener.health().health == :listening
  end

  @tag capture_log: true
  test "broker death terminates its Listener and a confirmed dead controller can restart", c do
    config = Map.put(c.config, "state_dir", Path.join(c.root, "separate-state"))
    {:ok, pid} = GenServer.start(Listener, config: config)
    send(pid, :configure)
    assert %{health: :listening} = GenServer.call(pid, :health)
    assert {:ok, [_]} = GenServer.call(pid, :issues)
    state = :sys.get_state(pid)
    {:os_pid, broker_pid} = Port.info(state.journal.port, :os_pid)
    ref = Process.monitor(pid)
    :ok = :sys.suspend(pid)
    port = state.journal.port
    port_ref = Port.monitor(port)
    assert {_, 0} = System.cmd("kill", ["-KILL", to_string(broker_pid)])
    assert_receive {:DOWN, ^port_ref, :port, ^port, _}, 2_000
    :ok = :sys.resume(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, {:review_journal_lost, _}}, 2_000
    {:ok, replacement} = GenServer.start(Listener, config: config)
    send(replacement, :configure)
    assert %{health: :listening} = GenServer.call(replacement, :health)
    GenServer.stop(replacement)
  end

  test "queued and running review survives repeated routing polls; completion stays durable and deduplicated", c do
    assert :ok = Listener.request_review("team/repo", 1)
    assert :ok = Listener.request_review("team/repo", 1)
    {:ok, [issue]} = Listener.issues()
    assert :ok = Listener.request_review("team/repo", 1)
    stop_supervised!(Listener)
    start_supervised!({Listener, config: c.config})
    await_listener()
    assert {:ok, _, _} = Listener.begin_run(issue.id)

    worker =
      Task.async(fn ->
        receive do
          :stop -> :ok
        end
      end)

    state = %Orchestrator.State{
      running: %{issue.id => %{pid: worker.pid, ref: worker.ref, issue: issue, identifier: issue.identifier}},
      claimed: MapSet.new([issue.id])
    }

    Enum.reduce(1..4, state, fn _, state ->
      {:ok, [active]} = Listener.issues()
      assert Issue.routable?(active, ["symphony"])
      next = Orchestrator.reconcile_issue_states_for_test([active], state)
      assert Map.has_key?(next.running, issue.id)
      assert Process.alive?(worker.pid)
      next
    end)

    send(worker.pid, :stop)
    Task.await(worker)
    assert :ok = owned_submit(issue.id, %{"findings" => []})
    :ok = owned_checkpoint(issue.id, %{"native_stop_confirmed" => true})
    {:ok, [done]} = Listener.issues()
    assert done.native_ref["phase"] == "completed"
    refute Issue.routable?(done, ["symphony"])
    stop_supervised!(Listener)
    start_supervised!({Listener, config: c.config})
    await_listener()
    assert :ok = Listener.request_review("team/repo", 1)
    {:ok, [restored]} = Listener.issues()
    assert restored.native_ref["phase"] == "completed"
    assert Jason.decode!(File.read!(Path.join(c.root, "discussions.json"))) == []
    assert :ok = owned_checkpoint(issue.id, %{"phase" => "failed", "error" => "late worker DOWN"})
    {:ok, [still_done]} = Listener.issues()
    assert still_done.native_ref["phase"] == "completed"
  end

  test "restart fences active execution uncertainty instead of dispatching duplicates", c do
    assert :ok = Listener.request_review("team/repo", 1)
    {:ok, [issue]} = Listener.issues()
    assert {:ok, _, _} = Listener.begin_run(issue.id)
    assert :ok = fixture_checkpoint(issue.id, %{"thread_id" => "native-thread", "turn_id" => "native-turn", "phase" => "running"})
    stop_supervised!(Listener)
    start_supervised!({Listener, config: c.config})
    await_listener()
    {:ok, [fenced]} = Listener.issues()
    assert fenced.native_ref["phase"] == "fenced"
    assert fenced.native_ref["previous_phase"] == "running"
    assert fenced.native_ref["thread_id"] == "native-thread"
    assert_receive :symphony_stop
    assert {:error, :review_execution_fenced} = owned_checkpoint(issue.id, %{"thread_allocation_intent" => true})
    assert {:error, :review_execution_fenced} = owned_checkpoint(issue.id, %{"turn_allocation_intent" => true})
    assert {:error, :incomplete_review} = owned_submit(issue.id, %{"findings" => []})
    refute Issue.routable?(fenced, ["symphony"])
    assert {:error, :review_execution_fenced} = Listener.begin_run(issue.id)
    assert :ok = Listener.request_review("team/repo", 1)
    assert {:ok, [_]} = Listener.issues()
    assert Jason.decode!(File.read!(Path.join(c.root, "discussions.json"))) == []
  end

  test "a new push after a no-findings result does not queue a new round", c do
    {:ok, [issue]} = Listener.issues()
    {:ok, _, _} = Listener.begin_run(issue.id)
    assert :ok = owned_submit(issue.id, %{"findings" => []})
    :ok = owned_checkpoint(issue.id, %{"native_stop_confirmed" => true})
    File.write!(Path.join(c.root, "changed-head"), "new commit")
    assert {:ok, [retained]} = Listener.issues()
    assert retained.native_ref["round"] == 1
    assert retained.native_ref["eligibility"] == "superseded"
    refute retained.dispatchable
    refute File.exists?(Path.join(c.root, "posts.json"))
    assert {:error, :review_execution_fenced} = Listener.begin_run(issue.id)
  end

  test "retargeting an open review retires the old round even when head and base are unchanged", c do
    {:ok, [issue]} = Listener.issues()
    assert issue.native_ref["target_branch"] == "main"
    {:ok, _, _} = Listener.begin_run(issue.id)
    assert :ok = owned_submit(issue.id, %{"findings" => []})
    :ok = owned_checkpoint(issue.id, %{"native_stop_confirmed" => true})
    refute File.exists?(Path.join(c.root, "posts.json"))

    File.write!(Path.join(c.root, "changed-target"), "release")
    assert {:ok, [retained]} = Listener.issues()
    assert retained.native_ref["round"] == 1
    assert retained.native_ref["eligibility"] == "superseded"
    refute retained.dispatchable
    assert {:ok, [^retained]} = Listener.issues()
    refute File.exists?(Path.join(c.root, "posts.json"))
  end

  test "changed input cannot replace an unconfirmed native executor", c do
    {:ok, [issue]} = Listener.issues()
    {:ok, _, _} = Listener.begin_run(issue.id)
    :ok = owned_checkpoint(issue.id, %{"thread_allocation_intent" => true, "thread_id" => "native-running"})
    File.write!(Path.join(c.root, "changed-head"), "new commit")
    {:ok, [stopping]} = Listener.issues()
    refute stopping.dispatchable
    assert stopping.native_ref["eligibility"] == "superseded"
    :ok = owned_checkpoint(issue.id, %{"native_stop_confirmed" => true, "phase" => "failed"})
    assert {:ok, [retained]} = Listener.issues()
    assert retained.native_ref["round"] == 1
    assert retained.native_ref["eligibility"] == "superseded"
    refute retained.dispatchable
  end

  test "ending an admitted review before thread allocation cannot release its executor ownership", c do
    {:ok, [issue]} = Listener.issues()
    {:ok, record, _} = Listener.begin_run(issue.id)

    closed = %{
      "id" => 1001,
      "iid" => 1,
      "project_id" => 10,
      "state" => "closed",
      "sha" => record["head"],
      "diff_refs" => %{"base_sha" => record["base"]},
      "target_branch" => record["target_branch"],
      "author" => %{"id" => 30},
      "reviewers" => [%{"id" => 20}],
      "web_url" => record["url"]
    }

    responses(c, %{"GET projects/team%2Frepo/merge_requests/1" => closed})
    {:ok, [ended]} = Listener.issues()
    assert ended.native_ref["phase"] == "ended"
    refute ended.dispatchable
    responses(c, %{})
    {:ok, [waiting]} = Listener.issues()
    refute waiting.dispatchable
    assert waiting.id == issue.id
    assert {:error, :review_execution_fenced} = Listener.begin_run(issue.id)
    :ok = owned_checkpoint(issue.id, %{"native_stop_confirmed" => true})
    assert {:ok, [retained]} = Listener.issues()
    assert retained.native_ref["round"] == 1
    assert retained.native_ref["eligibility"] == "superseded"
    refute retained.dispatchable
  end

  test "closed, merged and explicitly unassigned native MRs end eligibility and reopening does not queue a new round", c do
    {:ok, [issue]} = Listener.issues()
    record = issue.native_ref

    mr = %{
      "id" => 1001,
      "iid" => 1,
      "project_id" => 10,
      "state" => "opened",
      "sha" => record["head"],
      "diff_refs" => %{"base_sha" => record["base"]},
      "target_branch" => record["target_branch"],
      "author" => %{"id" => 30},
      "reviewers" => [%{"id" => 20}],
      "web_url" => record["url"]
    }

    path = "GET projects/team%2Frepo/merge_requests/1"

    for {change, reason} <- [{%{"state" => "closed"}, "closed"}, {%{"state" => "merged"}, "merged"}, {%{"reviewers" => []}, "unassigned"}] do
      responses(c, %{path => Map.merge(mr, change)})
      {:ok, rounds} = Listener.issues()
      refute Enum.any?(rounds, & &1.dispatchable)
      assert Enum.any?(rounds, &(&1.native_ref["eligibility"] == reason))
    end

    responses(c, %{path => mr})
    assert {:ok, [retained]} = Listener.issues()
    assert retained.native_ref["round"] == 1
    refute retained.dispatchable
    assert {:ok, [^retained]} = Listener.issues()
  end

  test "native scan discovers unseen assigned MRs without a mailbox or webhook and keeps failed hints durable", c do
    assert {:ok, [issue]} = Listener.issues()
    assert issue.kind == :review
    assert issue.native_ref["work"]["repository_id"] == "10"
    assert Listener.health().discovery == :native_scan
    refute Map.has_key?(:sys.get_state(Listener), :port)
    responses(c, %{"GET projects/team%2Frepo/merge_requests/2" => "EXIT"})
    assert :ok = Listener.request_review("team/repo", 2)
    assert {:ok, [_]} = Listener.issues()
    assert Listener.health().pending_hints == 1
    stop_supervised!(Listener)
    start_supervised!({Listener, config: c.config})
    await_listener()
    assert Listener.health().pending_hints == 1
  end

  test "an MR with prior human review, automated review, or approval skips candidate admission", c do
    human_note = %{
      "id" => "100",
      "notes" => [
        %{"id" => 1, "body" => "LGTM from human reviewer", "author" => %{"id" => 40}, "created_at" => "2026-01-01T00:00:00Z"}
      ]
    }

    File.write!(Path.join(c.root, "discussions.json"), Jason.encode!([human_note]))
    assert {:ok, []} = Listener.issues()
    assert :ok = Listener.request_review("team/repo", 1)
    assert {:ok, []} = Listener.issues()

    auto_note = %{
      "id" => "101",
      "notes" => [
        %{"id" => 2, "body" => "<!-- symphony-review: 1 -->\\nLGTM!", "author" => %{"id" => 99}, "created_at" => "2026-01-01T00:00:00Z"}
      ]
    }

    File.write!(Path.join(c.root, "discussions.json"), Jason.encode!([auto_note]))
    assert {:ok, []} = Listener.issues()

    File.write!(Path.join(c.root, "discussions.json"), "[]")

    mr = %{
      "id" => 1001,
      "project_id" => 10,
      "iid" => 1,
      "state" => "opened",
      "sha" => String.duplicate("a", 40),
      "diff_refs" => %{"base_sha" => String.duplicate("b", 40)},
      "target_branch" => "main",
      "author" => %{"id" => 30},
      "reviewers" => [%{"id" => 20}],
      "approved" => true,
      "web_url" => "https://review.invalid/team/repo/-/merge_requests/1"
    }

    responses(c, %{"GET projects/team%2Frepo/merge_requests/1" => mr})
    assert {:ok, []} = Listener.issues()

    unassigned_mr = Map.put(mr, "approved", false) |> Map.put("reviewers", [%{"id" => 99}])
    responses(c, %{"GET projects/team%2Frepo/merge_requests/1" => unassigned_mr})
    assert {:ok, []} = Listener.issues()
  end

  defp merged_mr(record, changes) do
    %{
      "id" => 1001,
      "project_id" => 10,
      "iid" => record["iid"],
      "state" => "merged",
      "sha" => record["head"],
      "diff_refs" => %{"base_sha" => record["base"]},
      "target_branch" => record["target_branch"],
      "author" => %{"id" => record["author_id"]},
      "reviewers" => [%{"id" => 20}],
      "web_url" => record["url"]
    }
    |> Map.merge(changes)
  end

  test "disabled, changed and legacy configurations cannot start native discovery", c do
    {:ok, disabled} = Listener.init([])
    assert {:reply, {:ok, []}, ^disabled} = Listener.handle_call(:issues, self(), disabled)

    assert {:reply, {:error, :invalid_review_scope}, _} =
             Listener.handle_call({:request_review, "team/repo", 1}, self(), disabled)

    assert {:noreply, ^disabled} = Listener.handle_info(:poll, disabled)
    :sys.replace_state(Listener, &%{&1 | initial_config: nil})
    assert {:error, :review_lane_configuration_changed_restart_required} = Listener.issues()
    assert Listener.health().health == :failed
    send(Listener, :check_config)
    assert Listener.health().health == :failed
    send(Listener, :poll)
    assert Listener.health().health == :failed
    before_unknown = :sys.get_state(Listener)
    send(Listener, :unknown)
    assert :sys.get_state(Listener) == before_unknown

    for {body, expected} <- [
          {"{}", "invalid_review_journal"},
          {"not json", "invalid_review_journal"},
          {Jason.encode!(%{"schema_version" => 2}), "fresh_state_required"}
        ] do
      stop_supervised!(Listener)
      File.write!(Path.join(c.config["state_dir"], "review-lane.json"), body)
      start_supervised!({Listener, config: c.config})
      send(Listener, :configure)
      assert %{health: :failed, error: error} = Listener.health()
      assert error =~ expected
    end

    stop_supervised!(Listener)
    File.write!(Path.join(c.config["state_dir"], "mail-review.json"), "legacy execution receipts")
    start_supervised!({Listener, config: c.config})
    send(Listener, :configure)
    assert %{health: :failed, error: error} = Listener.health()
    assert error =~ "legacy_review_journal_requires_migration"
  end

  test "damaged persisted execution identities and hints are never admitted as new work", c do
    {:ok, [_]} = Listener.issues()
    path = Path.join(c.config["state_dir"], "review-lane.json")
    original = Jason.decode!(File.read!(path))
    [id] = Map.keys(original["records"])

    for change <- [
          %{"records" => []},
          %{"records" => %{id => nil}},
          %{"hints" => []},
          %{"hints" => %{"bad" => %{"project" => "foreign/repo", "iid" => 1}}},
          %{"hints" => %{"bad" => nil}},
          %{"records" => %{id => Map.put(original["records"][id], "head", "invalid")}}
        ] do
      stop_supervised!(Listener)
      File.write!(path, Jason.encode!(Map.merge(original, change)))
      start_supervised!({Listener, config: c.config})
      send(Listener, :configure)
      assert %{health: :failed, error: error} = Listener.health()
      assert error =~ "invalid_review_journal"
    end

    File.write!(path, Jason.encode!(original))
  end

  test "only the admitted worker may checkpoint and submit, and worker updates cannot rewrite authority", c do
    {:ok, [issue]} = Listener.issues()
    {:ok, record, _} = Listener.begin_run(issue.id)
    owner = record["execution_owner"]

    task =
      Task.async(fn ->
        {Listener.checkpoint(issue.id, owner, %{"native_stop_confirmed" => true}), Listener.submit(issue.id, owner, %{"findings" => []})}
      end)

    assert {{:error, :review_execution_owner_mismatch}, {:error, :review_execution_owner_mismatch}} = Task.await(task)
    assert review_record(c, issue) == record
    assert {:error, :review_execution_owner_mismatch} = Listener.checkpoint("missing", owner, %{})
    before_down = :sys.get_state(Listener)
    send(Listener, {:DOWN, make_ref(), :process, self(), :normal})
    assert :sys.get_state(Listener) == before_down
    fixture_checkpoint(issue.id, %{"phase" => "queued", "native_stop_confirmed" => false})
    assert {:error, :review_execution_fenced} = Listener.begin_run(issue.id)
    fixture_checkpoint(issue.id, %{"phase" => "running"})

    for change <- [
          %{"execution_owner" => owner},
          %{"phase" => "queued"},
          %{"head" => String.duplicate("f", 40)},
          %{"thread_allocation_intent" => false},
          %{"native_stop_confirmed" => nil},
          %{"native_stop_confirmed" => true, "thread_allocation_intent" => true},
          []
        ] do
      assert {:error, :invalid_review_checkpoint} = Listener.checkpoint(issue.id, owner, change)
    end

    assert :ok = Listener.checkpoint(issue.id, owner, %{"thread_allocation_intent" => true})
    assert {:error, :review_execution_fenced} = Listener.checkpoint(issue.id, owner, %{"thread_allocation_intent" => true})
    assert {:error, :review_execution_fenced} = Listener.checkpoint(issue.id, owner, %{"turn_allocation_intent" => true})
    assert :ok = Listener.checkpoint(issue.id, owner, %{"thread_id" => "owned", "workspace" => "/owned", "worker_host" => nil, "backend" => "codex"})
    assert {:error, :invalid_review_checkpoint} = Listener.checkpoint(issue.id, owner, %{"thread_id" => "foreign"})
    assert {:error, :invalid_review_checkpoint} = Listener.checkpoint(issue.id, owner, %{"workspace" => "/foreign"})
    assert :ok = Listener.checkpoint(issue.id, owner, %{"turn_allocation_intent" => true})
    assert {:error, :review_execution_fenced} = Listener.checkpoint(issue.id, owner, %{"turn_allocation_intent" => true})
    assert :ok = Listener.checkpoint(issue.id, owner, %{"native_stop_confirmed" => true})
    assert {:error, :invalid_review_checkpoint} = Listener.checkpoint(issue.id, owner, %{"native_stop_confirmed" => false})
    refute File.exists?(Path.join(c.root, "posts.json"))
  end

  @tag native_review: true
  test "listener restart stops its surviving worker through the original native connection", c do
    %{issue: issue} = runner_fixture(c)
    File.write!(Path.join(c.root, "hang"), "true")
    recipient = self()
    task = Task.async(fn -> Runner.run(issue, recipient) end)
    assert_receive {:worker_runtime_info, _, _}, 5_000
    assert_receive {:codex_worker_update, _, %{event: :session_started}}, 5_000
    running = review_record(c, issue)
    stop_supervised!(Listener)
    assert Process.alive?(task.pid)
    start_supervised!({Listener, config: c.config})
    await_listener()
    assert Task.await(task, 5_000) == :ok
    stopped = review_record(c, issue)
    assert stopped["execution_owner"] == running["execution_owner"]
    assert stopped["native_stop_confirmed"]
    assert stopped["native_stop_receipt"]["thread_id"] == running["thread_id"]
    assert Enum.count(native_methods(c), &(&1 == "initialize")) == 1
    refute File.exists?(Path.join(c.root, "posts.json"))
  end

  @tag native_review: true
  test "a stop checkpoint waits for listener initialization without replacing native sessions", c do
    %{issue: issue} = runner_fixture(c)
    File.write!(Path.join(c.root, "hang"), "true")
    recipient = self()
    task = Task.async(fn -> Runner.run(issue, recipient) end)
    assert_receive {:codex_worker_update, _, %{event: :session_started}}, 5_000
    await_native_method(c, "turn/start", 1)
    running = review_record(c, issue)
    stop_supervised!(Listener)
    start_supervised!({Listener, config: nil})
    assert Listener.health().health == :disabled
    assert {:error, :review_lane_initializing} = Listener.checkpoint(issue.id, running["execution_owner"], %{})
    listener = Process.whereis(Listener)
    trace_review_calls(task.pid, listener)
    send(task.pid, :symphony_stop)
    {tag, {:checkpoint, _, owner, changes}} = await_checkpoint_call(task.pid, issue.id)
    assert_receive {:trace, ^listener, :send, {^tag, {:error, :review_lane_initializing}}, _}, 5_000
    {retry_tag, {:checkpoint, _, ^owner, ^changes}} = await_checkpoint_call(task.pid, issue.id)
    refute retry_tag == tag
    :sys.replace_state(Listener, &%{&1 | initial_config: c.config})
    send(Listener, :configure)
    await_listener()
    assert Task.await(task, 5_000) == :ok
    stopped = review_record(c, issue)
    assert stopped["execution_owner"] == running["execution_owner"]
    assert stopped["native_stop_confirmed"]
    assert Enum.count(native_methods(c), &(&1 == "thread/start")) == 1
    assert Enum.count(native_methods(c), &(&1 == "turn/interrupt")) == 1
    refute "thread/resume" in native_methods(c)
    refute File.exists?(Path.join(c.root, "posts.json"))
  end

  test "worker exit proves stop only when no native allocation intent was recorded, including listener downtime", c do
    {:ok, [issue]} = Listener.issues()
    recipient = self()

    for {allocated, restart} <- [{false, false}, {true, false}, {false, true}, {true, true}] do
      fixture_checkpoint(issue.id, %{"phase" => "queued", "native_stop_confirmed" => true, "thread_allocation_intent" => false})

      worker =
        Task.async(fn ->
          {:ok, record, _} = Listener.begin_run(issue.id)
          if allocated, do: Listener.checkpoint(issue.id, record["execution_owner"], %{"thread_allocation_intent" => true})
          send(recipient, :owner_ready)

          receive do
            :finish -> :ok
          end
        end)

      assert_receive :owner_ready, 5_000
      if restart, do: stop_supervised!(Listener)
      send(worker.pid, :finish)
      assert Task.await(worker) == :ok

      if restart do
        start_supervised!({Listener, config: c.config})
        await_listener()
      end

      record = await_review_phase(c, issue, "fenced")
      assert record["native_stop_confirmed"] == not allocated
      assert record["error"] =~ "Review worker exited"
    end
  end

  test "changed native input and configuration stop new allocation but permit the owner's stop report", c do
    {:ok, [issue]} = Listener.issues()
    {:ok, record, _} = Listener.begin_run(issue.id)
    owner = record["execution_owner"]
    File.write!(Path.join(c.root, "changed-head"), "changed")
    assert {:error, :review_execution_fenced} = Listener.checkpoint(issue.id, owner, %{"thread_allocation_intent" => true})
    refute review_record(c, issue)["thread_allocation_intent"]
    :sys.replace_state(Listener, &%{&1 | initial_config: nil})
    assert {:error, :review_execution_fenced} = Listener.checkpoint(issue.id, owner, %{"turn_allocation_intent" => true})
    assert :ok = Listener.checkpoint(issue.id, owner, %{"native_stop_confirmed" => true})
    assert review_record(c, issue)["native_stop_confirmed"]
  end

  test "foreign VM ownership remains uncertain after restart and cannot authorize callbacks", c do
    {:ok, [issue]} = Listener.issues()
    {:ok, record, _} = Listener.begin_run(issue.id)
    foreign = %{record["execution_owner"] | "vm" => String.duplicate("0", 32)}
    fixture_checkpoint(issue.id, %{"execution_owner" => foreign})
    stop_supervised!(Listener)
    start_supervised!({Listener, config: c.config})
    await_listener()
    record = review_record(c, issue)
    refute record["native_stop_confirmed"]
    assert record["phase"] == "fenced"
    assert {:error, :review_execution_owner_mismatch} = Listener.checkpoint(issue.id, foreign, %{"native_stop_confirmed" => true})
    assert {:error, :review_execution_fenced} = Listener.begin_run(issue.id)
  end

  test "two admitted MRs retain independent owners and checkpoints", c do
    {:ok, [first]} = Listener.issues()

    second_mr =
      merged_mr(first.native_ref, %{
        "state" => "opened",
        "iid" => 2,
        "id" => 1002,
        "web_url" => "https://review.invalid/team/repo/-/merge_requests/2"
      })

    responses(c, %{"GET projects/team%2Frepo/merge_requests/2" => second_mr})
    :ok = Listener.request_review("team/repo", 2)
    {:ok, issues} = Listener.issues()
    second = Enum.find(issues, &(&1.native_ref["iid"] == 2))
    assert second.dispatchable
    refute Map.has_key?(second.native_ref, "finding_register")
    {:ok, first_record, _} = Listener.begin_run(first.id)
    {:ok, second_record, _} = Listener.begin_run(second.id)
    assert first_record["execution_owner"] != second_record["execution_owner"]

    for {issue, record} <- [{first, first_record}, {second, second_record}] do
      assert :ok = Listener.checkpoint(issue.id, record["execution_owner"], %{"native_stop_confirmed" => true})
      assert review_record(c, issue)["native_stop_confirmed"]
    end
  end

  @tag native_review: true
  test "unavailable execution directory fails before any native allocation", c do
    %{issue: issue} = runner_fixture(c)
    File.write!(Path.join(c.root, "workspaces"), "not a directory")
    assert_raise RuntimeError, ~r/Review preparation failed/, fn -> Runner.run(issue, nil) end
    assert native_methods(c) == []
    assert review_record(c, issue)["phase"] == "failed"
  end

  @tag native_review: true
  test "fencing during a turn rejects its late result and still confirms stop", c do
    %{issue: issue} = runner_fixture(c)
    assert_raise RuntimeError, ~r/Workflow result rejected/, fn -> Runner.run(issue, nil, backend: FencedBackend) end
    assert_received :backend_stopped
    record = review_record(c, issue)
    assert record["native_stop_confirmed"]
    refute record["workflow_result"]
  end

  @tag native_review: true, local_review: true
  test "local-only authority reaches the native Agent without scheduler writes", c do
    %{issue: issue} = runner_fixture(c)
    assert :ok = Runner.run(issue, nil)
    requests = Path.join(c.root, "native-requests.jsonl") |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    turn = Enum.find(requests, &(&1["method"] == "turn/start"))
    prompt = Jason.encode!(turn["params"])
    assert prompt =~ "Keep results local. Do not publish comments or results."
    assert prompt =~ issue.id
    assert prompt =~ issue.native_ref["head"]
    assert prompt =~ "scratch space"
    refute File.exists?(Path.join(c.root, "posts.json"))
  end

  test "a stopped needs-input workflow retains its reason across restart without rerun", c do
    {:ok, [issue]} = Listener.issues()
    {:ok, _, _} = Listener.begin_run(issue.id)
    result = %{"status" => "needs_input", "body" => "Resource remains owned"}
    assert :ok = owned_submit(issue.id, result)
    stop_supervised!(Listener)
    start_supervised!({Listener, config: c.config})
    await_listener()
    assert {:ok, [restored]} = Listener.issues()
    assert restored.native_ref["phase"] == "failed"
    assert restored.native_ref["workflow_result"] == result
    refute restored.dispatchable
  end

  test "opaque completion is retained without invoking a validator or replaying publication", c do
    {:ok, [issue]} = Listener.issues()
    {:ok, record, _} = Listener.begin_run(issue.id)
    owner = record["execution_owner"]
    result = %{"status" => "completed", "arbitrary_workflow" => [1, 2], "body" => "Agent supplied result"}
    assert {:error, :incomplete_review} = Listener.submit(issue.id, owner, %{"completion" => result})
    assert :ok = Listener.checkpoint(issue.id, owner, %{"native_stop_confirmed" => true})
    assert :ok = Listener.submit(issue.id, owner, %{"completion" => result})
    assert :ok = Listener.submit(issue.id, owner, %{"completion" => result})
    assert {:error, :changed_submission} = Listener.submit(issue.id, owner, %{"completion" => %{}})
    assert {:error, :invalid_review_submission} = Listener.submit(issue.id, owner, %{"completion" => nil})
    stop_supervised!(Listener)
    start_supervised!({Listener, config: Map.put(c.config, "result_command", ["/not-an-executable"])})
    await_listener()
    assert {:ok, [restored]} = Listener.issues()
    assert restored.native_ref["workflow_result"] == result
    assert restored.native_ref["phase"] == "completed"
    refute restored.dispatchable
    refute File.exists?(Path.join(c.root, "posts.json"))
  end

  @tag native_review: true
  test "review runner executes the configured workflow once without engine-owned axes", c do
    %{issue: issue} = runner_fixture(c)

    assessment =
      Map.new(["standards", "spec"], fn axis ->
        {axis, %{"status" => "complete", "report" => "Reviewed source", "sources" => ["source.txt"], "scope" => ["diff"], "gaps" => [], "findings" => [], "responses" => []}}
      end)

    File.write!(Path.join(c.root, "submission.json"), Jason.encode!(%{"assessment" => assessment}))
    assert :ok = Runner.run(issue, self())
    assert_received {:worker_runtime_info, _, %{workspace_path: snapshot}}
    refute File.exists?(Path.join(snapshot, "source"))
    refute File.exists?(Path.join(snapshot, ".git"))
    record = review_record(c, issue)
    assert record["phase"] == "completed"
    assert record["workflow_result"] == %{"assessment" => assessment}
    assert record["thread_id"]
    assert record["native_stop_receipt"]["source"] == "thread/read"
    refute Map.has_key?(record, "axes")
    methods = native_methods(c)
    assert Enum.count(methods, &(&1 == "turn/start")) == 1
    assert {:error, :review_execution_fenced} = Listener.begin_run(issue.id)
    assert_raise RuntimeError, ~r/review_execution_fenced/, fn -> Runner.run(issue, nil) end
    assert native_methods(c) == methods
    refute File.exists?(Path.join(c.root, "posts.json"))
  end

  @tag native_review: true
  test "a native turn with no axis submission is a failed review", c do
    %{issue: issue} = runner_fixture(c)
    File.write!(Path.join(c.root, "no-submit"), "true")
    assert_raise RuntimeError, ~r/workflow_incomplete/, fn -> Runner.run(issue, nil) end
    record = review_record(c, issue)
    assert record["phase"] == "failed"
    assert record["review_completion"] == nil
    refute record["workflow_result"]
  end

  @tag native_review: true
  test "withdrawn review stops the native turn before releasing its running slot", c do
    %{issue: issue, mr: mr, project: project} = runner_fixture(c)
    File.write!(Path.join(c.root, "hang"), "true")
    recipient = self()
    task = Task.async(fn -> Runner.run(issue, recipient) end)
    assert_receive {:worker_runtime_info, _, %{workspace_path: snapshot}}, 5_000
    assert_receive {:codex_worker_update, _, %{event: :session_started}}, 5_000
    running = review_record(c, issue)
    assert_raise RuntimeError, ~r/review_execution_fenced/, fn -> Runner.run(issue, nil) end
    assert review_record(c, issue)["execution_owner"] == running["execution_owner"]
    responses(c, %{"GET projects/team%2Frepo/merge_requests/1" => %{mr | "state" => "closed"}, "GET projects/team%2Frepo" => project})

    entry = %{pid: task.pid, ref: task.ref, issue: issue, identifier: issue.identifier}
    state = %SymphonyElixir.Orchestrator.State{running: %{issue.id => entry}, claimed: MapSet.new([issue.id])}
    stopped = Orchestrator.reconcile_issue_states_for_test([%{issue | state: "closed", dispatchable: false}], state)
    assert stopped.running[issue.id].stop_requested
    assert stopped.running[issue.id].cleanup_workspace
    assert MapSet.member?(stopped.claimed, issue.id)
    assert Task.await(task, 5_000) == :ok
    record = review_record(c, issue)
    assert record["native_stop_confirmed"]
    assert record["native_stop_receipt"]["source"] == "thread/read"
    assert record["workspace"] == snapshot
    refute File.exists?(Path.join(snapshot, "source"))
    refute File.exists?(Path.join(snapshot, ".git"))
    methods = native_methods(c)
    assert Enum.count(methods, &(&1 == "initialize")) == 1
    assert Enum.count(methods, &(&1 == "thread/start")) == 1
    assert Enum.count(methods, &(&1 == "turn/start")) == 1
    assert "turn/interrupt" in methods
    refute "thread/resume" in methods
    refute File.exists?(Path.join(c.root, "posts.json"))
  end

  @tag native_review: true
  test "interrupt acknowledgment without native idle stays fenced and preserves the snapshot", c do
    %{issue: issue} = runner_fixture(c)
    File.write!(Path.join(c.root, "hang"), "true")
    File.write!(Path.join(c.root, "unconfirmed-stop"), "true")
    recipient = self()

    task =
      Task.async(fn ->
        try do
          Runner.run(issue, recipient)
        rescue
          error -> {:error, Exception.message(error)}
        end
      end)

    assert_receive {:worker_runtime_info, _, %{workspace_path: snapshot}}, 5_000
    assert_receive {:codex_worker_update, _, %{event: :session_started}}, 5_000
    send(task.pid, :symphony_stop)
    assert {:error, message} = Task.await(task, 5_000)
    assert message =~ "Workflow failed"
    refute review_record(c, issue)["native_stop_confirmed"]
    assert File.dir?(snapshot)
    terminal = %{issue | state: "closed", dispatchable: false}
    metadata = %{issue: issue, workspace_path: snapshot, worker_host: nil}
    state = %Orchestrator.State{blocked: %{issue.id => metadata}, claimed: MapSet.new([issue.id])}
    released = Orchestrator.reconcile_blocked_issue_states_for_test([terminal], state)
    refute MapSet.member?(released.claimed, issue.id)
    assert File.dir?(snapshot)
    retried = Orchestrator.handle_retry_issue_lookup_for_test(terminal, state, issue.id, 1, metadata)
    refute MapSet.member?(retried.claimed, issue.id)
    assert File.dir?(snapshot)
    {:ok, rounds} = Listener.issues()
    refute Enum.any?(rounds, & &1.dispatchable)
    assert "turn/interrupt" in native_methods(c)
    methods = native_methods(c)
    assert Enum.count(methods, &(&1 == "initialize")) == 1
    assert_raise RuntimeError, ~r/review_execution_fenced/, fn -> Runner.run(issue, nil) end
    assert native_methods(c) == methods
  end

  @tag native_review: true
  test "lost live transport preserves uncertainty without opening a replacement app server", c do
    %{issue: issue} = runner_fixture(c)
    File.write!(Path.join(c.root, "disconnect"), "true")
    assert_raise RuntimeError, ~r/Workflow failed/, fn -> Runner.run(issue, nil) end
    record = review_record(c, issue)
    refute record["native_stop_confirmed"]
    assert record["native_stop_error"] =~ "native_stop_transport_unavailable"
    assert File.dir?(record["workspace"])
    assert Enum.count(native_methods(c), &(&1 == "initialize")) == 1
    assert Jason.decode!(File.read!(Path.join(c.root, record["thread_id"] <> ".json")))["status"] == "inProgress"
    {:ok, rounds} = Listener.issues()
    refute Enum.any?(rounds, & &1.dispatchable)
  end

  @tag native_review: true
  test "stop queued before admission never allocates a native thread", c do
    %{issue: issue} = runner_fixture(c)
    send(self(), :symphony_stop)
    assert Runner.run(issue, nil) == :ok
    record = review_record(c, issue)
    assert record["native_stop_confirmed"]
    refute record["thread_allocation_intent"]
    refute Enum.any?(native_methods(c), &(&1 in ["thread/start", "thread/resume", "turn/start"]))
  end

  test "native review webhooks persist scoped hints and reject retired mail replay", c do
    config = Map.put(c.config, "webhook_secret", String.duplicate("s", 32))

    File.write!(Workflow.workflow_file_path(), """
    ---
    tracker:
      kind: memory
      provider:
        review_lane: #{Jason.encode!(config)}
    ---
    Review fixture
    """)

    :ok = WorkflowStore.force_reload()
    assert SymphonyElixir.ReviewLane.config() == config
    :sys.replace_state(Listener, &%{&1 | initial_config: nil, config: config})
    assert {:ok, _} = Listener.issues()
    {:ok, reviews} = SymphonyElixir.Tracker.fetch_issues_by_states(Config.settings!().tracker.active_states)
    review = Enum.find(reviews, &(&1.kind == :review))
    assert review
    assert {:ok, [^review]} = SymphonyElixir.Tracker.fetch_issues_by_ids([review.id])
    tracker = %{kind: "gitlab", required_labels: [], assignee: "separate-task-owner"}
    assert Issue.routable?(review, tracker)
    refute Issue.routable?(%{review | dispatchable: false}, tracker)
    conn = Plug.Test.conn(:post, "/", %{}) |> Plug.Conn.put_req_header("x-gitlab-token", config["webhook_secret"])
    project = %{"id" => 10, "path_with_namespace" => "team/repo", "web_url" => "https://review.invalid/team/repo"}
    payload = %{"object_kind" => "merge_request", "project" => project, "object_attributes" => %{"iid" => 1}}
    assert WebhookController.receive_event(%{conn | body_params: payload}, %{"provider" => "gitlab"}).status == 202
    note = %{"object_kind" => "note", "project" => project, "merge_request" => %{"iid" => 1}}
    assert WebhookController.receive_event(%{conn | body_params: note}, %{"provider" => "gitlab"}).status == 202

    for invalid <- [put_in(payload["project"]["id"], 99), put_in(payload["object_attributes"]["iid"], 0), Map.delete(payload, "object_attributes")] do
      assert WebhookController.receive_event(%{conn | body_params: invalid}, %{"provider" => "gitlab"}).status == 403
    end

    assert WebhookController.receive_event(conn, %{"provider" => "mail"}).status == 403
    native = %{conn | params: %{"provider" => "mail"}}
    assert WebhookController.init(:receive_event) == :receive_event
    assert WebhookController.call(native, :receive_event).status == 403
  end

  test "unreadable journal and invalid repository discovery remain explicit failures", c do
    assert {:ok, [_]} = Listener.issues()

    for invalid <- [%{}, []] do
      responses(c, %{"GET projects/team%2Frepo" => invalid})
      assert {:ok, [_]} = Listener.issues()
      assert Listener.health().health == :degraded
    end

    path = Path.join(c.config["state_dir"], "review-lane.json")
    stop_supervised!(Listener)
    File.rm!(path)
    File.mkdir!(path)
    start_supervised!({Listener, config: c.config})
    send(Listener, :configure)
    assert %{health: :failed, error: error} = Listener.health()
    assert error =~ "Is a directory"
  end

  test "malformed native work stops eligibility without inventing another review", c do
    {:ok, [_issue]} = Listener.issues()

    for invalid <- [
          [],
          %{"iid" => 1, "project_id" => 10, "author" => []},
          %{"iid" => 1, "project_id" => 10, "author" => %{"id" => 30}, "state" => "opened", "reviewers" => nil}
        ] do
      responses(c, %{"GET projects/team%2Frepo/merge_requests/1" => invalid})
      assert {:ok, [unknown]} = Listener.issues()
      refute unknown.dispatchable
      assert unknown.native_ref["eligibility"] == "unknown"
    end
  end

  defp owner_for(id), do: get_in(:sys.get_state(Listener), [:records, String.replace_prefix(id, "review:", ""), "execution_owner"])
  defp owned_checkpoint(id, changes), do: Listener.checkpoint(id, owner_for(id), changes)
  defp owned_submit(id, arguments), do: SymphonyElixir.TestSupport.submit_review(id, arguments)

  defp await_review_phase(c, issue, phase, attempts \\ 100) do
    record = review_record(c, issue)

    cond do
      record["phase"] == phase ->
        record

      attempts == 0 ->
        flunk("Review did not reach #{phase}: #{inspect(record)}")

      true ->
        Process.sleep(10)
        await_review_phase(c, issue, phase, attempts - 1)
    end
  end

  # Set up historical states which workers have no authority to manufacture.
  defp fixture_checkpoint(id, changes) do
    key = String.replace_prefix(id, "review:", "")
    state = :sys.replace_state(Listener, fn state -> update_in(state, [:records, key], &Map.merge(&1, changes)) end)
    path = Path.join(state.config["state_dir"], "review-lane.json")
    data = path |> File.read!() |> Jason.decode!() |> Map.put("records", state.records)
    File.write!(path, Jason.encode!(data))
    :ok
  end

  defp runner_fixture(c) do
    server = Path.join(c.root, "review-server")
    SymphonyElixir.TestSupport.write_review_server(server, c.root)
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", workspace_root: Path.join(c.root, "workspaces"), codex_command: server)

    mr =
      merged_mr(
        %{
          "iid" => 1,
          "author_id" => 30,
          "url" => "https://review.invalid/team/repo/-/merge_requests/1",
          "head" => String.duplicate("a", 40),
          "base" => String.duplicate("b", 40),
          "target_branch" => "main"
        },
        %{"state" => "opened"}
      )

    project = %{"id" => 10, "web_url" => "https://review.invalid/team/repo", "path_with_namespace" => "team/repo"}
    responses(c, %{"GET projects/team%2Frepo/merge_requests/1" => mr, "GET projects/team%2Frepo" => project})
    assert :ok = Listener.request_review("team/repo", 1)
    {:ok, rounds} = Listener.issues()
    %{issue: Enum.find(rounds, & &1.dispatchable), mr: mr, project: project}
  end

  defp review_record(c, issue) do
    records = c.config["state_dir"] |> Path.join("review-lane.json") |> File.read!() |> Jason.decode!() |> Map.fetch!("records")
    Map.fetch!(records, String.replace_prefix(issue.id, "review:", ""))
  end

  defp native_methods(c) do
    path = Path.join(c.root, "native-requests.jsonl")
    if File.exists?(path), do: File.read!(path) |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!(&1)["method"]), else: []
  end

  defp await_native_method(c, method, count, attempts \\ 500)
  defp await_native_method(_c, method, _count, 0), do: flunk("Native method #{method} was not observed")

  defp await_native_method(c, method, count, attempts) do
    if Enum.count(native_methods(c), &(&1 == method)) >= count do
      :ok
    else
      Process.sleep(10)
      await_native_method(c, method, count, attempts - 1)
    end
  end

  defp trace_review_calls(worker, listener) do
    for pid <- [worker, listener], do: :erlang.trace(pid, true, [:send, {:tracer, self()}])
  end

  defp await_checkpoint_call(worker, id) do
    receive do
      {:trace, ^worker, :send, {:"$gen_call", {^worker, tag}, {:checkpoint, ^id, _, _} = message}, _} -> {tag, message}
      {:trace, ^worker, :send, {:"$gen_call", {^worker, tag}, :health}, _} -> {tag, :health}
    after
      5_000 -> flunk("Worker did not call its review checkpoint boundary")
    end
  end

  defp responses(c, values), do: File.write!(Path.join(c.root, "responses.json"), Jason.encode!(values))

  defp await_listener(attempts \\ 100) do
    cond do
      Listener.health().health == :listening ->
        :ok

      attempts == 0 ->
        flunk("Listener did not become ready")

      true ->
        Process.sleep(10)
        await_listener(attempts - 1)
    end
  end
end
