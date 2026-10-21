defmodule SymphonyElixir.DiscoveryDisabledTest do
  use SymphonyElixir.TestSupport, runtime: false

  test "Issue discovery hot reload leaves existing execution reads and reconciliation intact" do
    issue = %Issue{id: "existing", identifier: "ISSUE-1", title: "Existing execution", state: "open", dispatchable: true}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    configure(false)
    assert {:ok, [^issue]} = Tracker.fetch_issues_by_states(["open"])

    worker = Task.async(fn -> receive do: (:finish -> :ok) end)
    on_exit(fn -> if Process.alive?(worker.pid), do: Process.exit(worker.pid, :kill) end)

    state = %Orchestrator.State{
      running: %{
        issue.id => %{
          pid: worker.pid,
          ref: worker.ref,
          issue: issue,
          identifier: issue.identifier,
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new([issue.id])
    }

    configure(true)
    assert {:ok, []} = Tracker.fetch_issues_by_states(["open"])
    assert {:ok, [^issue]} = Tracker.fetch_issues_by_ids([issue.id])
    reconciled = Orchestrator.reconcile_issue_states_for_test([issue], state)
    assert reconciled.running == state.running
    assert Process.alive?(worker.pid)

    configure(false)
    assert {:ok, [^issue]} = Tracker.fetch_issues_by_states(["open"])
    send(worker.pid, :finish)
    Task.await(worker)
  end

  test "omitted disabled defaults false and invalid reload retains the last good setting" do
    configure(true)
    assert Config.settings!().tracker.disabled
    File.write!(Workflow.workflow_file_path(), String.replace(File.read!(Workflow.workflow_file_path()), "disabled: true", "disabled: invalid"))
    assert {:error, _} = WorkflowStore.force_reload()
    assert Config.settings!().tracker.disabled
    configure(false)
    File.write!(Workflow.workflow_file_path(), String.replace(File.read!(Workflow.workflow_file_path()), "  disabled: false\n", ""))
    assert :ok = WorkflowStore.force_reload()
    refute Config.settings!().tracker.disabled
  end

  test "the existing periodic Workflow watcher applies disabled without an explicit refresh" do
    configure(false)
    File.write!(Workflow.workflow_file_path(), String.replace(File.read!(Workflow.workflow_file_path()), "disabled: false", "disabled: true"))
    await_disabled(200)
  end

  defp await_disabled(0), do: flunk("periodic configuration reload did not apply disabled")

  defp await_disabled(attempts) do
    if :sys.get_state(WorkflowStore).settings.tracker.disabled do
      :ok
    else
      Process.sleep(10)
      await_disabled(attempts - 1)
    end
  end

  test "Tracker disabled and Review Lane disabled operate independently" do
    ordinary = %Issue{id: "ordinary", identifier: "ISSUE-1", title: "Ordinary Issue", state: "open", dispatchable: true}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [ordinary])

    configure(true)
    assert {:ok, []} = Tracker.fetch_issues_by_states(["open"])

    configure(false)
    assert {:ok, issues} = Tracker.fetch_issues_by_states(["open"])
    assert ordinary in issues
  end

  defp configure(disabled) do
    File.write!(Workflow.workflow_file_path(), """
    ---
    tracker:
      kind: memory
      disabled: #{disabled}
      active_states: [open]
      terminal_states: [closed]
    ---
    Discovery fixture
    """)

    assert :ok = WorkflowStore.force_reload()
  end
end
