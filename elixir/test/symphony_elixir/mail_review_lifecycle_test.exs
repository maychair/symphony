defmodule SymphonyElixir.MailReviewLifecycleTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.MailReview.{Listener, Policy}

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
    if name=='lark':
      if a[1]=='+watch':
        print('Connected. Waiting for mail events... (Ctrl+C to stop)',flush=True);time.sleep(300)
      else: print(json.dumps({'ok':True,'data':{'head_from':{'mail_address':'gitlab@review.invalid'},'subject':'Example (!1)','body_plain_text':'Reviewer was added as a reviewer.','body_html':'<a href="https://review.invalid/team/repo/-/merge_requests/1">MR</a>'}}))
    else:
      path=a[a.index('--method')+2];method=a[a.index('--method')+1]
      ds=json.loads((r/'discussions.json').read_text())
      if path=='user':out={'id':20,'username':'reviewer'}
      elif '/discussions' in path:
        if method=='POST':
          body=a[a.index('--raw-field')+1].split('=',1)[1];n=len(ds)+1
          out={'id':str(n),'notes':[{'id':n,'body':body,'resolved':False,'created_at':'2026-01-01T00:00:00Z','author':{'id':20,'username':'reviewer'}}]}
          ds.append(out);(r/'discussions.json').write_text(json.dumps(ds))
        else:out=ds
      else:out={'iid':1,'state':'opened','sha':('c' if (r/'changed-head').exists() else 'a')*40,'diff_refs':{'base_sha':'b'*40},'author':{'id':30},'reviewers':[{'username':'reviewer'}],'web_url':'https://review.invalid/team/repo/-/merge_requests/1'}
      print(json.dumps(out))
    """)

    File.chmod!(fixture, 0o755)
    for name <- ["lark", "glab"], do: File.ln_s!(fixture, Path.join(root, name))

    config = %{
      "enabled" => true,
      "host" => "review.invalid",
      "username" => "reviewer",
      "reviewer_names" => ["Reviewer"],
      "mail_senders" => ["gitlab@review.invalid"],
      "projects" => %{"team/repo" => %{"checkout" => Path.join(root, "source")}},
      "state_dir" => Path.join(root, "state"),
      "instructions_file" => Path.join(root, "instructions"),
      "lark_bin" => Path.join(root, "lark"),
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
    event = %{"ok" => true, "data" => %{"event" => %{"message_id" => "request1"}}}
    assert :ok = Listener.ingest(event)
    assert :ok = Listener.ingest(event)
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
    {:ok, [done]} = Listener.issues()
    assert done.native_ref["phase"] == "completed"
    refute Issue.routable?(done, ["symphony"])
    stop_supervised!(Listener)
    start_supervised!({Listener, config: c.config})
    await_listener()
    assert :ok = Listener.ingest(event)
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

  test "head change fences publication; author reply is required before another round", c do
    assert :ok = Listener.request_review("team/repo", 1)
    {:ok, [issue]} = Listener.issues()
    {:ok, _, _} = Listener.begin_run(issue.id)
    File.write!(Path.join(c.root, "changed-head"), "changed")
    assert {:error, :mr_head_changed} = Listener.submit(issue.id, %{"findings" => ["空输入导致越界，见 source.cpp:10，请检查长度。"]})
    assert Jason.decode!(File.read!(Path.join(c.root, "discussions.json"))) == []
    refute Policy.answered?([%{"discussion_id" => "missing"}], [], 30)
  end

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
