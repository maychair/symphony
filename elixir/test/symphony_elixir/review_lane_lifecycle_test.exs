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
    if method=='GET' and '/discussions' in path and (r/'fail-read').exists():
      (r/'fail-read').unlink();sys.exit(3)
    ds=json.loads((r/'discussions.json').read_text())
    if path=='user':out={'id':20,'username':'reviewer'}
    elif '/discussions' in path:
      if method=='POST':
        body=a[a.index('--raw-field')+1].split('=',1)[1];n=len(ds)+1
        out={'id':str(n),'notes':[{'id':n,'body':body,'resolved':False,'created_at':'2026-01-01T00:00:00Z','author':{'id':20,'username':'reviewer'}}]}
        journal=json.loads((r/'state'/'review-lane.json').read_text())
        entries=[e for v in journal['records'].values() for e in v.get('publication',{}).get('entries',[])]
        assert any(e['body']==body and e['status']=='sending' for e in entries)
        posts=json.loads((r/'posts.json').read_text()) if (r/'posts.json').exists() else []
        posts.append(body);(r/'posts.json').write_text(json.dumps(posts))
        faults=json.loads((r/'faults.json').read_text()) if (r/'faults.json').exists() else {}
        mode=faults.get(str(len(posts)))
        if mode=='edited':out['notes'][0]['body']='edited '+body
        if mode=='wrong_actor':out['notes'][0]['author']['id']=99
        if mode=='reply':out['notes'].append({'id':900,'body':'请核对新增的边界条件','author':{'id':30},'created_at':'2026-01-02T00:00:00Z'})
        if mode!='drop':ds.append(out)
        if mode=='duplicate':ds.append({'id':'duplicate','notes':[dict(out['notes'][0],id=1000)]})
        if mode=='preempt_next':
          entry=next(e for e in entries if e['body']==body)
          next_entry=next(e for e in entries if e['index']==entry['index']+1)
          ds.append({'id':'preempted','notes':[dict(out['notes'][0],id=1001,body=next_entry['body'])]})
        (r/'discussions.json').write_text(json.dumps(ds))
        if mode=='head':(r/'changed-head').write_text('new head')
        if mode=='interrupt_read':(r/'fail-read').write_text('once')
        if mode in ['lost','interrupt_read']:sys.exit(3)
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
    assert {:error, :invalid_review_submission} = Listener.submit(issue.id, %{"findings" => ["请核对空输入。\n/approve"]})
    refute File.exists?(Path.join(c.root, "posts.json"))
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
    [discussion, conclusion] = Jason.decode!(File.read!(path))
    reply = %{"id" => 99, "body" => "已修复空输入处理", "author" => %{"id" => 30}, "created_at" => "2026-01-02T00:00:00Z"}
    File.write!(path, Jason.encode!([Map.update!(discussion, "notes", &(&1 ++ [reply])), conclusion]))
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
    [discussion, conclusion] = Jason.decode!(File.read!(path))
    reply = %{"id" => 99, "body" => "已修复输入检查", "author" => %{"id" => 30}, "created_at" => "2026-01-02T00:00:00Z"}
    discussion = Map.update!(discussion, "notes", &(&1 ++ [reply]))
    File.write!(path, Jason.encode!([discussion, conclusion]))
    {:ok, rounds} = Listener.issues()
    next = Enum.find(rounds, & &1.dispatchable)
    {:ok, _, _} = Listener.begin_run(next.id)
    changed = update_in(discussion["notes"], fn [own, reply] -> [own, Map.put(reply, "body", "还有另一个边界条件")] end)
    File.write!(path, Jason.encode!([changed, conclusion]))
    assert {:error, :review_responses_changed} = Listener.submit(next.id, %{"findings" => []})
    assert length(Jason.decode!(File.read!(path))) == 2
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

  test "POST response data alone never proves a comment was delivered", c do
    path = "projects/team%2Frepo/merge_requests/1/discussions"

    for reply <- [%{"id" => "d", "notes" => []}, %{}, "EXIT"] do
      :sys.replace_state(Listener, &%{&1 | records: %{}})
      assert :ok = Listener.request_review("team/repo", 1)
      {:ok, [issue]} = Listener.issues()
      {:ok, _, _} = Listener.begin_run(issue.id)
      responses(c, %{("POST " <> path) => reply})
      assert {:error, :review_publication_uncertain} = Listener.submit(issue.id, %{"findings" => []})
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

  test "lost POST responses recover from exact native comments without repeating sends", c do
    faults(c, %{"1" => "lost"})
    {:ok, [issue]} = Listener.issues()
    {:ok, _, _} = Listener.begin_run(issue.id)
    assert :ok = Listener.submit(issue.id, %{"findings" => []})
    record = saved_review(c, issue)
    assert record["phase"] == "completed"
    assert [%{"status" => "published", "receipt" => receipt}] = record["publication"]["entries"]
    assert receipt["actor"] == 20
    assert receipt["work"] == record["work"]
    assert [body] = posts(c)
    assert :ok = Listener.submit(issue.id, %{"findings" => []})
    assert {:error, :changed_submission} = Listener.submit(issue.id, %{"findings" => ["后来改变的结论。"]})
    assert posts(c) == [body]
    assert body =~ record["head"]
    assert body =~ record["base"]
    :ok = Listener.checkpoint(issue.id, %{"native_stop_confirmed" => true})
    assert {:ok, [_]} = Listener.issues()
    assert posts(c) == [body]
  end

  test "partial publication resumes unsent findings only after native stop and recovers the lost receipt", c do
    faults(c, %{"2" => "interrupt_read"})
    {:ok, [issue]} = Listener.issues()
    {:ok, _, _} = Listener.begin_run(issue.id)
    :ok = Listener.checkpoint(issue.id, %{"thread_id" => "native-review", "thread_allocation_intent" => true})
    findings = ["第一条：空输入越界。", "第二条：输出缺少终止符。", "第三条：错误路径泄漏句柄。"]
    assert {:error, {:command_failed, _, 3}} = Listener.submit(issue.id, %{"findings" => findings})
    record = saved_review(c, issue)
    assert Enum.map(record["publication"]["entries"], & &1["status"]) == ["published", "sending", "prepared", "prepared"]
    assert length(record["findings"]) == 1
    stop_supervised!(Listener)
    start_supervised!({Listener, config: c.config})
    await_listener()
    {:ok, [fenced]} = Listener.issues()
    assert fenced.native_ref["phase"] == "fenced"
    assert length(fenced.native_ref["findings"]) == 2
    assert length(posts(c)) == 2
    :ok = Listener.checkpoint(issue.id, %{"native_stop_confirmed" => true})
    responses(c, %{"GET user" => %{"id" => 99}})
    {:ok, [wrong_identity]} = Listener.issues()
    assert wrong_identity.native_ref["publication_error"] =~ "gitlab_identity_mismatch"
    assert length(posts(c)) == 2
    responses(c, %{})
    {:ok, [complete]} = Listener.issues()
    assert complete.native_ref["phase"] == "completed"
    assert length(complete.native_ref["findings"]) == 3
    assert length(complete.native_ref["receipts"]) == 4
    assert [_, _, third, conclusion] = posts(c)
    assert third =~ "第三条"
    assert conclusion =~ "本轮评审完成"
    assert Enum.all?(posts(c), &String.contains?(&1, issue.native_ref["head"]))
    assert {:ok, [^complete]} = Listener.issues()
    assert length(posts(c)) == 4
  end

  test "an absent uncertain send remains fenced across restart even when native execution stopped", c do
    faults(c, %{"1" => "drop"})
    {:ok, [issue]} = Listener.issues()
    {:ok, _, _} = Listener.begin_run(issue.id)
    assert {:error, :review_publication_uncertain} = Listener.submit(issue.id, %{"findings" => []})
    :ok = Listener.checkpoint(issue.id, %{"native_stop_confirmed" => true})
    stop_supervised!(Listener)
    start_supervised!({Listener, config: c.config})
    await_listener()
    {:ok, [fenced]} = Listener.issues()
    assert fenced.native_ref["publication_error"] =~ "review_publication_uncertain"
    assert fenced.native_ref["phase"] == "fenced"
    refute fenced.dispatchable
    assert length(posts(c)) == 1
    assert Jason.decode!(File.read!(Path.join(c.root, "discussions.json"))) == []
  end

  for {mode, reason} <- [
        {"edited", :review_publication_conflict},
        {"wrong_actor", :review_publication_conflict},
        {"duplicate", :review_publication_conflict},
        {"preempt_next", :unexpected_review_publication}
      ] do
    @tag publication_fault: {mode, reason}
    test "native readback rejects #{mode} and does not publish a conclusion", c do
      {mode, reason} = c.publication_fault
      faults(c, %{"1" => mode})
      {:ok, [issue]} = Listener.issues()
      {:ok, _, _} = Listener.begin_run(issue.id)
      assert {:error, ^reason} = Listener.submit(issue.id, %{"findings" => ["空输入导致越界，请检查长度。"]})
      assert length(posts(c)) == 1
      assert saved_review(c, issue)["phase"] == "fenced"
    end
  end

  test "head changes preserve old receipts without publishing the remainder on the new version", c do
    faults(c, %{"1" => "head"})
    {:ok, [issue]} = Listener.issues()
    {:ok, _, _} = Listener.begin_run(issue.id)
    assert {:error, :mr_head_changed} = Listener.submit(issue.id, %{"findings" => ["旧版本存在空输入越界。", "旧版本存在资源泄漏。"]})
    :ok = Listener.checkpoint(issue.id, %{"native_stop_confirmed" => true})
    {:ok, rounds} = Listener.issues()
    assert length(rounds) == 2
    old = Enum.find(rounds, &(&1.id == issue.id))
    assert old.native_ref["phase"] == "superseded"
    assert length(old.native_ref["findings"]) == 1
    assert length(posts(c)) == 1
    assert [next] = Enum.filter(rounds, & &1.dispatchable)
    assert next.native_ref["round"] == 2
  end

  test "editing or deleting a confirmed publication invalidates its current delivery evidence", c do
    {:ok, [issue]} = Listener.issues()
    {:ok, _, _} = Listener.begin_run(issue.id)
    :ok = Listener.submit(issue.id, %{"findings" => []})
    :ok = Listener.checkpoint(issue.id, %{"native_stop_confirmed" => true})
    path = Path.join(c.root, "discussions.json")
    [discussion] = Jason.decode!(File.read!(path))
    changed = update_in(discussion["notes"], fn [note] -> [Map.put(note, "id", 999)] end)
    File.write!(path, Jason.encode!([changed]))
    {:ok, [conflict]} = Listener.issues()
    assert conflict.native_ref["phase"] == "fenced"
    assert conflict.native_ref["publication_error"] =~ "review_publication_conflict"
    File.write!(path, "[]")
    {:ok, [missing]} = Listener.issues()
    assert missing.native_ref["publication_error"] =~ "review_publication_missing"
    assert length(posts(c)) == 1
    File.write!(Path.join(c.root, "changed-head"), "new head cannot erase a receipt conflict")
    {:ok, [unknown]} = Listener.issues()
    assert unknown.native_ref["eligibility"] == "unknown"
    assert unknown.native_ref["error"] =~ "review_publication_unverified"
    File.write!(path, Jason.encode!([discussion]))
    {:ok, rounds} = Listener.issues()
    assert [next] = Enum.filter(rounds, & &1.dispatchable)
    assert next.native_ref["round"] == 2
    assert length(posts(c)) == 1
  end

  test "an author reply during the batch invalidates the remaining publication", c do
    faults(c, %{"1" => "reply"})
    {:ok, [issue]} = Listener.issues()
    {:ok, _, _} = Listener.begin_run(issue.id)
    assert {:error, :review_responses_changed} = Listener.submit(issue.id, %{"findings" => ["空输入触发越界。"]})
    assert length(posts(c)) == 1
    :ok = Listener.checkpoint(issue.id, %{"native_stop_confirmed" => true})
    {:ok, rounds} = Listener.issues()
    assert [next] = Enum.filter(rounds, & &1.dispatchable)
    assert next.native_ref["round"] == 2
    assert next.native_ref["response_sha"] != issue.native_ref["response_sha"]
  end

  test "journal corruption cannot change a publication's context, body, status or native receipt", c do
    {:ok, [issue]} = Listener.issues()
    {:ok, _, _} = Listener.begin_run(issue.id)
    :ok = Listener.submit(issue.id, %{"findings" => []})
    :ok = Listener.checkpoint(issue.id, %{"native_stop_confirmed" => true})
    path = Path.join(c.root, "state/review-lane.json")
    original = Jason.decode!(File.read!(path))
    record = saved_review(c, issue)
    [entry] = record["publication"]["entries"]
    stop_supervised!(Listener)

    corruptions = [
      put_in(record["publication"]["context"]["head"], String.duplicate("f", 40)),
      put_in(record["publication"]["actor"], 99),
      put_in(record["publication"]["entries"], [nil]),
      put_in(record["publication"]["entries"], [Map.put(entry, "body", "different body")]),
      put_in(record["publication"]["entries"], [Map.put(entry, "status", "unknown")]),
      put_in(record["publication"]["entries"], [Map.put(entry, "receipt", nil)]),
      Map.delete(record, "publication")
    ]

    for corrupted <- corruptions do
      File.write!(path, Jason.encode!(put_in(original["records"][record["id"]], corrupted)))
      pid = start_supervised!({Listener, config: c.config})
      send(pid, :configure)
      assert %{health: :failed, error: error} = Listener.health()
      assert error =~ "invalid_review_journal"
      stop_supervised!(Listener)
    end

    File.write!(path, Jason.encode!(original))
    start_supervised!({Listener, config: c.config})
    await_listener()
    {:ok, [restored]} = Listener.issues()
    assert restored.native_ref["phase"] == "completed"
    assert length(posts(c)) == 1
  end

  defp faults(c, values), do: File.write!(Path.join(c.root, "faults.json"), Jason.encode!(values))
  defp posts(c), do: Jason.decode!(File.read!(Path.join(c.root, "posts.json")))

  defp saved_review(c, issue) do
    Jason.decode!(File.read!(Path.join(c.root, "state/review-lane.json")))["records"][String.replace_prefix(issue.id, "review:", "")]
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
    %{issue: issue, mr: mr, project: project} = runner_fixture(c)
    assert :ok = Runner.run(issue, self())
    assert_received {:worker_runtime_info, _, %{workspace_path: snapshot}}
    assert File.read!(Path.join(snapshot, "source.txt")) == "fixture"
    assert_received {:codex_worker_update, _, %{event: :session_started}}
    assert :ok = Listener.checkpoint(issue.id, %{"phase" => "queued", "resume_thread_id" => "review-thread"})
    assert :ok = Runner.run(issue, nil, [])
    assert :ok = Listener.checkpoint(issue.id, %{"phase" => "queued"})
    send(self(), :symphony_stop)
    assert :ok = Runner.run(issue, nil)
    assert review_record(c, issue)["native_stop_receipt"]["source"] == "thread/read"
    File.write!(Path.join(c.root, "no-submit"), "true")
    assert :ok = Listener.checkpoint(issue.id, %{"phase" => "queued"})
    assert_raise RuntimeError, ~r/Review did not complete/, fn -> Runner.run(issue, nil) end

    for remote <- [nil, "https://review.invalid/team/repo.git", "https://wrong.invalid/team/repo.git"] do
      assert :ok = Listener.checkpoint(issue.id, %{"phase" => "queued", "resume_thread_id" => nil})
      responses(c, %{"GET projects/team%2Frepo/merge_requests/1" => mr, "GET projects/team%2Frepo" => %{project | "ssh_url_to_repo" => remote}})
      assert_raise RuntimeError, ~r/Review execution fenced/, fn -> Runner.run(issue, nil) end
    end
  end

  test "withdrawn review stops the native turn before releasing its running slot", c do
    %{issue: issue, mr: mr, project: project} = runner_fixture(c)
    File.write!(Path.join(c.root, "hang"), "true")
    recipient = self()
    task = Task.async(fn -> Runner.run(issue, recipient) end)
    assert_receive {:worker_runtime_info, _, %{workspace_path: snapshot}}, 5_000
    assert_receive {:codex_worker_update, _, %{event: :session_started}}, 5_000
    running = review_record(c, issue)
    assert_raise RuntimeError, ~r/review_execution_fenced/, fn -> Runner.run(issue, nil) end
    assert review_record(c, issue) == running
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
    assert record["native_stop_receipt"]["turn_id"] == "review-turn"
    assert record["workspace"] == snapshot
    assert File.read!(Path.join(snapshot, "source.txt")) == "fixture"
    methods = native_methods(c)
    assert Enum.count(methods, &(&1 == "initialize")) == 1
    assert Enum.count(methods, &(&1 == "thread/start")) == 1
    assert Enum.count(methods, &(&1 == "turn/start")) == 1
    assert "turn/interrupt" in methods
    refute "thread/resume" in methods
    refute File.exists?(Path.join(c.root, "posts.json"))
  end

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
    assert message =~ "resume_thread_not_proven_idle"
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

  test "lost live transport preserves uncertainty without opening a replacement app server", c do
    %{issue: issue} = runner_fixture(c)
    File.write!(Path.join(c.root, "disconnect"), "true")
    assert_raise RuntimeError, ~r/native_stop_transport_unavailable/, fn -> Runner.run(issue, nil) end
    record = review_record(c, issue)
    refute record["native_stop_confirmed"]
    assert record["native_stop_recovery"] =~ "native_stop_transport_unavailable"
    assert File.dir?(record["workspace"])
    assert Enum.count(native_methods(c), &(&1 == "initialize")) == 1
    assert Jason.decode!(File.read!(Path.join(c.root, "native-state.json")))["status"] == "inProgress"
    {:ok, rounds} = Listener.issues()
    refute Enum.any?(rounds, & &1.dispatchable)
  end

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
    assert {:ok, [_]} = Listener.issues()

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

  defp runner_fixture(c) do
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
    root=pathlib.Path(#{inspect(c.root)})
    state=root/'native-state.json'
    def save(status):state.write_text(json.dumps({'id':'review-turn','status':status}))
    def thread():
      turns=[json.loads(state.read_text())] if state.exists() else []
      return {'id':'review-thread','status':{'type':'active' if turns and turns[-1]['status']=='inProgress' else 'idle'},'turns':turns}
    def emit(v):print(json.dumps(v),flush=True)
    for line in sys.stdin:
      q=json.loads(line);m=q.get('method')
      with (root/'native-requests.jsonl').open('a') as f:f.write(json.dumps(q)+'\\n')
      if m=='initialize':emit({'id':q['id'],'result':{}})
      elif m=='thread/goal/get':emit({'id':q['id'],'result':{'goal':None}})
      elif m=='thread/read':emit({'id':q['id'],'result':{'thread':thread()}})
      elif m=='turn/interrupt':
        assert q['params']=={'threadId':'review-thread','turnId':'review-turn'}
        if not (root/'unconfirmed-stop').exists():save('interrupted')
        emit({'id':q['id'],'result':{}})
      elif m in ['thread/start','thread/resume']:
        emit({'id':q['id'],'result':{'thread':{'id':'review-thread','status':{'type':'idle'},'turns':[]}}})
      elif m=='turn/start':
        assert q['params']['sandboxPolicy']=={'type':'readOnly'}
        save('inProgress')
        emit({'id':q['id'],'result':{'turn':{'id':'review-turn'}}})
        if (root/'disconnect').exists():sys.exit(0)
        if (root/'hang').exists():continue
        if not pathlib.Path(#{inspect(Path.join(c.root, "no-submit"))}).exists():
          emit({'id':100,'method':'item/tool/call','params':{'threadId':'review-thread','turnId':'review-turn','tool':'review_submit','arguments':{'findings':[]}}})
        else:
          save('completed')
          emit({'method':'turn/completed','params':{'threadId':'review-thread','turn':{'id':'review-turn','status':'completed'}}})
      elif q.get('id')==100:
        assert q['result']['success']
        save('completed')
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
    %{issue: issue, mr: mr, project: project}
  end

  defp review_record(c, issue) do
    records = c.config["state_dir"] |> Path.join("review-lane.json") |> File.read!() |> Jason.decode!() |> Map.fetch!("records")
    Map.fetch!(records, String.replace_prefix(issue.id, "review:", ""))
  end

  defp native_methods(c) do
    c.root |> Path.join("native-requests.jsonl") |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!(&1)["method"])
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
