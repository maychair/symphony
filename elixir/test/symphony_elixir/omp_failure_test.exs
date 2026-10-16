defmodule SymphonyElixir.OmpFailureTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.Omp.Rpc
  alias SymphonyElixir.RunJournal

  setup do
    root = Path.dirname(Workflow.workflow_file_path())
    workspace = Path.join(root, "workspaces/task")
    File.mkdir_p!(workspace)
    cli = Path.join(root, "omp")
    File.cp!(Path.expand("../support/omp_rpc_fixture.py", __DIR__), cli)
    File.chmod!(cli, 0o755)

    File.write!(Workflow.workflow_file_path(), """
    ---
    tracker:
      kind: memory
    agent:
      backend: omp
    workspace:
      root: #{Jason.encode!(Path.dirname(workspace))}
    omp:
      command: #{Jason.encode!(cli)}
    ---
    Fixture
    """)

    :ok = WorkflowStore.force_reload()
    {:ok, root: root, workspace: workspace, mode: Path.join(root, "mode")}
  end

  test "startup failures release the port and preserve native identity fences", c do
    for {mode, expected} <- [{"busy", :omp_session_busy}, {"missing-id", :omp_missing_session_id}, {"fail:new_session", {:omp_command_failed, "fixture failure"}}] do
      File.write!(c.mode, mode)
      assert {:error, ^expected} = Rpc.start_session(c.workspace)
    end

    File.write!(c.mode, "")
    assert {:error, :omp_session_mismatch} = Rpc.start_session(c.workspace, run_record: %{"thread_id" => "foreign"})
    assert {:error, :omp_model_changed} = Rpc.start_session(c.workspace, run_record: %{"native_model" => %{"id" => "other"}})
    config = Path.join(c.root, "config.yml")
    File.write!(config, "fixture: true")
    previous = System.get_env("SYMPHONY_OMP_CONFIG")
    System.put_env("SYMPHONY_OMP_CONFIG", config)

    try do
      {:ok, session} = Rpc.start_session(c.workspace)
      assert File.read!(Path.join(c.workspace, "omp-sessions/workspace-config.yml")) == "fixture: true"
      assert :ok = Rpc.stop_session(session)
      File.rm!(config)
      assert {:error, {:omp_start_failed, _}} = Rpc.start_session(c.workspace)
    after
      restore_env("SYMPHONY_OMP_CONFIG", previous)
    end
  end

  test "transport classifies rejected prompts, protocol failures, exits and deadlines", c do
    for {prompt, error} <- [
          {"rejected", {:omp_prompt_rejected, "rejected"}},
          {"overflow", :omp_transport_overflow},
          {"input", :omp_operator_input_required},
          {"abort", :omp_turn_aborted},
          {"chunk:invalid", :omp_invalid_chunk},
          {"chunk:size", :omp_invalid_chunk_size},
          {"chunk:sequence", :omp_invalid_chunk_sequence}
        ] do
      {:ok, session} = Rpc.start_session(c.workspace)
      assert {:error, ^error} = Rpc.run_turn(session, prompt, %{})
      assert :ok = Rpc.stop_session(session)
    end

    {:ok, session} = Rpc.start_session(c.workspace)
    assert {:ok, _} = Rpc.run_turn(session, "chunk:valid", %{})
    File.write!(c.mode, "noise")
    assert {:error, :omp_turn_aborted} = Rpc.run_turn(session, "abort", %{})
    File.write!(c.mode, "model")
    assert {:error, :omp_model_changed} = Rpc.run_turn(session, "abort", %{})
    assert :ok = Rpc.stop_session(session)
    {:ok, session} = Rpc.start_session(c.workspace)
    assert {:error, {:omp_exit, 9}} = Rpc.run_turn(session, "exit", %{})
    assert {:error, :omp_native_stop_unconfirmed} = Rpc.stop_session(session)
    File.write!(c.mode, "")
    {:ok, session} = Rpc.start_session(c.workspace)
    deadline = System.monotonic_time(:millisecond)
    assert {:error, :omp_execution_timeout} = Rpc.run_turn(session, "hang", %{}, deadline: deadline)
    assert :ok = Rpc.stop_session(session)
    assert {:error, :omp_transport_closed} = Rpc.run_turn(session, "closed", %{})
  end

  test "host tools enforce binding and stop after recorded delivery or blocker", c do
    {:ok, record} = RunJournal.admit(Path.join(c.root, "runs"), "task")
    {:ok, record} = RunJournal.checkpoint(record, %{"backend" => "omp"})
    binding = Tracker.bind_agent_tools()
    binding = %{binding | tool_specs: [%{"name" => "context", "description" => "Fixture", "inputSchema" => %{}}]}
    {:ok, session} = Rpc.start_session(c.workspace, run_record: record, dynamic_tool_binding: binding)
    assert {:error, :omp_turn_aborted} = Rpc.run_turn(session, "host:unknown", %{})
    session = put_in(session.binding.tool_specs, [%{"name" => "context", "description" => "Fixture", "inputSchema" => %{}}])
    assert {:error, :omp_turn_aborted} = Rpc.run_turn(session, "host:context", %{})

    for changes <- [%{"delivery" => %{"url" => "https://example.invalid/mr"}}, %{"delivery" => nil, "blocker_reason" => "Need input"}] do
      executor = fn _, _ ->
        {:ok, current} = RunJournal.read(record["directory"])
        {:ok, _} = RunJournal.checkpoint(current, changes)
        %{"success" => true, "output" => "done"}
      end

      assert {:ok, _} = Rpc.run_turn(session, "host:context", %{}, tool_executor: executor)
    end

    assert :ok = Rpc.stop_session(session)
    {:ok, stopped} = RunJournal.read(record["directory"])
    assert stopped["native_stop_confirmed"]
    assert is_binary(stopped["native_transcript_sha256"])
    assert {:ok, resumed} = Rpc.start_session(c.workspace, run_record: stopped, resume_thread_id: "session")
    File.rm!(stopped["native_session_file"])
    assert :ok = Rpc.stop_session(resumed)
    assert {:error, :omp_native_stop_unconfirmed} = Rpc.stop_session(%{resumed | port: 42})

    for field <- ["native_pid", "native_session_file", "native_transcript_sha256"] do
      assert {:error, _} = Rpc.start_session(c.workspace, run_record: Map.delete(stopped, field), resume_thread_id: "session")
    end
  end
end
