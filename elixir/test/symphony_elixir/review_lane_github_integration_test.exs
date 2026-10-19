defmodule SymphonyElixir.ReviewLaneGitHubIntegrationTest do
  use SymphonyElixir.TestSupport, runtime: false
  alias SymphonyElixir.ReviewLane.Listener

  setup do
    root = Path.dirname(Workflow.workflow_file_path())
    Supervisor.terminate_child(SymphonyElixir.Supervisor, Listener)

    on_exit(fn ->
      write_workflow_file!(Path.join(root, "WORKFLOW.md"), tracker_kind: "memory")
      Supervisor.restart_child(SymphonyElixir.Supervisor, Listener)
    end)

    source = Path.join(root, "source")
    File.mkdir_p!(source)
    File.write!(Path.join(root, "instructions"), "Review only.")
    File.write!(Path.join(root, "reviews.json"), "[]")
    File.write!(Path.join(root, "comments.json"), "[]")
    File.write!(Path.join(root, "timeline.json"), Jason.encode!([request_event(1, "review_requested")]))
    cli = Path.join(root, "gh-review")

    File.write!(cli, """
    #!/usr/bin/env python3
    import json,pathlib,sys
    r=pathlib.Path(#{inspect(root)});a=sys.argv[1:]
    path=a[a.index('--method')+2];method=a[a.index('--method')+1]
    head=('c' if (r/'changed-head').exists() else 'a')*40
    pull={'number':1,'id':101,'state':('closed' if (r/'closed').exists() else 'open'),'merged':False,'head':{'sha':head},'base':{'sha':'b'*40,'ref':'main','repo':{'id':10}},'user':{'id':30},'requested_reviewers':([] if (r/'withdrawn').exists() else [{'id':20}]),'html_url':'https://github.invalid/team/repo/pull/1'}
    reviews=json.loads((r/'reviews.json').read_text())
    if path=='user':out={'id':(99 if (r/'wrong-user').exists() else 20)}
    elif path=='repos/team/repo':out={'id':10,'full_name':'team/repo','html_url':'https://github.invalid/team/repo'}
    elif path.startswith('repos/team/repo/pulls?'):out=[pull]
    elif path=='repos/team/repo/pulls/1':out=pull
    elif path.startswith('repos/team/repo/issues/1/timeline?'):out=json.loads((r/'timeline.json').read_text())
    elif path.startswith('repos/team/repo/issues/1/comments?'):out=json.loads((r/'comments.json').read_text())
    elif path.startswith('repos/team/repo/pulls/1/comments?'):out=[]
    elif path.startswith('repos/team/repo/pulls/1/reviews?'):out=reviews
    elif path=='repos/team/repo/pulls/1/reviews' and method=='POST':
      fields=dict(v.split('=',1) for i,v in enumerate(a) if i>0 and a[i-1]=='--raw-field')
      assert fields['event']=='COMMENT' and fields['commit_id']==head
      journal=json.loads((r/'state'/'review-lane.json').read_text())
      entries=[e for rec in journal['records'].values() for e in rec.get('publication',{}).get('entries',[])]
      assert any(e['body']==fields['body'] and e['status']=='sending' for e in entries)
      out={'id':len(reviews)+1,'body':fields['body'],'user':{'id':20},'submitted_at':'2026-01-02T00:00:00Z'}
      reviews.append(out);(r/'reviews.json').write_text(json.dumps(reviews))
    else:sys.exit(3)
    print(json.dumps(out))
    """)

    File.chmod!(cli, 0o755)

    config = %{
      "enabled" => true,
      "provider" => "github",
      "host" => "github.invalid",
      "reviewer_id" => 20,
      "publisher_id" => 20,
      "projects" => %{"team/repo" => %{"id" => 10, "checkout" => source}},
      "state_dir" => Path.join(root, "state"),
      "instructions_file" => Path.join(root, "instructions"),
      "gh_bin" => cli
    }

    File.write!(Workflow.workflow_file_path(), "---\ntracker:\n  kind: memory\n  required_labels: [symphony]\n  active_states: [open, in_progress]\n  terminal_states: [closed]\n---\nReview task\n")
    :ok = WorkflowStore.force_reload()
    start_supervised!({Listener, config: config})
    await_listener()
    {:ok, root: root, config: config}
  end

  test "assigned GitHub PR publishes comments with native readback, reacts to pushes, and stops on withdrawal", c do
    assert {:ok, [issue]} = Listener.issues()
    assert issue.native_ref["work"]["provider"] == "github"
    assert issue.native_ref["work"]["kind"] == "pr"
    assert :ok = SymphonyElixir.WorkRef.validate(issue.native_ref["work"])
    assert issue.title == "Review team/repo#1"
    assert {:ok, _, _} = Listener.begin_run(issue.id)
    assert :ok = Listener.submit(issue.id, owner_for(issue.id), %{"findings" => []})
    assert length(Jason.decode!(File.read!(Path.join(c.root, "reviews.json")))) == 1
    assert :ok = Listener.checkpoint(issue.id, owner_for(issue.id), %{"native_stop_confirmed" => true})
    assert {:ok, [done]} = Listener.issues()
    assert done.native_ref["phase"] == "completed"

    File.write!(Path.join(c.root, "changed-head"), "new")
    assert {:ok, rounds} = Listener.issues()
    assert Enum.any?(rounds, &(&1.native_ref["phase"] == "queued" and &1.id != issue.id))

    File.write!(Path.join(c.root, "timeline.json"), Jason.encode!([request_event(1, "review_requested"), request_event(2, "review_request_removed")]))
    File.write!(Path.join(c.root, "withdrawn"), "yes")
    assert {:ok, withdrawn} = Listener.issues()
    assert Enum.all?(withdrawn, &(&1.native_ref["eligibility"] in ["superseded", "unassigned"]))
  end

  test "a GitHub author reply creates one new review round while unchanged polls do not", c do
    assert {:ok, [issue]} = Listener.issues()
    assert {:ok, _, _} = Listener.begin_run(issue.id)
    assert :ok = Listener.submit(issue.id, owner_for(issue.id), %{"findings" => ["已验证边界条件失败，请在 source.cpp:10 修复越界读取。"]})
    assert length(Jason.decode!(File.read!(Path.join(c.root, "reviews.json")))) == 2
    assert :ok = Listener.checkpoint(issue.id, owner_for(issue.id), %{"native_stop_confirmed" => true})

    comment = %{"id" => 500, "body" => "已修复越界读取并补回归检查。", "user" => %{"id" => 30}, "created_at" => "2026-01-03T00:00:00Z"}
    File.write!(Path.join(c.root, "comments.json"), Jason.encode!([comment]))
    assert {:ok, rounds} = Listener.issues()
    assert Enum.count(rounds, &(&1.native_ref["phase"] == "queued")) == 1
    assert {:ok, repeated} = Listener.issues()
    assert Enum.map(repeated, & &1.id) == Enum.map(rounds, & &1.id)
  end

  test "GitHub scope loss and unknown reviewer history block publication", c do
    assert {:ok, [issue]} = Listener.issues()
    assert {:ok, _, _} = Listener.begin_run(issue.id)
    File.write!(Path.join(c.root, "wrong-user"), "yes")
    assert {:error, :github_identity_mismatch} = Listener.submit(issue.id, owner_for(issue.id), %{"findings" => []})
    assert File.read!(Path.join(c.root, "reviews.json")) == "[]"

    File.rm!(Path.join(c.root, "wrong-user"))
    File.write!(Path.join(c.root, "withdrawn"), "yes")
    File.write!(Path.join(c.root, "timeline.json"), "[]")
    assert {:ok, [unknown]} = Listener.issues()
    assert unknown.native_ref["eligibility"] == "unknown"
  end

  test "closed GitHub PR ends review instead of remaining assigned", c do
    assert {:ok, [_]} = Listener.issues()
    File.write!(Path.join(c.root, "closed"), "yes")
    assert {:ok, [closed]} = Listener.issues()
    assert closed.native_ref["eligibility"] == "closed"
    assert closed.native_ref["phase"] == "ended"
  end

  test "withdrawal before a GitHub review send blocks publication", c do
    assert {:ok, [issue]} = Listener.issues()
    assert {:ok, _, _} = Listener.begin_run(issue.id)
    File.write!(Path.join(c.root, "withdrawn"), "yes")
    File.write!(Path.join(c.root, "timeline.json"), Jason.encode!([request_event(1, "review_requested"), request_event(2, "review_request_removed")]))
    assert {:error, :review_assignment_withdrawn} = Listener.submit(issue.id, owner_for(issue.id), %{"findings" => []})
    assert File.read!(Path.join(c.root, "reviews.json")) == "[]"
  end

  test "missing GitHub reviewer history blocks publication without guessing", c do
    assert {:ok, [issue]} = Listener.issues()
    assert {:ok, _, _} = Listener.begin_run(issue.id)
    File.write!(Path.join(c.root, "withdrawn"), "yes")
    File.write!(Path.join(c.root, "timeline.json"), "[]")
    assert {:error, :review_assignment_unconfirmed} = Listener.submit(issue.id, owner_for(issue.id), %{"findings" => []})
    assert File.read!(Path.join(c.root, "reviews.json")) == "[]"
  end

  defp request_event(id, event) do
    %{"id" => id, "event" => event, "requested_reviewer" => %{"id" => 20}, "created_at" => "2026-01-0#{id}T00:00:00Z"}
  end

  defp owner_for(id), do: get_in(:sys.get_state(Listener), [:records, String.replace_prefix(id, "review:", ""), "execution_owner"])

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
