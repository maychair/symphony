defmodule SymphonyElixir.BeadsTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.Beads.{Acceptance, Adapter, Reconciler, RunJournal}

  setup do
    root = Path.dirname(Workflow.workflow_file_path())
    database = Path.join(root, ".beads")
    File.mkdir_p!(database)
    bin = Path.join(root, "bd")
    data = Path.join(root, "data.json")
    trace = Path.join(root, "trace")

    File.write!(
      data,
      Jason.encode!([
        %{
          id: "bd-ready",
          title: "Ready",
          status: "open",
          description: "Implement safely in the assigned checkout using the authoritative Beads acceptance criteria",
          priority: 0,
          labels: ["symphony"],
          acceptance_criteria: "Tests pass",
          external_ref: "gh-1",
          metadata: %{source: "original"}
        },
        %{id: "bd-blocked", title: "Blocked", status: "open", labels: ["symphony"]},
        %{id: "bd-human", title: "Human", status: "blocked", assignee: "symphony-owner", labels: ["symphony", "human"]}
      ])
    )

    File.write!(bin, """
    #!/usr/bin/env python3
    import os,json,sys
    args=sys.argv[1:]
    with open(#{inspect(trace)},'a') as f: f.write(json.dumps({'args':args,'beads_dir':os.environ.get('BEADS_DIR')})+'\\n')
    args=args[3:]
    with open(#{inspect(data)}) as f: records=json.load(f)
    if args[0]=='list': print(json.dumps(records))
    elif args[0]=='ready': print(json.dumps([r for r in records if r['id']=='bd-ready' and r['status']=='open']))
    elif args[0]=='blocked': print(json.dumps([r for r in records if r['id']=='bd-blocked']))
    elif args[0]=='show': print(json.dumps([r for r in records if r['id']==args[1]]))
    elif args[0]=='update':
      r=next(r for r in records if r['id']==args[1])
      def val(key): return args[args.index(key)+1]
      if r.get('assignee','')!=val('--if-assignee') or r['status']!=val('--if-status'): sys.exit(13)
      r['status']=val('--status')
      if '--assignee' in args: r['assignee']=val('--assignee')
      if '--add-label' in args: r.setdefault('labels',[]).append(val('--add-label'))
      if '--remove-label' in args and val('--remove-label') in r.get('labels',[]): r['labels'].remove(val('--remove-label'))
      for i,a in enumerate(args):
        if a=='--set-metadata':
          key,value=args[i+1].split('=',1); r.setdefault('metadata',{})[key]=value
      with open(#{inspect(data)},'w') as f: json.dump(records,f)
      print(json.dumps([r]))
    else: sys.exit(1)
    """)

    File.chmod!(bin, 0o755)

    File.write!(Workflow.workflow_file_path(), """
    ---
    tracker:
      kind: beads
      required_labels: [symphony]
      provider:
        bin: #{Jason.encode!(bin)}
        beads_dir: #{Jason.encode!(database)}
        review_repository: github.com/example/repo
    workspace:
      root: #{Jason.encode!(Path.join(root, "workspaces"))}
      retain: true
    polling:
      interval_ms: 60000
    ---
    {{ issue.description }}
    """)

    :ok = WorkflowStore.force_reload()
    {:ok, root: root, database: database, bin: bin, data: data, trace: trace}
  end

  defp replace_owner(%{"id" => id} = record, id), do: Map.put(record, "assignee", "another-owner")
  defp replace_owner(record, _id), do: record

  test "bounded legacy run checkpoints intent before side effects and blocks on its turn budget", context do
    codex = Path.join(context.root, "codex")
    native_trace = Path.join(context.root, "native-trace")
    journal = RunJournal.directory(Adapter.journal_root(Config.settings!().tracker), "bd-ready")

    File.write!(codex, """
    #!/usr/bin/env python3
    import os,sys,json
    def send(x): print(json.dumps(x),flush=True)
    for line in sys.stdin:
      request=json.loads(line)
      if 'id' not in request: continue
      if 'method' not in request:
        assert request['result']['success'] is False
        assert 'root_task_tools_only' in request['result']['contentItems'][0]['text']
        if request['id']==70:
          send({'id':71,'method':'item/tool/call','params':{'threadId':'observed-thread','turnId':'stale-turn','tool':'beads_checkpoint','arguments':{}}})
        else:
          send({'method':'turn/completed','params':{'threadId':'child-thread','turn':{'id':'child-turn','status':'completed'}}})
          send({'method':'turn/completed','params':{'threadId':'observed-thread','turn':{'id':'observed-turn','status':'completed'}}})
        continue
      method=request['method']
      if method=='initialize': send({'id':request['id'],'result':{}})
      else:
        with open(#{inspect(journal)}+'/run.json') as f: record=json.load(f)
        with open(#{inspect(native_trace)},'a') as f: f.write(json.dumps({'method':method,'phase':record['phase'],'beads_dir':os.environ.get('BEADS_DIR')})+'\\n')
        if method=='thread/start': send({'id':request['id'],'result':{'thread':{'id':'observed-thread'}}})
        if method=='turn/start':
          assert record['thread_id']=='observed-thread'
          send({'id':request['id'],'result':{'turn':{'id':'observed-turn'}}})
          send({'id':70,'method':'item/tool/call','params':{'threadId':'child-thread','turnId':'child-turn','tool':'beads_task_context','arguments':{}}})
    """)

    File.chmod!(codex, 0o755)
    File.write!(Workflow.workflow_file_path(), File.read!(Workflow.workflow_file_path()) |> String.replace("polling:", "agent:\n  max_turns: 1\ncodex:\n  command: #{Jason.encode!(codex)}\npolling:"))
    :ok = WorkflowStore.force_reload()
    old = System.get_env("BEADS_DIR")
    on_exit(fn -> restore_env("BEADS_DIR", old) end)
    System.put_env("BEADS_DIR", "/wrong/inherited/database")
    {:ok, [issue]} = Adapter.fetch_issues_by_ids(["bd-ready"])
    assert_raise RuntimeError, ~r/agent_turn_budget_exhausted/, fn -> AgentRunner.run(issue) end
    events = native_trace |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    assert Enum.map(events, &{&1["method"], &1["phase"]}) == [{"thread/start", "thread_start_intent"}, {"turn/start", "turn_start_intent"}]
    assert Enum.all?(events, &(&1["beads_dir"] == context.database))
    assert {:ok, record} = RunJournal.read(journal)
    assert record["phase"] == "blocked"
    assert record["blocker_reason"] =~ "Run ended without a delivery"
    assert record["thread_id"] == "observed-thread"
    assert record["turn_id"] == "observed-turn"
    assert record["turn_count"] == 1
    assert {:ok, [issue]} = Adapter.fetch_issues_by_ids([issue.id])
    assert issue.state == "blocked"
    state = %Orchestrator.State{blocked: %{issue.id => %{issue: issue}}, claimed: MapSet.new([issue.id])}
    reconciled = Orchestrator.reconcile_blocked_issue_states_for_test([issue], state)
    assert Map.has_key?(reconciled.blocked, issue.id)
  end

  test "native Goal owns two automatic root turns until an explicit blocker without a Butler", context do
    codex = Path.join(context.root, "goal-server")
    native_trace = Path.join(context.root, "goal-trace")

    File.write!(codex, """
    #!/usr/bin/env python3
    import json,sys
    def send(x): print(json.dumps(x),flush=True)
    def goal(status): return {'threadId':'goal-thread','status':status,'objective':'retained objective'}
    def started(turn): send({'method':'turn/started','params':{'threadId':'goal-thread','turn':{'id':turn,'status':'inProgress'}}})
    def completed(turn): send({'method':'turn/completed','params':{'threadId':'goal-thread','turn':{'id':turn,'status':'completed'}}})
    for line in sys.stdin:
      request=json.loads(line)
      if 'id' not in request: continue
      with open(#{inspect(native_trace)},'a') as f: f.write(json.dumps(request)+'\\n')
      method=request.get('method')
      if method=='initialize': send({'id':request['id'],'result':{}})
      elif method=='thread/start': send({'id':request['id'],'result':{'thread':{'id':'goal-thread'}}})
      elif method=='thread/goal/get': send({'id':request['id'],'result':{'goal':None}})
      elif method=='thread/goal/set':
        status=request['params']['status']
        send({'id':request['id'],'result':{'goal':goal(status)}})
        send({'method':'thread/goal/updated','params':{'threadId':'goal-thread','goal':goal(status)}})
        if status=='active':
          started('goal-turn-1')
          completed('goal-turn-1')
          send({'method':'turn/completed','params':{'threadId':'child-thread','turn':{'id':'child-turn','status':'completed'}}})
          started('goal-turn-2')
          send({'id':71,'method':'item/tool/call','params':{'threadId':'goal-thread','turnId':'goal-turn-2','tool':'beads_await_human','arguments':{'intent':'blocked','reason':'Required target artifact is absent; resume after producer delivers it'}}})
      elif method=='turn/start': raise AssertionError('Goal continuation must not start a competing explicit turn')
      elif method is None:
        assert request['id']==71 and request['result']['success'] is True, request
        completed('goal-turn-2')
    """)

    File.chmod!(codex, 0o755)

    workflow =
      File.read!(Workflow.workflow_file_path())
      |> String.replace("review_repository:", "goal_mode: true\n    review_repository:")
      |> String.replace(
        "polling:",
        "agent:\n  max_turns: 1\ncodex:\n  command: #{Jason.encode!(codex)}\n  turn_sandbox_policy:\n    type: workspaceWrite\n    networkAccess: true\n    writableRoots: [#{Jason.encode!(context.root)}]\npolling:"
      )

    File.write!(Workflow.workflow_file_path(), workflow)
    :ok = WorkflowStore.force_reload()
    {:ok, [issue]} = Adapter.fetch_issues_by_ids(["bd-ready"])
    assert_raise RuntimeError, ~r/native_goal_stopped.*blocked/, fn -> AgentRunner.run(issue) end

    events =
      native_trace
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    assert Enum.count(events, &(&1["method"] == "thread/start")) == 1
    thread_start = Enum.find(events, &(&1["method"] == "thread/start"))
    assert thread_start["params"]["config"]["sandbox_workspace_write.network_access"] == true
    assert context.root in thread_start["params"]["config"]["sandbox_workspace_write.writable_roots"]
    assert Enum.count(events, &(&1["method"] == "thread/goal/set")) == 2
    active_goal = Enum.find(events, &(&1["method"] == "thread/goal/set" and &1["params"]["status"] == "active"))
    assert String.length(active_goal["params"]["objective"]) <= 4000
    refute Enum.any?(events, &(&1["method"] == "turn/start"))
    assert {:ok, record} = RunJournal.read(RunJournal.directory(Adapter.journal_root(Config.settings!().tracker), issue.id))
    assert record["turn_id"] == "goal-turn-2"
    assert File.read!(Path.join(record["directory"], "goal-instructions.txt")) =~ "Frozen validation policy"
    assert record["turn_count"] == 2
    assert record["goal_status"] == "blocked"
    assert record["native_stop_confirmed"] == true
    assert record["blocker_reason"] =~ "Required target artifact"
    refute File.exists?(Path.join(record["directory"], "executor.lock"))
    assert {:ok, [issue]} = Adapter.fetch_issues_by_ids([issue.id])
    assert issue.state == "blocked"
  end

  test "Goal wall-clock budget survives notification traffic and fences an unconfirmed stop", context do
    codex = Path.join(context.root, "goal-budget-server")

    File.write!(codex, """
    #!/usr/bin/env python3
    import json,sys,threading,time
    running=threading.Event()
    goal_state=None
    def send(x): print(json.dumps(x),flush=True)
    def goal(status): return {'threadId':'budget-thread','status':status,'objective':'budget smoke'}
    def traffic():
      while running.is_set():
        send({'method':'item/updated','params':{'threadId':'budget-thread','turnId':'budget-turn'}})
        time.sleep(.005)
    for line in sys.stdin:
      q=json.loads(line);m=q.get('method')
      if 'id' not in q: continue
      if m=='initialize': send({'id':q['id'],'result':{}})
      elif m=='thread/start': send({'id':q['id'],'result':{'thread':{'id':'budget-thread'}}})
      elif m=='thread/goal/get': send({'id':q['id'],'result':{'goal':goal_state}})
      elif m=='thread/goal/set':
        status=q['params']['status']
        goal_state=goal(status)
        send({'id':q['id'],'result':{'goal':goal_state}})
        if status=='active':
          send({'method':'turn/started','params':{'threadId':'budget-thread','turn':{'id':'budget-turn','status':'inProgress'}}})
          running.set()
          threading.Thread(target=traffic,daemon=True).start()
        else: running.clear()
      elif m=='turn/interrupt': send({'id':q['id'],'result':{}})
      elif m=='thread/read':
        send({'id':q['id'],'result':{'thread':{'id':'budget-thread','turns':[{'id':'budget-turn','status':'inProgress'}]}}})
    """)

    File.chmod!(codex, 0o755)

    workflow =
      File.read!(Workflow.workflow_file_path())
      |> String.replace("review_repository:", "goal_mode: true\n    run_budget_ms: 1000\n    review_repository:")
      |> String.replace("polling:", "codex:\n  command: #{Jason.encode!(codex)}\npolling:")

    File.write!(Workflow.workflow_file_path(), workflow)
    :ok = WorkflowStore.force_reload()
    {:ok, [issue]} = Adapter.fetch_issues_by_ids(["bd-ready"])
    started = System.monotonic_time(:millisecond)
    assert_raise RuntimeError, ~r/execution_budget_exhausted/, fn -> AgentRunner.run(issue) end
    assert System.monotonic_time(:millisecond) - started < 5000
    assert {:ok, record} = RunJournal.read(RunJournal.directory(Adapter.journal_root(Config.settings!().tracker), issue.id))
    assert record["phase"] == "blocked"
    assert record["goal_status"] == "blocked"
    assert record["native_stop_confirmed"] == false
    assert File.exists?(Path.join(record["directory"], "executor.lock"))
    assert {:ok, [issue]} = Adapter.fetch_issues_by_ids([issue.id])
    assert issue.state == "blocked"
  end

  test "scheduler polling parks a lost executor without remote reconciliation or a Butler", context do
    {:ok, [issue]} = Adapter.fetch_issues_by_ids(["bd-ready"])
    {:ok, _issue, opts} = Adapter.prepare_run(issue, [])
    settings = opts[:tracker_settings]
    record = opts[:run_record]
    {:ok, [raw]} = Adapter.command(settings, ["show", issue.id, "--json"])
    refute settings.provider["remote_reconcile"]
    assert RunJournal.executor_state(record) == :alive
    assert :ok = Reconciler.poll(settings)
    assert {:ok, [unchanged]} = Adapter.command(settings, ["show", issue.id, "--json"])
    assert unchanged["status"] == "in_progress"

    {:ok, dead} = RunJournal.checkpoint(record, %{"executor_os_pid" => "999999999", "phase" => "turn_running", "thread_id" => "lost-thread", "turn_id" => "lost-turn"})
    assert RunJournal.executor_state(dead) == :stopped
    assert :ok = Reconciler.reconcile_runtime(settings, %{raw | "assignee" => "foreign-owner"})
    assert {:ok, [unchanged]} = Adapter.command(settings, ["show", issue.id, "--json"])
    assert unchanged["status"] == "in_progress"

    assert :ok = Reconciler.poll(settings)
    assert {:ok, [parked]} = Adapter.command(settings, ["show", issue.id, "--json"])
    assert parked["status"] == "blocked"
    assert {:ok, parked_run} = RunJournal.read(record["directory"])
    assert parked_run["blocker_reason"] =~ "Scheduler executor exited"
    assert parked_run["native_stop_confirmed"] == false
    assert File.exists?(Path.join(record["directory"], "executor.lock"))
    assert :ok = Reconciler.poll(settings)
    assert File.exists?(Path.join(record["directory"], "executor.lock"))
    assert File.exists?(context.data)
  end

  test "polling preserves operator-authorized resume until a new admission consumes it" do
    {:ok, [issue]} = Adapter.fetch_issues_by_ids(["bd-ready"])
    {:ok, _issue, opts} = Adapter.prepare_run(issue, [])
    record = opts[:run_record]
    settings = opts[:tracker_settings]
    {:ok, recovered} = RunJournal.checkpoint(record, %{"executor_os_pid" => "999999999", "phase" => "completed", "resume_authorized" => true, "thread_id" => "idle-thread", "turn_id" => "idle-turn"})
    File.rmdir!(Path.join(record["directory"], "executor.lock"))
    assert :ok = Reconciler.poll(settings)
    assert {:ok, [current]} = Adapter.command(settings, ["show", issue.id, "--json"])
    assert current["status"] == "in_progress"
    assert {:ok, admitted} = RunJournal.admit(Adapter.journal_root(settings), issue.id)
    refute admitted["resume_authorized"]
    assert admitted["thread_id"] == recovered["thread_id"]
  end

  test "observed Coordinator worker death parks Beads while the scheduler process remains alive" do
    {:ok, [issue]} = Adapter.fetch_issues_by_ids(["bd-ready"])
    {:ok, _issue, opts} = Adapter.prepare_run(issue, [])
    record = opts[:run_record]
    assert RunJournal.executor_state(record) == :alive

    {pid, ref} = spawn_monitor(fn -> exit(:coordinator_crashed) end)
    assert_receive {:DOWN, ^ref, :process, ^pid, :coordinator_crashed}
    assert :ok = Reconciler.park_worker_exit(opts[:tracker_settings], issue.id, :coordinator_crashed)
    assert {:ok, [parked]} = Adapter.command(opts[:tracker_settings], ["show", issue.id, "--json"])
    assert parked["status"] == "blocked"
    assert {:ok, current} = RunJournal.read(record["directory"])
    assert current["blocker_reason"] =~ "coordinator_crashed"
    assert current["native_stop_confirmed"] == false
    assert File.exists?(Path.join(record["directory"], "executor.lock"))

    assert {:ok, _} =
             Adapter.command(opts[:tracker_settings], [
               "update",
               issue.id,
               "--if-assignee",
               record["owner"],
               "--if-status",
               "blocked",
               "--status",
               "in_progress",
               "--json"
             ])

    assert :ok = Reconciler.poll(opts[:tracker_settings])
    assert {:ok, [repaired]} = Adapter.command(opts[:tracker_settings], ["show", issue.id, "--json"])
    assert repaired["status"] == "blocked"
  end

  test "child server requests refuse safely and root approvals never auto-approve", context do
    codex = Path.join(context.root, "approval-server")
    {:ok, workspace} = Workspace.create_for_issue("approval")
    issue = %Issue{id: "bd-ready", identifier: "bd-ready", title: "Approval", state: "in_progress"}

    for thread <- ["child-thread", "root-thread"] do
      File.write!(codex, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count+1))
        case "$count" in
          1) printf '%s\\n' '{"id":1,"result":{}}' ;;
          2) ;;
          3) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"root-thread"}}}' ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"root-turn"}}}'
            printf '%s\\n' '{"id":70,"method":"item/commandExecution/requestApproval","params":{"threadId":"#{thread}","turnId":"root-turn"}}'
            ;;
        esac
      done
      """)

      File.chmod!(codex, 0o755)
      text = File.read!(Workflow.workflow_file_path())
      text = Regex.replace(~r/codex:\n  command:.*\n  approval_policy: never\n/, text, "")
      text = String.replace(text, "polling:", "codex:\n  command: #{Jason.encode!(codex)}\n  approval_policy: never\npolling:")
      File.write!(Workflow.workflow_file_path(), text)
      :ok = WorkflowStore.force_reload()

      if thread == "child-thread" do
        assert {:error, {:unscoped_server_request, _}} = AppServer.run(workspace, "approval", issue)
      else
        assert {:error, {:approval_required, _}} = AppServer.run(workspace, "approval", issue)
      end
    end
  end

  test "current arrays route ready dependencies, include authoritative acceptance, preserve source metadata", context do
    assert {:ok, issues} = Adapter.fetch_issues_by_states(["open"])
    assert ready = Enum.find(issues, &(&1.id == "bd-ready"))
    assert ready.dispatchable
    assert ready.description =~ "Acceptance criteria:\nTests pass"
    assert ready.native_ref["metadata"] == %{"source" => "original"}
    assert ready.priority == 1
    blocked = Enum.find(issues, &(&1.id == "bd-blocked"))
    refute blocked.dispatchable
    assert blocked.native_ref["dependency_blocked"]
    refute ready.native_ref["dependency_blocked"]
    assert {:ok, [^ready]} = Adapter.fetch_issues_by_ids(["bd-ready"])
    assert Enum.all?(File.stream!(context.trace), &(Jason.decode!(&1)["beads_dir"] == context.database))
  end

  test "claim is guarded, second executor is fenced, delivery persists human gate", context do
    {:ok, [issue]} = Adapter.fetch_issues_by_ids(["bd-ready"])
    assert {:ok, prepared, opts} = Adapter.prepare_run(issue, [])
    assert prepared.assignee_id =~ "symphony-"
    assert {:error, {:run_admission_blocked, "bd-ready", :eexist}} = Adapter.prepare_run(issue, [])
    assert {:ok, record} = RunJournal.read(opts[:run_record]["directory"])
    assert record["beads_dir"] == context.database
    assert :ok = Adapter.finish_run(prepared, opts, :ok)
    assert {:ok, [gated]} = Adapter.fetch_issues_by_ids([issue.id])
    assert gated.state == "blocked"
    refute "human" in gated.labels
    refute gated.dispatchable
    assert {:error, {:run_admission_blocked, _, :uncertain_or_awaiting_run}} = Adapter.prepare_run(gated, [])
  end

  test "claim loser preserves changed ownership and never enters native execution", context do
    {:ok, [issue]} = Adapter.fetch_issues_by_ids(["bd-ready"])
    records = Jason.decode!(File.read!(context.data))
    updated = Enum.map(records, &replace_owner(&1, issue.id))
    File.write!(context.data, Jason.encode!(updated))
    assert {:error, {:beads_command_failed, "update", 13}} = Adapter.prepare_run(issue, [])
    assert {:ok, [current]} = Adapter.fetch_issues_by_ids([issue.id])
    assert current.assignee_id == "another-owner"
  end

  test "unknown intent, corrupt records, and missing durable IDs block admission", context do
    for phase <- ["admitted", "thread_start_intent", "turn_start_intent", "turn_running"] do
      id = "test-" <> phase
      {:ok, record} = RunJournal.admit(context.root, id)
      {:ok, _} = RunJournal.checkpoint(record, %{"phase" => phase})
      File.rmdir!(Path.join(record["directory"], "executor.lock"))
      assert {:error, {:run_admission_blocked, ^id, :uncertain_or_awaiting_run}} = RunJournal.admit(context.root, id)
    end

    {:ok, record} = RunJournal.admit(context.root, "corrupt")
    File.write!(Path.join(record["directory"], "run.json"), "{")
    File.rmdir!(Path.join(record["directory"], "executor.lock"))
    assert {:error, {:run_admission_blocked, "corrupt", %Jason.DecodeError{}}} = RunJournal.admit(context.root, "corrupt")
    {:ok, record} = RunJournal.admit(context.root, "completed")
    assert :ok = RunJournal.complete(record, "completed")
    assert {:error, _} = RunJournal.admit(context.root, "completed")
  end

  test "known completed checkpoint retains native identity on next admission", context do
    {:ok, record} = RunJournal.admit(context.root, "completed")
    {:ok, record} = RunJournal.checkpoint(record, %{"thread_id" => "thread", "turn_id" => "turn", "blocker_reason" => "Old preparation blocker"})
    assert :ok = RunJournal.complete(record, "completed")
    assert {:ok, resumed} = RunJournal.admit(context.root, "completed")
    assert resumed["owner"] == record["owner"]
    assert resumed["thread_id"] == "thread"
    refute Map.has_key?(resumed, "blocker_reason")
  end

  test "agent tool can only park its own claimed issue and cannot accept" do
    {:ok, [issue]} = Adapter.fetch_issues_by_ids(["bd-ready"])
    {:ok, issue, opts} = Adapter.prepare_run(issue, [])
    settings = opts[:tracker_settings]
    wrong_owner = %{issue | assignee_id: "other"}
    result = Adapter.execute_agent_tool("beads_await_human", %{"reason" => "Review"}, issue: wrong_owner, tracker_settings: settings)
    refute result["success"]
    refute Adapter.execute_agent_tool("beads_await_human", %{"reason" => "Review", "review_url" => nil}, issue: issue, tracker_settings: settings)["success"]
    assert Adapter.execute_agent_tool("beads_await_human", %{"reason" => "Build directory missing; operator must prepare it before resuming"}, issue: issue, tracker_settings: settings)["success"]
    refute Adapter.execute_agent_tool("beads_accept", %{}, issue: issue, tracker_settings: settings)["success"]
    assert :ok = Adapter.finish_run(issue, opts, :ok)
  end

  test "preparation blockers retain reasons, skip review polling and fence admission" do
    {:ok, [issue]} = Adapter.fetch_issues_by_ids(["bd-ready"])
    {:ok, issue, opts} = Adapter.prepare_run(issue, [])
    reason = "Linked repository missing; prepare it before resuming"
    wrong_owner = %{issue | assignee_id: "other"}
    tool_opts = [issue: wrong_owner, tracker_settings: opts[:tracker_settings]]
    wrong_result = Adapter.execute_agent_tool("beads_block", %{"reason" => reason}, tool_opts)
    refute wrong_result["success"]
    assert Adapter.execute_agent_tool("beads_block", %{"reason" => reason}, issue: issue, tracker_settings: opts[:tracker_settings])["success"]
    assert :ok = Adapter.finish_run(issue, opts, :ok)
    {:ok, record} = RunJournal.read(opts[:run_record]["directory"])
    assert record["phase"] == "blocked"
    assert record["blocker_reason"] == reason
    assert is_nil(record["delivery"])
    {:ok, [raw]} = Adapter.command(opts[:tracker_settings], ["show", issue.id, "--json"])
    assert raw["metadata"]["symphony_gate"] == "blocked"
    assert :ok = Reconciler.reconcile(opts[:tracker_settings], raw)
    assert :ok = Reconciler.reconcile(opts[:tracker_settings], raw)
    assert {:error, {:run_admission_blocked, _, :uncertain_or_awaiting_run}} = RunJournal.admit(Adapter.journal_root(opts[:tracker_settings]), issue.id)
  end

  test "dashboard reasons distinguish preparation, dependency blocking and actual review on completion and restart" do
    {:ok, [issue]} = Adapter.fetch_issues_by_ids(["bd-ready"])
    {:ok, issue, opts} = Adapter.prepare_run(issue, [])
    reason = "Prepare linked repository before resuming"
    assert Adapter.execute_agent_tool("beads_block", %{"reason" => reason}, issue: issue, tracker_settings: opts[:tracker_settings])["success"]
    assert :ok = Adapter.finish_run(issue, opts, :ok)
    server = Module.concat(__MODULE__, :BlockerDashboard)
    pid = start_supervised!({Orchestrator, name: server})
    row = Enum.find(Orchestrator.snapshot(server, 5_000).blocked, &(&1.issue_id == issue.id))
    assert row.error == "blocked: " <> reason

    ref = make_ref()
    entry = %{pid: self(), ref: ref, identifier: issue.id, issue: issue, started_at: DateTime.utc_now()}
    :sys.replace_state(pid, &%{&1 | running: %{issue.id => entry}})
    send(pid, {:DOWN, ref, :process, self(), :normal})
    row = Enum.find(Orchestrator.snapshot(server, 5_000).blocked, &(&1.issue_id == issue.id))
    assert row.error == "blocked: " <> reason

    {:ok, [current]} = Adapter.fetch_issues_by_ids([issue.id])
    dependent = %{current | native_ref: Map.put(current.native_ref, "dependency_blocked", true)}
    state = Orchestrator.reconcile_blocked_issue_states_for_test([dependent], :sys.get_state(pid))
    assert state.blocked[issue.id].error == "blocked by task dependencies"

    {:ok, record} = RunJournal.read(opts[:run_record]["directory"])
    delivery = %{"review_url" => "https://github.com/example/repo/pull/1", "head_sha" => String.duplicate("a", 40)}
    {:ok, _} = RunJournal.checkpoint(record, %{"phase" => "awaiting_human", "delivery" => delivery})
    stop_supervised!(Orchestrator)
    start_supervised!({Orchestrator, name: server})
    row = Enum.find(Orchestrator.snapshot(server, 5_000).blocked, &(&1.issue_id == issue.id))
    assert row.error == "awaiting human acceptance"
  end

  test "legacy undelivered runs migrate only after executor lock release; partial deliveries stay strict" do
    {:ok, [issue]} = Adapter.fetch_issues_by_ids(["bd-ready"])
    {:ok, issue, opts} = Adapter.prepare_run(issue, [])
    settings = opts[:tracker_settings]
    assert :ok = Adapter.await_human(settings, issue.id, issue.assignee_id, "Build missing; prepare before resume")
    {:ok, record} = RunJournal.checkpoint(opts[:run_record], %{"phase" => "awaiting_human"})
    {:ok, [raw]} = Adapter.command(settings, ["show", issue.id, "--json"])
    assert {:error, :run_may_have_live_executor} = Reconciler.reconcile(settings, raw)
    assert :ok = RunJournal.complete(record, "awaiting_human")
    raw = Map.put(raw, "notes", "Build missing; prepare before resume")
    assert :ok = Reconciler.reconcile(settings, raw)
    {:ok, blocked} = RunJournal.read(record["directory"])
    assert blocked["phase"] == "blocked"
    assert blocked["blocker_reason"] == "Build missing; prepare before resume"
    {:ok, _} = RunJournal.checkpoint(blocked, %{"phase" => "awaiting_human", "delivery" => %{"head_sha" => String.duplicate("a", 40)}})
    assert {:error, :missing_review_binding} = Reconciler.reconcile(settings, raw)
  end

  test "actual delivery requires complete binding and remains awaiting acceptance" do
    {:ok, [issue]} = Adapter.fetch_issues_by_ids(["bd-ready"])
    {:ok, issue, opts} = Adapter.prepare_run(issue, [])
    arguments = %{"reason" => "Delivered", "review_url" => "https://github.com/example/repo/pull/1", "head_sha" => String.duplicate("a", 40)}
    assert Adapter.execute_agent_tool("beads_await_human", arguments, issue: issue, tracker_settings: opts[:tracker_settings])["success"]
    refute Adapter.execute_agent_tool("beads_block", %{"reason" => "Ignore delivery"}, issue: issue, tracker_settings: opts[:tracker_settings])["success"]
    assert :ok = Adapter.finish_run(issue, opts, :ok)
    {:ok, record} = RunJournal.read(opts[:run_record]["directory"])
    assert record["phase"] == "awaiting_human"
    assert record["delivery"]["review_url"] == arguments["review_url"]
    assert record["delivery"]["head_sha"] == arguments["head_sha"]
  end

  test "acceptance binds a merged review to durable delivery, scope, owner and human identity" do
    settings = Config.settings!().tracker
    url = "https://github.com/example/repo/pull/1"
    sha = String.duplicate("a", 40)
    verifier = fn _ -> {:error, :review_not_merged} end
    assert {:error, :human_identity_required} = Acceptance.accept(settings, "bd-human", url, "", verifier: verifier)
    assert {:error, :review_outside_configured_repository} = Acceptance.accept(settings, "bd-human", "https://github.com/other/repo/pull/1", "Human")
    assert {:error, :missing_matching_delivery} = Acceptance.accept(settings, "bd-human", url, "Human")
    {:ok, record} = RunJournal.admit(Adapter.journal_root(settings), "bd-human")

    {:ok, record} =
      RunJournal.checkpoint(record, %{
        "owner" => "symphony-owner",
        "beads_dir" => Adapter.beads_dir(settings),
        "thread_id" => "thread",
        "turn_id" => "turn",
        "delivery" => %{"review_url" => url, "head_sha" => sha, "attempt_id" => record["attempt_id"], "turn_id" => "turn"}
      })

    assert :ok = RunJournal.complete(record, "awaiting_human")
    assert {:error, :review_not_merged} = Acceptance.accept(settings, "bd-human", url, "Human", verifier: verifier)
    assert {:error, :missing_matching_delivery} = Acceptance.accept(settings, "bd-human", "https://github.com/example/repo/pull/2", "Human")
    assert {:error, :delivery_commit_mismatch} = Acceptance.accept(settings, "bd-human", url, "Human", verifier: fn _ -> {:ok, %{"headRefOid" => "wrong"}} end)
    proof = %{"headRefOid" => sha, "url" => url}
    assert :ok = Acceptance.accept(settings, "bd-human", url, "Human", verifier: fn _ -> {:ok, proof} end)
    assert :ok = Acceptance.accept(settings, "bd-human", url, "Human", verifier: fn _ -> {:ok, proof} end)
    assert {:ok, [closed]} = Adapter.fetch_issues_by_ids(["bd-human"])
    assert closed.state == "closed"
    assert closed.native_ref["metadata"]["symphony_gate"] == "accepted"
  end

  test "remote source closure requires explicit operator flag and precedes local closure", context do
    settings = Config.settings!().tracker
    url = "https://github.com/example/repo/pull/1"
    source = "https://github.com/example/repo/issues/1"
    sha = String.duplicate("b", 40)
    records = Jason.decode!(File.read!(context.data))

    records =
      Enum.map(records, fn record ->
        if record["id"] == "bd-human", do: Map.put(record, "external_ref", source), else: record
      end)

    File.write!(context.data, Jason.encode!(records))
    {:ok, record} = RunJournal.admit(Adapter.journal_root(settings), "bd-human")

    {:ok, record} =
      RunJournal.checkpoint(record, %{
        "owner" => "symphony-owner",
        "beads_dir" => Adapter.beads_dir(settings),
        "thread_id" => "thread",
        "turn_id" => "turn",
        "delivery" => %{"review_url" => url, "head_sha" => sha, "attempt_id" => record["attempt_id"], "turn_id" => "turn"}
      })

    :ok = RunJournal.complete(record, "awaiting_human")
    verify = fn _ -> {:ok, %{"headRefOid" => sha}} end
    assert {:error, :explicit_source_issue_closure_required} = Acceptance.accept(settings, "bd-human", url, "Human", verifier: verify)
    failure = fn _, _ -> {:error, :source_issue_not_confirmed_closed} end
    opts = [verifier: verify, close_source: true, source_closer: failure]
    assert {:error, :source_issue_not_confirmed_closed} = Acceptance.accept(settings, "bd-human", url, "Human", opts)
    assert {:ok, [issue]} = Adapter.fetch_issues_by_ids(["bd-human"])
    assert issue.state == "blocked"
    parent = self()

    success = fn _, ^source ->
      send(parent, :source_closed)
      :ok
    end

    assert :ok = Acceptance.accept(settings, "bd-human", url, "Human", verifier: verify, close_source: true, source_closer: success)
    assert_received :source_closed
    assert {:ok, [issue]} = Adapter.fetch_issues_by_ids(["bd-human"])
    assert issue.state == "closed"
    assert issue.native_ref["external_ref"] == source
  end

  test "Beads keeps recorded workspaces and partial bootstrap data even with retain disabled", context do
    File.write!(Workflow.workflow_file_path(), File.read!(Workflow.workflow_file_path()) |> String.replace("retain: true", "retain: false"))
    :ok = WorkflowStore.force_reload()
    assert {:ok, workspace} = Workspace.create_for_issue("retained")
    File.write!(Path.join(workspace, "valuable"), "data")
    assert {:ok, []} = Workspace.remove(workspace)
    assert {:ok, []} = Workspace.remove_recorded(workspace, nil)
    assert File.read!(Path.join(workspace, "valuable")) == "data"
    assert File.dir?(Path.join(context.root, "workspaces"))
  end

  test "invalid task prompt fails before admission or claim", context do
    path = Workflow.workflow_file_path()
    File.write!(path, String.replace(File.read!(path), "{{ issue.description }}", "{{ issue.native_ref.missing_field }}"))
    :ok = WorkflowStore.force_reload()
    assert {:ok, [issue]} = Adapter.fetch_issues_by_ids(["bd-ready"])
    assert {:error, :prompt_preflight_failed} = Adapter.prepare_run(issue, [])
    refute File.exists?(RunJournal.directory(Adapter.journal_root(Config.settings!().tracker), issue.id))
    assert Enum.find(Jason.decode!(File.read!(context.data)), &(&1["id"] == issue.id))["status"] == "open"
  end

  test "baseline policy requires explicit authority and host context is scoped" do
    alias SymphonyElixir.Beads.Validation
    assert {:ok, [issue]} = Adapter.fetch_issues_by_ids(["bd-ready"])
    metadata = %{"symphony_validation" => %{"mode" => "baseline_diff", "commands" => [["true"]]}}
    unsafe = %{issue | native_ref: Map.put(issue.native_ref, "metadata", metadata)}
    assert {:error, :baseline_requires_explicit_authorization} = Validation.policy(Config.settings!().tracker, unsafe)
    assert {:ok, issue, opts} = Adapter.prepare_run(issue, [])
    binding = [issue: issue, tracker_settings: opts[:tracker_settings]]
    assert Adapter.execute_agent_tool("beads_task_context", %{}, binding)["success"]
    wrong = %{issue | assignee_id: "another-owner"}
    refute Adapter.execute_agent_tool("beads_task_context", %{}, Keyword.put(binding, :issue, wrong))["success"]
    refute Adapter.execute_agent_tool("beads_task_context", %{"id" => "bd-human"}, binding)["success"]
  end

  test "host validation binds results to attempt policy and clean HEAD", context do
    alias SymphonyElixir.Beads.Validation
    path = Workflow.workflow_file_path()
    File.write!(path, String.replace(File.read!(path), "provider:", "provider:\n    allow_host_validation: true"))
    :ok = WorkflowStore.force_reload()
    assert {:ok, [issue]} = Adapter.fetch_issues_by_ids(["bd-ready"])
    policy = %{"mode" => "targeted", "commands" => [["sh", "-c", "exit 0"]], "review" => "none"}
    metadata = Map.put(issue.native_ref["metadata"], "symphony_validation", policy)
    issue = %{issue | native_ref: Map.put(issue.native_ref, "metadata", metadata)}
    assert {:ok, issue, opts} = Adapter.prepare_run(issue, [])
    workspace = Path.join(context.root, "verification-worktree")
    File.mkdir_p!(workspace)
    {_, 0} = System.cmd("git", ["init", "-q", workspace])
    {_, 0} = System.cmd("git", ["-c", "user.name=Smoke", "-c", "user.email=smoke@example.com", "commit", "--allow-empty", "-qm", "initial"], cd: workspace)
    assert {:ok, record} = RunJournal.checkpoint(opts[:run_record], %{"workspace" => workspace})
    assert {:error, :current_validation_required} = Validation.gate(record)
    assert {:ok, %{"passed" => true}} = Validation.run(opts[:tracker_settings], issue)
    assert {:ok, record} = RunJournal.read(record["directory"])
    assert :ok = Validation.gate(record)
    assert {:error, :validation_delivery_head_mismatch} = Validation.delivery_head(record, String.duplicate("a", 40))
    File.write!(Path.join(workspace, "untracked-change"), "dirty")
    assert {:error, :current_validation_required} = Validation.gate(record)
    assert {:error, :validation_requires_clean_commit} = Validation.run(opts[:tracker_settings], issue)
  end

  test "failed and timed out host checks do not open delivery", context do
    alias SymphonyElixir.Beads.Validation
    path = Workflow.workflow_file_path()
    File.write!(path, String.replace(File.read!(path), "provider:", "provider:\n    allow_host_validation: true"))
    :ok = WorkflowStore.force_reload()
    assert {:ok, [issue]} = Adapter.fetch_issues_by_ids(["bd-ready"])
    policy = %{"mode" => "targeted", "commands" => [["sh", "-c", "exit 7"], ["sh", "-c", "sleep 5"]], "timeout_ms" => 100}
    issue = %{issue | native_ref: Map.put(issue.native_ref, "metadata", %{"symphony_validation" => policy})}
    assert {:ok, issue, opts} = Adapter.prepare_run(issue, [])
    workspace = Path.join(context.root, "failed-verification")
    File.mkdir_p!(workspace)
    {_, 0} = System.cmd("git", ["init", "-q", workspace])
    {_, 0} = System.cmd("git", ["-c", "user.name=Smoke", "-c", "user.email=smoke@example.com", "commit", "--allow-empty", "-qm", "initial"], cd: workspace)
    {:ok, record} = RunJournal.checkpoint(opts[:run_record], %{"workspace" => workspace})
    assert {:ok, %{"passed" => false, "results" => results}} = Validation.run(opts[:tracker_settings], issue)
    assert Enum.map(results, & &1["exit_code"]) == [7, 124]
    {:ok, record} = RunJournal.read(record["directory"])
    assert {:error, :current_validation_required} = Validation.gate(record)
    {:ok, _} = RunJournal.checkpoint(record, %{"thread_id" => "existing-thread"})
    changed = put_in(issue.native_ref["metadata"]["symphony_validation"]["timeout_ms"], 200)
    {:ok, policy} = Validation.policy(opts[:tracker_settings], changed)
    result = Adapter.preflight(opts[:tracker_settings], changed, [], policy)
    assert {:error, :validation_policy_changed_for_existing_thread} = result
  end

  test "host checkpoint commits only authorized paths without publishing before validation", context do
    alias SymphonyElixir.Beads.Publication
    url = "https://github.com/example/repo/issues/1"
    records = Jason.decode!(File.read!(context.data))

    records =
      Enum.map(records, fn row ->
        if row["id"] == "bd-ready", do: row |> Map.put("external_ref", url) |> Map.put("labels", ["symphony", "symphony:checkpoint"]), else: row
      end)

    File.write!(context.data, Jason.encode!(records))
    fake_gh = Path.join(context.root, "gh")
    File.write!(fake_gh, "#!/bin/sh\nprintf '%s' '{\"state\":\"OPEN\",\"url\":\"#{url}\"}'\n")
    File.chmod!(fake_gh, 0o755)
    old_path = System.fetch_env!("PATH")
    System.put_env("PATH", context.root <> ":" <> old_path)
    on_exit(fn -> System.put_env("PATH", old_path) end)
    {:ok, [issue]} = Adapter.fetch_issues_by_ids(["bd-ready"])
    {:ok, issue, opts} = Adapter.prepare_run(issue, [])
    settings = opts[:tracker_settings]
    settings = put_in(settings.provider["checkpoint_paths"], ["allowed.txt"])
    workspace = Path.join(context.root, "checkpoint-worktree")
    File.mkdir_p!(workspace)

    for args <- [
          ["init", "-q"],
          ["config", "user.name", "Smoke"],
          ["config", "user.email", "smoke@example.com"],
          ["checkout", "-qb", "codex/checkpoint"],
          ["remote", "add", "origin", "https://github.com/example/repo"],
          ["remote", "set-url", "--push", "origin", "file:///nonexistent-checkpoint-test"]
        ] do
      {_, 0} = System.cmd("git", args, cd: workspace)
    end

    File.write!(Path.join(workspace, "allowed.txt"), "approved")
    File.write!(Path.join(workspace, "unrelated.txt"), "preserved")
    policy = %{"mode" => "targeted", "commands" => [["true"]]}
    {:ok, _} = RunJournal.checkpoint(opts[:run_record], %{"workspace" => workspace, "validation_policy" => policy})
    assert {:ok, %{published: false, head_sha: sha}} = Publication.checkpoint(settings, issue)
    assert {"allowed.txt\n", 0} = System.cmd("git", ["ls-tree", "--name-only", "HEAD"], cd: workspace)
    assert File.read!(Path.join(workspace, "unrelated.txt")) == "preserved"
    assert {:error, :publication_not_currently_authorized} = Publication.publish(settings, issue)
    File.write!(Path.join(workspace, "allowed.txt"), "second change")
    {_, 0} = System.cmd("git", ["add", "unrelated.txt"], cd: workspace)
    assert {:error, :unrelated_staged_changes} = Publication.checkpoint(settings, issue)
    {_, 0} = System.cmd("git", ["reset", "--", "unrelated.txt"], cd: workspace)
    local = Enum.map(Jason.decode!(File.read!(context.data)), &Map.delete(&1, "external_ref"))
    File.write!(context.data, Jason.encode!(local))
    assert {:error, _} = Publication.checkpoint(settings, issue)
    settings = put_in(settings.provider["allow_local_checkpoint"], true)
    settings = put_in(settings.provider["checkpoint_paths_by_issue"], %{issue.id => ["allowed.txt"]})
    assert {:ok, %{published: false, head_sha: local_sha}} = Publication.checkpoint(settings, issue)
    assert local_sha != sha
    assert {:error, :publication_not_currently_authorized} = Publication.publish(settings, issue)
    revoked = Enum.map(Jason.decode!(File.read!(context.data)), &Map.put(&1, "labels", ["symphony"]))
    File.write!(context.data, Jason.encode!(revoked))
    assert {:error, :publication_not_currently_authorized} = Publication.checkpoint(settings, issue)
    {head, 0} = System.cmd("git", ["rev-parse", "--verify", "HEAD"], cd: workspace)
    assert String.trim(head) == local_sha
    refute Adapter.execute_agent_tool("beads_checkpoint", %{}, issue: %{issue | assignee_id: "wrong"}, tracker_settings: settings)["success"]
  end

  test "retained workspace passes preflight without hiding unrelated or foreign files", context do
    alias SymphonyElixir.Beads.Validation
    workspace = initialized_git(context.root, "retained-preflight")
    marker = Path.join(workspace, ".symphony-retain")
    File.write!(marker, "retained by Symphony\n")
    record = %{"validation_policy" => %{"commands" => [["true"]]}}
    assert :ok = Validation.preflight_workspace(workspace, record)
    assert File.exists?(marker)
    File.write!(Path.join(workspace, "unrelated"), "keep")
    assert {:error, :validation_requires_clean_commit} = Validation.preflight_workspace(workspace, record)
    File.rm!(Path.join(workspace, "unrelated"))
    File.write!(marker, "not owned by Symphony")
    assert {:error, :unowned_retention_marker} = Validation.identity(workspace)
  end

  test "typed handoff rejects partial review before effects and permits blocked checkpoint", context do
    {:ok, [issue]} = Adapter.fetch_issues_by_ids(["bd-ready"])
    {:ok, issue, opts} = Adapter.prepare_run(issue, [])
    binding = [issue: issue, tracker_settings: opts[:tracker_settings]]
    before = File.read!(context.data)
    result = Adapter.execute_agent_tool("beads_await_human", %{"reason" => "blocked", "head_sha" => String.duplicate("a", 40)}, binding)
    refute result["success"]
    assert File.read!(context.data) == before
    arguments = %{"intent" => "blocked", "reason" => "runtime prerequisite", "head_sha" => String.duplicate("a", 40)}
    assert Adapter.execute_agent_tool("beads_await_human", arguments, binding)["success"]
    {:ok, record} = RunJournal.read(opts[:run_record]["directory"])
    assert record["handoff_intent"] == "blocked"
    assert record["blocker_reason"] == arguments["reason"]
    refute record["delivery"]
    {:ok, [task]} = Adapter.command(opts[:tracker_settings], ["show", issue.id, "--json"])
    assert task["metadata"]["symphony_gate"] == "blocked"
    assert :ok = Adapter.finish_run(issue, opts, :ok)
    {:ok, record} = RunJournal.read(record["directory"])
    assert record["phase"] == "blocked"
    {:ok, _} = RunJournal.checkpoint(record, %{"delivery" => %{"head_sha" => String.duplicate("b", 40)}})
    before_run = File.read!(Path.join(record["directory"], "run.json"))
    refute Adapter.execute_agent_tool("beads_await_human", arguments, binding)["success"]
    assert File.read!(Path.join(record["directory"], "run.json")) == before_run
  end

  test "compact same-thread prompt keeps custom rules and rejects stale template reuse" do
    alias SymphonyElixir.Beads.{Brief, Validation}
    path = Workflow.workflow_file_path()
    text = File.read!(path) |> String.replace("provider:", "provider:\n    compact_task_context: true")
    File.write!(path, text <> "\nMANDATORY CUSTOM RULE\n" <> String.duplicate("Preserve the custom Workflow instruction.\n", 20))
    :ok = WorkflowStore.force_reload()
    {:ok, [issue]} = Adapter.fetch_issues_by_ids(["bd-ready"])
    settings = Config.settings!().tracker
    {:ok, policy} = Validation.policy(settings, issue)
    {:ok, prompt} = Adapter.preflight(settings, issue, [], policy)
    assert prompt =~ "MANDATORY CUSTOM RULE"
    refute prompt =~ "Implement safely in the assigned checkout"
    {:ok, _prepared, opts} = Adapter.prepare_run(issue, [])
    {:ok, _} = RunJournal.checkpoint(opts[:run_record], %{"thread_id" => "same-thread"})
    {:ok, resumed} = Adapter.preflight(settings, issue, [], policy)
    assert resumed =~ "same native thread"
    assert byte_size(resumed) < byte_size(prompt)
    File.write!(path, File.read!(path) <> "\nNEW CUSTOM RULE\n")
    :ok = WorkflowStore.force_reload()
    {:ok, changed} = Adapter.preflight(settings, issue, [], policy)
    assert changed =~ "NEW CUSTOM RULE"
    assert Brief.template_hash() != opts[:run_record]["brief_template_hash"]
  end

  test "composed delivery validates retained worktree and reuses confirmed publication", context do
    alias SymphonyElixir.Beads.Delivery
    source = "https://github.com/example/repo/issues/1"
    records = Jason.decode!(File.read!(context.data))

    records =
      Enum.map(records, fn row ->
        if row["id"] == "bd-ready", do: row |> Map.put("external_ref", source) |> Map.put("labels", ["symphony", "symphony:publish"]), else: row
      end)

    File.write!(context.data, Jason.encode!(records))
    fake_gh = Path.join(context.root, "gh")
    calls = Path.join(context.root, "gh-calls")

    File.write!(fake_gh, """
    #!/usr/bin/env python3
    import json,sys
    args=sys.argv[1:]
    with open(#{inspect(calls)},'a') as f: f.write(json.dumps(args)+'\\n')
    if args[:2]==['issue','view']: print(json.dumps({'state':'OPEN','url':#{inspect(source)}}))
    elif args[:2]==['pr','list']: print('[]')
    elif args[:2]==['pr','create']: print('https://github.com/example/repo/pull/1')
    else: sys.exit(9)
    """)

    File.chmod!(fake_gh, 0o755)
    old = System.fetch_env!("PATH")
    System.put_env("PATH", context.root <> ":" <> old)
    on_exit(fn -> System.put_env("PATH", old) end)
    {:ok, [issue]} = Adapter.fetch_issues_by_ids(["bd-ready"])
    {:ok, issue, opts} = Adapter.prepare_run(issue, [])
    workspace = initialized_git(context.root, "composed-delivery")
    {_, 0} = System.cmd("git", ["checkout", "-qb", "codex/composed"], cd: workspace)
    {_, 0} = System.cmd("git", ["remote", "add", "origin", "https://github.com/example/repo"], cd: workspace)
    bare = Path.join(context.root, "local-remote.git")
    {_, 0} = System.cmd("git", ["init", "--bare", "-q", bare])
    {_, 0} = System.cmd("git", ["remote", "set-url", "--push", "origin", bare], cd: workspace)
    File.write!(Path.join(workspace, ".symphony-retain"), "retained by Symphony\n")
    File.write!(Path.join(workspace, "allowed.txt"), "approved")
    settings = opts[:tracker_settings]
    settings = %{settings | provider: Map.merge(settings.provider, %{"publish_paths" => ["allowed.txt"], "allow_host_validation" => true})}
    policy = %{"mode" => "targeted", "commands" => [["sh", "-c", "printf verified"]], "timeout_ms" => 1000}
    {:ok, _} = RunJournal.checkpoint(opts[:run_record], %{"workspace" => workspace, "validation_policy" => policy})
    binding = [issue: issue, tracker_settings: settings]
    assert {:ok, delivery} = Delivery.run(binding)
    receipt = delivery["validation_receipt"]
    [result] = receipt["results"]
    assert result["log_sha256"] == Base.encode16(:crypto.hash(:sha256, File.read!(result["log"])), case: :lower)
    assert result["exit_code"] == 0
    {:ok, checkpoint} = RunJournal.read(opts[:run_record]["directory"])
    {:ok, _} = RunJournal.checkpoint(checkpoint, %{"delivery_step" => "handoff"})
    assert {:ok, %{"reused" => true}} = Delivery.run(binding)
    assert Enum.count(String.split(File.read!(calls), "\n", trim: true), &String.contains?(&1, ~s("create"))) == 1
    {:ok, record} = RunJournal.read(opts[:run_record]["directory"])
    assert record["delivery_step"] == "completed"
    assert record["handoff_intent"] == "ready_for_review"
  end

  test "workspace bootstrap preserves a foreign retention marker" do
    {:ok, workspace} = Workspace.create_for_issue("foreign-marker")
    marker = Path.join(workspace, ".symphony-retain")
    File.write!(marker, "user-owned data")
    assert {:error, :retention_marker_occupied} = Workspace.create_for_issue("foreign-marker")
    assert File.read!(marker) == "user-owned data"
  end

  defp initialized_git(root, name) do
    workspace = Path.join(root, name)
    File.mkdir_p!(workspace)

    for args <- [["init", "-q"], ["config", "user.name", "Smoke"], ["config", "user.email", "smoke@example.com"], ["commit", "--allow-empty", "-qm", "initial"]] do
      {_, 0} = System.cmd("git", args, cd: workspace)
    end

    workspace
  end
end
