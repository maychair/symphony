defmodule SymphonyElixir.MailReviewLifecycleTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.MailReview.{Listener, Policy, Runner}
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
    if name=='lark' and a[1]!='+watch' and (r/'mail.json').exists():
      print((r/'mail.json').read_text());sys.exit(0)
    if name=='lark':
      if a[1]=='+watch':
        print('Connected. Waiting for mail events... (Ctrl+C to stop)',flush=True);time.sleep(300)
      else: print(json.dumps({'ok':True,'data':{'head_from':{'mail_address':'gitlab@review.invalid'},'subject':'Example (!1)','body_plain_text':'Reviewer was added as a reviewer.','body_html':'<a href="https://review.invalid/team/repo/-/merge_requests/1">MR</a>'}}))
    else:
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

  test "invalid submissions and failed provider reads cannot publish", c do
    assert {:error, :invalid_review_scope} = Listener.request_review("other/repo", 1)
    assert {:error, :invalid_mail_event} = Listener.ingest(%{})
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
    assert {:error, _} = Listener.request_review("team/repo", 1)
    responses(c, %{"GET projects/team%2Frepo/merge_requests/1" => %{}})
    assert :ok = Listener.request_review("team/repo", 1)
    File.write!(Path.join(c.root, "lark"), "#!/bin/sh\nexit 3\n")
    assert {:error, _} = Listener.ingest(%{"ok" => true, "data" => %{"event" => %{"message_id" => "failed"}}})
  end

  test "findings wait for author response and schedule only one subsequent round", c do
    assert :ok = Listener.request_review("team/repo", 1)
    {:ok, [issue]} = Listener.issues()
    {:ok, _, _} = Listener.begin_run(issue.id)

    assert %{"success" => true} =
             SymphonyElixir.MailReview.execute_agent_tool(
               "mail_review_submit",
               %{"findings" => ["空输入导致越界，见 source.cpp:10，请检查长度。"]},
               issue: issue
             )

    assert {:ok, [_]} = Listener.issues()
    path = Path.join(c.root, "discussions.json")
    [discussion] = Jason.decode!(File.read!(path))
    reply = %{"id" => 99, "author" => %{"id" => 30}, "created_at" => "2026-01-02T00:00:00Z"}
    File.write!(path, Jason.encode!([Map.update!(discussion, "notes", &(&1 ++ [reply]))]))
    {:ok, rounds} = Listener.issues()
    assert length(rounds) == 2
    assert Enum.any?(rounds, &(&1.native_ref["round"] == 2 and &1.native_ref["phase"] == "queued"))
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

  test "watch transport retries, ignores diagnostics, accepts complete events and bounds line size", c do
    state = :sys.get_state(Listener)
    port = state.port
    send(Listener, {port, {:data, "diagnostic\n"}})
    event = %{"ok" => true, "data" => %{"event" => %{"message_id" => "stream-event"}}}
    send(Listener, {port, {:data, Jason.encode!(event) <> "\n"}})
    assert {:ok, [_]} = Listener.issues()
    assert Listener.health().last_event_at
    send(Listener, {port, {:data, Jason.encode!(put_in(event, ["data", "event", "message_id"], "")) <> "\n"}})
    assert {:ok, [_]} = Listener.issues()
    send(Listener, :check_config)
    send(Listener, :unknown)
    assert Listener.health().health == :listening
    send(Listener, {port, {:data, String.duplicate("x", 2_097_153)}})
    assert Listener.health().health == :restarting
    send(Listener, :restart_watch)
    await_listener()
    state = :sys.get_state(Listener)
    send(Listener, {state.port, {:exit_status, 1}})
    assert Listener.health().restarts == 2
    :sys.replace_state(Listener, &put_in(&1.config["restart_limit"], 0))
    send(Listener, {:sys.get_state(Listener).port, {:exit_status, 1}})
    assert Listener.health().health == :failed
    assert File.exists?(Path.join(c.config["state_dir"], "mail-review.json"))
  end

  test "disabled and changed configuration fence every new request", c do
    {:ok, disabled} = Listener.init([])
    assert {:reply, {:ok, []}, ^disabled} = Listener.handle_call(:issues, self(), disabled)
    assert {:reply, {:error, :listener_disabled}, _} = Listener.handle_call({:ingest, %{}}, self(), disabled)
    assert :ok = Listener.terminate(:normal, disabled)
    state = :sys.get_state(Listener)
    changed = %{state | initial_config: nil}

    assert {:reply, {:error, :mail_review_configuration_changed_restart_required}, suspended} =
             Listener.handle_call(:issues, self(), changed)

    assert suspended.health == :failed
    assert {:noreply, %{health: :failed}} = Listener.handle_info(:check_config, %{changed | port: nil})
    assert {:noreply, %{health: :failed}} = Listener.handle_info(:restart_watch, %{changed | port: nil})
    assert {:noreply, %{health: :failed}} = Listener.handle_info({state.port, {:data, "event"}}, changed)
    assert :ok = Listener.terminate(:normal, %{state | port: nil})
    # No replay state may be loaded across repository or reviewer changes.
    File.write!(Path.join(c.config["state_dir"], "mail-review.json"), "{}")
    {:ok, initial} = Listener.init(config: c.config)
    assert {:noreply, %{health: :failed}} = Listener.handle_info(:configure, initial)
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
          emit({'id':100,'method':'item/tool/call','params':{'threadId':'review-thread','turnId':'review-turn','tool':'mail_review_submit','arguments':{'findings':[]}}})
        else:emit({'method':'turn/completed','params':{'threadId':'review-thread','turn':{'id':'review-turn','status':'completed'}}})
      elif q.get('id')==100:
        assert q['result']['success']
        emit({'method':'turn/completed','params':{'threadId':'review-thread','turn':{'id':'review-turn','status':'completed'}}})
    """)

    File.chmod!(server, 0o755)
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", workspace_root: Path.join(c.root, "workspaces"), codex_command: server)

    mr = %{
      "iid" => 1,
      "state" => "opened",
      "sha" => head,
      "diff_refs" => %{"base_sha" => head},
      "author" => %{"id" => 30},
      "reviewers" => [%{"username" => "reviewer"}],
      "web_url" => "https://review.invalid/team/repo/-/merge_requests/1"
    }

    project = %{"path_with_namespace" => "team/repo", "ssh_url_to_repo" => "git@review.invalid:team/repo.git"}
    responses(c, %{"GET projects/team%2Frepo/merge_requests/1" => mr, "GET projects/team%2Frepo" => project})
    assert :ok = Listener.request_review("team/repo", 1)
    {:ok, [issue]} = Listener.issues()
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
      responses(c, %{"GET projects/team%2Frepo" => %{project | "ssh_url_to_repo" => remote}})
      assert_raise RuntimeError, ~r/Review execution fenced/, fn -> Runner.run(issue, nil) end
    end
  end

  test "mail replay validates deployment configuration and request shape", c do
    config = Map.put(c.config, "replay_secret", String.duplicate("s", 32))

    File.write!(Workflow.workflow_file_path(), """
    ---
    tracker:
      kind: memory
      provider:
        mail_review: #{Jason.encode!(config)}
    ---
    Review fixture
    """)

    :ok = WorkflowStore.force_reload()
    assert SymphonyElixir.MailReview.config() == config
    state = :sys.get_state(Listener)
    assert {:reply, {:ok, _}, _} = Listener.handle_call(:issues, self(), %{state | initial_config: nil, config: config})
    conn = Plug.Test.conn(:post, "/", %{}) |> Plug.Conn.put_req_header("x-symphony-token", config["replay_secret"])

    for payload <- [%{"project" => "team/repo", "iid" => 1}, %{"message_id" => "webhook"}, %{}] do
      response = WebhookController.receive_event(%{conn | body_params: payload}, %{"provider" => "mail"})
      assert response.status == if(payload == %{}, do: 403, else: 202)
    end

    # Native controller entry executes the Phoenix action as well as the handler.
    native = %{conn | params: %{"provider" => "mail"}}
    assert WebhookController.init(:receive_event) == :receive_event
    assert WebhookController.call(native, :receive_event).status == 403
    assert Listener.terminate(:normal, state) in [:ok, true]
  end

  test "malformed mail and missing watch executable surface bounded failures", c do
    for mail <- [%{}, %{"ok" => true, "data" => %{}}] do
      File.write!(Path.join(c.root, "mail.json"), Jason.encode!(mail))
      id = inspect(mail)
      event = %{"ok" => true, "data" => %{"event" => %{"message_id" => id}}}
      if mail == %{}, do: assert({:error, :invalid_mail_response} = Listener.ingest(event)), else: assert(:ok = Listener.ingest(event))
    end

    state = :sys.get_state(Listener)
    config = Map.put(c.config, "lark_bin", "/no/such/command")
    assert {:noreply, %{health: :restarting}} = Listener.handle_info(:restart_watch, %{state | config: config})
    config = Map.put(c.config, "lark_bin", 42)
    assert {:noreply, %{health: :restarting}} = Listener.handle_info(:restart_watch, %{state | config: config})
    path = Path.join(c.config["state_dir"], "mail-review.json")
    File.rm(path)
    File.mkdir!(path)
    {:ok, initial} = Listener.init(config: c.config)
    assert {:noreply, %{health: :failed}} = Listener.handle_info(:configure, initial)
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
