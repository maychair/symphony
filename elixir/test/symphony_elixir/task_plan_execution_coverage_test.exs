defmodule SymphonyElixir.TaskPlanExecutionCoverageTest do
  use SymphonyElixir.TestSupport, runtime: false

  alias SymphonyElixir.{
    RunJournal,
    TaskPlan,
    TaskPlanExecution,
    TaskWorkflow,
    WorkRef
  }

  defp contract(work, parent) do
    data = %{
      "schema_version" => 2,
      "work" => work,
      "parent" => parent,
      "goal" => "Produce the approved report",
      "non_goals" => [],
      "criteria" => ["result"],
      "criteria_details" => %{"result" => "Reproducible report"},
      "verification_checks" => %{"result" => ["review"]},
      "authorizer" => "1",
      "acceptance_mode" => if(parent, do: "technical", else: "separate"),
      "acceptor" => if(parent, do: nil, else: "2"),
      "budget_ms" => 100_000,
      "deliverables" => [%{"id" => "report", "kind" => "report", "criteria" => ["result"]}]
    }

    Map.put(data, "contract_sha", TaskWorkflow.digest(data))
  end

  defp block(name, value), do: "<!-- symphony-#{name} " <> Jason.encode!(value) <> " -->"

  defp note(body, id) do
    %{
      "id" => id,
      "body" => body,
      "user" => %{"id" => 1},
      "created_at" => "2026-10-18T00:00:00Z",
      "updated_at" => "2026-10-18T00:00:00Z"
    }
  end

  setup tags do
    work = %{"provider" => "github", "host" => "github.test", "repository_id" => "10", "kind" => "issue", "number" => 2}
    parent = %{work | "number" => 1}
    scope = contract(work, parent)
    parent_scope = contract(parent, nil)

    member = %{
      "work" => work,
      "contract_sha" => scope["contract_sha"],
      "criteria" => ["result"],
      "budget_ms" => 100_000,
      "human_gate" => false
    }

    {:ok, plan} =
      TaskPlan.seal(%{
        "parent" => parent,
        "contract_sha" => parent_scope["contract_sha"],
        "authorizer" => "1",
        "criteria" => ["result"],
        "members" => [member],
        "dependencies" => [],
        "integration" => work,
        "budget_ms" => 100_000
      })

    prefix = "/repos/team/repo"

    raw = fn number, body, state ->
      %{
        "id" => number + 100,
        "number" => number,
        "body" => body,
        "state" => state,
        "assignees" => [%{"id" => 1}],
        "html_url" => "https://github.test/team/repo/issues/#{number}"
      }
    end

    objects = %{
      prefix => %{"id" => 10, "full_name" => "team/repo", "html_url" => "https://github.test/team/repo"},
      "/user" => %{"id" => 99},
      (prefix <> "/issues/1") => raw.(1, block("contract", parent_scope) <> block("plan", plan), "closed"),
      (prefix <> "/issues/2") => raw.(2, block("contract", scope), "open"),
      (prefix <> "/issues/1/comments") => [
        note(block("plan-decision", %{"action" => "authorize", "revision" => plan["revision"]}), 1)
      ],
      (prefix <> "/issues/2/comments") => []
    }

    state = start_supervised!({Agent, fn -> objects end})
    request = fn "github", "GET", path, _, _ -> {:ok, %{status: 200, body: Agent.get(state, &Map.fetch!(&1, path))}} end

    repo =
      Map.take(work, ~w(provider host repository_id))
      |> Map.merge(%{
        "path" => "team/repo",
        "api_url" => "https://github.test/api/v3",
        "credential" => "$UNUSED_SESSION_FIXTURE",
        "execution" => %{
          "policy" => %{
            "engine_actor" => "99",
            "max_retries" => 2,
            "max_repairs" => 2,
            "checks" => %{"review" => %{"kind" => "review"}}
          }
        }
      })

    journal_root = Path.join(System.tmp_dir!(), "journal-#{tags[:test] |> to_string() |> TaskWorkflow.digest()}")
    File.mkdir_p!(journal_root)

    opts = [
      repositories: [repo],
      roots: [parent],
      active_state: "open",
      request: request,
      journal_root: journal_root
    ]

    %{
      parent: parent,
      work: work,
      plan: plan,
      opts: opts,
      journal_root: journal_root,
      state: state
    }
  end

  test "projection/0 default options uses configured plan roots" do
    assert {:ok, _} = TaskPlanExecution.projection()
  end

  test "discover/1 handles recovered_parent inconsistent and error results", %{
    parent: parent,
    work: work,
    opts: opts,
    journal_root: journal_root
  } do
    # 1. When journal has parent_close_intent with status inconsistent -> recovered_parent returns inconsistent
    dir = RunJournal.directory(journal_root, WorkRef.key(work))
    File.mkdir_p!(dir)

    record = %{
      "schema_version" => 2,
      "issue_id" => WorkRef.key(work),
      "directory" => dir,
      "execution_binding" => %{"authority" => %{"work" => parent}},
      "parent_close_intent" => %{"status" => "inconsistent"}
    }

    File.write!(Path.join(dir, "run.json"), Jason.encode!(record))

    assert {:ok, [%{native_ref: %{"plan_preflight" => %{"reason" => ":parent_close_inconsistent"}}}]} =
             TaskPlanExecution.discover(opts)

    # 2. When journal file is absent -> recover_closed returns {:error, :parent_close_intent_unavailable}
    File.rm!(Path.join(dir, "run.json"))

    assert {:ok, [%{native_ref: %{"plan_preflight" => %{"reason" => ":parent_close_intent_unavailable"}}}]} =
             TaskPlanExecution.discover(opts)
  end

  test "project_member and outcome reason_label / detail_label / state_of edge cases", %{
    work: work,
    opts: opts,
    state: state
  } do
    # Update issue 1 to open so discover_plan progresses
    Agent.update(state, fn objects ->
      issue1 = Map.put(objects["/repos/team/repo/issues/1"], "state", "open")
      Map.put(objects, "/repos/team/repo/issues/1", issue1)
    end)

    # Test closed state for member issue (line 141)
    Agent.update(state, fn objects ->
      issue2 = Map.put(objects["/repos/team/repo/issues/2"], "state", "closed")
      Map.put(objects, "/repos/team/repo/issues/2", issue2)
    end)

    assert {:ok, discovered} = TaskPlanExecution.discover(opts)
    member_card = Enum.find(discovered, &(&1.native_ref["work"] == work))
    assert member_card.native_ref["native_state"] == "closed"

    # Test unknown state for member issue (line 143)
    Agent.update(state, fn objects ->
      issue2 = Map.put(objects["/repos/team/repo/issues/2"], "state", "custom_state")
      Map.put(objects, "/repos/team/repo/issues/2", issue2)
    end)

    assert {:ok, discovered2} = TaskPlanExecution.discover(opts)
    member_card2 = Enum.find(discovered2, &(&1.native_ref["work"] == work))
    assert member_card2.native_ref["native_state"] == "unknown"
  end

  test "projection_of covers atom and non-atom details in reason_label", %{
    parent: parent,
    work: work,
    opts: opts
  } do
    # When a plan member has restriction with atom detail: {:custom_reason, :some_detail}
    configured = %{
      plan: %{
        plan: %{"parent" => parent},
        members: %{},
        restricted: %{
          "entry1" => %{work: work, reason: {:custom_reason, :atom_detail}},
          "entry2" => %{work: work, reason: {:custom_reason, 12_345}},
          "entry3" => %{work: work, reason: "string_reason"}
        }
      },
      executions: %{},
      opts: opts
    }

    projected = TaskPlanExecution.projection_of(configured)
    assert projected["entry1"].restricted == "custom_reason:atom_detail"
    assert projected["entry2"].restricted == "custom_reason:12345"
    assert projected["entry3"].restricted == "\"string_reason\""
  end
end
