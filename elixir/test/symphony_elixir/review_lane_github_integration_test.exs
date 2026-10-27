defmodule SymphonyElixir.ReviewLaneGitHubIntegrationTest do
  use SymphonyElixir.TestSupport, runtime: false
  alias SymphonyElixir.ReviewLane.{Listener, Runner}

  setup do
    root = Path.dirname(Workflow.workflow_file_path())
    Supervisor.terminate_child(SymphonyElixir.Supervisor, Listener)

    on_exit(fn ->
      write_workflow_file!(Path.join(root, "WORKFLOW.md"), tracker_kind: "memory")
      Supervisor.restart_child(SymphonyElixir.Supervisor, Listener)
    end)

    source = Path.join(root, "source")
    File.mkdir_p!(source)
    File.write!(Path.join(root, "instructions"), "## Common\nRead all evidence.\n## Standards\nRead standards.\n## Spec\nVerify requirements.\n")
    File.write!(Path.join(root, "reviews.json"), "[]")
    File.write!(Path.join(root, "comments.json"), "[]")
    File.write!(Path.join(root, "timeline.json"), Jason.encode!([request_event(1, "review_requested")]))
    cli = Path.join(root, "gh-review")

    File.write!(cli, """
    #!/usr/bin/env python3
    import json,pathlib,sys
    r=pathlib.Path(#{inspect(root)});a=sys.argv[1:]
    path=a[a.index('--method')+2];method=a[a.index('--method')+1]
    head=(r/'head').read_text() if (r/'head').exists() else ('c' if (r/'changed-head').exists() else 'a')*40
    base=(r/'base').read_text() if (r/'base').exists() else 'b'*40
    pull={'body':'Closes #1','number':1,'id':101,'state':('closed' if (r/'closed').exists() else 'open'),'merged':False,'head':{'sha':head},'base':{'sha':base,'ref':'main','repo':{'id':10}},'user':{'id':30},'requested_reviewers':([] if (r/'withdrawn').exists() else [{'id':20}]),'html_url':'https://github.invalid/team/repo/pull/1'}
    reviews=json.loads((r/'reviews.json').read_text())
    if path=='user':out={'id':(99 if (r/'wrong-user').exists() else 20)}
    elif path=='repos/team/repo':out={'id':10,'full_name':'team/repo','html_url':'https://github.invalid/team/repo','ssh_url':'git@github.invalid:team/repo.git'}
    elif path.startswith('repos/team/repo/pulls?'):out=[pull]
    elif path=='repos/team/repo/pulls/1':out=pull
    elif path=='repos/team/repo/issues/1':out={'number':1,'body':'验收完整变更'}
    elif path.startswith('repos/team/repo/issues/1/timeline?'):out=json.loads((r/'timeline.json').read_text())
    elif path.startswith('repos/team/repo/issues/1/comments?'):out=json.loads((r/'comments.json').read_text())
    elif path.startswith('repos/team/repo/pulls/1/comments?'):out=[]
    elif path.startswith('repos/team/repo/pulls/1/reviews?'):out=reviews
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
      "instruction_files" => [Path.join(root, "instructions")],
      "result_command" => SymphonyElixir.TestSupport.workflow_result_command(),
      "gh_bin" => cli
    }

    File.write!(Workflow.workflow_file_path(), "---\ntracker:\n  kind: memory\n  required_labels: [symphony]\n  active_states: [open, in_progress]\n  terminal_states: [closed]\n---\nReview task\n")
    :ok = WorkflowStore.force_reload()
    start_supervised!({Listener, config: config})
    await_listener()
    {:ok, root: root, config: config}
  end

  test "assigned GitHub PR records the workflow result without posting, reacts to pushes, and stops on withdrawal", c do
    assert {:ok, [issue]} = Listener.issues()
    assert issue.native_ref["work"]["provider"] == "github"
    assert issue.native_ref["work"]["kind"] == "pr"
    assert :ok = SymphonyElixir.WorkRef.validate(issue.native_ref["work"])
    assert issue.title == "Review team/repo#1"
    assert {:ok, _, _} = Listener.begin_run(issue.id)
    assert :ok = SymphonyElixir.TestSupport.submit_review(issue.id, %{"findings" => []})
    assert Jason.decode!(File.read!(Path.join(c.root, "reviews.json"))) == []
    assert :ok = Listener.checkpoint(issue.id, owner_for(issue.id), %{"native_stop_confirmed" => true})
    assert {:ok, [done]} = Listener.issues()
    assert done.native_ref["phase"] == "completed"

    File.write!(Path.join(c.root, "changed-head"), "new")
    assert {:ok, [retained]} = Listener.issues()
    assert retained.id == issue.id
    assert retained.native_ref["round"] == 1
    assert retained.native_ref["eligibility"] == "superseded"
    refute retained.dispatchable

    File.write!(Path.join(c.root, "timeline.json"), Jason.encode!([request_event(1, "review_requested"), request_event(2, "review_request_removed")]))
    File.write!(Path.join(c.root, "withdrawn"), "yes")
    assert {:ok, [withdrawn]} = Listener.issues()
    assert withdrawn.native_ref["eligibility"] in ["superseded", "unassigned"]
  end

  test "a GitHub author reply does not create a new review round while unchanged polls remain stable", c do
    assert {:ok, [issue]} = Listener.issues()
    assert {:ok, _, _} = Listener.begin_run(issue.id)
    assert :ok = SymphonyElixir.TestSupport.submit_review(issue.id, %{"findings" => ["已验证边界条件失败，请在 source.cpp:10 修复越界读取。"]})
    assert Jason.decode!(File.read!(Path.join(c.root, "reviews.json"))) == []
    assert :ok = Listener.checkpoint(issue.id, owner_for(issue.id), %{"native_stop_confirmed" => true})

    comment = %{"id" => 500, "body" => "已修复越界读取并补回归检查。", "user" => %{"id" => 30}, "created_at" => "2026-01-03T00:00:00Z"}
    File.write!(Path.join(c.root, "comments.json"), Jason.encode!([comment]))
    assert {:ok, [retained]} = Listener.issues()
    assert retained.id == issue.id
    assert retained.native_ref["round"] == 1
    assert retained.native_ref["eligibility"] == "current"
    refute retained.dispatchable
    assert {:ok, [repeated]} = Listener.issues()
    assert repeated.id == issue.id
  end

  test "GitHub unknown reviewer history blocks admission", c do
    assert {:ok, [issue]} = Listener.issues()
    assert {:ok, _, _} = Listener.begin_run(issue.id)
    assert File.read!(Path.join(c.root, "reviews.json")) == "[]"

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

  test "GitHub review starts an ordinary native session without acquiring source", c do
    server = Path.join(c.root, "native-review-server")
    SymphonyElixir.TestSupport.write_review_server(server, c.root)
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", workspace_root: Path.join(c.root, "workspaces"), codex_command: server)
    {:ok, [issue]} = Listener.issues()
    assert :ok = Runner.run(issue, self())
    assert_received {:worker_runtime_info, _, %{workspace_path: scratch}}
    refute File.exists?(Path.join(scratch, "source"))
    {:ok, [complete]} = Listener.issues()
    assert complete.native_ref["phase"] == "completed"
    assert is_map(complete.native_ref["workflow_result"])
    assert File.read!(Path.join(c.root, "reviews.json")) == "[]"
  end

  test "GitHub review webhooks use lane identity and durable hints independently of the task tracker", c do
    config = Map.put(c.config, "webhook_secret", String.duplicate("s", 32))
    File.write!(Workflow.workflow_file_path(), "---\ntracker:\n  kind: memory\n  provider:\n    review_lane: " <> Jason.encode!(config) <> "\n---\nReview fixture\n")
    :ok = WorkflowStore.force_reload()

    for event <- ~w(pull_request pull_request_review pull_request_review_comment pull_request_review_thread issue_comment) do
      payload = %{"action" => "review_requested", "repository" => %{"id" => 10, "full_name" => "team/repo", "html_url" => "https://github.invalid/team/repo"}}
      payload = if event == "issue_comment", do: Map.put(payload, "issue", %{"number" => 1, "pull_request" => %{}}), else: Map.put(payload, "pull_request", %{"number" => 1})
      raw = Jason.encode!(payload)
      signature = "sha256=" <> Base.encode16(:crypto.mac(:hmac, :sha256, config["webhook_secret"], raw), case: :lower)

      conn =
        Plug.Test.conn(:post, "/api/webhooks/github", raw)
        |> Plug.Conn.assign(:webhook_body, raw)
        |> Plug.Conn.put_req_header("x-github-event", event)
        |> Plug.Conn.put_req_header("x-hub-signature-256", signature)

      conn = %{conn | body_params: payload}
      assert SymphonyElixirWeb.WebhookController.receive_event(conn, %{"provider" => "github"}).status == 202
      assert Listener.health().pending_hints == 1
      invalid = %{conn | body_params: put_in(payload, ["repository", "id"], 99)}
      assert SymphonyElixirWeb.WebhookController.receive_event(invalid, %{"provider" => "github"}).status == 403
      invalid = Plug.Conn.put_req_header(conn, "x-hub-signature-256", "sha256=invalid")
      assert SymphonyElixirWeb.WebhookController.receive_event(invalid, %{"provider" => "github"}).status == 403
    end

    {:ok, [issue]} = Listener.issues()
    assert issue.native_ref["work"]["provider"] == "github"
    assert Listener.health().pending_hints == 0
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
