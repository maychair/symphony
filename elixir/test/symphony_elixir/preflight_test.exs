defmodule SymphonyElixir.PreflightTest do
  use SymphonyElixir.TestSupport, runtime: false
  alias SymphonyElixir.Preflight

  test "standalone tracker validation reads memory issues without starting the runtime" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    :ok = WorkflowStore.force_reload()
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    assert {:ok, 0} = Preflight.run(nil)
    assert {:error, :issue_not_found} = Preflight.run("missing")
    issue = %SymphonyElixir.Tracker.Issue{id: "2", identifier: "MEM-2", title: "Preflight", state: "Todo", description: "Check only"}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    assert {:ok, 1} = Preflight.run("2")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [%{id: "malformed"}])
    assert {:error, _} = Preflight.run("malformed")
    Workflow.set_workflow_file_path(Path.join(Path.dirname(Workflow.workflow_file_path()), "missing.md"))
    assert {:error, _} = Preflight.run(nil)
  end

  test "prompt validation errors are returned by packaged preflight rather than crashing" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", prompt: "{{ issue.unknown_field }}")
    :ok = WorkflowStore.force_reload()
    issue = %SymphonyElixir.Tracker.Issue{id: "2", identifier: "MEM-2", title: "Preflight", state: "Todo"}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    assert {:error, reason} = Preflight.run("2")
    assert is_binary(reason)
    assert reason =~ "unknown_field"
  end
end
