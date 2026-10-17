defmodule SymphonyElixir.TaskPlanDispatchTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.{Execution, TaskPlan, TaskWorkflow}

  test "unconfigured plans and unavailable selected credentials never enter the native read transport" do
    work = %{"provider" => "github", "host" => "github.test", "repository_id" => "1", "kind" => "issue", "number" => 1}
    assert {:error, :unregistered_plan_repository} = SymphonyElixir.NativeWork.read(work)
    assert {:error, :unregistered_plan_repository} = SymphonyElixir.TaskPlanPreflight.inspect_plan(work)
    env = "SYMPHONY_PLAN_EMPTY_#{System.unique_integer([:positive])}"
    original = Map.new(["GITHUB_TOKEN", "GITLAB_PAT"], &{&1, System.get_env(&1)})
    Enum.each(original, fn {key, _} -> System.put_env(key, "unrelated-default-token") end)
    on_exit(fn -> Enum.each(original, fn {key, value} -> restore_env(key, value) end) end)

    for {provider, api} <- [{"github", "v3"}, {"gitlab", "v4"}] do
      work = %{work | "provider" => provider, "host" => provider <> ".test"}
      repository = Map.take(work, ~w(provider host repository_id))
      repository = Map.merge(repository, %{"path" => "team/project", "api_url" => "https://#{work["host"]}/api/#{api}", "credential" => "$" <> env})

      {client, key, error} =
        if provider == "github",
          do: {SymphonyElixir.GitHub.Client, "token", :missing_github_token},
          else: {SymphonyElixir.GitLab.Client, "api_key", :missing_gitlab_api_key}

      settings = %{provider: %{"repo" => "team/project", "project_path" => "team/project", key => "$" <> env}}
      request = fn _, _, _, _, _ -> flunk("missing selected credential fell back to another identity") end
      assert {:error, ^error} = client.request("GET", "/", %{}, nil, tracker_settings: settings, request_fun: request)
      assert {:error, :native_read_failed} = SymphonyElixir.NativeWork.read(work, repositories: [repository])
    end
  end

  test "plan members cannot inherit legacy routing even when goal mode is disabled" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", tracker_required_labels: ["symphony:ready"])

    for contract <- [%{"schema_version" => 2}, %{"parent" => %{}}, %{"schema_version" => 99}, "invalid"] do
      issue = %Issue{
        id: "2",
        identifier: "GH-2",
        title: "Plan child",
        state: "Todo",
        description: "<!-- symphony-contract " <> Jason.encode!(contract) <> " -->",
        labels: ["symphony:ready"],
        dispatchable: true
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      for fetch <- [fn -> Tracker.fetch_issues_by_states(["Todo"]) end, fn -> Tracker.fetch_issues_by_ids(["2"]) end] do
        assert {:ok, [blocked]} = fetch.()
        refute Issue.routable?(blocked, Config.settings!().tracker)
        assert blocked.native_ref["plan_preflight"]["reason"] == "plan_execution_unavailable"
      end

      assert {:error, :plan_execution_unavailable} = Execution.prepare(issue, [])
    end

    data = %{"schema_version" => 1, "criteria" => ["legacy"]}
    sealed = Map.put(data, "contract_sha", TaskWorkflow.digest(data))
    legacy = %Issue{description: "<!-- symphony-contract " <> Jason.encode!(sealed) <> " -->"}
    refute TaskPlan.requires_plan_lifecycle?(legacy)
    assert TaskPlan.requires_plan_lifecycle?(%{legacy | description: legacy.description <> "\n<!-- symphony-contract broken"})
  end

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
