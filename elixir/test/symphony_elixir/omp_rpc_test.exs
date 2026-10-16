defmodule SymphonyElixir.OmpRpcTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.Omp.Rpc
  alias SymphonyElixir.ExecutionBackend

  setup do
    root = Path.dirname(Workflow.workflow_file_path())
    workspace_root = Path.join(root, "workspaces")
    workspace = Path.join(workspace_root, "task")
    File.mkdir_p!(workspace)
    cli = Path.join(root, "omp")

    File.write!(cli, """
    #!/usr/bin/env python3
    import json,sys
    def emit(v): print(json.dumps(v),flush=True)
    state={'sessionId':'native-omp-session','sessionFile':'/tmp/omp-test-session.jsonl','isSettled':True,'messageCount':0,'model':{'provider':'native','id':'role-default'}}
    emit({'type':'ready'})
    prompt=None
    for line in sys.stdin:
      c=json.loads(line); t=c['type']
      if t=='prompt':
        prompt=c['id']; emit({'type':'response','id':prompt,'success':True})
        if c['message']=='quota':
          emit({'type':'prompt_result','id':prompt,'status':'error','sessionSettled':True,'error':{'message':'insufficient_quota'}})
        elif c['message']=='host':
          emit({'type':'host_tool_call','id':'host-1','toolCallId':'native-call','toolName':'context','arguments':{}})
        else:
          emit({'type':'prompt_result','id':prompt,'status':'completed','sessionSettled':False})
          emit({'type':'message_end','message':{'role':'assistant','content':[],'usage':{'input':2,'cacheRead':3,'cacheWrite':1,'output':4}}})
          emit({'type':'session_settled'})
      elif t=='host_tool_result':
        assert c['result']['content'][0]['text']=='bound result'
        emit({'type':'prompt_result','id':prompt,'status':'completed','sessionSettled':True})
      else:
        emit({'type':'response','id':c.get('id'),'command':t,'success':True,'data':state if t=='get_state' else {}})
    """)

    File.chmod!(cli, 0o755)

    File.write!(Workflow.workflow_file_path(), """
    ---
    tracker:
      kind: memory
    workspace:
      root: #{Jason.encode!(workspace_root)}
    agent:
      backend: omp
    omp:
      command: #{Jason.encode!(cli)}
    ---
    {{ issue.title }}
    """)

    :ok = WorkflowStore.force_reload()
    {:ok, workspace: workspace}
  end

  test "native backend is selected and a turn waits until background work settles", %{workspace: workspace} do
    assert ExecutionBackend.module() == Rpc
    {:ok, session} = Rpc.start_session(workspace)
    assert {:ok, %{thread_id: "native-omp-session", turn_id: id}} = Rpc.run_turn(session, "normal", %{})
    assert is_binary(id)
    owner = self()
    callback = fn event -> send(owner, {:event, event}) end
    assert {:ok, _} = Rpc.run_turn(session, "normal", %{}, on_message: callback)
    assert_received {:event, %{usage: %{"input_tokens" => 12, "output_tokens" => 8, "total_tokens" => 20}}}
    assert :ok = Rpc.stop_session(session)
  end

  test "native host tools use the bound executor and report their results", %{workspace: workspace} do
    {:ok, session} = Rpc.start_session(workspace)
    session = put_in(session.binding.tool_specs, [%{"name" => "context"}])
    me = self()

    executor = fn name, args ->
      send(me, {:host_tool, name, args})
      %{"success" => true, "output" => "bound result"}
    end

    assert {:ok, _} = Rpc.run_turn(session, "host", %{}, tool_executor: executor)
    assert_received {:host_tool, "context", %{}}
    assert :ok = Rpc.stop_session(session)
  end

  test "provider quota errors are errors even when prompt admission succeeded", %{workspace: workspace} do
    {:ok, session} = Rpc.start_session(workspace)
    assert {:error, {:omp_provider_error, %{"message" => "insufficient_quota"}}} = error = Rpc.run_turn(session, "quota", %{})
    assert ExecutionBackend.quota_error?(error)
    assert :ok = Rpc.stop_session(session)
  end

  test "resume cannot allocate another session without confirmed native stop", %{workspace: workspace} do
    assert {:error, :omp_native_outcome_unknown} = Rpc.start_session(workspace, resume_thread_id: "old", run_record: %{"backend" => "omp", "thread_id" => "old"})
  end

  test "workspace root itself is not an execution checkout", %{workspace: workspace} do
    assert {:error, :omp_workspace_outside_root} = Rpc.start_session(Path.dirname(workspace))
  end

  test "AgentRunner continues an unfinished OMP task in the same session", %{workspace: _workspace} do
    issue = %Issue{id: "omp-loop", identifier: "omp-loop", title: "Continue", state: "Todo", labels: [], dispatchable: true}
    Process.put(:omp_fetch_count, 0)

    fetcher = fn _ ->
      count = Process.get(:omp_fetch_count) + 1
      Process.put(:omp_fetch_count, count)
      {:ok, [%{issue | state: if(count == 1, do: "Todo", else: "Done")}]}
    end

    assert :ok = AgentRunner.run(issue, self(), max_turns: 2, issue_state_fetcher: fetcher)
    assert_received {:codex_worker_update, "omp-loop", %{event: :session_started, thread_id: first}}
    assert_received {:codex_worker_update, "omp-loop", %{event: :session_started, thread_id: second}}
    assert first == second
  end

  test "a changed persisted transcript cannot be resumed", %{workspace: workspace} do
    transcript = Path.join(workspace, "session.jsonl")
    File.write!(transcript, "modified")
    record = %{"backend" => "omp", "thread_id" => "old", "native_stop_confirmed" => true, "native_pid" => "99999999", "native_session_file" => transcript, "native_transcript_sha256" => "previous"}
    assert {:error, :omp_session_changed} = Rpc.start_session(workspace, resume_thread_id: "old", run_record: record)
  end
end
