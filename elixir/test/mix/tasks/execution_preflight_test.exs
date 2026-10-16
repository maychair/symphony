defmodule Mix.Tasks.ExecutionPreflightTest do
  use SymphonyElixir.TestSupport
  import ExUnit.CaptureIO
  alias Mix.Tasks.Execution.Preflight

  test "preflight reads candidates or one native Issue without dispatch" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    issue = %Issue{id: "one", identifier: "one", title: "Fixture", state: "Todo"}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    args = ["--workflow", Workflow.workflow_file_path()]
    assert capture_io(fn -> Preflight.run(args) end) =~ "1 Issues read; no dispatch"
    assert capture_io(fn -> Preflight.run(args ++ ["--issue", "one"]) end) =~ "1 Issues read"
    assert_raise Mix.Error, ~r/issue_not_found/, fn -> Preflight.run(args ++ ["--issue", "missing"]) end
  end
end
