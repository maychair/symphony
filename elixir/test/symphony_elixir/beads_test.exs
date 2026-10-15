defmodule SymphonyElixir.BeadsTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.Beads.{Acceptance, Adapter, RunJournal}

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

  test "native run checkpoints intent before side effects and delivers exactly one root turn", context do
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
      method=request['method']
      if method=='initialize': send({'id':request['id'],'result':{}})
      else:
        with open(#{inspect(journal)}+'/run.json') as f: record=json.load(f)
        with open(#{inspect(native_trace)},'a') as f: f.write(json.dumps({'method':method,'phase':record['phase'],'beads_dir':os.environ.get('BEADS_DIR')})+'\\n')
        if method=='thread/start': send({'id':request['id'],'result':{'thread':{'id':'observed-thread'}}})
        if method=='turn/start':
          assert record['thread_id']=='observed-thread'
          send({'id':request['id'],'result':{'turn':{'id':'observed-turn'}}})
          send({'method':'turn/completed','params':{'threadId':'child-thread','turn':{'id':'child-turn','status':'completed'}}})
          send({'method':'turn/completed','params':{'threadId':'observed-thread','turn':{'id':'observed-turn','status':'completed'}}})
    """)

    File.chmod!(codex, 0o755)
    File.write!(Workflow.workflow_file_path(), File.read!(Workflow.workflow_file_path()) |> String.replace("polling:", "codex:\n  command: #{Jason.encode!(codex)}\npolling:"))
    :ok = WorkflowStore.force_reload()
    old = System.get_env("BEADS_DIR")
    on_exit(fn -> restore_env("BEADS_DIR", old) end)
    System.put_env("BEADS_DIR", "/wrong/inherited/database")
    {:ok, [issue]} = Adapter.fetch_issues_by_ids(["bd-ready"])
    assert :ok = AgentRunner.run(issue)
    events = native_trace |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    assert Enum.map(events, &{&1["method"], &1["phase"]}) == [{"thread/start", "thread_start_intent"}, {"turn/start", "turn_start_intent"}]
    assert Enum.all?(events, &(&1["beads_dir"] == context.database))
    assert {:ok, record} = RunJournal.read(journal)
    assert record["phase"] == "awaiting_human"
    assert record["thread_id"] == "observed-thread"
    assert record["turn_id"] == "observed-turn"
    assert record["turn_count"] == 1
    assert {:ok, [issue]} = Adapter.fetch_issues_by_ids([issue.id])
    assert issue.state == "blocked"
    state = %Orchestrator.State{blocked: %{issue.id => %{issue: issue}}, claimed: MapSet.new([issue.id])}
    reconciled = Orchestrator.reconcile_blocked_issue_states_for_test([issue], state)
    assert Map.has_key?(reconciled.blocked, issue.id)
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
    refute Enum.find(issues, &(&1.id == "bd-blocked")).dispatchable
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
    assert "human" in gated.labels
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
    {:ok, record} = RunJournal.checkpoint(record, %{"thread_id" => "thread", "turn_id" => "turn"})
    assert :ok = RunJournal.complete(record, "completed")
    assert {:ok, resumed} = RunJournal.admit(context.root, "completed")
    assert resumed["owner"] == record["owner"]
    assert resumed["thread_id"] == "thread"
  end

  test "agent tool can only park its own claimed issue and cannot accept" do
    {:ok, [issue]} = Adapter.fetch_issues_by_ids(["bd-ready"])
    {:ok, issue, opts} = Adapter.prepare_run(issue, [])
    settings = opts[:tracker_settings]
    wrong_owner = %{issue | assignee_id: "other"}
    result = Adapter.execute_agent_tool("beads_await_human", %{"reason" => "Review"}, issue: wrong_owner, tracker_settings: settings)
    refute result["success"]
    assert Adapter.execute_agent_tool("beads_await_human", %{"reason" => "Review"}, issue: issue, tracker_settings: settings)["success"]
    refute Adapter.execute_agent_tool("beads_accept", %{}, issue: issue, tracker_settings: settings)["success"]
    assert :ok = Adapter.finish_run(issue, opts, :ok)
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
end
