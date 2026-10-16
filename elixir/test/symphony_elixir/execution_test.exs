defmodule SymphonyElixir.ExecutionTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.{Execution, RunJournal}

  defmodule StopProbe do
    @spec start_session(Path.t(), keyword()) :: term()
    def start_session(workspace, opts) do
      send(self(), {:stop_probe, workspace, opts})
      Process.get(:stop_probe_result, {:ok, %{}})
    end

    @spec stop_session(map()) :: :ok
    def stop_session(_session) do
      send(self(), :stop_probe_closed)
      :ok
    end
  end

  setup do
    root = Path.dirname(Workflow.workflow_file_path())

    File.write!(Workflow.workflow_file_path(), """
    ---
    tracker:
      kind: github
      provider:
        repo: example/repository
        token: fixture-token
      required_labels: [symphony:ready]
      active_states: [open]
      terminal_states: [closed]
    agent:
      goal_mode: true
      run_journal_dir: #{Jason.encode!(Path.join(root, "runs"))}
    ---
    Execute {{ issue.url }}
    """)

    assert :ok = WorkflowStore.force_reload()
    issue = %Issue{id: "42", identifier: "example/repository#42", title: "Fixture", state: "open", url: "https://github.com/example/repository/issues/42", labels: ["symphony:ready"]}
    {:ok, issue: issue}
  end

  test "only one executor may admit an Issue and failed admission releases its own lock", %{issue: issue} do
    assert {:ok, _, opts} = Execution.prepare(issue, [])
    assert {:error, _} = Execution.prepare(issue, [])
    record = opts[:run_record]
    assert :ok = RunJournal.complete(record, "incident")
    assert {:error, _} = RunJournal.admit(Execution.journal_root(), issue.id)
    refute File.exists?(Path.join(record["directory"], "executor.lock"))
  end

  test "completed-run recovery cannot steal a cleanup lock from a new scheduler", %{issue: issue} do
    assert {:ok, _, opts} = Execution.prepare(issue, [])
    record = opts[:run_record]
    assert :ok = RunJournal.complete(record, "completed")

    assert {:ok, record} =
             RunJournal.checkpoint(record, %{
               "phase" => "completed",
               "executor_os_pid" => "999999999",
               "native_stop_confirmed" => true,
               "handoff" => %{"kind" => "review", "url" => "https://example.invalid/mr/6"}
             })

    lock = Path.join(record["directory"], "executor.lock")
    File.mkdir!(lock)
    File.write!(Path.join(lock, "cleanup-owner.json"), "cleanup owns this lock")
    before = File.read!(Path.join(record["directory"], "run.json"))
    assert {:error, {:run_admission_blocked, _, :eexist}} = Execution.prepare(issue, [])
    assert File.read!(Path.join(record["directory"], "run.json")) == before
    assert File.read!(Path.join(lock, "cleanup-owner.json")) == "cleanup owns this lock"
  end

  test "a recorded native thread cannot silently change execution backend", %{issue: issue} do
    {:ok, _, opts} = Execution.prepare(issue, [])
    {:ok, record} = RunJournal.checkpoint(opts[:run_record], %{"backend" => "omp"})
    assert :ok = RunJournal.complete(record, "completed")
    assert {:error, :execution_backend_changed} = Execution.prepare(issue, [])
  end

  test "stopped scheduler resumes the recorded thread but never invents a missing allocation", %{issue: issue} do
    {:ok, _, opts} = Execution.prepare(issue, [])
    record = opts[:run_record]

    {:ok, stopped} =
      RunJournal.checkpoint(record, %{"phase" => "turn_started", "thread_allocation_intent" => true, "thread_id" => "same-thread", "turn_id" => "same-turn", "executor_os_pid" => "99999999"})

    write_lock_owner(stopped)
    assert {:ok, _, resumed} = Execution.prepare(issue, [])
    assert resumed[:run_record]["thread_id"] == "same-thread"
    assert resumed[:run_record]["turn_id"] == "same-turn"
    assert resumed[:run_record]["attempt_count"] == 2
    {:ok, _} = RunJournal.checkpoint(resumed[:run_record], %{"phase" => "thread_start_intent", "thread_id" => nil, "executor_os_pid" => "99999999"})
    assert {:error, {:execution_requires_recovery, _}} = Execution.prepare(issue, [])
  end

  test "incident survives restart until explicitly retried, and retry label is consumed", %{issue: issue} do
    {:ok, _, opts} = Execution.prepare(issue, [])

    {:ok, record} =
      RunJournal.checkpoint(opts[:run_record], %{
        "thread_allocation_intent" => true,
        "thread_id" => "same-thread",
        "turn_id" => "same-turn",
        "native_stop_confirmed" => true,
        "executor_os_pid" => "99999999",
        "blocker_reason" => "transport unavailable"
      })

    write_lock_owner(record)
    assert :ok = RunJournal.complete(record, "incident")
    assert {:error, {:execution_requires_recovery, "transport unavailable"}} = Execution.prepare(issue, [])

    client = fn method, path, _, _, _ ->
      send(self(), {:native, method, path})
      native_ok(method, path)
    end

    assert {:ok, _, resumed} = Execution.prepare(%{issue | labels: issue.labels ++ ["symphony:retry"]}, github_client: client)
    assert_receive {:native, "DELETE", "/repos/example/repository/issues/42/labels/symphony%3Aretry"}
    assert resumed[:run_record]["thread_id"] == "same-thread"
    refute Execution.resumable?(issue)
  end

  test "pre-session errors retry twice and then expose the actual failure", %{issue: issue} do
    for attempt <- 1..3 do
      assert {:ok, _, opts} = Execution.prepare(issue, [])
      assert :ok = Execution.finish(issue, opts, {:error, :checkout_failed})

      if attempt < 3 do
        assert :ok = Execution.worker_down(issue.id, :failed)
      else
        assert {:blocked, reason} = Execution.worker_down(issue.id, :failed)
        assert reason =~ "checkout_failed"
      end
    end
  end

  test "tracker reconciliation retains the worker and claim until native shutdown", %{issue: issue} do
    {:ok, _, opts} = Execution.prepare(issue, [])
    {:ok, _} = RunJournal.checkpoint(opts[:run_record], %{"phase" => "turn_running", "thread_id" => "thread", "turn_id" => "turn"})
    owner = self()

    worker =
      spawn(fn ->
        receive do
          :symphony_stop ->
            send(owner, :shutdown_requested)

            receive do
              :confirm_shutdown ->
                {:ok, record} = RunJournal.read(opts[:run_record]["directory"])
                {:ok, _} = RunJournal.checkpoint(record, %{"native_stop_confirmed" => true})
                :ok = Execution.finish(issue, opts, {:error, :scheduler_stop})
            end
        end
      end)

    ref = Process.monitor(worker)
    entry = %{pid: worker, ref: ref, issue: issue, identifier: issue.identifier, started_at: DateTime.utc_now()}
    state = %Orchestrator.State{running: %{issue.id => entry}, claimed: MapSet.new([issue.id]), codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}}
    next = Orchestrator.reconcile_issue_states_for_test([%{issue | state: "closed", labels: []}], state)
    assert_receive :shutdown_requested
    assert next.running[issue.id].stop_requested
    assert MapSet.member?(next.claimed, issue.id)
    {:ok, record} = RunJournal.read(opts[:run_record]["directory"])
    assert record["phase"] == "turn_running"
    assert File.dir?(Path.join(record["directory"], "executor.lock"))
    again = Orchestrator.reconcile_issue_states_for_test([%{issue | state: "closed"}], next)
    assert again.running[issue.id].stop_requested
    send(worker, :confirm_shutdown)
    assert_receive {:DOWN, ^ref, :process, ^worker, :normal}
    {:noreply, done} = Orchestrator.handle_info({:DOWN, ref, :process, worker, :normal}, again)
    refute Map.has_key?(done.running, issue.id)
    refute MapSet.member?(done.claimed, issue.id)
    assert done.retry_attempts == %{}
    {:ok, record} = RunJournal.read(opts[:run_record]["directory"])
    assert record["phase"] == "completed"
    refute File.exists?(Path.join(record["directory"], "executor.lock"))
  end

  test "routing label removal retains the worker until native shutdown", %{issue: issue} do
    {:ok, _, opts} = Execution.prepare(issue, [])
    {:ok, _} = RunJournal.checkpoint(opts[:run_record], %{"phase" => "turn_running", "thread_id" => "thread", "turn_id" => "turn"})
    owner = self()

    worker =
      spawn(fn ->
        receive do
          :symphony_stop ->
            send(owner, :shutdown_requested)

            receive do
              :confirm_shutdown ->
                {:ok, record} = RunJournal.read(opts[:run_record]["directory"])
                {:ok, _} = RunJournal.checkpoint(record, %{"native_stop_confirmed" => true})
                :ok = Execution.finish(issue, opts, {:error, :scheduler_stop})
            end
        end
      end)

    ref = Process.monitor(worker)
    entry = %{pid: worker, ref: ref, issue: issue, identifier: issue.identifier, started_at: DateTime.utc_now()}
    state = %Orchestrator.State{running: %{issue.id => entry}, claimed: MapSet.new([issue.id]), codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}}
    next = Orchestrator.reconcile_issue_states_for_test([%{issue | labels: []}], state)
    assert_receive :shutdown_requested
    assert next.running[issue.id].stop_requested
    assert MapSet.member?(next.claimed, issue.id)
    {:ok, record} = RunJournal.read(opts[:run_record]["directory"])
    assert record["phase"] == "turn_running"
    assert File.dir?(Path.join(record["directory"], "executor.lock"))
    again = Orchestrator.reconcile_issue_states_for_test([%{issue | labels: []}], next)
    assert again.running[issue.id].stop_requested
    send(worker, :confirm_shutdown)
    assert_receive {:DOWN, ^ref, :process, ^worker, :normal}
    {:noreply, done} = Orchestrator.handle_info({:DOWN, ref, :process, worker, :normal}, again)
    refute Map.has_key?(done.running, issue.id)
    refute MapSet.member?(done.claimed, issue.id)
    assert done.retry_attempts == %{}
    {:ok, record} = RunJournal.read(opts[:run_record]["directory"])
    assert record["phase"] == "completed"
    refute File.exists?(Path.join(record["directory"], "executor.lock"))
  end

  test "shutdown timeout fences a stuck startup and releases its lock as an incident", %{issue: issue} do
    {:ok, _, opts} = Execution.prepare(issue, [])

    worker =
      spawn(fn ->
        receive do
          :never -> :ok
        end
      end)

    ref = Process.monitor(worker)
    entry = %{pid: worker, ref: ref, issue: issue, identifier: issue.identifier, started_at: DateTime.utc_now()}
    state = %Orchestrator.State{running: %{issue.id => entry}, claimed: MapSet.new([issue.id]), codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}}
    stopping = Orchestrator.reconcile_issue_states_for_test([%{issue | state: "closed"}], state)
    assert {:noreply, ^stopping} = Orchestrator.handle_info({:execution_stop_timeout, issue.id, make_ref()}, stopping)
    assert Process.alive?(worker)
    {:noreply, done} = Orchestrator.handle_info({:execution_stop_timeout, issue.id, ref}, stopping)
    refute Process.alive?(worker)
    refute Map.has_key?(done.running, issue.id)
    assert Map.has_key?(done.blocked, issue.id)
    assert done.retry_attempts == %{}
    {:ok, record} = RunJournal.read(opts[:run_record]["directory"])
    assert record["phase"] == "incident"
    assert record["blocker_reason"] =~ "scheduler_stop_timeout"
    refute record["native_stop_confirmed"]
    refute File.exists?(Path.join(record["directory"], "executor.lock"))
  end

  test "scheduler cancellation requires native stop confirmation even after the retry limit", %{issue: issue} do
    for confirmed <- [false, true] do
      issue = %{issue | id: issue.id <> "-#{confirmed}"}
      {:ok, _, opts} = Execution.prepare(issue, [])
      {:ok, _} = RunJournal.checkpoint(opts[:run_record], %{"phase" => "turn_running", "attempt_count" => 3, "native_stop_confirmed" => confirmed})
      assert :ok = Execution.finish(issue, opts, {:error, :scheduler_stop})
      {:ok, record} = RunJournal.read(opts[:run_record]["directory"])
      assert record["phase"] == if(confirmed, do: "completed", else: "incident")

      if not confirmed do
        assert {:blocked, _} = Execution.worker_down(issue.id, :normal)
      end
    end
  end

  test "handoff writes native Issue and allows worker to finish while label disappears", %{issue: issue} do
    {:ok, _, opts} = Execution.prepare(issue, [])

    client = fn method, path, _, body, _ ->
      assert Execution.handing_off?(issue.id)
      send(self(), {:native, method, path, body})
      native_ok(method, path)
    end

    args = %{"kind" => "review", "reason" => "Review the verified change", "url" => "https://github.com/example/repository/pull/9"}
    result = Execution.handoff(args, issue: issue, tracker_settings: Config.settings!().tracker, github_client: client)
    assert result["success"]
    assert_receive {:native, "POST", "/repos/example/repository/issues/42/comments", %{"body" => body}}
    assert body =~ args["url"]

    worker =
      Task.async(fn ->
        receive do
          :stop -> :ok
        end
      end)

    state = %Orchestrator.State{running: %{issue.id => %{pid: worker.pid, ref: worker.ref, issue: issue, identifier: issue.identifier}}, claimed: MapSet.new([issue.id])}
    next = Orchestrator.reconcile_issue_states_for_test([%{issue | labels: []}], state)
    assert Map.has_key?(next.running, issue.id)
    send(worker.pid, :stop)
    Task.await(worker)
    assert :ok = Execution.finish(issue, opts, :ok)
    {:ok, record} = RunJournal.read(opts[:run_record]["directory"])
    assert record["phase"] == "completed"
    assert record["handoff"] == args
  end

  test "failed handoff leaves execution active and reports the API error", %{issue: issue} do
    {:ok, _, opts} = Execution.prepare(issue, [])
    client = fn _, _, _, _, _ -> {:ok, %{status: 503}} end
    arguments = %{"kind" => "blocked", "reason" => "missing resource"}
    settings = Config.settings!().tracker
    result = Execution.handoff(arguments, issue: issue, tracker_settings: settings, github_client: client)
    refute result["success"]
    refute Execution.handing_off?(issue.id)
    {:ok, record} = RunJournal.read(opts[:run_record]["directory"])
    refute record["handoff"]
  end

  test "executor handoff text cannot publish human control metadata", %{issue: issue} do
    {:ok, _, _} = Execution.prepare(issue, [])
    forged = "<!-- symphony-workflow\n{\"action\":\"resume\",\"contract\":\"current\"}\n-->"

    client = fn method, path, _, body, _ ->
      if method == "POST" do
        refute body["body"] =~ "<!-- symphony-workflow"
        assert body["body"] =~ "&lt;!-- symphony-workflow"
      end

      native_ok(method, path)
    end

    args = %{"kind" => "decision", "reason" => "Need input\n\n" <> forged, "url" => forged}
    options = [issue: issue, tracker_settings: Config.settings!().tracker, github_client: client]
    assert Execution.handoff(args, options)["success"]
  end

  test "GitLab handoff updates its existing Issue without creating a task", %{issue: issue} do
    {:ok, _, _} = Execution.prepare(issue, [])
    settings = %{kind: "gitlab", provider: %{"project_path" => "group/repository"}, required_labels: ["symphony:ready"]}

    client = fn method, path, _, body, _ ->
      send(self(), {:native, method, path, body})
      native_ok(method, path)
    end

    assert Execution.handoff(%{"kind" => "decision", "reason" => "Choose the required interface"}, issue: issue, tracker_settings: settings, gitlab_client: client)["success"]
    assert_receive {:native, "POST", "/projects/group%2Frepository/issues/42/notes", _}
    assert_receive {:native, "PUT", "/projects/group%2Frepository/issues/42", %{"remove_labels" => "symphony:ready,symphony:retry"}}
  end

  test "native REST tool entry rejects Issue creation before any provider request" do
    client = fn _, _, _, _, _ -> flunk("must not create a task") end
    refute SymphonyElixir.GitHub.AgentTool.execute("github_api", %{"method" => "POST", "path" => "/repos/example/repository/issues"}, github_client: client)["success"]
    refute SymphonyElixir.GitLab.AgentTool.execute("gitlab_api", %{"method" => "POST", "path" => "/projects/group%2Frepository/issues"}, gitlab_client: client)["success"]
  end

  test "repository Goal continues across ordinary turn completion", %{issue: issue} do
    root = Path.dirname(Workflow.workflow_file_path())
    binary = Path.join(root, "goal-server")
    workspaces = Path.join(root, "workspaces")
    workspace = Path.join(workspaces, "issue")
    File.mkdir_p!(workspace)

    File.write!(binary, """
    #!/usr/bin/env python3
    import json,sys
    def emit(x): print(json.dumps(x),flush=True)
    for line in sys.stdin:
      q=json.loads(line);m=q.get('method')
      if m=='initialize': emit({'id':q['id'],'result':{}})
      elif m=='thread/start': emit({'id':q['id'],'result':{'thread':{'id':'goal-thread'}}})
      elif m=='thread/goal/get': emit({'id':q['id'],'result':{'goal':None}})
      elif m=='thread/goal/set':
        goal={'threadId':'goal-thread','objective':q['params']['objective'],'status':'active'}
        emit({'id':q['id'],'result':{'goal':goal}})
        for n in [1,2]:
          emit({'method':'turn/started','params':{'threadId':'goal-thread','turn':{'id':'turn-'+str(n)}}})
          emit({'method':'turn/completed','params':{'threadId':'goal-thread','turn':{'id':'turn-'+str(n),'status':'completed'}}})
        goal['status']='complete'
        emit({'method':'thread/goal/updated','params':{'threadId':'goal-thread','goal':goal}})
    """)

    File.chmod!(binary, 0o755)
    [front, config, prompt] = String.split(File.read!(Workflow.workflow_file_path()), "---", parts: 3)
    File.write!(Workflow.workflow_file_path(), front <> "---" <> config <> "\nworkspace:\n  root: #{Jason.encode!(workspaces)}\ncodex:\n  command: #{Jason.encode!(binary)}\n---" <> prompt)
    assert :ok = WorkflowStore.force_reload()
    {:ok, session} = AppServer.start_session(workspace)
    owner = self()

    try do
      assert {:ok, %{goal_status: "complete", turn_id: "turn-2"}} =
               AppServer.run_goal(session, "Execute the Issue", issue,
                 deadline: System.monotonic_time(:millisecond) + 2_000,
                 on_message: fn event -> send(owner, {:event, event}) end,
                 on_goal_stopped: fn value -> send(owner, {:stopped, value}) end
               )

      assert_receive {:event, %{event: :session_started, turn_id: "turn-1"}}
      assert_receive {:event, %{event: :session_started, turn_id: "turn-2"}}
      assert_receive {:stopped, true}
    after
      AppServer.stop_session(session)
    end
  end

  test "scheduler stop halts a native Goal and verifies its final turn", %{issue: issue} do
    root = Path.dirname(Workflow.workflow_file_path())
    binary = Path.join(root, "cancellable-goal-server")
    workspace = Path.join(root, "workspaces/issue")
    File.mkdir_p!(workspace)

    File.write!(binary, """
    #!/usr/bin/env python3
    import json,sys
    def emit(x): print(json.dumps(x),flush=True)
    goal=None
    for line in sys.stdin:
      q=json.loads(line);m=q.get('method');p=q.get('params',{})
      if m=='initialize': emit({'id':q['id'],'result':{}})
      elif m=='thread/start': emit({'id':q['id'],'result':{'thread':{'id':'cancel-thread'}}})
      elif m=='thread/goal/get': emit({'id':q['id'],'result':{'goal':goal}})
      elif m=='thread/goal/set':
        goal={'threadId':'cancel-thread','objective':'fixture','status':p['status']}
        emit({'id':q['id'],'result':{'goal':goal}})
        if p['status']=='active': emit({'method':'turn/started','params':{'threadId':'cancel-thread','turn':{'id':'cancel-turn'}}})
      elif m=='turn/interrupt': emit({'id':q['id'],'result':{}})
      elif m=='thread/read': emit({'id':q['id'],'result':{'thread':{'id':'cancel-thread','turns':[{'id':'cancel-turn','status':'interrupted' if goal['status']=='blocked' else 'inProgress'}]}}})
    """)

    File.chmod!(binary, 0o755)
    [front, config, prompt] = String.split(File.read!(Workflow.workflow_file_path()), "---", parts: 3)

    File.write!(
      Workflow.workflow_file_path(),
      front <> "---" <> config <> "\nworkspace:\n  root: #{Jason.encode!(Path.dirname(workspace))}\ncodex:\n  command: #{Jason.encode!(binary)}\n---" <> prompt
    )

    assert :ok = WorkflowStore.force_reload()
    {:ok, session} = AppServer.start_session(workspace)

    try do
      assert {:error, :scheduler_stop} =
               AppServer.run_goal(session, "fixture", issue,
                 deadline: System.monotonic_time(:millisecond) + 3_000,
                 latest_turn: fn -> "cancel-turn" end,
                 on_message: fn event -> if event.event == :session_started, do: send(self(), :symphony_stop) end,
                 on_goal_stopped: fn confirmed -> send(self(), {:confirmed, confirmed}) end
               )

      assert_receive {:confirmed, true}
    after
      AppServer.stop_session(session)
    end
  end

  test "scheduler stop does not confirm a native turn that remains active", %{issue: issue} do
    root = Path.dirname(Workflow.workflow_file_path())
    binary = Path.join(root, "cancellable-goal-server")
    workspace = Path.join(root, "workspaces/issue")
    File.mkdir_p!(workspace)

    File.write!(binary, """
    #!/usr/bin/env python3
    import json,sys
    def emit(x): print(json.dumps(x),flush=True)
    goal=None
    for line in sys.stdin:
      q=json.loads(line);m=q.get('method');p=q.get('params',{})
      if m=='initialize': emit({'id':q['id'],'result':{}})
      elif m=='thread/start': emit({'id':q['id'],'result':{'thread':{'id':'cancel-thread'}}})
      elif m=='thread/goal/get': emit({'id':q['id'],'result':{'goal':goal}})
      elif m=='thread/goal/set':
        goal={'threadId':'cancel-thread','objective':'fixture','status':p['status']}
        emit({'id':q['id'],'result':{'goal':goal}})
        if p['status']=='active': emit({'method':'turn/started','params':{'threadId':'cancel-thread','turn':{'id':'cancel-turn'}}})
      elif m=='turn/interrupt': emit({'id':q['id'],'result':{}})
      elif m=='thread/read': emit({'id':q['id'],'result':{'thread':{'id':'cancel-thread','turns':[{'id':'cancel-turn','status':'inProgress'}]}}})
    """)

    File.chmod!(binary, 0o755)
    [front, config, prompt] = String.split(File.read!(Workflow.workflow_file_path()), "---", parts: 3)

    File.write!(
      Workflow.workflow_file_path(),
      front <> "---" <> config <> "\nworkspace:\n  root: #{Jason.encode!(Path.dirname(workspace))}\ncodex:\n  command: #{Jason.encode!(binary)}\n---" <> prompt
    )

    assert :ok = WorkflowStore.force_reload()
    {:ok, session} = AppServer.start_session(workspace)

    try do
      assert {:error, :scheduler_stop} =
               AppServer.run_goal(session, "fixture", issue,
                 deadline: System.monotonic_time(:millisecond) + 3_000,
                 latest_turn: fn -> "cancel-turn" end,
                 on_message: fn event -> if event.event == :session_started, do: send(self(), :symphony_stop) end,
                 on_goal_stopped: fn confirmed -> send(self(), {:confirmed, confirmed}) end
               )

      assert_receive {:confirmed, false}
    after
      AppServer.stop_session(session)
    end
  end

  test "verified publication automatically completes one review handoff", %{issue: original} do
    issue = %{original | url: "https://gitlab.test/group/repository/-/issues/42"}
    {:ok, _, opts} = Execution.prepare(issue, [])
    record = opts[:run_record]
    settings = %{kind: "gitlab", provider: %{"project_path" => "group/repository"}, required_labels: ["symphony:ready"]}

    mr = %{
      "iid" => 9,
      "sha" => "source",
      "source_branch" => "task",
      "target_branch" => "main",
      "source_project_id" => 1,
      "target_project_id" => 1,
      "state" => "opened",
      "web_url" => "https://gitlab.test/group/repository/-/merge_requests/9",
      "squash" => true,
      "force_remove_source_branch" => true
    }

    request = %{
      "schema_version" => 1,
      "attempt_id" => record["attempt_id"],
      "issue_url" => issue.url,
      "kind" => "review",
      "reason" => "Please review the published change.",
      "url" => mr["web_url"],
      "publication" => mr
    }

    File.write!(Path.join(record["directory"], "review-request-#{record["attempt_id"]}.json"), Jason.encode!(request))

    client = fn method, path, _, body, _ ->
      send(self(), {:publication_native, method, path, body})
      if String.ends_with?(path, "/merge_requests/9"), do: {:ok, %{status: 200, body: mr}}, else: native_ok(method, path)
    end

    delivery_opts = [tracker_settings: settings, gitlab_client: client]
    assert :ok = Execution.reconcile_delivery(issue, delivery_opts)
    assert_receive {:publication_native, "POST", "/projects/group%2Frepository/issues/42/notes", _}
    assert_receive {:publication_native, "PUT", "/projects/group%2Frepository/issues/42", _}
    assert :ok = Execution.reconcile_delivery(issue, delivery_opts)
    refute_receive {:publication_native, "POST", _, _}
    {:ok, current} = RunJournal.read(record["directory"])
    assert current["stage_results"]["mr_publication"] == "passed"
    assert current["stage_results"]["review_handoff"] == "passed"
    assert current["stage_results"]["native_execution_stopped"] == "not_verified"
    assert current["stage_results"]["business_validation"] == "see_mr_evidence"
  end

  test "a partial handoff retries label removal without repeating the notice", %{issue: issue} do
    {:ok, _, opts} = Execution.prepare(issue, [])
    args = %{"kind" => "review", "reason" => "Please review.", "url" => "https://github.com/example/repository/pull/9"}

    client = fn method, path, _, _, _ ->
      send(self(), {:handoff_call, method})
      if method == "DELETE", do: {:ok, %{status: 503}}, else: native_ok(method, path)
    end

    handoff_opts = [issue: issue, tracker_settings: Config.settings!().tracker, github_client: client]
    refute Execution.handoff(args, handoff_opts)["success"]
    assert_receive {:handoff_call, "POST"}
    assert_receive {:handoff_call, "DELETE"}
    {:ok, record} = RunJournal.read(opts[:run_record]["directory"])
    assert record["handoff_notice"]
    refute record["handoff"]

    client = fn method, path, _, _, _ ->
      send(self(), {:retry_call, method})
      native_ok(method, path)
    end

    handoff_opts = [issue: issue, tracker_settings: Config.settings!().tracker, github_client: client]
    assert Execution.handoff(args, handoff_opts)["success"]
    refute_receive {:retry_call, "POST"}
    assert_receive {:retry_call, "DELETE"}
  end

  test "a stale publication request never creates a handoff or a passed publication stage", %{issue: issue} do
    {:ok, _, opts} = Execution.prepare(issue, [])
    record = opts[:run_record]
    request = %{"schema_version" => 1, "attempt_id" => "previous", "issue_url" => issue.url}
    File.write!(Path.join(record["directory"], "review-request-#{record["attempt_id"]}.json"), Jason.encode!(request))
    settings = %{kind: "gitlab", provider: %{"project_path" => "group/repository"}, required_labels: ["symphony:ready"]}
    client = fn _, _, _, _, _ -> flunk("stale request reached provider") end
    assert {:error, _} = Execution.reconcile_delivery(issue, tracker_settings: settings, gitlab_client: client)
    {:ok, current} = RunJournal.read(record["directory"])
    refute current["handoff"]
    assert current["stage_results"]["mr_publication"] == "not_verified"
    assert current["blocker_reason"] =~ "Automatic review handoff failed"
  end

  test "restart carries only an unfinished review request to the resumed native thread", %{issue: issue} do
    {:ok, _, opts} = Execution.prepare(issue, [])
    record = opts[:run_record]
    notice = "Already posted review request"
    {:ok, record} = RunJournal.checkpoint(record, %{"thread_id" => "same-native-thread", "handoff_notice" => notice})
    request = %{"attempt_id" => record["attempt_id"], "issue_url" => issue.url}
    File.write!(Path.join(record["directory"], "review-request-#{record["attempt_id"]}.json"), Jason.encode!(request))
    assert :ok = RunJournal.complete(record, "completed")
    {:ok, resumed} = RunJournal.admit(Execution.journal_root(), issue.id)
    assert resumed["thread_id"] == "same-native-thread"
    assert resumed["handoff_notice"] == notice
    assert resumed["attempt_id"] != record["attempt_id"]
    {:ok, copied} = Path.join(record["directory"], "review-request-#{resumed["attempt_id"]}.json") |> File.read()
    assert Jason.decode!(copied)["attempt_id"] == resumed["attempt_id"]
    refute resumed["stage_results"]["mr_publication"] == "passed"
    assert :ok = RunJournal.complete(resumed, "completed")
    {:ok, completed} = RunJournal.read(resumed["directory"])
    {:ok, ended} = RunJournal.checkpoint(completed, %{"handoff" => %{"kind" => "review"}})
    {:ok, next} = RunJournal.admit(Execution.journal_root(), issue.id)
    refute File.exists?(Path.join(ended["directory"], "review-request-#{next["attempt_id"]}.json"))
    refute next["handoff_notice"]
  end

  test "malformed pending review recovery releases its failed admission lock", %{issue: issue} do
    {:ok, _, opts} = Execution.prepare(issue, [])
    {:ok, record} = RunJournal.checkpoint(opts[:run_record], %{"thread_id" => "same-thread"})
    File.write!(Path.join(record["directory"], "review-request-#{record["attempt_id"]}.json"), "[]")
    assert :ok = RunJournal.complete(record, "completed")
    assert {:error, {:pending_review_recovery_failed, _}} = RunJournal.admit(Execution.journal_root(), issue.id)
    refute File.exists?(Path.join(record["directory"], "executor.lock"))
  end

  test "handoff cannot pass while a required label remains with different casing", %{issue: issue} do
    {:ok, _, opts} = Execution.prepare(issue, [])

    client = fn method, path, _, _, _ ->
      if method == "GET" and String.ends_with?(path, "/42") do
        {:ok, %{status: 200, body: %{"labels" => [%{"name" => "SYMPHONY:READY"}]}}}
      else
        native_ok(method, path)
      end
    end

    args = %{"kind" => "review", "reason" => "Review the delivery."}
    options = [issue: issue, tracker_settings: Config.settings!().tracker, github_client: client]
    refute Execution.handoff(args, options)["success"]
    {:ok, record} = RunJournal.read(opts[:run_record]["directory"])
    refute record["handoff"]
  end

  test "completion checks the current Issue and preserves lookup failures", %{issue: issue} do
    for {current, phase} <- [{%{issue | dispatchable: true}, "incident"}, {%{issue | state: "closed"}, "completed"}, {nil, "completed"}] do
      id = issue.id <> phase <> inspect(current && current.state)
      task = %{issue | id: id}
      switch_tracker("memory")
      Application.put_env(:symphony_elixir, :memory_tracker_issues, if(current, do: [%{current | id: id}], else: []))
      {:ok, _, opts} = Execution.prepare(task, [])
      assert :ok = Execution.finish(task, opts, :ok)
      {:ok, record} = RunJournal.read(opts[:run_record]["directory"])
      assert record["phase"] == phase
    end

    switch_tracker("github")
    text = File.read!(Workflow.workflow_file_path()) |> String.replace("token: fixture-token", "token: fixture-token\n    api_url: https://127.0.0.1:1")
    File.write!(Workflow.workflow_file_path(), text)
    :ok = WorkflowStore.force_reload()
    {:ok, _, opts} = Execution.prepare(issue, [])
    assert :ok = Execution.finish(issue, opts, :ok)
    {:ok, record} = RunJournal.read(opts[:run_record]["directory"])
    assert record["blocker_reason"] =~ "Cannot confirm the Issue"
    assert :ok = Execution.finish(issue, nil, :ok)
    assert :ok = Execution.finish(issue, [], :ok)
  end

  test "journal environment paths and invalid per-Issue budgets use configured fallbacks", %{issue: issue} do
    root = Execution.journal_root()
    text = File.read!(Workflow.workflow_file_path())
    text = String.replace(text, Jason.encode!(root), "$SYMPHONY_TEST_JOURNAL")
    text = String.replace(text, "goal_mode: true", "goal_mode: true\n  run_budget_ms_by_issue: {\"42\": 0}")
    File.write!(Workflow.workflow_file_path(), text)
    System.put_env("SYMPHONY_TEST_JOURNAL", root)
    on_exit(fn -> System.delete_env("SYMPHONY_TEST_JOURNAL") end)
    :ok = WorkflowStore.force_reload()
    assert Execution.journal_root() == root
    assert Execution.run_budget_ms(issue.id) == Config.settings!().agent.run_budget_ms
    refute Execution.handing_off?(issue.id)
    refute Execution.resumable?(%{issue | labels: ["symphony:retry"]})
    assert :ok = Execution.reconcile_delivery(issue, [])
    refute Execution.handoff(%{}, [])["success"]
    {:ok, _, _} = Execution.prepare(issue, [])
    settings = %{kind: "gitlab", provider: %{"project_path" => "group/repo"}, required_labels: []}

    client = fn method, _, _, _, _ ->
      if method == "PUT", do: {:error, :offline}, else: {:ok, %{status: 200, body: []}}
    end

    args = %{"kind" => "blocked", "reason" => "Need input"}
    refute Execution.handoff(args, issue: issue, tracker_settings: settings, gitlab_client: client)["success"]
  end

  test "cleanup locks and failed writes stop recovery without releasing ownership", %{issue: issue} do
    {:ok, _, opts} = Execution.prepare(issue, [])
    record = opts[:run_record]
    {:ok, stopped} = RunJournal.checkpoint(record, %{"phase" => "turn_running", "executor_os_pid" => "99999999"})
    write_lock_owner(stopped)
    lock = Path.join(record["directory"], "executor.lock")
    owner = Path.join(lock, "cleanup-owner.json")
    File.write!(owner, "owned")
    assert {:error, :merge_cleanup_in_progress} = Execution.prepare(issue, [])
    File.rm!(owner)
    File.write!(Path.join(lock, "unexpected"), "keep")
    assert {:error, reason} = Execution.prepare(issue, [])
    assert match?({:execution_lock_owner_changed, _}, reason)
    assert File.exists?(Path.join(lock, "executor-owner.json"))
    assert File.read!(Path.join(lock, "unexpected")) == "keep"
    {:ok, _} = RunJournal.checkpoint(record, %{"phase" => "turn_running", "executor_os_pid" => "99999999"})
    File.mkdir!(Path.join(record["directory"], "run.json.pending"))
    assert {:error, :eisdir} = Execution.prepare(issue, [])
    File.rm_rf!(Path.join(record["directory"], "run.json.pending"))
    File.rm!(Path.join(record["directory"], "run.json"))
    File.mkdir!(Path.join(record["directory"], "run.json"))
    assert {:error, :eisdir} = RunJournal.read(record["directory"])
    assert {:error, :eisdir} = Execution.reconcile_delivery(issue, [])
  end

  test "unconfirmed thread allocation cannot be readmitted; unsupported trackers cannot hand off", %{issue: issue} do
    {:ok, _, opts} = Execution.prepare(issue, [])
    record = opts[:run_record]
    options = [issue: issue, tracker_settings: %{kind: "memory"}]
    refute Execution.handoff(%{"kind" => "blocked", "reason" => "Need input"}, options)["success"]
    switch_tracker("memory")
    assert {:error, :repository_tracker_required} = Execution.prepare(%{issue | labels: ["symphony:retry"]}, [])
    {:ok, record} = RunJournal.checkpoint(record, %{"thread_id" => nil, "thread_allocation_intent" => true})
    :ok = RunJournal.complete(record, "completed")
    assert {:error, :uncertain_thread_allocation} = RunJournal.admit(Execution.journal_root(), issue.id)
    binding = %{adapter: SymphonyElixir.Tracker.Memory, tracker_settings: Config.settings!().tracker}
    refute Tracker.execute_bound_agent_tool(binding, "task_handoff", %{}, issue: issue)["success"]
    # Optional adapter callbacks remain part of the shared boundary.
    assert :ok = Tracker.finish_run(issue, [tracker_adapter: __MODULE__], :ok)
  end

  @spec finish_run(Issue.t(), keyword(), term()) :: :ok
  def finish_run(_issue, _opts, _result), do: :ok

  test "activation and late scheduler callbacks cannot mutate another execution owner", %{issue: issue} do
    assert {:ok, []} = Execution.activation_options([])
    {:ok, _, opts} = Execution.prepare(issue, [])
    record = opts[:run_record]
    assert {:ok, _} = Execution.activation_options(opts)
    {:ok, stopped} = RunJournal.checkpoint(record, %{"phase" => "turn_running", "thread_id" => "same", "executor_os_pid" => "99999999"})
    # The source says another scheduler owns this record. A delayed DOWN is local only.
    assert :ok = Execution.worker_down(issue.id, :late_down)
    {:ok, unchanged} = RunJournal.read(record["directory"])
    assert unchanged == stopped
    File.rm!(Path.join([record["directory"], "executor.lock", "executor-owner.json"]))
    assert {:error, :execution_lock_owner_unverified} = Execution.prepare(issue, [])
    assert File.dir?(Path.join(record["directory"], "executor.lock"))
    owner = Path.join([record["directory"], "executor.lock", "executor-owner.json"])
    File.mkdir!(owner)
    assert {:error, :eisdir} = RunJournal.release_lock(stopped)
    File.rm!(Path.join(record["directory"], "run.json"))
    File.mkdir!(Path.join(record["directory"], "run.json"))
    assert {:error, :eisdir} = Execution.activation_options(opts)
  end

  test "orphan recovery halts and validates the recorded thread, preserves its host and never invents a session", %{issue: issue} do
    assert {:ok, _} = Execution.reconcile_native_stop(%{"thread_allocation_intent" => false})
    {:ok, _, opts} = Execution.prepare(issue, worker_host: "worker-a")
    workspace = Path.join(opts[:run_record]["directory"], "task-workspace")

    {:ok, record} =
      RunJournal.checkpoint(opts[:run_record], %{
        "thread_allocation_intent" => true,
        "thread_id" => "recorded",
        "turn_id" => "recorded-turn",
        "workspace" => workspace,
        "native_stop_confirmed" => false
      })

    {:ok, stopped} = Execution.reconcile_native_stop(record, backend: StopProbe)
    assert stopped["native_stop_confirmed"]
    assert_receive {:stop_probe, ^workspace, recovery}
    assert recovery[:resume_thread_id] == "recorded"
    assert recovery[:expected_turn_id] == "recorded-turn"
    assert recovery[:suspend_goal]
    assert recovery[:worker_host] == "worker-a"
    assert_receive :stop_probe_closed
    Process.put(:stop_probe_result, {:error, :native_thread_not_idle})
    {:ok, uncertain} = Execution.reconcile_native_stop(record, backend: StopProbe)
    refute uncertain["native_stop_confirmed"]
    assert_receive {:stop_probe, ^workspace, _}
    refute_receive :stop_probe_closed
    {:ok, unknown} = Execution.reconcile_native_stop(Map.delete(uncertain, "thread_id"), backend: StopProbe)
    refute unknown["native_stop_confirmed"]
    {:ok, _} = Execution.reconcile_native_stop(Map.put(unknown, "backend", "omp"), backend: StopProbe)
    refute_receive {:stop_probe, _, _}
    {:ok, restored} = RunJournal.checkpoint(stopped, %{"backend" => "codex"})
    :ok = RunJournal.complete(restored, "completed")
    {:ok, _, resumed} = Execution.prepare(issue, worker_host: "worker-b")
    assert resumed[:worker_host] == "worker-a"
    assert resumed[:run_record]["thread_id"] == "recorded"
  end

  test "orphan stop interrupts an unobserved active turn without resuming or allocating a thread", %{issue: issue} do
    root = Path.dirname(Workflow.workflow_file_path())
    workspace = Path.join(root, "workspaces/orphan")
    File.mkdir_p!(workspace)
    binary = Path.join(root, "orphan-server")
    trace = Path.join(root, "orphan-requests.jsonl")

    File.write!(binary, """
    #!/usr/bin/env python3
    import json,sys
    trace=#{Jason.encode!(trace)}
    goal={'threadId':'recorded','objective':'fixture','status':'active'}
    interrupted=False
    def emit(q,result): print(json.dumps({'id':q['id'],'result':result}),flush=True)
    def thread():
      return {'id':'recorded','status':{'type':'idle' if interrupted else 'active'},
              'turns':[{'id':'old','status':'completed'},{'id':'unobserved','status':'interrupted' if interrupted else 'inProgress'}]}
    for line in sys.stdin:
      q=json.loads(line);m=q.get('method');p=q.get('params',{})
      with open(trace,'a') as f: f.write(json.dumps(q)+'\\n')
      if m=='initialize': emit(q,{})
      elif m=='thread/goal/get': emit(q,{'goal':goal})
      elif m=='thread/goal/set':
        assert p['status']=='blocked'
        goal['status']='blocked';emit(q,{'goal':goal})
      elif m=='thread/read': emit(q,{'thread':thread()})
      elif m=='turn/interrupt':
        assert p['turnId']=='unobserved';interrupted=True;emit(q,{})
      elif 'id' in q: raise RuntimeError('unexpected activation: '+m)
    """)

    File.chmod!(binary, 0o755)
    [front, config, prompt] = String.split(File.read!(Workflow.workflow_file_path()), "---", parts: 3)
    config = config <> "\nworkspace:\n  root: #{Jason.encode!(Path.dirname(workspace))}\ncodex:\n  command: #{Jason.encode!(binary)}\n"
    File.write!(Workflow.workflow_file_path(), front <> "---" <> config <> "---" <> prompt)
    :ok = WorkflowStore.force_reload()
    {:ok, _, opts} = Execution.prepare(issue, [])

    {:ok, record} =
      RunJournal.checkpoint(opts[:run_record], %{"thread_id" => "recorded", "turn_id" => "old", "thread_allocation_intent" => true, "native_stop_confirmed" => false, "workspace" => workspace})

    {:ok, stopped} = Execution.reconcile_native_stop(record)
    assert stopped["native_stop_confirmed"]
    assert stopped["turn_id"] == "unobserved"
    requests = trace |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    methods = Enum.map(requests, & &1["method"])
    assert "turn/interrupt" in methods
    refute Enum.any?(methods, &(&1 in ["thread/start", "thread/resume", "turn/start"]))
    refute Enum.any?(requests, &(get_in(&1, ["params", "status"]) == "active"))
  end

  defp write_lock_owner(record) do
    path = Path.join([record["directory"], "executor.lock", "executor-owner.json"])
    File.write!(path, Jason.encode!(Map.take(record, ["attempt_id", "host", "executor_os_pid"])))
  end

  defp switch_tracker(kind) do
    text = File.read!(Workflow.workflow_file_path()) |> String.replace(~r/kind: (github|memory)/, "kind: " <> kind)
    File.write!(Workflow.workflow_file_path(), text)
    :ok = WorkflowStore.force_reload()
  end

  defp native_ok(method, path) do
    body = if method == "GET" and (String.ends_with?(path, "/comments") or String.ends_with?(path, "/notes")), do: [], else: %{"labels" => []}
    {:ok, %{status: 200, body: body}}
  end
end
