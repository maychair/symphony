defmodule SymphonyElixir.TaskSessionTest do
  use SymphonyElixir.TestSupport, runtime: false
  alias SymphonyElixir.Codex.DynamicTool
  alias SymphonyElixir.{RunJournal, TaskExecution, TaskObserver, TaskPlan, TaskSession, TaskWorkflow, WorkRef}
  alias SymphonyElixir.TaskPlanExecution

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

  setup tags do
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
    import json,sys,pathlib,hashlib
    path=pathlib.Path(#{Jason.encode!(native)})
    state=json.loads(path.read_text()) if path.exists() else {'id':'owned-thread','goal':None,'turns':[],'allocations':0}
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
        else:
          if m=='thread/start':
            state['allocations']+=1
            state['id']='owned-thread' if state['allocations']==1 else 'owned-thread-'+str(state['allocations'])
            state['goal']=None;state['turns']=[]
          emit(q,{'thread':{'id':state['id'],'status':{'type':'idle'},'turns':state['turns']}})
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
          elif mode in ['develop','verify','reject']:
            print(json.dumps({'id':'context-call','method':'item/tool/call','params':{'tool':'task_context','arguments':{},'callId':'context-call','threadId':state['id'],'turnId':'owned-turn'}}),flush=True)
      elif m=='turn/interrupt':
        state['turns'][0]['status']='interrupted';emit(q,{})
        print(json.dumps({'method':'turn/completed','params':{'threadId':state['id'],'turn':state['turns'][0]}}),flush=True)
      elif q.get('id')=='context-call':
        assert q['result']['success'] is True
        context=json.loads(q['result']['contentItems'][0]['text'])['data']
        mode=pathlib.Path(#{Jason.encode!(mode)}).read_text()
        if mode=='develop':
          tool='task_candidate';args={'artifacts':[{'id':'report','body':'# Result\\n\\nVerified scope result '+str(state['allocations'])+'.'}],'summary':'Candidate ready'}
        else:
          findings=[]
          if mode=='reject':
            findings=[{'id':'missing-detail','criterion':'result','status':'valid','required':True,'rationale':'Add the missing report detail','problem_sha':hashlib.sha256(b'missing detail').hexdigest(),'repair_basis_sha':hashlib.sha256(context['candidate']['digest'].encode()).hexdigest(),'evidence':[context['candidate']['source']]}]
          tool='task_verification';args={'review_checks':[{'id':'review','result':'failed' if mode=='reject' else 'passed','rationale':'Fixed report independently inspected'}],'findings':findings,'summary':'Independent verification'}
        print(json.dumps({'id':'result-call','method':'item/tool/call','params':{'tool':tool,'arguments':args,'callId':'result-call','threadId':state['id'],'turnId':'owned-turn'}}),flush=True)
      elif q.get('id') in ['candidate-call','result-call']:assert q['result']['success'] is True
      else:raise AssertionError('unexpected method: '+str(m))
      path.write_text(json.dumps(state))
    """)

    File.chmod!(binary, 0o755)
    settings = [tracker_kind: "memory", workspace_root: opts[:workspace_root], codex_command: binary]
    write_workflow_file!(Workflow.workflow_file_path(), settings)

    record =
      if tags[:unadmitted] do
        %{"directory" => directory, "issue_id" => WorkRef.key(work)}
      else
        {:ok, admitted} = TaskExecution.admit(parent, work, registry, opts)
        admitted.record
      end

    scope = [root: root, work: work, parent: parent, plan: plan, state: state, registry: registry]
    {:ok, scope ++ [opts: opts, record: record, trace: trace, failure: failure, mode: mode]}
  end

  defp current(c), do: elem(SymphonyElixir.RunJournal.read(c.record["directory"]), 1)
  defp requests(c), do: c.trace |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

  defp scheduler_options(c) do
    policy = c.registry[WorkRef.key(c.work)].policy
    repositories = Enum.map(c.opts[:repositories], &Map.put(&1, "execution", %{"policy" => policy}))
    provider = %{"plan_roots" => [c.parent], "plan_repositories" => repositories}
    path = Workflow.workflow_file_path()
    workflow = String.replace(File.read!(path), "tracker:\n", "tracker:\n  provider: " <> Jason.encode!(provider) <> "\n")
    workflow = String.replace(workflow, "agent:\n", "agent:\n  run_journal_dir: " <> Jason.encode!(Path.dirname(c.record["directory"])) <> "\n")
    File.write!(path, workflow)
    WorkflowStore.force_reload()
    Keyword.delete(c.opts, :repositories)
  end

  defp start_scheduler(opts) do
    supervisor = start_supervised!({Task.Supervisor, []})
    start_orchestrator(supervisor, opts)
  end

  defp start_orchestrator(supervisor, opts) do
    options = [name: SymphonyElixir.TaskSessionOrchestrator, task_supervisor: supervisor, plan_options: opts]
    start_supervised!({Orchestrator, options})
  end

  defp crash_member(c) do
    File.write!(c.mode, "hold")
    supervisor = start_supervised!({Task.Supervisor, []})
    runner = fn -> AgentRunner.run_member(c.parent, c.work, c.registry, nil, c.opts) end
    {:ok, worker} = Task.Supervisor.start_child(supervisor, runner)

    await_scheduler(fn ->
      case RunJournal.read(c.record["directory"]) do
        {:ok, %{"turn_id" => "owned-turn"}} -> true
        _ -> false
      end
    end)

    ref = Process.monitor(worker)
    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^ref, :process, ^worker, :killed}
    current(c)
  end

  defp await_scheduler(fun, attempts \\ 500)
  defp await_scheduler(_fun, 0), do: flunk("scheduler did not reach the expected state")

  defp await_scheduler(fun, attempts) do
    case fun.() do
      value when value in [false, nil] ->
        Process.sleep(10)
        await_scheduler(fun, attempts - 1)

      value ->
        value
    end
  end

  @tag :unadmitted
  test "the existing scheduler discovers a configured plan and continues through independent repair roles", c do
    owner = self()

    ready = fn record ->
      generation = record["execution_generation"]
      mode = Enum.at(["develop", "reject", "develop", "verify"], generation - 1)
      File.write!(c.mode, mode)
      send(owner, {:scheduled_role, generation, record["execution_binding"]["role"]})
      :ok
    end

    opts = scheduler_options(c) |> Keyword.put(:on_ready, ready)
    path = Workflow.workflow_file_path()
    File.write!(path, String.replace(File.read!(path), "agent:\n", "agent:\n  goal_mode: true\n  run_budget_ms: 1\n"))
    WorkflowStore.force_reload()
    assert SymphonyElixir.Execution.run_budget_ms("legacy") == 1
    assert {:ok, [job]} = Tracker.fetch_issues_by_states(["Todo"], opts)
    assert job.dispatchable
    assert TaskPlanExecution.job?(job)
    refute File.exists?(c.record["directory"])
    scheduler = start_scheduler(opts)

    for {generation, role} <- [{1, "developer"}, {2, "verifier"}, {3, "developer"}, {4, "verifier"}] do
      assert_receive {:scheduled_role, ^generation, ^role}, 10_000

      if generation < 4 do
        await_scheduler(fn -> :sys.get_state(scheduler).retry_attempts[job.id] end)
        assert :ok = GenServer.call(scheduler, {:retry_now, job.id})
      end
    end

    await_scheduler(fn -> map_size(:sys.get_state(scheduler).running) == 0 end)
    state = :sys.get_state(scheduler)
    assert state.retry_attempts == %{}
    assert state.blocked == %{}
    assert current(c)["native_stop_confirmed"]
    assert current(c)["retry_count"] == 0
    assert current(c)["execution_generation"] == 4
    assert {:ok, [finished]} = Tracker.fetch_issues_by_ids([job.id], opts)
    refute finished.dispatchable
    assert finished.native_ref["lifecycle"]["closeable"]
    assert Agent.get(c.state, & &1["/repos/team/repo/issues/2"]["state"]) == "open"
    assert Enum.count(requests(c), &(&1["method"] == "thread/start")) == 4
  end

  @tag :unadmitted
  test "scheduler polling preserves an active locked member and rejects foreign completion messages", c do
    File.write!(c.mode, "hold")
    owner = self()

    opts =
      scheduler_options(c)
      |> Keyword.put(:on_ready, fn _ ->
        send(owner, :member_ready)
        :ok
      end)

    scheduler = start_scheduler(opts)
    assert_receive :member_ready, 10_000
    id = "member:" <> WorkRef.key(c.work)
    entry = :sys.get_state(scheduler).running[id]
    assert entry.worker_host == nil
    send(scheduler, {:member_worker_result, id, entry.pid, make_ref(), {:waiting, %{}}})
    send(scheduler, {:member_worker_result, id, self(), entry.dispatch_token, {:waiting, %{}}})
    send(scheduler, :run_poll_cycle)
    assert :sys.get_state(scheduler).running[id].pid == entry.pid
    refute :sys.get_state(scheduler).running[id][:member_result]
    refute :sys.get_state(scheduler).running[id][:stop_requested]
    assert Process.alive?(entry.pid)
    assert {:error, :member_result_unconfirmed} = TaskExecution.completed_result(current(c))
    assert {:ok, [locked]} = Tracker.fetch_issues_by_ids([id], opts)
    refute locked.dispatchable

    pause = note(block("plan-decision", %{"action" => "pause", "revision" => c.plan["revision"]}), 2)
    Agent.update(c.state, &Map.update!(&1, "/repos/team/repo/issues/1/comments", fn notes -> notes ++ [pause] end))
    await_scheduler(fn -> map_size(:sys.get_state(scheduler).running) == 0 end)
    assert current(c)["native_stop_confirmed"]
    assert :sys.get_state(scheduler).retry_attempts == %{}
    send(scheduler, :run_poll_cycle)
    assert :sys.get_state(scheduler).running == %{}
    assert Enum.count(requests(c), &(&1["method"] == "thread/start")) == 1
  end

  @tag :unadmitted
  test "a killed local member is stopped under its original attempt before scheduler restart", c do
    File.write!(c.mode, "hold")
    owner = self()

    opts =
      scheduler_options(c)
      |> Keyword.put(:on_ready, fn _ ->
        send(owner, :member_ready)
        :ok
      end)

    scheduler = start_scheduler(opts)
    assert_receive :member_ready, 10_000
    id = "member:" <> WorkRef.key(c.work)
    await_scheduler(fn -> current(c)["turn_id"] == "owned-turn" end)
    entry = :sys.get_state(scheduler).running[id]
    original = current(c)
    Process.exit(entry.pid, :kill)
    await_scheduler(fn -> :sys.get_state(scheduler).blocked[id] end)
    assert :sys.get_state(scheduler).retry_attempts == %{}
    assert File.exists?(Path.join(c.record["directory"], "executor.lock"))
    pause = note(block("plan-decision", %{"action" => "pause", "revision" => c.plan["revision"]}), 2)
    Agent.update(c.state, &Map.update!(&1, "/repos/team/repo/issues/1/comments", fn notes -> notes ++ [pause] end))
    send(scheduler, :run_poll_cycle)
    await_scheduler(fn -> current(c)["phase"] == "completed" and :sys.get_state(scheduler).running == %{} end)
    assert current(c)["native_stop_confirmed"]
    assert current(c)["attempt_id"] == original["attempt_id"]
    assert current(c)["attempt_count"] == original["attempt_count"]
    assert current(c)["retry_count"] == (original["retry_count"] || 0)
    refute :sys.get_state(scheduler).blocked[id]
    supervisor = :sys.get_state(scheduler).task_supervisor
    assert :ok = stop_supervised(Orchestrator)
    restarted = start_orchestrator(supervisor, opts)
    send(restarted, :run_poll_cycle)
    assert :sys.get_state(restarted).running == %{}
    refute File.exists?(Path.join(c.record["directory"], "executor.lock"))
    assert Enum.count(requests(c), &(&1["method"] == "thread/start")) == 1
  end

  @tag :unadmitted
  test "scheduler retries consume the original finite counter and stop after repeated no progress", c do
    opts = scheduler_options(c)
    scheduler = start_scheduler(opts)
    id = "member:" <> WorkRef.key(c.work)

    for count <- [1, 2] do
      await_scheduler(fn -> :sys.get_state(scheduler).retry_attempts[id] end)
      assert current(c)["retry_count"] == count
      assert :ok = GenServer.call(scheduler, {:retry_now, id})
    end

    await_scheduler(fn ->
      record = current(c)
      record["retry_count"] == 3 and record["phase"] == "completed" and :sys.get_state(scheduler).running == %{}
    end)

    assert :sys.get_state(scheduler).retry_attempts == %{}
    send(scheduler, :run_poll_cycle)
    assert :sys.get_state(scheduler).running == %{}
    assert Enum.count(requests(c), &(&1["method"] == "thread/start")) == 1
    assert Enum.count(requests(c), &(&1["method"] == "thread/resume")) == 2
    assert current(c)["native_stop_confirmed"]
  end

  @tag :unadmitted
  test "local recovery stops the original thread, charges one failure and resumes without another allocation", c do
    original = crash_member(c)
    assert RunJournal.interrupted_member?(original)
    other = %{c.work | "number" => 3}
    foreign_registry = %{WorkRef.key(other) => c.registry[WorkRef.key(c.work)]}
    before = requests(c)

    assert {:error, :member_recovery_scope_changed} =
             AgentRunner.run_member(c.parent, other, foreign_registry, nil, c.opts)

    assert current(c) == original
    assert requests(c) == before
    assert {:ok, recovered} = AgentRunner.run_member(c.parent, c.work, c.registry, nil, c.opts)
    assert recovered.outcome == "retry"
    assert recovered.record["attempt_id"] == original["attempt_id"]
    assert recovered.record["attempt_count"] == 1
    assert recovered.record["retry_count"] == 1
    assert recovered.record["workflow"]["used_ms"] >= original["workflow"]["used_ms"]
    assert recovered.record["native_stop_confirmed"]
    assert recovered.record["task_session_phase"] == "stopped"
    assert Enum.count(requests(c), &(&1["method"] == "thread/start")) == 1
    refute Enum.any?(requests(c), &(&1["method"] == "thread/resume"))
    File.write!(c.mode, "develop")
    assert {:ok, continued} = AgentRunner.run_member(c.parent, c.work, c.registry, nil, c.opts)
    assert continued.outcome == "continue"
    assert continued.record["retry_count"] == 1
    assert continued.record["attempt_count"] == 2
    assert continued.record["thread_id"] == original["thread_id"]
    assert Enum.count(requests(c), &(&1["method"] == "thread/start")) == 1
    assert Enum.count(requests(c), &(&1["method"] == "thread/resume")) == 1
  end

  @tag :unadmitted
  test "recovery with an unconfirmed native stop becomes an incident without replacement", c do
    original = crash_member(c)
    File.write!(c.failure, "")
    assert {:ok, result} = SymphonyElixir.TaskRecovery.recover(original, c.registry, c.opts)
    assert result.outcome == "incident"
    refute result.record["native_stop_confirmed"]
    refute result.flow["dispatchable"]
    assert result.record["retry_count"] == (original["retry_count"] || 0)
    assert {:waiting, _} = AgentRunner.run_member(c.parent, c.work, c.registry, nil, c.opts)
    assert Enum.count(requests(c), &(&1["method"] == "thread/start")) == 1
    refute Enum.any?(requests(c), &(&1["method"] == "thread/resume"))
  end

  @tag :unadmitted
  test "only one recovery caller can claim a dead member, and stale recovery cannot steal it", c do
    original = crash_member(c)
    owner = self()

    contenders =
      for _ <- 1..2 do
        spawn(fn ->
          result = RunJournal.recover_member(original)
          send(owner, {:claimed_recovery, self(), result})
          receive do: (:release -> :ok)
        end)
      end

    on_exit(fn -> Enum.each(contenders, &Process.exit(&1, :kill)) end)

    results =
      for _ <- contenders do
        assert_receive {:claimed_recovery, worker, result}, 2_000
        {worker, result}
      end

    assert Enum.count(results, &match?({_, {:ok, _}}, &1)) == 1
    assert Enum.count(results, &match?({_, {:error, :member_recovery_not_owned}}, &1)) == 1
    refute RunJournal.interrupted_member?(current(c))
    assert {:error, :member_recovery_not_owned} = SymphonyElixir.TaskRecovery.recover(original, c.registry, c.opts)

    Enum.each(contenders, fn worker ->
      ref = Process.monitor(worker)
      send(worker, :release)
      assert_receive {:DOWN, ^ref, :process, ^worker, :normal}
    end)

    assert {:ok, %{outcome: "retry"}} = SymphonyElixir.TaskRecovery.recover(current(c), c.registry, c.opts)
    assert current(c)["attempt_count"] == original["attempt_count"]
  end

  test "live, foreign-VM and missing member ownership never authorize local recovery", c do
    refute RunJournal.interrupted_member?(c.record)
    refute RunJournal.interrupted_member?(Map.delete(c.record, "executor_identity"))
    foreign = put_in(c.record, ["executor_identity", "vm"], String.duplicate("a", 32))
    refute RunJournal.interrupted_member?(foreign)
    refute RunJournal.interrupted_member?(nil)
    assert {:error, :member_recovery_not_owned} = RunJournal.recover_member(c.record)
    refute File.exists?(c.trace)
  end

  @tag :unadmitted
  test "recovery replays a completed result after lock-release failure without charging twice", c do
    File.write!(c.mode, "develop")
    barrier = Path.join([c.record["directory"], "executor.lock", "release-barrier"])
    opts = Keyword.put(c.opts, :on_ready, fn _ -> File.write(barrier, "") end)
    task = Task.async(fn -> AgentRunner.run_member(c.parent, c.work, c.registry, nil, opts) end)
    assert {:error, {:execution_lock_owner_changed, _}} = Task.await(task, 10_000)
    stopped = current(c)
    assert stopped["phase"] == "completed"
    assert stopped["native_stop_confirmed"]
    File.rm!(barrier)
    before = requests(c)
    assert {:ok, replayed} = SymphonyElixir.TaskRecovery.recover(stopped, c.registry, c.opts)
    assert replayed.outcome == "continue"
    assert replayed.record["task_attempt_results"] == stopped["task_attempt_results"]
    assert replayed.record["retry_count"] == stopped["retry_count"]
    assert requests(c) == before
  end

  @tag :unadmitted
  test "an interrupted admission is recoverable but a lost thread allocation remains uncertain", c do
    task = Task.async(fn -> TaskExecution.admit(c.parent, c.work, c.registry, c.opts) end)
    assert {:ok, admitted} = Task.await(task)
    assert {:ok, result} = SymphonyElixir.TaskRecovery.recover(admitted.record, c.registry, c.opts)
    assert result.outcome == "retry"
    assert result.record["native_stop_confirmed"]
    refute File.exists?(c.trace)

    task =
      Task.async(fn ->
        {:ok, admitted} = TaskExecution.admit(c.parent, c.work, c.registry, c.opts)
        RunJournal.checkpoint(admitted.record, %{"thread_allocation_intent" => true, "native_stop_confirmed" => false})
      end)

    assert {:ok, uncertain} = Task.await(task)
    assert {:ok, result} = SymphonyElixir.TaskRecovery.recover(uncertain, c.registry, c.opts)
    assert result.outcome == "incident"
    refute result.record["native_stop_confirmed"]
    refute File.exists?(c.trace)
  end

  @tag :unadmitted
  test "damaged or missing command stop evidence cannot be cleared by recovery", c do
    id = String.duplicate("a", 64)
    missing = %{id => %{"id" => id, "status" => "running"}}
    variants = [invalid: [], missing_receipt: %{"lost" => %{"status" => "unknown"}}, missing_directory: missing]

    for {name, checks} <- variants do
      key = WorkRef.key(c.work)
      directory = RunJournal.directory(Path.join(c.root, to_string(name)), key)
      registry = put_in(c.registry, [key, :directory], directory)

      task =
        Task.async(fn ->
          {:ok, admitted} = TaskExecution.admit(c.parent, c.work, registry, c.opts)
          RunJournal.checkpoint(admitted.record, %{"native_stop_confirmed" => true, "check_runs" => checks})
        end)

      assert {:ok, broken} = Task.await(task)
      assert {:ok, result} = SymphonyElixir.TaskRecovery.recover(broken, registry, c.opts)
      assert result.outcome == "incident"
      assert result.record["check_runs"] == checks
      refute result.flow["dispatchable"]
    end

    refute File.exists?(c.trace)
  end

  @tag :unadmitted
  test "an exception while validating retained recovery inputs cannot confirm native stop", c do
    original = crash_member(c)
    manifest_path = Path.join(original["task_workspace"]["directory"], "manifest.json")
    manifest = manifest_path |> File.read!() |> Jason.decode!() |> Map.put("packages", [nil]) |> Jason.encode!()
    File.write!(manifest_path, manifest)
    sha = Base.encode16(:crypto.hash(:sha256, manifest), case: :lower)
    damaged = put_in(original, ["task_workspace", "manifest_sha"], sha)
    File.write!(Path.join(original["directory"], "run.json"), Jason.encode!(damaged))
    assert {:ok, result} = SymphonyElixir.TaskRecovery.recover(damaged, c.registry, c.opts)
    assert result.outcome == "incident"
    refute result.record["native_stop_confirmed"]
    assert Enum.count(requests(c), &(&1["method"] == "thread/start")) == 1
  end

  @tag :unadmitted
  test "removing a routed plan stops its active worker and retains its workspace", c do
    File.write!(c.mode, "hold")
    opts = scheduler_options(c)
    scheduler = start_scheduler(opts)
    id = "member:" <> WorkRef.key(c.work)

    await_scheduler(fn ->
      case RunJournal.read(c.record["directory"]) do
        {:ok, record} -> record["execution_mode"] == "goal" and record["native_stop_confirmed"] == false
        _ -> false
      end
    end)

    before = :sys.get_state(scheduler).running[id]
    path = Workflow.workflow_file_path()
    File.write!(path, String.replace(File.read!(path), Jason.encode!([c.parent]), "[]"))
    WorkflowStore.force_reload()
    send(scheduler, :run_poll_cycle)
    await_scheduler(fn -> :sys.get_state(scheduler).running == %{} end)
    assert current(c)["native_stop_confirmed"]
    assert File.dir?(current(c)["workspace"])
    assert :sys.get_state(scheduler).retry_attempts == %{}
    refute Process.alive?(before.pid)
    assert {:ok, []} = Tracker.fetch_issues_by_ids([id], opts)
    assert Enum.count(requests(c), &(&1["method"] == "thread/start")) == 1
  end

  @tag :unadmitted
  test "discovery contains invalid native plans and refuses unrouted or paused workers without allocation", c do
    assert {:ok, []} = TaskPlanExecution.discover()
    refute File.exists?(c.record["directory"])
    opts = scheduler_options(c)
    assert {:error, :invalid_plan_roots} = TaskPlanExecution.discover(Keyword.put(opts, :roots, [%{}]))
    assert {:ok, [blocked]} = TaskPlanExecution.discover(Keyword.put(opts, :active_state, ""))
    assert blocked.kind == :plan
    refute blocked.dispatchable
    missing_policy = Keyword.put(opts, :repositories, c.opts[:repositories])
    assert {:ok, [blocked]} = TaskPlanExecution.discover(missing_policy)
    assert blocked.native_ref["plan_preflight"]["reason"] =~ "missing_repository_execution_policy"
    refute File.exists?(c.record["directory"])
    assert {:ok, [job]} = TaskPlanExecution.discover(opts)
    token = make_ref()
    unrouted = Keyword.merge(opts, roots: [], dispatch_token: token)
    assert :ok = AgentRunner.run(job, self(), unrouted)
    assert_receive {:member_worker_result, _, _, ^token, {:error, :plan_member_not_routed}}
    assert :ok = AgentRunner.run(job, nil, unrouted)
    assert :ok = AgentRunner.run(job, self(), Keyword.put(missing_policy, :dispatch_token, token))
    assert_receive {:member_worker_result, _, _, ^token, {:error, {:member_execution_configuration, _, _}}}
    pause = note(block("plan-decision", %{"action" => "pause", "revision" => c.plan["revision"]}), 2)
    Agent.update(c.state, &Map.update!(&1, "/repos/team/repo/issues/1/comments", fn notes -> notes ++ [pause] end))
    assert :ok = AgentRunner.run(job, self(), Keyword.put(opts, :dispatch_token, token))
    assert_receive {:member_worker_result, _, _, ^token, waiting = {:waiting, _}}
    assert {:ok, %{outcome: "waiting"}} = TaskPlanExecution.completed_result(job, waiting)
    assert {:ok, [paused]} = TaskPlanExecution.discover(opts)
    refute paused.dispatchable
    refute File.exists?(Path.join(c.record["directory"], "executor.lock"))
    refute File.exists?(c.trace)
  end

  @tag :unadmitted
  test "discovery fences observation read failures after configuration without hiding other roots", c do
    opts = scheduler_options(c)
    counter = start_supervised!({Agent, fn -> 0 end}, id: :native_read_counter)
    request = c.opts[:request]

    counting = fn provider, method, path, params, config ->
      Agent.update(counter, &(&1 + 1))
      request.(provider, method, path, params, config)
    end

    assert {:ok, _} = SymphonyElixir.TaskExecutionConfig.prepare(c.parent, Keyword.put(opts, :request, counting))
    configuration_reads = Agent.get(counter, & &1)

    for fault <- [:unavailable, :raise, :throw] do
      Agent.update(counter, fn _ -> 0 end)

      failing = fn provider, method, path, params, config ->
        reads = Agent.get_and_update(counter, fn n -> {n + 1, n + 1} end)

        if reads > configuration_reads do
          case fault do
            :unavailable -> {:error, :native_unavailable}
            :raise -> raise "native observation failed"
            :throw -> throw(:native_observation_failed)
          end
        else
          request.(provider, method, path, params, config)
        end
      end

      assert {:ok, [blocked]} = TaskPlanExecution.discover(Keyword.put(opts, :request, failing))
      refute blocked.dispatchable
      assert blocked.native_ref["lifecycle"]["error"]
    end

    missing = fn
      "github", "GET", "/repos/team/repo/issues/99", _, _ -> {:ok, %{status: 404, body: %{}}}
      provider, method, path, params, config -> request.(provider, method, path, params, config)
    end

    options = Keyword.merge(opts, roots: [%{c.parent | "number" => 99}, c.parent], request: missing)
    assert {:ok, jobs} = TaskPlanExecution.discover(options)
    assert Enum.any?(jobs, &(&1.kind == :plan and not &1.dispatchable))
    assert Enum.any?(jobs, & &1.dispatchable)
    refute File.exists?(c.trace)
  end

  @tag :unadmitted
  test "discovery reports an unreadable member journal as blocked instead of claiming recovery", c do
    opts = scheduler_options(c)
    File.mkdir_p!(Path.join(c.record["directory"], "run.json"))

    assert {:ok, [job]} = TaskPlanExecution.discover(opts)
    refute job.kind == :plan
    refute job.dispatchable
    refute job.native_ref["recovery_required"]
    assert job.native_ref["lifecycle"]["error"] == ":eisdir"
    refute File.exists?(Path.join(c.record["directory"], "executor.lock"))
    refute File.exists?(c.trace)
  end

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

  @tag :unadmitted
  test "the configured member worker runs independent report development, verification, repair and re-verification", c do
    key = WorkRef.key(c.work)
    instructions = %{"developer" => "Keep the report reproducible.", "verifier" => "Review the report independently."}
    registry = update_in(c.registry, [key, :policy], &Map.put(&1, "role_instructions", instructions))
    repositories = Enum.map(c.opts[:repositories], &Map.put(&1, "execution", %{"policy" => registry[key].policy}))
    env = "SYMPHONY_CONFIGURED_ROOT_FIXTURE"
    previous = System.get_env(env)
    System.put_env(env, Path.dirname(c.record["directory"]))
    on_exit(fn -> restore_env(env, previous) end)
    workflow = File.read!(Workflow.workflow_file_path())
    workflow = String.replace(workflow, "tracker:\n", "tracker:\n  provider: " <> Jason.encode!(%{"plan_repositories" => repositories}) <> "\n")
    workflow = String.replace(workflow, "agent:\n", "agent:\n  run_journal_dir: $#{env}\n")
    File.write!(Workflow.workflow_file_path(), workflow)
    WorkflowStore.force_reload()
    opts = Keyword.delete(c.opts, :repositories)
    assert {:ok, configured} = SymphonyElixir.TaskExecutionConfig.prepare(c.parent, Keyword.put(opts, :journal_root, "$#{env}"))
    assert configured.executions[key].directory == c.record["directory"]
    assert {:error, :unsupported_task_session_transport} = AgentRunner.run_configured_member(c.parent, c.work, nil, Keyword.put(opts, :worker_host, "remote"))

    assert {:error, {:member_execution_configuration, _, :missing_repository_execution_policy}} =
             AgentRunner.run_configured_member(c.parent, c.work, nil, c.opts)

    refute File.exists?(c.trace)

    results =
      Enum.map(["develop", "reject", "develop", "verify"], fn mode ->
        File.write!(c.mode, mode)
        assert {:ok, result} = AgentRunner.run_configured_member(c.parent, c.work, self(), opts)
        assert result.record["native_stop_confirmed"]
        refute File.exists?(Path.join(c.record["directory"], "executor.lock"))
        assert_receive {:worker_runtime_info, ^key, %{worker_host: nil, workspace_path: workspace}}
        assert workspace == result.record["workspace"]
        assert_receive {:codex_worker_update, ^key, %{event: :session_started}}
        result
      end)

    assert Enum.map(results, & &1.record["execution_binding"]["role"]) == ~w(developer verifier developer verifier)
    assert length(Enum.uniq_by(results, & &1.record["thread_id"])) == 4
    assert Enum.map(results, & &1.record["execution_generation"]) == [1, 2, 3, 4]
    final = List.last(results)
    job = %Issue{id: "member:" <> key, native_ref: %{"execution_kind" => "plan_member", "work" => c.work, "parent" => c.parent}}
    assert {:ok, %{outcome: "waiting"}} = TaskPlanExecution.completed_result(job, {:ok, final})
    assert {:error, :member_result_unconfirmed} = TaskPlanExecution.completed_result(job, {:ok, hd(results)})
    assert {:error, :member_result_unconfirmed} = TaskPlanExecution.completed_result(job, {:ok, %{final | outcome: "retry"}})
    assert {:error, :member_result_unconfirmed} = TaskPlanExecution.completed_result(%Issue{id: "foreign"}, {:ok, final})
    assert {:error, {:member_worker_failed, :missing}} = TaskPlanExecution.completed_result(job, :missing)
    assert {:error, :member_result_unconfirmed} = TaskExecution.completed_result(%{})
    assert {:error, :member_result_unconfirmed} = TaskExecution.completed_result(%{"directory" => Path.join(c.root, "absent")})
    assert final.record["retry_count"] == 0
    assert final.flow["repair_count"] == 1
    assert final.flow["closeable"]
    assert final.flow["outcome"] == "delivered"
    assert {:waiting, _} = AgentRunner.run_configured_member(c.parent, c.work, nil, opts)
    assert Agent.get(c.state, & &1["/repos/team/repo/issues/2"]["state"]) == "open"
    goals = requests(c) |> Enum.filter(&(get_in(&1, ["params", "status"]) == "active")) |> Enum.map(& &1["params"]["objective"])
    assert Enum.at(goals, 0) =~ "Keep the report reproducible."
    assert Enum.at(goals, 1) =~ "Review the report independently."
    assert Enum.at(goals, 2) =~ "Add the missing report detail"
    contexts = requests(c) |> Enum.filter(&(&1["id"] == "context-call")) |> Enum.map(&Jason.decode!(&1["result"]["contentItems"] |> hd() |> Map.fetch!("text")))
    assert get_in(Enum.at(contexts, 2), ["data", "verification", "findings"]) != []
  end

  test "a managed worker derives its Goal from sealed scope and stops an idle session if readiness notification fails", c do
    Agent.update(c.state, &update_in(&1, ["/repos/team/repo/issues/2", "body"], fn body -> body <> "\nUNAPPROVED EXTRA TARGET" end))
    assert {:ok, result} = TaskSession.run(c.record, c.registry, c.opts)
    goal = Enum.find(requests(c), &(get_in(&1, ["params", "status"]) == "active"))["params"]["objective"]
    assert goal =~ "Produce the approved report"
    refute goal =~ "UNAPPROVED EXTRA TARGET"
    assert result.reason == ":task_execution_no_progress"
    assert {:error, :task_attempt_not_admitted} = TaskSession.run(result.record, c.registry, c.opts)
    {:ok, admitted} = TaskExecution.admit(c.parent, c.work, c.registry, c.opts)
    failed = Keyword.put(c.opts, :on_ready, fn _ -> throw(:ready_consumer_failed) end)
    assert {:ok, stopped} = TaskSession.run(admitted.record, c.registry, failed)
    assert stopped.record["native_stop_confirmed"]
    assert stopped.reason =~ "ready_consumer_failed"
    assert length(Enum.filter(requests(c), &(get_in(&1, ["params", "status"]) == "active"))) == 1
  end

  test "startup failures finalize only their own preparation and native allocation", c do
    opts = Keyword.put(c.opts, :workspace_root, 12)
    assert {:ok, failed} = TaskSession.run(c.record, c.registry, opts)
    assert failed.outcome == "retry"
    refute failed.record["thread_allocation_intent"]
    refute File.exists?(c.trace)
    {:ok, admitted} = TaskExecution.admit(c.parent, c.work, c.registry, c.opts)
    File.write!(c.failure, "")
    assert {:ok, uncertain} = TaskSession.run(admitted.record, c.registry, c.opts)
    assert uncertain.outcome == "incident"
    refute uncertain.record["native_stop_confirmed"]
    refute File.exists?(Path.join(c.record["directory"], "executor.lock"))
  end

  @tag :unadmitted
  test "unsupported worker transport and native waiting do not allocate execution", c do
    assert {:error, :unsupported_task_session_transport} = AgentRunner.run_member(c.parent, c.work, c.registry, nil, Keyword.put(c.opts, :worker_host, "remote"))
    refute File.exists?(c.record["directory"])
    pause = note(block("plan-decision", %{"action" => "pause", "revision" => c.plan["revision"]}), 2)
    Agent.update(c.state, &Map.update!(&1, "/repos/team/repo/issues/1/comments", fn notes -> notes ++ [pause] end))
    assert {:waiting, _} = AgentRunner.run_member(c.parent, c.work, c.registry, nil, c.opts)
    refute File.exists?(c.trace)
  end

  test "role prompt generation rejects changed or incomplete authority and invalid role instructions", c do
    {:ok, observation} = TaskExecution.observe(c.parent, c.work, c.registry, c.opts)
    assert {:ok, prompt} = PromptBuilder.build_role_prompt(observation)
    assert prompt =~ "task_candidate"
    assert {:error, :invalid_role_prompt_context} = PromptBuilder.build_role_prompt(%{})
    changed = Map.update!(observation.policy, "max_retries", &(&1 + 1))
    assert {:error, :role_prompt_not_ready} = PromptBuilder.build_role_prompt(%{observation | policy: changed})

    for instructions <- [nil, [], %{"unknown" => "instruction"}, %{"developer" => ""}] do
      policy = Map.put(observation.policy, "role_instructions", instructions)
      invalid = %{observation | policy: policy}
      assert {:error, :incomplete_verification_policy} = PromptBuilder.build_role_prompt(invalid)
    end
  end

  defp owned_ports, do: Enum.filter(Port.list(), &(Port.info(&1, :connected) == {:connected, self()}))
  defp provider_failure(:raise), do: raise("provider unavailable")
  defp provider_failure(:throw), do: throw(:provider_unavailable)

  test "a failing native activation callback closes its transport and finalizes without claiming allocation", c do
    once = start_supervised!({Agent, fn -> false end}, id: :start_fault)

    request = fn provider, method, path, query, settings ->
      if File.exists?(c.trace) and Agent.get_and_update(once, &{not &1, true}), do: raise("startup callback failed")
      c.opts[:request].(provider, method, path, query, settings)
    end

    ports = owned_ports()
    assert {:ok, result} = TaskSession.run(c.record, c.registry, Keyword.put(c.opts, :request, request))
    assert {:error, {:native_session_start_failed, :error, _}} = result.native_result
    assert result.outcome == "retry"
    refute result.record["thread_allocation_intent"]
    assert owned_ports() == ports
    refute Enum.any?(requests(c), &(&1["method"] == "thread/start"))
  end

  test "a second worker cannot adopt a session claim while its owner initializes the native transport", c do
    once = start_supervised!({Agent, fn -> false end}, id: :competing_start)

    request = fn provider, method, path, query, settings ->
      if File.exists?(c.trace) and Agent.get_and_update(once, &{not &1, true}) do
        record = current(c)
        assert record["task_session_phase"] == "opening"
        other = Task.async(fn -> TaskSession.run(record, c.registry, c.opts) end)
        assert {:error, :task_attempt_not_admitted} = Task.await(other)
        assert current(c) == record
      end

      c.opts[:request].(provider, method, path, query, settings)
    end

    assert {:ok, result} = TaskSession.run(c.record, c.registry, Keyword.put(c.opts, :request, request))
    assert result.record["native_stop_confirmed"]
    assert result.record["retry_count"] == 1
    assert Enum.count(requests(c), &(&1["method"] == "initialize")) == 1
  end

  for failure <- [:raise, :throw] do
    @failure failure
    test "a #{@failure} from preparation and final observation keeps evidence unknown without orphaning ownership", c do
      request = fn _, _, _, _, _ -> provider_failure(@failure) end
      assert {:ok, result} = TaskSession.run(c.record, c.registry, Keyword.put(c.opts, :request, request))
      assert result.flow["evidence"] == "unknown"
      assert result.reason =~ "finalization_observation_failed"
      assert inspect(result.native_result) =~ "task_start_failed"
      refute result.flow["dispatchable"]
      refute File.exists?(c.trace)
      refute File.exists?(Path.join(c.record["directory"], "executor.lock"))
    end
  end

  test "a worker that loses its admission during preparation cannot finalize the replacement", c do
    once = start_supervised!({Agent, fn -> false end}, id: :replace_preparation)

    request = fn provider, method, path, query, settings ->
      if Agent.get_and_update(once, &{not &1, true}) do
        replacement = Map.put(current(c), "attempt_id", "replacement")
        File.write!(Path.join(c.record["directory"], "run.json"), Jason.encode!(replacement))
      end

      c.opts[:request].(provider, method, path, query, settings)
    end

    assert {:error, :task_session_no_longer_owned} = TaskSession.run(c.record, c.registry, Keyword.put(c.opts, :request, request))
    assert current(c)["attempt_id"] == "replacement"
    refute current(c)["task_attempt_results"]
    refute File.exists?(c.trace)
  end

  @tag :unadmitted
  test "native pause after the approved prompt is built still prevents Goal activation", c do
    on_ready = fn _ ->
      pause = note(block("plan-decision", %{"action" => "pause", "revision" => c.plan["revision"]}), 2)
      Agent.update(c.state, &Map.update!(&1, "/repos/team/repo/issues/1/comments", fn notes -> notes ++ [pause] end))
    end

    assert {:ok, result} = AgentRunner.run_member(c.parent, c.work, c.registry, nil, Keyword.put(c.opts, :on_ready, on_ready))
    assert result.outcome == "waiting"
    assert result.record["native_stop_confirmed"]
    assert result.record["retry_count"] == 0
    refute Enum.any?(requests(c), &(&1["method"] == "thread/goal/set"))
  end

  defp ready_for_repair(c) do
    for mode <- ["develop", "reject"] do
      File.write!(c.mode, mode)
      assert {:ok, _} = AgentRunner.run_member(c.parent, c.work, c.registry, nil, c.opts)
    end
  end

  @tag :unadmitted
  test "a repair Goal without new evidence stops further repair of the same finding", c do
    ready_for_repair(c)
    File.write!(c.mode, "complete")
    assert {:ok, result} = AgentRunner.run_member(c.parent, c.work, c.registry, nil, c.opts)
    assert result.flow["restrictions"]["repair_without_progress"]
    assert result.flow["repair_count"] == 1
    assert result.outcome == "waiting"
    assert result.record["last_result"] == "completed"
    before = requests(c)
    assert {:waiting, _} = AgentRunner.run_member(c.parent, c.work, c.registry, nil, c.opts)
    assert requests(c) == before
  end

  @tag :unadmitted
  test "scheduler interruption and technical retry preserve the admitted repair generation and allowance", c do
    ready_for_repair(c)
    File.write!(c.mode, "hold")

    on_ready = fn _ ->
      send(self(), :symphony_stop)
      :ok
    end

    assert {:ok, stopped} = AgentRunner.run_member(c.parent, c.work, c.registry, nil, Keyword.put(c.opts, :on_ready, on_ready))
    assert stopped.outcome == "continue"
    assert stopped.record["last_result"] == "interrupted"
    assert stopped.record["retry_count"] == 0
    assert stopped.flow["repair_count"] == 1

    handler = fn
      %{event: :session_started} -> throw(:transient_failure)
      _ -> :ok
    end

    assert {:ok, failed} = AgentRunner.run_member(c.parent, c.work, c.registry, nil, Keyword.put(c.opts, :on_message, handler))
    assert failed.outcome == "retry"
    assert failed.record["retry_count"] == 1
    assert failed.record["last_result"] == "retryable_error"
    File.write!(c.mode, "develop")
    assert {:ok, repaired} = AgentRunner.run_member(c.parent, c.work, c.registry, nil, c.opts)
    assert repaired.flow["next_binding"]["role"] == "verifier"
    assert repaired.record["execution_generation"] == stopped.record["execution_generation"]
    assert repaired.record["thread_id"] == stopped.record["thread_id"]
    assert repaired.flow["repair_count"] == 1
    assert repaired.record["retry_count"] == 1
  end

  @tag :unadmitted
  test "human pause and explicit native resume preserve a repair interrupted by a blocked Goal", c do
    ready_for_repair(c)
    File.write!(c.mode, "hold")

    handler = fn
      %{event: :session_started} ->
        pause = note(block("plan-decision", %{"action" => "pause", "revision" => c.plan["revision"]}), 2)
        Agent.update(c.state, &Map.update!(&1, "/repos/team/repo/issues/1/comments", fn notes -> notes ++ [pause] end))

      _ ->
        :ok
    end

    assert {:ok, paused} = AgentRunner.run_member(c.parent, c.work, c.registry, nil, Keyword.put(c.opts, :on_message, handler))
    assert {:ok, %{goal_status: "blocked"}} = paused.native_result
    assert paused.record["last_result"] == "interrupted"
    assert paused.record["retry_count"] == 0
    assert paused.flow["repair_count"] == 1
    assert {:waiting, _} = AgentRunner.run_member(c.parent, c.work, c.registry, nil, c.opts)
    source = paused.flow["restrictions"] |> Map.values() |> Enum.find(&(&1["kind"] == "pause")) |> Map.fetch!("source")
    decision = %{"action" => "resume", "revision" => c.plan["revision"], "restriction" => source}
    resume = note(block("plan-decision", decision), 3)
    resume = Map.merge(resume, %{"created_at" => "2026-10-18T00:00:01Z", "updated_at" => "2026-10-18T00:00:01Z"})
    Agent.update(c.state, &Map.update!(&1, "/repos/team/repo/issues/1/comments", fn notes -> notes ++ [resume] end))
    File.write!(c.mode, "develop")
    assert {:ok, resumed} = AgentRunner.run_member(c.parent, c.work, c.registry, nil, c.opts)
    assert resumed.flow["next_binding"]["role"] == "verifier"
    assert resumed.record["execution_generation"] == paused.record["execution_generation"]
    assert resumed.record["thread_id"] == paused.record["thread_id"]
    assert resumed.record["retry_count"] == 0
    assert resumed.flow["repair_count"] == 1
  end
end
