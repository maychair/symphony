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
        if row["id"] == "bd-ready", do: row |> Map.put("external_ref", url) |> Map.put("labels", ["symphony", "symphony:publish"]), else: row
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
    settings = put_in(settings.provider["publish_paths"], ["allowed.txt"])
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
    assert {:error, :current_validation_required} = Publication.publish(settings, issue)
    {head, 0} = System.cmd("git", ["rev-parse", "--verify", "HEAD"], cd: workspace)
    assert String.trim(head) == sha
    refute Adapter.execute_agent_tool("beads_checkpoint", %{}, issue: %{issue | assignee_id: "wrong"}, tracker_settings: settings)["success"]
  end
end
