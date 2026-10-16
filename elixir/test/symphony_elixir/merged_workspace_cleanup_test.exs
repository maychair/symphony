defmodule SymphonyElixir.MergedWorkspaceCleanupTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.MergedWorkspaceCleanup

  test "cleanup is opt-in" do
    assert Config.settings!().workspace.merge_cleanup_command == nil
    assert MergedWorkspaceCleanup.start(SymphonyElixir.TaskSupervisor) == nil
  end

  test "the existing poll cycle runs a responsive single-flight cleanup and can run again" do
    root = Path.dirname(Workflow.workflow_file_path())
    log = Path.join(root, "cleanup.log")
    gate = Path.join(root, "release")
    command = "echo pass >> '#{log}'; while [ ! -f '#{gate}' ]; do sleep 0.01; done; printf done"
    configure(command)
    on_exit(fn -> File.write(gate, "release") end)
    pid = start_supervised!({Orchestrator, name: __MODULE__.Polling})
    await(fn -> is_reference(:sys.get_state(pid).merge_cleanup_ref) and File.exists?(log) end)
    ref = :sys.get_state(pid).merge_cleanup_ref
    send(pid, :run_poll_cycle)
    send(pid, :run_poll_cycle)
    assert :sys.get_state(pid).merge_cleanup_ref == ref
    assert File.read!(log) == "pass\n"
    File.write!(gate, "release")
    await(fn -> :sys.get_state(pid).merge_cleanup_ref == nil end)
    send(pid, :run_poll_cycle)
    await(fn -> File.read!(log) == "pass\npass\n" end)
    await(fn -> :sys.get_state(pid).merge_cleanup_ref == nil end)
  end

  test "a failed command clears its flight without affecting task state" do
    configure("exit 7")
    ref = MergedWorkspaceCleanup.start(SymphonyElixir.TaskSupervisor)
    assert_receive {^ref, {"", 7}}, 2_000
    state = %Orchestrator.State{merge_cleanup_ref: ref}
    assert {:noreply, updated} = Orchestrator.handle_info({ref, {"", 7}}, state)
    assert updated.merge_cleanup_ref == nil
    assert updated.running == %{}
    other = make_ref()
    message = {:DOWN, other, :process, self(), :killed}
    assert {:noreply, stopped} = Orchestrator.handle_info(message, %{state | merge_cleanup_ref: other})
    assert stopped.merge_cleanup_ref == nil
  end

  defp configure(command) do
    File.write!(Workflow.workflow_file_path(), """
    ---
    tracker:
      kind: memory
      active_states: [open]
      terminal_states: [closed]
    polling:
      interval_ms: 3600000
    workspace:
      merge_cleanup_command: #{Jason.encode!(command)}
    ---
    Run the task.
    """)

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    assert :ok = WorkflowStore.force_reload()
  end

  defp await(predicate, attempts \\ 100)
  defp await(predicate, 0), do: assert(predicate.())

  defp await(predicate, attempts) do
    if predicate.() do
      :ok
    else
      Process.sleep(10)
      await(predicate, attempts - 1)
    end
  end
end
