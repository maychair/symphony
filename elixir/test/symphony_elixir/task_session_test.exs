defmodule SymphonyElixir.TaskSessionTest do
  use SymphonyElixir.TestSupport, runtime: false
  alias SymphonyElixir.Codex.DynamicTool
  alias SymphonyElixir.{RunJournal, TaskExecution, TaskObserver, TaskPlan, TaskSession, TaskWorkflow, WorkRef}

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

    writer = fn "github", "POST", "/repos/team/repo/issues/2/comments" = path, _, %{"body" => body}, _ ->
      Agent.get_and_update(state, fn objects ->
        comment = note(body, 100 + length(objects[path])) |> Map.put("user", %{"id" => 99})
        {{:ok, %{status: 201, body: comment}}, Map.update!(objects, path, &(&1 ++ [comment]))}
      end)
    end

    repository = Map.take(work, ~w(provider host repository_id)) |> Map.merge(%{"path" => "team/repo", "api_url" => "https://github.test/api/v3", "credential" => "$UNUSED_SESSION_FIXTURE"})
    policy = %{"engine_actor" => "99", "max_retries" => 2, "max_repairs" => 2, "checks" => %{"review" => %{"kind" => "review"}}}
    directory = SymphonyElixir.RunJournal.directory(Path.join(root, "runs"), WorkRef.key(work))
    registry = %{WorkRef.key(work) => %{directory: directory, policy: policy}}
    opts = [request: request, write_request: writer, repositories: [repository], workspace_root: Path.join(root, "workspaces"), observation_interval_ms: 10]
    binary = Path.join(root, "role-server")
    trace = Path.join(root, "trace.jsonl")
    native = Path.join(root, "native.json")
    failure = Path.join(root, "fail-read")
    mode = Path.join(root, "mode")
    File.write!(mode, "complete")

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
          mode=pathlib.Path(#{Jason.encode!(mode)}).read_text()
          state['turns']=[{'id':'owned-turn','status':'inProgress'}]
          print(json.dumps({'method':'turn/started','params':{'threadId':state['id'],'turn':{'id':'owned-turn'}}}),flush=True)
          if mode=='complete':
            state['turns'][0]['status']='completed'
            print(json.dumps({'method':'turn/completed','params':{'threadId':state['id'],'turn':state['turns'][0]}}),flush=True)
            state['goal']['status']='complete'
            print(json.dumps({'method':'thread/goal/updated','params':{'threadId':state['id'],'goal':state['goal']}}),flush=True)
          elif mode=='candidate':
            args={'artifacts':[{'id':'report','body':'# Result\\n\\nThe approved result is reproducible.'}],'summary':'Candidate ready'}
            print(json.dumps({'id':'candidate-call','method':'item/tool/call','params':{'tool':'task_candidate','arguments':args,'callId':'candidate-call','threadId':state['id'],'turnId':'owned-turn'}}),flush=True)
      elif m=='turn/interrupt':
        state['turns'][0]['status']='interrupted';emit(q,{})
        print(json.dumps({'method':'turn/completed','params':{'threadId':state['id'],'turn':state['turns'][0]}}),flush=True)
      elif q.get('id')=='candidate-call':assert q['result']['success'] is True
      else:raise AssertionError('unexpected method: '+str(m))
      path.write_text(json.dumps(state))
    """)

    File.chmod!(binary, 0o755)
    settings = [tracker_kind: "memory", workspace_root: opts[:workspace_root], codex_command: binary]
    write_workflow_file!(Workflow.workflow_file_path(), settings)
    {:ok, admitted} = TaskExecution.admit(parent, work, registry, opts)
    {:ok, root: root, work: work, parent: parent, plan: plan, state: state, registry: registry, opts: opts, record: admitted.record, trace: trace, failure: failure, mode: mode}
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

  test "active observations preserve native progress and accounting but cannot overwrite newer task facts", c do
    {:ok, session} = TaskSession.start(c.record, c.registry, c.opts)
    :ok = TaskSession.checkpoint(session, %{"native_stop_confirmed" => false})
    record = current(c)

    request = fn provider, method, path, query, settings ->
      now = current(c)
      :ok = TaskSession.checkpoint(session, %{"turn_id" => "progress", "turn_count" => now["turn_count"] + 1, "phase" => "goal_waiting"})
      c.opts[:request].(provider, method, path, query, settings)
    end

    assert {:ok, observed} = TaskExecution.observe_running(record, c.registry, Keyword.put(c.opts, :request, request))
    before = current(c)
    assert before["turn_count"] > observed.record["turn_count"]
    assert {:ok, applied} = TaskExecution.apply_running(before, observed)
    assert applied.record["turn_count"] == before["turn_count"]
    assert applied.record["workflow"]["used_ms"] >= before["workflow"]["used_ms"]
    assert applied.flow["state"] == "running"
    assert {:error, :stale_or_unowned_execution_checkpoint} = TaskExecution.apply_running(before, observed)
    assert current(c) == applied.record
    assert {:error, :execution_observation_superseded} = TaskExecution.apply_running(Map.put(before, "new_task_fact", true), observed)
    assert {:error, :execution_attempt_changed} = TaskExecution.observe_running(Map.put(record, "task_session_id", "old"), c.registry, c.opts)
    assert :ok = TaskSession.stop(session)
  end

  test "active observation cannot recreate a missing journal or conceal native read failure", c do
    journal = Path.join(c.record["directory"], "run.json")
    stored = File.read!(journal)
    File.rm!(journal)
    assert {:error, :execution_attempt_changed} = TaskExecution.observe_running(c.record, c.registry, c.opts)
    refute File.exists?(journal)
    File.write!(journal, stored)
    request = fn _, _, _, _, _ -> {:error, :source_unavailable} end
    assert {:error, _} = TaskExecution.observe_running(c.record, c.registry, Keyword.put(c.opts, :request, request))
    assert File.read!(journal) == stored
  end

  test "managed Goal completion persists native progress without claiming task completion", c do
    {:ok, session} = TaskSession.start(c.record, c.registry, c.opts)
    assert {:ok, result} = TaskSession.run_goal(session, "Produce the approved report")
    assert {:ok, %{goal_status: "complete"}} = result.native_result
    assert result.record["turn_id"] == "owned-turn"
    assert result.record["turn_count"] == 1
    assert result.record["native_stop_confirmed"]
    refute result.flow["closeable"]
    refute File.exists?(Path.join(c.record["directory"], "executor.lock"))
    assert result.outcome == "retry"
    assert result.record["retry_count"] == 1
    assert result.reason == ":task_execution_no_progress"
    assert {:error, :task_session_not_ready} = TaskSession.run_goal(session, "Do not reuse a closed transport")
  end

  test "a pause during an active Goal interrupts its native turn and persists the restriction", c do
    File.write!(c.mode, "hold")
    {:ok, session} = TaskSession.start(c.record, c.registry, c.opts)

    handler = fn
      %{event: :session_started} ->
        pause = note(block("plan-decision", %{"action" => "pause", "revision" => c.plan["revision"]}), 2)
        Agent.update(c.state, &Map.update!(&1, "/repos/team/repo/issues/1/comments", fn notes -> notes ++ [pause] end))

      _ ->
        :ok
    end

    assert {:ok, result} = TaskSession.run_goal(session, "Wait for native control", on_message: handler)
    assert result.record["native_stop_confirmed"]
    assert result.record["task_session_phase"] == "stopped"
    assert result.flow["state"] == "waiting"
    refute result.flow["charging"]
    assert map_size(result.record["control_receipts"]) > 0
    assert result.record["retry_count"] == 0
    assert Enum.any?(requests(c), &(&1["method"] == "turn/interrupt"))
  end

  test "candidate publication through a live Goal selects a separate verifier after confirmed stop", c do
    File.write!(c.mode, "candidate")
    {:ok, session} = TaskSession.start(c.record, c.registry, c.opts)
    assert {:ok, result} = TaskSession.run_goal(session, "Publish the fixed report")
    assert result.flow["next_binding"]["role"] == "verifier"
    assert result.record["native_stop_confirmed"]
    assert Enum.any?(requests(c), &(&1["id"] == "candidate-call" and &1["result"]["success"]))
    assert result.outcome == "continue"
    assert result.record["retry_count"] == 0
    assert {:ok, verifying} = TaskExecution.admit(c.parent, c.work, c.registry, c.opts)
    assert verifying.record["execution_generation"] == 2
    refute verifying.record["task_session_id"]
    assert hd(verifying.record["execution_history"])["task_session_phase"] == "stopped"
  end

  defp after_running(c, effect) do
    owner = self()
    reacted = start_supervised!({Agent, fn -> false end}, id: :running_observation_effect)

    request = fn provider, method, path, query, settings ->
      record = current(c)

      if self() != owner and record["workflow"]["state"] == "running" and Agent.get_and_update(reacted, &{not &1, true}) do
        effect.(record)
        send(owner, {:running_observed, record["workflow"]["used_ms"]})
      end

      c.opts[:request].(provider, method, path, query, settings)
    end

    Keyword.merge(c.opts, request: request, deadline: System.monotonic_time(:millisecond) + 8_000)
  end

  test "healthy observations keep the Goal active and a subsequent native pause stops it", c do
    File.write!(c.mode, "hold")

    opts =
      after_running(c, fn _ ->
        pause = note(block("plan-decision", %{"action" => "pause", "revision" => c.plan["revision"]}), 2)
        Agent.update(c.state, &Map.update!(&1, "/repos/team/repo/issues/1/comments", fn notes -> notes ++ [pause] end))
      end)

    {:ok, session} = TaskSession.start(c.record, c.registry, opts)
    assert {:ok, result} = TaskSession.run_goal(session, "Observe until paused")
    assert_receive {:running_observed, used_ms}
    assert result.record["workflow"]["used_ms"] >= used_ms
    refute result.record["task_observation_error"]
    assert result.flow["state"] == "waiting"
    assert result.record["native_stop_confirmed"]
    assert Enum.any?(requests(c), &(&1["method"] == "turn/interrupt"))
  end

  test "physical input corruption during a healthy Goal stops it before applying new facts", c do
    File.write!(c.mode, "hold")
    opts = after_running(c, fn record -> File.write!(Path.join(record["task_workspace"]["directory"], "manifest.json"), "corrupt") end)
    {:ok, session} = TaskSession.start(c.record, c.registry, opts)
    assert {:ok, result} = TaskSession.run_goal(session, "Keep fixed inputs")
    assert_receive {:running_observed, _}
    assert result.record["task_observation_error"] == ":role_workspace_changed"
    assert result.record["native_stop_confirmed"]
    assert Enum.any?(requests(c), &(&1["method"] == "turn/interrupt"))
  end

  defp blocked_reader(c, extra) do
    owner = self()

    request = fn provider, method, path, query, settings ->
      if self() != owner and not Process.get(:read_released, false) do
        send(owner, {:reader, self()})

        receive do
          :release -> Process.put(:read_released, true)
        end
      end

      c.opts[:request].(provider, method, path, query, settings)
    end

    c.opts |> Keyword.put(:request, request) |> Keyword.merge(extra)
  end

  test "a timed-out native fact read blocks the Goal and its reader cannot survive cleanup", c do
    File.write!(c.mode, "hold")
    opts = blocked_reader(c, observation_timeout_ms: 100)
    {:ok, session} = TaskSession.start(c.record, c.registry, opts)
    assert {:ok, result} = TaskSession.run_goal(session, "Wait for current facts")
    assert result.record["task_observation_error"] == ":observation_timeout"
    assert result.record["native_stop_confirmed"]
    assert_receive {:reader, reader}
    refute Process.alive?(reader)
  end

  test "pending native reads cannot delay the Goal budget deadline", c do
    File.write!(c.mode, "hold")
    opts = blocked_reader(c, observation_timeout_ms: 60_000, deadline: System.monotonic_time(:millisecond) + 2_000)
    {:ok, session} = TaskSession.start(c.record, c.registry, opts)
    started = System.monotonic_time(:millisecond)
    assert {:ok, result} = TaskSession.run_goal(session, "Respect the native deadline")
    assert result.native_result == {:error, :execution_budget_exhausted}
    assert result.record["native_stop_confirmed"]
    assert System.monotonic_time(:millisecond) - started < 5_000
    assert_receive {:reader, reader}
    refute Process.alive?(reader)
  end

  defp observed_result(observer, remaining \\ 200) do
    case :sys.get_state(observer).result do
      :pending when remaining > 0 ->
        Process.sleep(10)
        observed_result(observer, remaining - 1)

      :pending ->
        flunk("native observation did not settle")

      result ->
        result
    end
  end

  test "observation ownership and freshness are checked without blocking the native caller", c do
    invalid = [observation_interval_ms: 0]
    assert {:error, :invalid_observation_timing} = TaskObserver.start_link(c.record, c.registry, invalid)
    opts = blocked_reader(c, observation_timeout_ms: 1_000)
    {:ok, observer} = TaskObserver.start_link(c.record, c.registry, opts)
    assert :pending = TaskObserver.take(observer)
    denied = {:error, :observation_not_owned}
    other = Task.async(fn -> {TaskObserver.take(observer), TaskObserver.activate(observer), TaskObserver.stop(observer)} end)
    assert {^denied, ^denied, ^denied} = Task.await(other)
    assert :ok = TaskObserver.activate(observer)
    assert {:error, :observation_already_active} = TaskObserver.activate(observer)
    assert_receive {:reader, reader}
    assert :pending = TaskObserver.take(observer)
    send(reader, :release)
    assert {:ok, _} = observed_result(observer)
    Process.sleep(1_050)
    assert {:error, :observation_expired} = TaskObserver.take(observer)
    assert :ok = TaskObserver.stop(observer)
  end

  test "a crashed observation becomes an error while the session owner and journal remain intact", c do
    before = current(c)
    request = fn _, _, _, _, _ -> raise "native reader fixture failure" end
    {:ok, observer} = TaskObserver.start_link(c.record, c.registry, Keyword.put(c.opts, :request, request))

    capture_log(fn ->
      assert :ok = TaskObserver.activate(observer)
      assert {:error, {:observation_process_failed, _}} = observed_result(observer)
    end)

    assert {:error, {:observation_process_failed, _}} = TaskObserver.take(observer)
    assert current(c) == before
    assert :ok = TaskObserver.stop(observer)
  end

  test "owner death terminates the observer and its pending reader without a journal write", c do
    before = current(c)
    parent = self()
    opts = blocked_reader(c, observation_timeout_ms: 60_000)

    {owner, owner_ref} =
      spawn_monitor(fn ->
        {:ok, observer} = TaskObserver.start_link(c.record, c.registry, opts)
        :ok = TaskObserver.activate(observer)
        send(parent, {:observer, observer})

        receive do
          :finish -> :ok
        end
      end)

    assert_receive {:observer, observer}
    assert_receive {:reader, reader}
    observer_ref = Process.monitor(observer)
    reader_ref = Process.monitor(reader)

    capture_log(fn ->
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^owner_ref, :process, ^owner, :killed}
      assert_receive {:DOWN, ^observer_ref, :process, ^observer, _}
      assert_receive {:DOWN, ^reader_ref, :process, ^reader, _}
    end)

    assert current(c) == before
  end

  test "an old Goal loop cannot interrupt a replacement execution", c do
    File.write!(c.mode, "hold")
    {:ok, session} = TaskSession.start(c.record, c.registry, c.opts)

    handler = fn
      %{event: :session_started} ->
        replacement = Map.put(current(c), "attempt_id", "replacement")
        File.write!(Path.join(c.record["directory"], "run.json"), Jason.encode!(replacement))

      _ ->
        :ok
    end

    assert {:error, :task_session_no_longer_owned} = TaskSession.run_goal(session, "Lose ownership", on_message: handler)
    assert current(c)["attempt_id"] == "replacement"
    refute Enum.any?(requests(c), &(&1["method"] == "turn/interrupt" or get_in(&1, ["params", "status"]) == "blocked"))
  end

  test "native stop fences also prevent implicit cleanup from issuing unauthorized Goal writes", c do
    File.write!(c.mode, "hold")
    {:ok, session} = TaskSession.start(c.record, c.registry, c.opts)
    {:ok, opts} = TaskSession.activation_options(session)
    opts = Keyword.merge(opts, handoff_status: fn -> "blocked" end, before_goal_stop: fn -> {:error, :owner_changed} end)
    issue = %Issue{id: c.record["issue_id"], identifier: "ROLE", title: "Fence cleanup", state: "open"}
    assert {:error, {:goal_stream_failed, _}} = AppServer.run_goal(session.native, "Stop fence fixture", issue, opts)
    refute Enum.any?(requests(c), &(&1["method"] == "turn/interrupt" or get_in(&1, ["params", "status"]) == "blocked"))
    assert :ok = TaskSession.stop(session)
  end

  test "transport and caller failures retain uncertainty or obtain explicit native stop proof", c do
    {:ok, session} = TaskSession.start(c.record, c.registry, c.opts)
    :ok = AppServer.stop_session(session.native)
    assert {:error, :native_stop_transport_unavailable} = TaskSession.run_goal(session, "Closed transport")
    refute current(c)["native_stop_confirmed"]
  end

  test "a throwing event consumer still stops its native Goal and retains the failed result", c do
    File.write!(c.mode, "hold")
    {:ok, session} = TaskSession.start(c.record, c.registry, c.opts)

    handler = fn
      %{event: :session_started} -> throw(:consumer_failed)
      _ -> :ok
    end

    assert {:ok, result} = TaskSession.run_goal(session, "Fail the consumer", on_message: handler)
    assert {:error, {:task_goal_failed, :throw, ":consumer_failed"}} = result.native_result
    assert result.record["native_stop_confirmed"]
  end

  test "repeated Goals without task progress exhaust retries without resetting generation or budget", c do
    final =
      Enum.reduce(1..3, c.record, fn attempt, record ->
        {:ok, session} = TaskSession.start(record, c.registry, c.opts)
        {:ok, result} = TaskSession.run_goal(session, "Return without publishing")
        assert result.record["retry_count"] == attempt
        assert result.record["execution_generation"] == 1
        assert result.record["workflow"]["used_ms"] >= record["workflow"]["used_ms"]
        assert map_size(result.record["task_attempt_results"]) == attempt
        unchanged = File.read!(Path.join(record["directory"], "run.json"))
        assert {:ok, duplicate} = TaskExecution.finish(result.record, {:error, :different_result}, c.registry, [])
        assert duplicate.record == result.record
        assert File.read!(Path.join(record["directory"], "run.json")) == unchanged

        if attempt < 3 do
          assert result.outcome == "retry"
          assert {:ok, next} = TaskExecution.admit(c.parent, c.work, c.registry, c.opts)
          assert next.record["thread_id"] == result.record["thread_id"]
          assert {:error, :execution_attempt_changed} = TaskExecution.finish(result.record, :ok, c.registry, c.opts)
          next.record
        else
          assert result.outcome == "waiting"
          result.record
        end
      end)

    assert final["workflow"]["restrictions"]["retry_limit"]
    assert {:waiting, _} = TaskExecution.admit(c.parent, c.work, c.registry, c.opts)
    refute File.exists?(Path.join(final["directory"], "executor.lock"))
  end

  test "scheduler stop before Goal activation finalizes without consuming retries", c do
    {:ok, session} = TaskSession.start(c.record, c.registry, c.opts)
    send(self(), :symphony_stop)
    assert {:ok, result} = TaskSession.run_goal(session, "Respect scheduler stop")
    assert result.native_result == {:error, :scheduler_stop}
    assert result.outcome == "continue"
    assert result.record["retry_count"] == 0
    assert result.record["native_stop_confirmed"]
    refute Enum.any?(requests(c), &(&1["method"] == "thread/goal/set"))
  end

  test "a pause before managed activation still finalizes the allocated idle session", c do
    {:ok, session} = TaskSession.start(c.record, c.registry, c.opts)
    pause = note(block("plan-decision", %{"action" => "pause", "revision" => c.plan["revision"]}), 2)
    Agent.update(c.state, &Map.update!(&1, "/repos/team/repo/issues/1/comments", fn notes -> notes ++ [pause] end))
    assert {:ok, result} = TaskSession.run_goal(session, "Do not activate")
    assert result.native_result == {:error, :task_activation_not_ready}
    assert result.record["native_stop_confirmed"]
    assert result.record["retry_count"] == 0
    assert result.outcome == "waiting"
    refute File.exists?(Path.join(result.record["directory"], "executor.lock"))
  end

  test "unreadable native facts after stop preserve unknown evidence and release only execution ownership", c do
    request = fn provider, method, path, query, settings ->
      if current(c)["task_session_phase"] == "stopped",
        do: {:error, :source_unavailable},
        else: c.opts[:request].(provider, method, path, query, settings)
    end

    {:ok, session} = TaskSession.start(c.record, c.registry, Keyword.put(c.opts, :request, request))
    assert {:ok, result} = TaskSession.run_goal(session, "Stop before provider failure")
    assert result.flow["evidence"] == "unknown"
    refute result.flow["dispatchable"]
    refute result.flow["closeable"]
    assert result.reason =~ "finalization_evidence_unconfirmed"
    assert result.record["native_stop_confirmed"]
    assert {:ok, resumed} = TaskExecution.admit(c.parent, c.work, c.registry, c.opts)
    refute resumed.flow["restrictions"]["finalization_evidence"]
  end

  for boundary <- ["finalizing", "completed"] do
    @boundary boundary
    test "finalization recovers the #{@boundary} boundary without counting the failure twice", c do
      {:ok, session} = TaskSession.start(c.record, c.registry, c.opts)
      marker = Path.join([c.record["directory"], "executor.lock", "cleanup-owner.json"])
      File.write!(marker, "protect cleanup")
      assert {:error, {:execution_lock_owner_changed, _}} = TaskSession.run_goal(session, "Finalize once")
      record = current(c)
      assert record["retry_count"] == 1
      assert record["native_stop_confirmed"]
      assert record["phase"] == "completed"
      assert File.read!(marker) == "protect cleanup"
      # Replay the durable boundary left by interruption before/after the final
      # phase checkpoint. Keep the real lock, receipt and native stop proof.
      record = Map.put(record, "phase", @boundary)
      File.write!(Path.join(record["directory"], "run.json"), Jason.encode!(record))
      File.rm!(marker)
      assert {:ok, recovered} = TaskExecution.finish(record, {:error, :replayed}, c.registry, [])
      assert recovered.record["retry_count"] == 1
      assert recovered.record["task_attempt_results"] == record["task_attempt_results"]
      refute File.exists?(Path.dirname(marker))
    end
  end

  test "uncertain native allocation finalizes as an incident and cannot admit a replacement", c do
    File.write!(c.failure, "")
    assert {:error, _} = TaskSession.start(c.record, c.registry, c.opts)
    assert {:ok, finished} = TaskExecution.finish(current(c), {:error, :allocation_response_lost}, c.registry, [])
    assert finished.outcome == "incident"
    assert finished.record["phase"] == "incident"
    assert finished.flow["execution"] == "uncertain"
    refute finished.flow["dispatchable"]
    refute finished.record["native_stop_confirmed"]
    File.rm!(c.failure)
    assert {:waiting, _} = TaskExecution.admit(c.parent, c.work, c.registry, c.opts)
    assert Enum.count(requests(c), &(&1["method"] == "thread/start")) == 1
  end

  test "failure before native allocation consumes a bounded retry and preserves the same admitted scope", c do
    assert {:ok, finished} = TaskExecution.finish(c.record, {:error, :workspace_prepare_failed}, c.registry, c.opts)
    assert finished.outcome == "retry"
    assert finished.record["retry_count"] == 1
    refute finished.record["thread_allocation_intent"]
    assert {:ok, next} = TaskExecution.admit(c.parent, c.work, c.registry, c.opts)
    assert next.record["execution_binding"] == c.record["execution_binding"]
  end

  test "a changed journal during final observation cannot be overwritten or released", c do
    once = start_supervised!({Agent, fn -> false end}, id: :finalization_update)

    request = fn provider, method, path, query, settings ->
      if Agent.get_and_update(once, &{not &1, true}), do: RunJournal.checkpoint(current(c), %{"new_fact" => "preserve"})
      c.opts[:request].(provider, method, path, query, settings)
    end

    assert {:error, :stale_or_unowned_execution_checkpoint} = TaskExecution.finish(c.record, {:error, :failed}, c.registry, Keyword.put(c.opts, :request, request))
    assert current(c)["new_fact"] == "preserve"
    refute current(c)["task_attempt_results"]
    assert File.exists?(Path.join(c.record["directory"], "executor.lock"))
    assert {:ok, _} = TaskExecution.finish(current(c), {:error, :failed}, c.registry, c.opts)
  end

  test "malformed finalization receipts and missing or foreign records do not authorize cleanup", c do
    assert {:ok, finished} = TaskExecution.finish(c.record, {:error, :failed}, c.registry, c.opts)
    journal = Path.join(c.record["directory"], "run.json")
    corrupted = put_in(finished.record, ["task_attempt_results", c.record["attempt_id"]], %{"phase" => "completed"})
    File.write!(journal, Jason.encode!(corrupted))
    assert {:error, :invalid_attempt_result} = TaskExecution.finish(finished.record, :ok, c.registry, c.opts)
    foreign = Map.put(finished.record, "task_session_id", "other")
    assert {:error, :execution_attempt_changed} = TaskExecution.finish(foreign, :ok, c.registry, c.opts)
    File.rm!(journal)
    assert {:error, :execution_attempt_changed} = TaskExecution.finish(finished.record, :ok, c.registry, c.opts)
    File.write!(journal, "null")
    assert {:error, :invalid_run_journal} = TaskExecution.finish(finished.record, :ok, c.registry, c.opts)
  end

  test "legacy finalization and worker-down handling cannot rewrite a plan member", c do
    issue = %Issue{id: c.record["issue_id"], identifier: "ROLE", title: "Owned member", state: "open"}
    before = File.read!(Path.join(c.record["directory"], "run.json"))
    assert {:error, :plan_execution_finalizer_required} = SymphonyElixir.Execution.finish(issue, [run_record: c.record], :ok)
    path = Workflow.workflow_file_path()
    agent = "agent:\n  goal_mode: true\n  run_journal_dir: " <> Jason.encode!(Path.dirname(c.record["directory"])) <> "\n"
    File.write!(path, String.replace(File.read!(path), "agent:\n", agent))
    WorkflowStore.force_reload()
    assert {:blocked, reason} = SymphonyElixir.Execution.worker_down(issue.id, :killed)
    assert reason =~ "plan_execution_finalizer_required"
    assert File.read!(Path.join(c.record["directory"], "run.json")) == before
    assert File.exists?(Path.join(c.record["directory"], "executor.lock"))
  end
end
