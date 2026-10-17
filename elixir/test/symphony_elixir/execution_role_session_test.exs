defmodule SymphonyElixir.ExecutionRoleSessionTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.{RunJournal, TaskWorkflow}

  setup do
    root = Path.dirname(Workflow.workflow_file_path())
    workspace = Path.join(root, "workspaces/role-fixture")
    File.mkdir_p!(workspace)
    binary = Path.join(root, "role-server")
    mode = Path.join(root, "thread-id")
    trace = Path.join(root, "requests.jsonl")

    File.write!(binary, """
    #!/usr/bin/env python3
    import json,sys
    thread=open(#{Jason.encode!(mode)}).read()
    def emit(value): print(json.dumps(value),flush=True)
    for line in sys.stdin:
      request=json.loads(line)
      with open(#{Jason.encode!(trace)},'a') as out: out.write(json.dumps(request)+'\\n')
      method=request.get('method')
      if method=='initialize': emit({'id':request['id'],'result':{}})
      elif method=='thread/start': emit({'id':request['id'],'result':{'thread':{'id':thread}}})
      elif method=='turn/start':
        assert request['params']['threadId']==thread
        emit({'id':request['id'],'result':{'turn':{'id':thread+'-turn'}}})
        completed={'id':thread+'-turn','status':'completed'}
        emit({'method':'turn/completed','params':{'threadId':thread,'turn':completed}})
      elif method!='initialized': raise AssertionError('Unexpected native activation: '+str(method))
    """)

    File.chmod!(binary, 0o755)
    settings = [tracker_kind: "memory", workspace_root: Path.dirname(workspace), codex_command: binary]
    write_workflow_file!(Workflow.workflow_file_path(), settings)
    {:ok, root: root, workspace: workspace, mode: mode, trace: trace}
  end

  defp role_binding(role) do
    work = %{"provider" => "github", "host" => "github.test", "repository_id" => "1", "kind" => "issue", "number" => 2}
    revision = TaskWorkflow.digest("plan")

    %{
      "work" => work,
      "role" => role,
      "plan_revision" => revision,
      "contract_sha" => TaskWorkflow.digest("contract"),
      "policy_sha" => TaskWorkflow.digest("policy"),
      "authority" => %{"work" => %{work | "number" => 1}, "source" => "native-approval", "actor" => "1", "revision" => revision},
      "inputs" => [],
      "candidate" => if(role == "verifier", do: TaskWorkflow.digest("candidate"))
    }
  end

  defp checkpoint(record, changes) do
    {:ok, current} = RunJournal.read(record["directory"])
    {:ok, _} = RunJournal.checkpoint(current, changes)
    :ok
  end

  defp session_options(record) do
    [
      run_record: record,
      resume_thread_id: record["thread_id"],
      on_thread_intent: fn -> checkpoint(record, %{"thread_allocation_intent" => true}) end,
      on_thread_started: fn thread -> checkpoint(record, %{"thread_id" => thread}) end
    ]
  end

  defp complete_role(context, record, thread) do
    File.write!(context.mode, thread)
    assert {:ok, session} = AppServer.start_session(context.workspace, session_options(record))
    issue = %Issue{id: "2", identifier: "ROLE-2", title: "Role protocol fixture", state: "Todo"}

    try do
      assert {:ok, result} = AppServer.run_turn(session, "Protocol fixture", issue)
      assert result.thread_id == thread
      checkpoint(record, %{"turn_id" => result.turn_id, "native_stop_confirmed" => true})
    after
      assert :ok = AppServer.stop_session(session)
    end

    {:ok, current} = RunJournal.read(record["directory"])
    assert :ok = RunJournal.complete(current, "completed")
  end

  test "the actual app-server client starts a fresh verifier thread after a completed developer turn", context do
    {:ok, developer} = RunJournal.admit(context.root, "2", execution_binding: role_binding("developer"))
    complete_role(context, developer, "developer-thread")
    {:ok, verifier} = RunJournal.admit(context.root, "2", execution_binding: role_binding("verifier"))
    complete_role(context, verifier, "verifier-thread")
    {:ok, current} = RunJournal.read(verifier["directory"])
    assert current["execution_generation"] == 2
    assert current["thread_id"] == "verifier-thread"
    assert hd(current["execution_history"])["thread_id"] == "developer-thread"
    requests = context.trace |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    assert Enum.count(requests, &(&1["method"] == "thread/start")) == 2
    refute Enum.any?(requests, &(&1["method"] == "thread/resume"))
    turns = requests |> Enum.filter(&(&1["method"] == "turn/start")) |> Enum.map(&get_in(&1, ["params", "threadId"]))
    assert turns == ["developer-thread", "verifier-thread"]
  end

  test "a provider returning the old developer thread cannot run a verifier turn or silently retry allocation", context do
    {:ok, developer} = RunJournal.admit(context.root, "2", execution_binding: role_binding("developer"))
    complete_role(context, developer, "developer-thread")
    {:ok, verifier} = RunJournal.admit(context.root, "2", execution_binding: role_binding("verifier"))
    options = session_options(verifier)
    assert {:error, :native_thread_reused_across_generations} = AppServer.start_session(context.workspace, options)
    {:ok, current} = RunJournal.read(verifier["directory"])
    refute current["thread_id"]
    assert current["thread_allocation_intent"]
    assert :ok = RunJournal.complete(current, "completed")
    assert {:error, :uncertain_thread_allocation} = RunJournal.admit(context.root, "2", execution_binding: role_binding("verifier"))
    requests = context.trace |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    assert Enum.count(requests, &(&1["method"] == "turn/start")) == 1
  end
end
