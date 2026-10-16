defmodule SymphonyElixir.ExecutionTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.{Execution, RunJournal}

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

  test "a recorded native thread cannot silently change execution backend", %{issue: issue} do
    {:ok, _, opts} = Execution.prepare(issue, [])
    {:ok, record} = RunJournal.checkpoint(opts[:run_record], %{"backend" => "omp"})
    assert :ok = RunJournal.complete(record, "completed")
    assert {:error, :execution_backend_changed} = Execution.prepare(issue, [])
  end

  test "stopped scheduler resumes the recorded thread but never invents a missing allocation", %{issue: issue} do
    {:ok, _, opts} = Execution.prepare(issue, [])
    record = opts[:run_record]
    {:ok, _} = RunJournal.checkpoint(record, %{"phase" => "turn_started", "thread_allocation_intent" => true, "thread_id" => "same-thread", "turn_id" => "same-turn", "executor_os_pid" => "99999999"})
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

    assert :ok = RunJournal.complete(record, "incident")
    assert {:error, {:execution_requires_recovery, "transport unavailable"}} = Execution.prepare(issue, [])

    client = fn method, path, _, _, _ ->
      send(self(), {:native, method, path})
      {:ok, %{status: 200}}
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

  test "handoff writes native Issue and allows worker to finish while label disappears", %{issue: issue} do
    {:ok, _, opts} = Execution.prepare(issue, [])

    client = fn method, path, _, body, _ ->
      assert Execution.handing_off?(issue.id)
      send(self(), {:native, method, path, body})
      {:ok, %{status: 200}}
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
    result = Execution.handoff(%{"kind" => "blocked", "reason" => "missing resource"}, issue: issue, tracker_settings: Config.settings!().tracker, github_client: client)
    refute result["success"]
    refute Execution.handing_off?(issue.id)
    {:ok, record} = RunJournal.read(opts[:run_record]["directory"])
    refute record["handoff"]
  end

  test "GitLab handoff updates its existing Issue without creating a task", %{issue: issue} do
    {:ok, _, _} = Execution.prepare(issue, [])
    settings = %{kind: "gitlab", provider: %{"project_path" => "group/repository"}, required_labels: ["symphony:ready"]}

    client = fn method, path, _, body, _ ->
      send(self(), {:native, method, path, body})
      {:ok, %{status: 200}}
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
end
