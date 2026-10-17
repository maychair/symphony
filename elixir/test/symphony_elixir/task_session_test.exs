defmodule SymphonyElixir.TaskSessionTest do
  use SymphonyElixir.TestSupport, runtime: false
  alias SymphonyElixir.Codex.DynamicTool
  alias SymphonyElixir.{TaskExecution, TaskPlan, TaskSession, TaskWorkflow, WorkRef}

  defp contract(work, parent) do
    data = %{
      "schema_version" => 2,
      "work" => work,
      "parent" => parent,
      "goal" => "Produce the approved report",
      "non_goals" => [],
      "criteria" => ["result"],
      "criteria_details" => %{"result" => "Reproducible report"},
      "verification_checks" => %{"result" => ["review"]},
      "authorizer" => "1",
      "acceptance_mode" => if(parent, do: "technical", else: "separate"),
      "acceptor" => if(parent, do: nil, else: "2"),
      "budget_ms" => 100_000,
      "deliverables" => [%{"id" => "report", "kind" => "report", "criteria" => ["result"]}]
    }

    Map.put(data, "contract_sha", TaskWorkflow.digest(data))
  end

  defp block(name, value), do: "<!-- symphony-#{name} " <> Jason.encode!(value) <> " -->"
  defp note(body, id), do: %{"id" => id, "body" => body, "user" => %{"id" => 1}, "created_at" => "2026-10-18T00:00:00Z", "updated_at" => "2026-10-18T00:00:00Z"}

  setup do
    root = Path.dirname(Workflow.workflow_file_path())
    work = %{"provider" => "github", "host" => "github.test", "repository_id" => "10", "kind" => "issue", "number" => 2}
    parent = %{work | "number" => 1}
    scope = contract(work, parent)
    parent_scope = contract(parent, nil)
    member = %{"work" => work, "contract_sha" => scope["contract_sha"], "criteria" => ["result"], "budget_ms" => 100_000, "human_gate" => false}

    {:ok, plan} =
      TaskPlan.seal(%{
        "parent" => parent,
        "contract_sha" => parent_scope["contract_sha"],
        "authorizer" => "1",
        "criteria" => ["result"],
        "members" => [member],
        "dependencies" => [],
        "integration" => work,
        "budget_ms" => 100_000
      })

    prefix = "/repos/team/repo"

    raw = fn number, body ->
      %{"id" => number + 100, "number" => number, "body" => body, "state" => "open", "assignees" => [%{"id" => 1}], "html_url" => "https://github.test/team/repo/issues/#{number}"}
    end

    objects = %{
      prefix => %{"id" => 10, "full_name" => "team/repo", "html_url" => "https://github.test/team/repo"},
      "/user" => %{"id" => 99},
      (prefix <> "/issues/1") => raw.(1, block("contract", parent_scope) <> block("plan", plan)),
      (prefix <> "/issues/2") => raw.(2, block("contract", scope)),
      (prefix <> "/issues/1/comments") => [note(block("plan-decision", %{"action" => "authorize", "revision" => plan["revision"]}), 1)],
      (prefix <> "/issues/2/comments") => []
    }

    state = start_supervised!({Agent, fn -> objects end})
    request = fn "github", "GET", path, _, _ -> {:ok, %{status: 200, body: Agent.get(state, &Map.fetch!(&1, path))}} end
    repository = Map.take(work, ~w(provider host repository_id)) |> Map.merge(%{"path" => "team/repo", "api_url" => "https://github.test/api/v3", "credential" => "$UNUSED_SESSION_FIXTURE"})
    policy = %{"engine_actor" => "99", "max_retries" => 2, "max_repairs" => 2, "checks" => %{"review" => %{"kind" => "review"}}}
    directory = SymphonyElixir.RunJournal.directory(Path.join(root, "runs"), WorkRef.key(work))
    registry = %{WorkRef.key(work) => %{directory: directory, policy: policy}}
    opts = [request: request, repositories: [repository], workspace_root: Path.join(root, "workspaces")]
    binary = Path.join(root, "role-server")
    trace = Path.join(root, "trace.jsonl")
    native = Path.join(root, "native.json")
    failure = Path.join(root, "fail-read")

    File.write!(binary, """
    #!/usr/bin/env python3
    import json,sys,pathlib
    path=pathlib.Path(#{Jason.encode!(native)})
    state=json.loads(path.read_text()) if path.exists() else {'id':'owned-thread','goal':None,'turns':[]}
    def emit(q,result):print(json.dumps({'id':q['id'],'result':result}),flush=True)
    for line in sys.stdin:
      q=json.loads(line);m=q.get('method');p=q.get('params',{})
      with open(#{Jason.encode!(trace)},'a') as f:f.write(json.dumps(q)+'\\n')
      if m=='initialized':continue
      if m=='initialize':emit(q,{})
      elif m in ['thread/start','thread/resume','thread/read']:
        if m=='thread/start' and pathlib.Path(#{Jason.encode!(failure)}).exists():
          print(json.dumps({'id':q['id'],'error':{'message':'allocation response lost'}}),flush=True)
        elif m=='thread/read' and pathlib.Path(#{Jason.encode!(failure)}).exists():
          emit(q,{'thread':{'id':'foreign','status':{'type':'idle'},'turns':[]}})
        else:emit(q,{'thread':{'id':state['id'],'status':{'type':'idle'},'turns':state['turns']}})
      elif m=='thread/goal/get':emit(q,{'goal':state['goal']})
      elif m=='turn/start':
        state['turns']=[{'id':'owned-turn','status':'completed'}]
        emit(q,{'turn':{'id':'owned-turn'}})
        print(json.dumps({'method':'turn/completed','params':{'threadId':state['id'],'turn':state['turns'][0]}}),flush=True)
      elif m=='thread/goal/set':
        state['goal']={'threadId':state['id'],'objective':p.get('objective','approved role'),'status':p['status']}
        emit(q,{'goal':state['goal']})
        if p['status']=='active':
          state['turns']=[{'id':'owned-turn','status':'completed'}]
          print(json.dumps({'method':'turn/started','params':{'threadId':state['id'],'turn':{'id':'owned-turn'}}}),flush=True)
          print(json.dumps({'method':'turn/completed','params':{'threadId':state['id'],'turn':state['turns'][0]}}),flush=True)
          state['goal']['status']='complete'
          print(json.dumps({'method':'thread/goal/updated','params':{'threadId':state['id'],'goal':state['goal']}}),flush=True)
      else:raise AssertionError('unexpected method: '+str(m))
      path.write_text(json.dumps(state))
    """)

    File.chmod!(binary, 0o755)
    settings = [tracker_kind: "memory", workspace_root: opts[:workspace_root], codex_command: binary]
    write_workflow_file!(Workflow.workflow_file_path(), settings)
    {:ok, admitted} = TaskExecution.admit(parent, work, registry, opts)
    {:ok, root: root, work: work, plan: plan, state: state, registry: registry, opts: opts, record: admitted.record, trace: trace, failure: failure}
  end

  defp current(c), do: elem(SymphonyElixir.RunJournal.read(c.record["directory"]), 1)
  defp requests(c), do: c.trace |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

  test "a prepared role activates a real native Goal, records stop proof and resumes its own thread", c do
    assert {:ok, session} = TaskSession.start(c.record, c.registry, c.opts)
    assert session.native.workspace == current(c)["workspace"]
    assert current(c)["thread_id"] == "owned-thread"
    assert {:error, :task_session_requires_recovery} = TaskSession.start(current(c), c.registry, c.opts)
    assert {:ok, opts} = TaskSession.activation_options(session)
    assert opts[:deadline] <= System.monotonic_time(:millisecond) + 100_000

    handler = fn
      %{event: :session_started, turn_id: turn} -> assert :ok = TaskSession.checkpoint(session, %{"turn_id" => turn})
      _ -> :ok
    end

    issue = %Issue{id: c.record["issue_id"], identifier: "ROLE", title: "Approved role", state: "open"}
    assert {:ok, %{goal_status: "complete"}} = AppServer.run_goal(session.native, "Produce the approved report", issue, Keyword.put(opts, :on_message, handler))
    refute current(c)["native_stop_confirmed"]
    assert :ok = TaskSession.stop(session)
    assert current(c)["native_stop_receipt"]["source"] == "thread/read"
    assert current(c)["native_stop_confirmed"]
    assert {:ok, resumed} = TaskSession.start(current(c), c.registry, c.opts)
    assert resumed.native.thread_id == session.native.thread_id
    assert {:error, :task_session_no_longer_owned} = TaskSession.checkpoint(session, %{"turn_id" => "late"})
    assert session.task_session.record["task_session_id"] != resumed.task_session.record["task_session_id"]
    rejected = DynamicTool.execute("task_context", %{}, session.native.dynamic_tool_binding)
    refute rejected["success"]
    assert rejected["output"] =~ "task_execution_no_longer_owned"
    assert :ok = TaskSession.stop(resumed)
    methods = Enum.map(requests(c), & &1["method"])
    assert Enum.count(methods, &(&1 == "thread/start")) == 1
    assert Enum.count(methods, &(&1 == "thread/resume")) == 1
    assert File.exists?(Path.join(c.record["directory"], "executor.lock"))
  end

  test "a pause after options were built blocks Goal activation and leaves the thread stoppable", c do
    assert {:ok, session} = TaskSession.start(c.record, c.registry, c.opts)
    assert {:ok, opts} = TaskSession.activation_options(session)
    pause = note(block("plan-decision", %{"action" => "pause", "revision" => c.plan["revision"]}), 2)
    Agent.update(c.state, &Map.update!(&1, "/repos/team/repo/issues/1/comments", fn notes -> notes ++ [pause] end))
    issue = %Issue{id: c.record["issue_id"], identifier: "ROLE", title: "Paused role", state: "open"}
    assert {:error, :task_activation_not_ready} = AppServer.run_goal(session.native, "Do not start", issue, opts)
    assert :ok = TaskSession.stop(session)
    refute Enum.any?(requests(c), &(&1["method"] == "thread/goal/set"))
    assert map_size(current(c)["control_receipts"]) > 0
  end

  test "single-turn activation uses the same finite role gate and records native stop separately", c do
    assert {:ok, session} = TaskSession.start(c.record, c.registry, c.opts)
    assert {:ok, opts} = TaskSession.activation_options(session)
    issue = %Issue{id: c.record["issue_id"], identifier: "ROLE", title: "Approved role", state: "open"}
    assert {:ok, %{turn_id: "owned-turn"}} = AppServer.run_turn(session.native, "Read the approved context", issue, opts)
    assert current(c)["execution_mode"] == "turn"
    refute current(c)["native_stop_confirmed"]
    assert :ok = TaskSession.stop(session)
    assert current(c)["native_stop_receipt"]["turn_id"] == "owned-turn"
  end

  test "foreign callers and late callbacks cannot mutate or stop another generation", c do
    assert {:ok, session} = TaskSession.start(c.record, c.registry, c.opts)
    task = Task.async(fn -> {TaskSession.activation_options(session), TaskSession.checkpoint(session, %{"turn_id" => "foreign"}), TaskSession.stop(session)} end)
    denied = {:error, :task_session_no_longer_owned}
    assert {^denied, ^denied, ^denied} = Task.await(task)
    original = current(c)
    replacement = Map.put(original, "attempt_id", "replacement")
    File.write!(Path.join(c.record["directory"], "run.json"), Jason.encode!(replacement))
    assert ^denied = TaskSession.checkpoint(session, %{"turn_id" => "late"})
    before_stop = requests(c)
    assert ^denied = TaskSession.stop(session)
    assert requests(c) == before_stop
    assert current(c) == replacement
  end

  test "unsupported transports, expired deadlines and missing native stop proof remain fenced", c do
    assert {:error, :unsupported_task_session_transport} = TaskSession.start(c.record, c.registry, Keyword.put(c.opts, :worker_host, "remote"))
    expired = Keyword.put(c.opts, :deadline, System.monotonic_time(:millisecond) - 1)
    assert {:error, :task_activation_budget_exhausted} = TaskSession.start(c.record, c.registry, expired)
    refute File.exists?(c.trace)
    assert {:ok, session} = TaskSession.start(current(c), c.registry, c.opts)
    File.write!(c.failure, "")
    assert {:error, _} = TaskSession.stop(session)
    refute current(c)["native_stop_confirmed"]
    assert {:error, :workspace_execution_not_ready} = TaskSession.start(current(c), c.registry, c.opts)
  end

  test "final thread admission rechecks native controls after the transport has initialized", c do
    pause = note(block("plan-decision", %{"action" => "pause", "revision" => c.plan["revision"]}), 2)

    request = fn provider, method, path, query, settings ->
      if File.exists?(c.trace) do
        Agent.update(c.state, &Map.update!(&1, "/repos/team/repo/issues/1/comments", fn [approval | _] -> [approval, pause] end))
      end

      c.opts[:request].(provider, method, path, query, settings)
    end

    assert {:error, :task_activation_not_ready} = TaskSession.start(c.record, c.registry, Keyword.put(c.opts, :request, request))
    assert Enum.any?(requests(c), &(&1["method"] == "initialize"))
    refute Enum.any?(requests(c), &(&1["method"] == "thread/start"))
    refute current(c)["thread_allocation_intent"]
  end

  test "corrupt inputs and unreadable journals cannot authorize an existing session", c do
    assert {:ok, session} = TaskSession.start(c.record, c.registry, c.opts)
    manifest = Path.join(current(c)["task_workspace"]["directory"], "manifest.json")
    original = File.read!(manifest)
    File.write!(manifest, "changed")
    assert {:error, :role_workspace_changed} = TaskSession.activation_options(session)
    File.write!(manifest, original)
    journal = Path.join(c.record["directory"], "run.json")
    original = File.read!(journal)
    File.write!(journal, "null")
    assert {:error, :invalid_run_journal} = TaskSession.activation_options(session)
    File.write!(journal, original)
    assert :ok = TaskSession.stop(session)
  end

  test "failed allocation retains uncertainty and cannot silently open a replacement transport", c do
    File.write!(c.failure, "")
    assert {:error, _} = TaskSession.start(c.record, c.registry, c.opts)
    assert current(c)["task_session_phase"] == "uncertain"
    assert current(c)["thread_allocation_intent"]
    refute current(c)["thread_id"]
    File.rm!(c.failure)
    assert {:error, :workspace_execution_not_ready} = TaskSession.start(current(c), c.registry, c.opts)
    assert Enum.count(requests(c), &(&1["method"] == "thread/start")) == 1
  end
end
