defmodule SymphonyElixir.ReviewLaneLifecycleTest do
  use SymphonyElixir.TestSupport, runtime: false
  alias SymphonyElixir.ReviewLane.{Listener, Runner}
  alias SymphonyElixirWeb.WebhookController

  setup do
    root = Path.dirname(Workflow.workflow_file_path())
    Supervisor.terminate_child(SymphonyElixir.Supervisor, Listener)
    on_exit(fn -> Supervisor.restart_child(SymphonyElixir.Supervisor, Listener) end)
    fixture = Path.join(root, "fixture")
    File.mkdir_p!(Path.join(root, "source"))
    File.write!(Path.join(root, "instructions"), "Review only; no subagents.")
    File.write!(Path.join(root, "discussions.json"), "[]")

    File.write!(fixture, """
    #!/usr/bin/env python3
    import sys,json,pathlib,time
    r=pathlib.Path(#{inspect(root)});a=sys.argv[1:];name=pathlib.Path(sys.argv[0]).name
    path=a[a.index('--method')+2];method=a[a.index('--method')+1]
    if (r/'responses.json').exists():
      responses=json.loads((r/'responses.json').read_text())
      key=method+' '+path
      if key in responses:
        if responses[key]=='EXIT':sys.exit(3)
        print(json.dumps(responses[key]));sys.exit(0)
    ds=json.loads((r/'discussions.json').read_text())
    if path=='user':out={'id':20,'username':'reviewer'}
    elif '/discussions' in path:
      if method=='POST':
        body=a[a.index('--raw-field')+1].split('=',1)[1];n=len(ds)+1
        out={'id':str(n),'notes':[{'id':n,'body':body,'resolved':False,'created_at':'2026-01-01T00:00:00Z','author':{'id':20,'username':'reviewer'}}]}
        ds.append(out);(r/'discussions.json').write_text(json.dumps(ds))
      else:out=ds
    else:out={'id':1001,'project_id':10,'iid':1,'state':'opened','sha':('c' if (r/'changed-head').exists() else 'a')*40,'diff_refs':{'base_sha':'b'*40},'author':{'id':30},'reviewers':[{'id':20,'username':'reviewer'}],'web_url':'https://review.invalid/team/repo/-/merge_requests/1'}
    if path=='projects/team%2Frepo':out={'id':10,'path_with_namespace':'team/repo','web_url':'https://review.invalid/team/repo'}
    elif '/merge_requests?' in path:out=[out]
    print(json.dumps(out))
    """)

    File.chmod!(fixture, 0o755)
    File.ln_s!(fixture, Path.join(root, "glab"))

    config = %{
      "enabled" => true,
      "host" => "review.invalid",
      "provider" => "gitlab",
      "reviewer_id" => 20,
      "publisher_id" => 20,
      "projects" => %{"team/repo" => %{"id" => 10, "checkout" => Path.join(root, "source")}},
      "state_dir" => Path.join(root, "state"),
      "instructions_file" => Path.join(root, "instructions"),
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
    assert :ok = Listener.submit(issue.id, %{"findings" => []})
    :ok = Listener.checkpoint(issue.id, %{"native_stop_confirmed" => true})
    {:ok, [done]} = Listener.issues()
    assert done.native_ref["phase"] == "completed"
    refute Issue.routable?(done, ["symphony"])
    stop_supervised!(Listener)
    start_supervised!({Listener, config: c.config})
    await_listener()
    assert :ok = Listener.request_review("team/repo", 1)
    {:ok, [restored]} = Listener.issues()
    assert restored.native_ref["phase"] == "completed"
    assert length(Jason.decode!(File.read!(Path.join(c.root, "discussions.json")))) == 1
    assert :ok = Listener.checkpoint(issue.id, %{"phase" => "failed", "error" => "late worker DOWN"})
    {:ok, [still_done]} = Listener.issues()
    assert still_done.native_ref["phase"] == "completed"
  end

  test "restart fences active execution and publication uncertainty instead of dispatching duplicates", c do
    assert :ok = Listener.request_review("team/repo", 1)
    {:ok, [issue]} = Listener.issues()
    assert {:ok, _, _} = Listener.begin_run(issue.id)
    assert :ok = Listener.checkpoint(issue.id, %{"thread_id" => "native-thread", "turn_id" => "native-turn", "phase" => "publishing"})
    stop_supervised!(Listener)
    start_supervised!({Listener, config: c.config})
    await_listener()
    {:ok, [fenced]} = Listener.issues()
    assert fenced.native_ref["phase"] == "fenced"
    assert fenced.native_ref["previous_phase"] == "publishing"
    assert fenced.native_ref["thread_id"] == "native-thread"
    refute Issue.routable?(fenced, ["symphony"])
    assert {:error, :review_execution_fenced} = Listener.begin_run(issue.id)
    assert :ok = Listener.request_review("team/repo", 1)
    assert {:ok, [_]} = Listener.issues()
    assert Jason.decode!(File.read!(Path.join(c.root, "discussions.json"))) == []
  end

  test "published findings keep their existing worker alive until the native turn stops, and restart cannot redispatch it", c do
    {:ok, [issue]} = Listener.issues()
    {:ok, _, _} = Listener.begin_run(issue.id)
    :ok = Listener.checkpoint(issue.id, %{"thread_id" => "still-finishing", "thread_allocation_intent" => true})
    :ok = Listener.submit(issue.id, %{"findings" => []})
    {:ok, [finishing]} = Listener.issues()
    assert finishing.native_ref["phase"] == "completed"
    assert finishing.dispatchable
    assert {:error, :review_execution_fenced} = Listener.begin_run(issue.id)

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

    next = Orchestrator.reconcile_issue_states_for_test([finishing], state)
    assert Map.has_key?(next.running, issue.id)
    assert Process.alive?(worker.pid)
    send(worker.pid, :stop)
    Task.await(worker)
    stop_supervised!(Listener)
    start_supervised!({Listener, config: c.config})
    await_listener()
    {:ok, [fenced]} = Listener.issues()
    assert fenced.native_ref["phase"] == "fenced"
    assert fenced.native_ref["previous_phase"] == "completed"
    refute fenced.dispatchable
    assert length(Jason.decode!(File.read!(Path.join(c.root, "discussions.json")))) == 1
  end

  test "head change fences publication; author reply is required before another round", c do
    assert :ok = Listener.request_review("team/repo", 1)
    {:ok, [issue]} = Listener.issues()
    {:ok, _, _} = Listener.begin_run(issue.id)
    File.write!(Path.join(c.root, "changed-head"), "changed")
    assert {:error, :mr_head_changed} = Listener.submit(issue.id, %{"findings" => ["空输入导致越界，见 source.cpp:10，请检查长度。"]})
    assert Jason.decode!(File.read!(Path.join(c.root, "discussions.json"))) == []
  end

  test "invalid submissions and failed provider reads cannot publish", c do
    assert {:error, :invalid_review_scope} = Listener.request_review("other/repo", 1)
    assert :ok = Listener.request_review("team/repo", 1)
    {:ok, [issue]} = Listener.issues()
    assert {:error, :invalid_review_submission} = Listener.submit(issue.id, %{})
    assert {:error, :invalid_review_submission} = Listener.submit(issue.id, %{"findings" => []})
    assert {:ok, _, _} = Listener.begin_run(issue.id)
    assert {:error, :invalid_review_submission} = Listener.submit(issue.id, %{"findings" => ["English only"]})
    assert {:error, :invalid_review_submission} = Listener.submit("missing", %{"findings" => []})
    responses(c, %{"GET user" => %{"username" => "someone-else"}})
    assert {:error, :gitlab_identity_mismatch} = Listener.submit(issue.id, %{"findings" => []})
    responses(c, %{"GET projects/team%2Frepo/merge_requests/1" => "EXIT"})
    assert :ok = Listener.request_review("team/repo", 1)
    {:ok, [unknown]} = Listener.issues()
    refute unknown.dispatchable
    assert unknown.native_ref["eligibility"] == "unknown"
    responses(c, %{"GET projects/team%2Frepo/merge_requests/1" => %{}})
    assert :ok = Listener.request_review("team/repo", 1)
    assert {:ok, [_]} = Listener.issues()
  end

  test "native identity drift at submission cannot publish into a same-number foreign MR", c do
    {:ok, [issue]} = Listener.issues()
    {:ok, _, _} = Listener.begin_run(issue.id)
    responses(c, %{"GET projects/team%2Frepo/merge_requests/1" => %{"iid" => 1, "project_id" => 99}})
    assert {:error, :mr_head_changed} = Listener.submit(issue.id, %{"findings" => []})
    assert Jason.decode!(File.read!(Path.join(c.root, "discussions.json"))) == []
  end

  test "findings wait for author response and schedule only one subsequent round", c do
    assert :ok = Listener.request_review("team/repo", 1)
    {:ok, [issue]} = Listener.issues()
    {:ok, _, _} = Listener.begin_run(issue.id)

    assert %{"success" => true} =
             SymphonyElixir.ReviewLane.execute_agent_tool(
               "review_submit",
               %{"findings" => ["空输入导致越界，见 source.cpp:10，请检查长度。"]},
               issue: issue
             )

    :ok = Listener.checkpoint(issue.id, %{"native_stop_confirmed" => true})
    assert {:ok, [_]} = Listener.issues()
    path = Path.join(c.root, "discussions.json")
    [discussion] = Jason.decode!(File.read!(path))
    reply = %{"id" => 99, "body" => "已修复空输入处理", "author" => %{"id" => 30}, "created_at" => "2026-01-02T00:00:00Z"}
    File.write!(path, Jason.encode!([Map.update!(discussion, "notes", &(&1 ++ [reply]))]))
    {:ok, rounds} = Listener.issues()
    assert length(rounds) == 2
    assert Enum.any?(rounds, &(&1.native_ref["round"] == 2 and &1.native_ref["phase"] == "queued"))
    assert {:ok, ^rounds} = Listener.issues()
  end

  test "a reply edited during review cannot publish a conclusion for the prior response version", c do
    {:ok, [issue]} = Listener.issues()
    {:ok, _, _} = Listener.begin_run(issue.id)
    :ok = Listener.submit(issue.id, %{"findings" => ["空输入导致越界，见 source.cpp:10，请检查输入长度。"]})
    :ok = Listener.checkpoint(issue.id, %{"native_stop_confirmed" => true})
    path = Path.join(c.root, "discussions.json")
    [discussion] = Jason.decode!(File.read!(path))
    reply = %{"id" => 99, "body" => "已修复输入检查", "author" => %{"id" => 30}, "created_at" => "2026-01-02T00:00:00Z"}
    discussion = Map.update!(discussion, "notes", &(&1 ++ [reply]))
    File.write!(path, Jason.encode!([discussion]))
    {:ok, rounds} = Listener.issues()
    next = Enum.find(rounds, & &1.dispatchable)
    {:ok, _, _} = Listener.begin_run(next.id)
    changed = update_in(discussion["notes"], fn [own, reply] -> [own, Map.put(reply, "body", "还有另一个边界条件")] end)
    File.write!(path, Jason.encode!([changed]))
    assert {:error, :review_responses_changed} = Listener.submit(next.id, %{"findings" => []})
    assert length(Jason.decode!(File.read!(path))) == 1
  end

  test "a new push after a no-findings result starts one round and retires the previous dispatch", c do
    {:ok, [issue]} = Listener.issues()
    {:ok, _, _} = Listener.begin_run(issue.id)
    assert :ok = Listener.submit(issue.id, %{"findings" => []})
    :ok = Listener.checkpoint(issue.id, %{"native_stop_confirmed" => true})
    File.write!(Path.join(c.root, "changed-head"), "new commit")
    {:ok, rounds} = Listener.issues()
    assert length(rounds) == 2
    assert [next] = Enum.filter(rounds, & &1.dispatchable)
    assert next.native_ref["round"] == 2
    assert next.native_ref["head"] == String.duplicate("c", 40)
    assert {:ok, ^rounds} = Listener.issues()
    assert {:error, :review_execution_fenced} = Listener.begin_run(issue.id)
  end

  test "changed input cannot replace an unconfirmed native executor", c do
    {:ok, [issue]} = Listener.issues()
    {:ok, _, _} = Listener.begin_run(issue.id)
    :ok = Listener.checkpoint(issue.id, %{"thread_allocation_intent" => true, "thread_id" => "native-running"})
    File.write!(Path.join(c.root, "changed-head"), "new commit")
    {:ok, [stopping]} = Listener.issues()
    refute stopping.dispatchable
    assert stopping.native_ref["eligibility"] == "superseded"
    :ok = Listener.checkpoint(issue.id, %{"native_stop_confirmed" => true, "phase" => "failed"})
    {:ok, rounds} = Listener.issues()
    assert length(Enum.filter(rounds, & &1.dispatchable)) == 1
    assert length(rounds) == 2
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
    :ok = Listener.checkpoint(issue.id, %{"native_stop_confirmed" => true})
    {:ok, rounds} = Listener.issues()
    assert length(rounds) == 2
    assert [next] = Enum.filter(rounds, & &1.dispatchable)
    assert next.native_ref["round"] == 2
  end

  test "closed, merged and explicitly unassigned native MRs end eligibility and reopening creates a new round", c do
    {:ok, [issue]} = Listener.issues()
    record = issue.native_ref

    mr = %{
      "id" => 1001,
      "iid" => 1,
      "project_id" => 10,
      "state" => "opened",
      "sha" => record["head"],
      "diff_refs" => %{"base_sha" => record["base"]},
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
    {:ok, rounds} = Listener.issues()
    assert [next] = Enum.filter(rounds, & &1.dispatchable)
    assert next.native_ref["round"] == 2
    assert {:ok, ^rounds} = Listener.issues()
  end

  test "publication receipts must belong to the configured reviewer", c do
    path = "projects/team%2Frepo/merge_requests/1/discussions"

    for {reply, reason} <- [
          {%{"id" => "d", "notes" => []}, :invalid_owned_note_receipt},
          {%{}, :invalid_discussion_receipt},
          {"EXIT", {:command_failed, c.config["glab_bin"], 3}}
        ] do
      :sys.replace_state(Listener, &%{&1 | records: %{}})
      assert :ok = Listener.request_review("team/repo", 1)
      {:ok, [issue]} = Listener.issues()
      {:ok, _, _} = Listener.begin_run(issue.id)
      responses(c, %{("POST " <> path) => reply})
      assert {:error, ^reason} = Listener.submit(issue.id, %{"findings" => []})
      File.rm!(Path.join(c.root, "responses.json"))
    end
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

  test "disabled, changed and legacy configurations cannot start native discovery", c do
    {:ok, disabled} = Listener.init([])
    assert {:reply, {:ok, []}, ^disabled} = Listener.handle_call(:issues, self(), disabled)

    assert {:reply, {:error, :invalid_review_scope}, _} =
             Listener.handle_call({:request_review, "team/repo", 1}, self(), disabled)

    assert {:noreply, ^disabled} = Listener.handle_info(:poll, disabled)
    state = :sys.get_state(Listener)
    changed = %{state | initial_config: nil}

    assert {:reply, {:error, :review_lane_configuration_changed_restart_required}, suspended} =
             Listener.handle_call(:issues, self(), changed)

    assert suspended.health == :failed
    assert {:noreply, %{health: :failed}} = Listener.handle_info(:check_config, changed)
    assert {:noreply, %{health: :failed}} = Listener.handle_info(:poll, changed)
    assert {:noreply, ^state} = Listener.handle_info(:unknown, state)
    File.write!(Path.join(c.config["state_dir"], "review-lane.json"), "{}")
    {:ok, initial} = Listener.init(config: c.config)
    assert {:noreply, %{health: :failed}} = Listener.handle_info(:configure, initial)
    File.write!(Path.join(c.config["state_dir"], "mail-review.json"), "legacy execution receipts")
    assert {:noreply, %{health: :failed, error: error}} = Listener.handle_info(:configure, initial)
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
      File.write!(path, Jason.encode!(Map.merge(original, change)))
      {:ok, initial} = Listener.init(config: c.config)
      assert {:noreply, %{health: :failed}} = Listener.handle_info(:configure, initial)
    end

    File.write!(path, Jason.encode!(original))
  end

  test "review runner uses a fixed snapshot, submits findings and resumes only that same head", c do
    source = c.config["projects"]["team/repo"]["checkout"]
    git = System.find_executable("git")
    {_, 0} = System.cmd(git, ["init", "-q", source])
    File.write!(Path.join(source, "source.txt"), "fixture")
    {_, 0} = System.cmd(git, ["-C", source, "add", "source.txt"])
    {_, 0} = System.cmd(git, ["-C", source, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "Fixture"])
    {head, 0} = System.cmd(git, ["-C", source, "rev-parse", "HEAD"])
    head = String.trim(head)
    bin = Path.join(c.root, "bin")
    File.mkdir!(bin)

    File.write!(Path.join(bin, "git"), """
    #!/usr/bin/env python3
    import os,sys
    a=sys.argv[1:]
    if 'fetch' in a: a=a[:a.index('fetch')]+['fetch',#{inspect(source)},'HEAD']
    os.execv(#{inspect(git)},[#{inspect(git)}]+a)
    """)

    File.chmod!(Path.join(bin, "git"), 0o755)
    previous = System.get_env("PATH")
    System.put_env("PATH", bin <> ":" <> previous)
    on_exit(fn -> restore_env("PATH", previous) end)
    server = Path.join(c.root, "review-server")

    File.write!(server, """
    #!/usr/bin/env python3
    import sys,json,pathlib
    def emit(v):print(json.dumps(v),flush=True)
    for line in sys.stdin:
      q=json.loads(line);m=q.get('method')
      if m=='initialize':emit({'id':q['id'],'result':{}})
      elif m in ['thread/start','thread/resume']:
        emit({'id':q['id'],'result':{'thread':{'id':'review-thread','status':{'type':'idle'},'turns':[]}}})
      elif m=='turn/start':
        assert q['params']['sandboxPolicy']=={'type':'readOnly'}
        emit({'id':q['id'],'result':{'turn':{'id':'review-turn'}}})
        if not pathlib.Path(#{inspect(Path.join(c.root, "no-submit"))}).exists():
          emit({'id':100,'method':'item/tool/call','params':{'threadId':'review-thread','turnId':'review-turn','tool':'review_submit','arguments':{'findings':[]}}})
        else:emit({'method':'turn/completed','params':{'threadId':'review-thread','turn':{'id':'review-turn','status':'completed'}}})
      elif q.get('id')==100:
        assert q['result']['success']
        emit({'method':'turn/completed','params':{'threadId':'review-thread','turn':{'id':'review-turn','status':'completed'}}})
    """)

    File.chmod!(server, 0o755)
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", workspace_root: Path.join(c.root, "workspaces"), codex_command: server)

    mr = %{
      "id" => 1001,
      "project_id" => 10,
      "iid" => 1,
      "state" => "opened",
      "sha" => head,
      "diff_refs" => %{"base_sha" => head},
      "author" => %{"id" => 30},
      "reviewers" => [%{"id" => 20, "username" => "reviewer"}],
      "web_url" => "https://review.invalid/team/repo/-/merge_requests/1"
    }

    project = %{"id" => 10, "web_url" => "https://review.invalid/team/repo", "path_with_namespace" => "team/repo", "ssh_url_to_repo" => "git@review.invalid:team/repo.git"}
    responses(c, %{"GET projects/team%2Frepo/merge_requests/1" => mr, "GET projects/team%2Frepo" => project})
    assert :ok = Listener.request_review("team/repo", 1)
    {:ok, rounds} = Listener.issues()
    issue = Enum.find(rounds, & &1.dispatchable)
    assert :ok = Runner.run(issue, self())
    assert_received {:worker_runtime_info, _, %{workspace_path: snapshot}}
    assert File.read!(Path.join(snapshot, "source.txt")) == "fixture"
    assert_received {:codex_worker_update, _, %{event: :session_started}}
    assert :ok = Listener.checkpoint(issue.id, %{"phase" => "queued", "resume_thread_id" => "review-thread"})
    assert :ok = Runner.run(issue, nil, [])
    File.write!(Path.join(c.root, "no-submit"), "true")
    assert :ok = Listener.checkpoint(issue.id, %{"phase" => "queued"})
    assert_raise RuntimeError, ~r/Review did not complete/, fn -> Runner.run(issue, nil) end

    for remote <- [nil, "https://review.invalid/team/repo.git", "https://wrong.invalid/team/repo.git"] do
      assert :ok = Listener.checkpoint(issue.id, %{"phase" => "queued", "resume_thread_id" => nil})
      responses(c, %{"GET projects/team%2Frepo/merge_requests/1" => mr, "GET projects/team%2Frepo" => %{project | "ssh_url_to_repo" => remote}})
      assert_raise RuntimeError, ~r/Review execution fenced/, fn -> Runner.run(issue, nil) end
    end
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
    state = :sys.get_state(Listener)
    assert {:reply, {:ok, _}, _} = Listener.handle_call(:issues, self(), %{state | initial_config: nil, config: config})
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
    for invalid <- [%{}, []] do
      responses(c, %{"GET projects/team%2Frepo" => invalid})
      assert {:ok, [_]} = Listener.issues()
      assert Listener.health().health == :degraded
    end

    path = Path.join(c.config["state_dir"], "review-lane.json")
    File.rm!(path)
    File.mkdir!(path)
    {:ok, initial} = Listener.init(config: c.config)
    assert {:noreply, %{health: :failed}} = Listener.handle_info(:configure, initial)
  end

  test "malformed native work and missing discussion evidence stop eligibility without inventing another review", c do
    {:ok, [issue]} = Listener.issues()

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

    responses(c, %{})
    {:ok, _, _} = Listener.begin_run(issue.id)
    :ok = Listener.submit(issue.id, %{"findings" => ["空输入可触发越界，请在 source.cpp:10 检查输入长度。"]})
    File.write!(Path.join(c.root, "discussions.json"), "[]")
    assert {:ok, [unknown]} = Listener.issues()
    assert unknown.native_ref["eligibility"] == "unknown"
    assert unknown.native_ref["error"] =~ "review_finding_source_missing"
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
