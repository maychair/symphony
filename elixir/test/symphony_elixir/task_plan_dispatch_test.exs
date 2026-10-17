defmodule SymphonyElixir.TaskPlanDispatchTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.{Execution, TaskPlan, TaskWorkflow}

  test "poll and running reconciliation both classify parents before executor admission" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", tracker_required_labels: ["symphony:ready"])
    child = %{"provider" => "github", "host" => "github.test", "repository_id" => "1", "kind" => "issue", "number" => 2}

    {:ok, plan} =
      TaskPlan.seal(%{
        "parent" => %{child | "number" => 1},
        "contract_sha" => TaskWorkflow.digest("parent scope"),
        "authorizer" => "1",
        "criteria" => ["result"],
        "dependencies" => [],
        "integration" => child,
        "members" => [
          %{
            "work" => child,
            "contract_sha" => TaskWorkflow.digest("child scope"),
            "criteria" => ["result"],
            "budget_ms" => 100,
            "human_gate" => false
          }
        ]
      })

    parent = %Issue{
      id: "1",
      identifier: "GH-1",
      title: "Parent",
      state: "Todo",
      description: "<!-- symphony-plan\n" <> Jason.encode!(plan) <> "\n-->",
      labels: ["symphony:ready"],
      dispatchable: true
    }

    task = %Issue{
      id: "2",
      identifier: "GH-2",
      title: "Child",
      state: "Todo",
      description: "Child contract",
      labels: ["symphony:ready"],
      dispatchable: true
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [parent, task])

    for fetch <- [fn -> Tracker.fetch_issues_by_states(["Todo"]) end, fn -> Tracker.fetch_issues_by_ids(["1", "2"]) end] do
      assert {:ok, [observed_parent, observed_task]} = fetch.()
      assert observed_parent.kind == :plan
      assert observed_parent.native_ref["plan"] == plan
      refute Issue.routable?(observed_parent, Config.settings!().tracker)
      assert {:error, :parent_plan_has_no_executor} = Execution.prepare(observed_parent, [])
      assert observed_task == task
    end
  end
end
