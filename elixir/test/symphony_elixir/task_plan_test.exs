defmodule SymphonyElixir.TaskPlanTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.{Execution, TaskPlan, TaskWorkflow, WorkRef}
  alias SymphonyElixir.Tracker.Issue

  defp work(repo, number, provider \\ "github"),
    do: %{"provider" => provider, "host" => provider <> ".test", "repository_id" => repo, "kind" => "issue", "number" => number}

  defp member(ref),
    do: %{"work" => ref, "contract_sha" => TaskWorkflow.digest(ref), "criteria" => ["result"], "budget_ms" => 100, "human_gate" => false}

  defp edge(from, to, stage \\ "verified"),
    do: %{"from" => from, "to" => to, "artifact" => "code", "stage" => stage, "criteria" => ["behavior"]}

  defp draft do
    a = work("10", 1)
    b = work("20", 1, "gitlab")
    c = work("30", 1)
    integration = work("10", 2)

    %{
      "parent" => work("10", 100),
      "contract_sha" => TaskWorkflow.digest(%{"goal" => "The whole result", "scope" => ["result"]}),
      "authorizer" => "operator-id",
      "criteria" => ["result"],
      "members" => Enum.map([a, b, c, integration], &member/1),
      "dependencies" => [edge(a, b), edge(a, c, "delivered"), edge(b, integration), edge(c, integration, "published")],
      "integration" => integration,
      "budget_ms" => 500
    }
  end

  test "parent Issues are coordination work even with a ready label or a malformed plan" do
    assert {:ok, plan} = TaskPlan.seal(draft())
    block = "<!-- symphony-plan\n" <> Jason.encode!(plan) <> "\n-->"
    issue = %Issue{id: "100", description: "Parent goal\n\n" <> block, labels: ["symphony:ready"], dispatchable: true}
    parent = TaskPlan.project(issue)
    assert parent.kind == :plan
    assert parent.native_ref["plan"] == plan
    refute Issue.routable?(%{parent | dispatchable: true}, ["symphony:ready"])
    assert {:error, :parent_plan_has_no_executor} = Execution.prepare(parent, [])

    for body <- ["<!-- symphony-plan broken -->", block <> "\n" <> block, "<!-- symphony-plan {bad json} -->", "<!-- symphony-plan " <> Jason.encode!(%{plan | "revision" => "edited"}) <> " -->"] do
      invalid = TaskPlan.project(%{parent | description: body})
      refute invalid.native_ref["plan"]
      assert invalid.kind == :plan
      refute invalid.dispatchable
      assert is_binary(invalid.native_ref["plan_error"])
    end

    normal = %{issue | description: "An ordinary task"}
    assert TaskPlan.project(normal) == normal
    assert TaskPlan.project(%{normal | description: nil}) == %{normal | description: nil}
  end

  test "cross-provider plans bind every child contract and survive JSON persistence" do
    assert {:ok, plan} = TaskPlan.seal(draft())
    assert :ok = TaskPlan.validate(Jason.decode!(Jason.encode!(plan)))
    [first | _] = plan["members"]
    assert {:ok, ^first} = TaskPlan.member(plan, first["work"], first["contract_sha"])
    assert {:error, :member_contract_changed} = TaskPlan.member(plan, first["work"], String.duplicate("a", 64))
    assert {:error, :not_plan_member} = TaskPlan.member(plan, work("other", 1), first["contract_sha"])
    assert {:error, :invalid_work_ref} = TaskPlan.member(plan, %{}, first["contract_sha"])
    changed = put_in(plan, ["members", Access.at(0), "contract_sha"], String.duplicate("b", 64))
    assert {:error, :plan_revision_changed} = TaskPlan.validate(changed)
    assert {:ok, new_plan} = TaskPlan.seal(changed)
    refute new_plan["revision"] == plan["revision"]
  end

  test "invalidation reaches transitive consumers without affecting an independent sibling" do
    assert {:ok, plan} = TaskPlan.seal(draft())
    [a, b, c, integration] = Enum.map(plan["members"], & &1["work"])
    assert {:ok, [^b, ^integration]} = TaskPlan.affected(plan, [b])
    assert {:ok, [^c, ^integration]} = TaskPlan.affected(plan, [c])
    assert {:ok, all} = TaskPlan.affected(plan, [a])
    assert hd(all) == a
    assert List.last(all) == integration
    assert MapSet.new(all) == MapSet.new([a, b, c, integration])
    assert {:ok, []} = TaskPlan.affected(plan, [])
    assert {:ok, [^b, ^integration]} = TaskPlan.affected(plan, [b, b])
    assert {:error, :not_plan_member} = TaskPlan.affected(plan, [work("missing", 9)])
  end

  test "cycles and disconnected integration cannot authorize a partial graph" do
    plan = draft()
    [a, b, c, integration] = Enum.map(plan["members"], & &1["work"])
    assert {:error, :cyclic_plan} = TaskPlan.seal(%{plan | "dependencies" => [edge(b, a) | plan["dependencies"]]})
    assert {:error, :missing_integration_member} = TaskPlan.seal(%{plan | "integration" => work("missing", 1)})
    assert {:error, :incomplete_integration_graph} = TaskPlan.seal(%{plan | "dependencies" => [edge(a, b), edge(b, integration)]})
    assert {:error, :invalid_plan_dependencies} = TaskPlan.seal(%{plan | "dependencies" => [edge(c, c)]})
  end

  test "duplicate members, parent membership and incomplete criteria are rejected" do
    plan = draft()
    [first | rest] = plan["members"]

    for members <- [
          [],
          nil,
          [nil],
          [first, first | rest],
          [%{first | "work" => plan["parent"]} | rest],
          [%{first | "work" => %{}} | rest],
          [%{first | "contract_sha" => "not-a-digest"} | rest],
          [%{first | "human_gate" => "false"} | rest],
          [%{first | "budget_ms" => 0} | rest],
          [%{first | "criteria" => ["new"]} | rest],
          [Map.put(first, "extra", true) | rest]
        ] do
      assert {:error, :invalid_plan_members} = TaskPlan.seal(%{plan | "members" => members})
    end

    assert {:error, :invalid_plan_members} = TaskPlan.seal(%{plan | "criteria" => ["result", "uncovered"]})
  end

  test "dependencies require a usable named artifact, stage and criteria" do
    plan = draft()
    [first | rest] = plan["dependencies"]

    for edges <- [
          nil,
          [nil],
          [first, first | rest],
          [%{first | "to" => work("unknown", 1)} | rest],
          [%{first | "stage" => "closed"} | rest],
          [%{first | "criteria" => []} | rest],
          [%{first | "criteria" => ["a", "a"]} | rest],
          [%{first | "artifact" => " "} | rest],
          [Map.put(first, "latest", true) | rest]
        ] do
      assert {:error, :invalid_plan_dependencies} = TaskPlan.seal(%{plan | "dependencies" => edges})
    end
  end

  test "allocations cannot silently exceed a declared total budget" do
    for budget <- [0, -1, 399, "500"] do
      assert {:error, :invalid_plan_budget} = TaskPlan.seal(Map.put(draft(), "budget_ms", budget))
    end

    assert {:ok, _} = TaskPlan.seal(Map.put(draft(), "budget_ms", 400))
    assert {:ok, _} = TaskPlan.seal(Map.delete(draft(), "budget_ms"))
  end

  test "schema, owner and parent are explicit" do
    assert {:error, :invalid_plan_schema} = TaskPlan.validate(nil)
    assert {:error, :invalid_plan_schema} = TaskPlan.validate(%{})
    assert {:error, :invalid_plan_schema} = TaskPlan.seal(Map.put(draft(), "future", true))
    assert {:ok, plan} = TaskPlan.seal(draft())
    assert {:error, :invalid_plan_schema} = TaskPlan.validate(%{plan | "schema_version" => 99})
    assert {:error, :invalid_plan_schema} = TaskPlan.seal(%{plan | "schema_version" => 99})

    for fields <- [%{"authorizer" => " "}, %{"authorizer" => nil}, %{"contract_sha" => "missing"}, %{"parent" => %{}}, %{"criteria" => []}] do
      assert {:error, :invalid_plan_identity} = TaskPlan.seal(Map.merge(draft(), fields))
    end
  end

  test "native identity separates same numbers across hosts, repositories, providers and object kinds" do
    issue = work("10", 1)

    refs = [
      issue,
      %{issue | "repository_id" => "20"},
      %{issue | "host" => "another.test"},
      %{issue | "provider" => "gitlab"},
      %{issue | "kind" => "pr"},
      %{issue | "number" => 2}
    ]

    assert Enum.all?(refs, &(WorkRef.validate(&1) == :ok))
    assert length(Enum.uniq_by(refs, &WorkRef.key/1)) == length(refs)
    assert WorkRef.key(issue) == WorkRef.key(Jason.decode!(Jason.encode!(issue)))
    assert :ok = WorkRef.validate(%{issue | "host" => "example.test:8443"})
    assert :ok = WorkRef.validate(%{issue | "provider" => "gitlab", "kind" => "mr"})
  end

  test "display fields, credentials and malformed native identities are never silently normalized" do
    issue = work("10", 1)

    for fields <- [
          %{"host" => "EXAMPLE.test"},
          %{"host" => "example.test/path"},
          %{"host" => "user@example.test"},
          %{"host" => "example.test?token=private"},
          %{"host" => "example.test#fragment"},
          %{"host" => "example.test:443"},
          %{"host" => "example.test."},
          %{"host" => "example.test:0"},
          %{"host" => "example.test:65536"},
          %{"host" => ""},
          %{"host" => nil},
          %{"provider" => "other"},
          %{"kind" => "mr"},
          %{"number" => "1"},
          %{"number" => 0},
          %{"repository_id" => "owner/name"},
          %{"repository_id" => nil},
          %{"url" => "https://example.test/repo/issues/1"}
        ] do
      assert {:error, :invalid_work_ref} = WorkRef.validate(Map.merge(issue, fields))
    end

    assert {:error, :invalid_work_ref} = WorkRef.validate(nil)
    assert_raise ArgumentError, fn -> WorkRef.key(%{}) end
  end
end
