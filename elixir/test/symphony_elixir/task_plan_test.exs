defmodule SymphonyElixir.TaskPlanTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.{Execution, TaskControl, TaskPlan, TaskWorkflow, WorkRef}
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

  defp pinned_draft(selects) do
    plan = draft()
    [a, b, c | _] = Enum.map(plan["members"], & &1["work"])

    dependencies =
      Enum.map(plan["dependencies"], fn
        %{"from" => ^a, "to" => ^b} = edge -> Map.put(edge, "selects", "b1")
        %{"from" => ^a, "to" => ^c} = edge -> Map.put(edge, "selects", selects)
        edge -> edge
      end)

    %{plan | "dependencies" => dependencies}
  end

  defp explicit_schema_one_selection do
    plan = pinned_draft("b1")
    Map.put(plan, "schema_version", 1)
  end

  defp reseal(plan) do
    plan = Map.delete(plan, "revision")
    Map.put(plan, "revision", TaskWorkflow.digest(plan))
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
    assert TaskPlan.project(%{issue | description: String.replace(block, "<!-- ", "<!--\n  ")}).kind == :plan

    for body <- ["<!-- symphony-plan broken -->", block <> "\n" <> block, "<!-- symphony-plan {bad json} -->", "<!-- symphony-plan " <> Jason.encode!(%{plan | "revision" => "edited"}) <> " -->"] do
      invalid = TaskPlan.project(%{parent | description: body})
      refute invalid.native_ref["plan"]
      assert invalid.kind == :plan
      refute invalid.dispatchable
      assert is_binary(invalid.native_ref["plan_error"])
    end

    normal = %{issue | description: "An ordinary task"}

    for broken <- [block <> "\n<!-- symphony-plan broken", "<!--\n symphony-plan"] do
      rejected = TaskPlan.project(%{normal | description: broken})
      assert rejected.kind == :plan
      refute rejected.dispatchable
      assert rejected.native_ref["plan_error"] == "invalid_plan_block"
    end

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

  test "unchanged member evidence survives a new plan grant only while the old native grant is intact" do
    initial = %{draft() | "authorizer" => "1"}
    assert {:ok, old} = TaskPlan.seal(initial)
    assert {:ok, current} = TaskPlan.seal(%{initial | "budget_ms" => 501})
    member = hd(current["members"])

    note = plan_decision_note(7, 1, %{"action" => "authorize", "revision" => old["revision"]})

    prior = %{"work" => current["parent"], "actor" => "1", "revision" => old["revision"], "source" => SymphonyElixir.TaskDecision.source_ref(note)}
    latest = %{prior | "revision" => current["revision"], "source" => "note:8"}

    binding = %{
      "work" => member["work"],
      "contract_sha" => member["contract_sha"],
      "authority" => prior,
      "plan_revision" => old["revision"],
      "inputs" => []
    }

    assert TaskPlan.compatible_binding?(current, latest, binding, member["work"], [note])
    refute TaskPlan.compatible_binding?(current, latest, binding, member["work"], [%{note | "body" => "edited"}])
    refute TaskPlan.compatible_binding?(current, latest, %{binding | "contract_sha" => TaskWorkflow.digest("changed")}, member["work"], [note])
    changed_input = %{binding | "inputs" => [%{"work" => member["work"], "artifact" => "wrong"}]}
    refute TaskPlan.compatible_binding?(current, latest, changed_input, member["work"], [note])

    # A note that shares the recorded native source and actor but is not a
    # genuine authorization for the bound revision must not resurrect the stale
    # grant (§17 historical-grant tightening).
    for wrong <- [
          %{note | "body" => "P1 approved"},
          plan_decision_note(7, 1, %{"action" => "pause", "revision" => old["revision"]}),
          plan_decision_note(7, 1, %{"action" => "authorize", "revision" => current["revision"]}),
          plan_decision_note(7, 1, %{"action" => "authorize", "revision" => old["revision"], "extra" => "x"}),
          %{note | "body" => "<!-- symphony-plan-decision {invalid} -->"},
          %{note | "created_at" => "2026-10-18T00:00:01Z"},
          %{note | "id" => 0},
          %{note | "author" => %{"id" => "1"}}
        ] do
      forged_prior = %{prior | "source" => SymphonyElixir.TaskDecision.source_ref(wrong)}
      refute TaskPlan.compatible_binding?(current, latest, %{binding | "authority" => forged_prior}, member["work"], [wrong])
    end
  end

  test "a native short-version authorization remains a compatible historical grant" do
    initial = %{draft() | "authorizer" => "1"}
    assert {:ok, old} = TaskPlan.seal(initial)
    assert {:ok, current} = TaskPlan.seal(%{initial | "budget_ms" => 501})
    member = hd(current["members"])

    candidate = %{
      "id" => 6,
      "body" =>
        "计划版本 P1\n<!-- symphony-candidate " <>
          Jason.encode!(%{"label" => "P1", "revision" => old["revision"], "authorizer" => "1", "data" => %{}}) <> " -->",
      "author" => %{"id" => 99},
      "created_at" => "2026-10-18T00:00:00Z",
      "updated_at" => "2026-10-18T00:00:00Z"
    }

    reply = %{
      "id" => 7,
      "body" => "按 P1 执行",
      "author" => %{"id" => 1},
      "created_at" => "2026-10-18T00:00:01Z",
      "updated_at" => "2026-10-18T00:00:01Z"
    }

    notes = [candidate, reply]
    assert {:ok, event} = TaskControl.bind_reply(%{work: old["parent"], notes: notes}, reply, "1")

    prior = %{
      "work" => old["parent"],
      "actor" => "1",
      "revision" => old["revision"],
      "source" => event["note_source"],
      "candidate_source" => event["candidate_source"],
      "candidate_digest" => event["candidate_digest"]
    }

    latest = %{prior | "revision" => current["revision"], "source" => "note:8"}
    binding = %{"work" => member["work"], "contract_sha" => member["contract_sha"], "authority" => prior, "plan_revision" => old["revision"], "inputs" => []}

    assert TaskPlan.compatible_binding?(current, latest, binding, member["work"], notes)
    refute TaskPlan.compatible_binding?(current, latest, binding, member["work"], [%{reply | "body" => "P1 approved"}, candidate])
    refute TaskPlan.compatible_binding?(current, latest, %{binding | "authority" => %{prior | "candidate_source" => "forged"}}, member["work"], notes)
  end

  defp plan_decision_note(id, actor, payload) do
    %{
      "id" => id,
      "body" => "<!-- symphony-plan-decision " <> Jason.encode!(payload) <> " -->",
      "author" => %{"id" => actor},
      "created_at" => "2026-10-18T00:00:00Z",
      "updated_at" => "2026-10-18T00:00:00Z"
    }
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

  test "requires_plan_lifecycle? returns false for non-plan Issue" do
    refute TaskPlan.requires_plan_lifecycle?(%SymphonyElixir.Tracker.Issue{id: "raw:1"})
  end

  test "compatible? handles invalid input list elements and non-list inputs" do
    assert {:ok, plan} = TaskPlan.seal(draft())
    member = hd(plan["members"])
    work = member["work"]

    refute TaskPlan.compatible?(plan, work, "different_revision", [%{"work" => "not_a_map", "artifact" => "art"}])
    refute TaskPlan.compatible?(plan, work, "different_revision", "not_a_list")
  end

  test "compatible? compares declared dependencies against input pairs" do
    assert {:ok, plan} = TaskPlan.seal(draft())
    [a, b | _] = Enum.map(plan["members"], & &1["work"])

    # In draft(), b depends on a with artifact: "code"
    matching_inputs = [%{"work" => a, "artifact" => "code"}]
    assert TaskPlan.compatible?(plan, b, "different_revision", matching_inputs)

    non_matching_inputs = [%{"work" => a, "artifact" => "other"}]
    refute TaskPlan.compatible?(plan, b, "different_revision", non_matching_inputs)
  end

  test "an explicit edge selection seals a schema v2 plan while legacy drafts keep schema v1" do
    assert {:ok, legacy} = TaskPlan.seal(draft())
    assert legacy["schema_version"] == 1
    refute Enum.any?(legacy["dependencies"], &Map.has_key?(&1, "selects"))

    assert {:ok, pinned} = TaskPlan.seal(pinned_draft("b1"))
    assert pinned["schema_version"] == 2
    assert Enum.map(pinned["dependencies"], & &1["selects"]) == ["b1", "b1", nil, nil]
    assert :ok = TaskPlan.validate(Jason.decode!(Jason.encode!(pinned)))
    assert pinned["revision"] != legacy["revision"]

    assert {:ok, declared} = TaskPlan.seal(Map.put(draft(), "schema_version", 2))
    assert declared["schema_version"] == 2
    assert Enum.all?(declared["dependencies"], &(&1["selects"] == nil))
  end

  test "conflicting or unusable selection shapes are rejected instead of being ignored" do
    assert {:error, :invalid_plan_dependencies} = TaskPlan.seal(explicit_schema_one_selection())

    for unusable <- ["", " ", 5, []] do
      assert {:error, :invalid_plan_dependencies} = TaskPlan.seal(pinned_draft(unusable))
    end

    malformed = pinned_draft("b1") |> Map.put("schema_version", 2) |> Map.put("dependencies", [nil])
    assert {:error, :invalid_plan_dependencies} = TaskPlan.seal(malformed)

    assert {:ok, pinned} = TaskPlan.seal(pinned_draft("b1"))
    [dropped | rest] = pinned["dependencies"]
    incomplete = reseal(%{pinned | "dependencies" => [Map.delete(dropped, "selects") | rest]})
    assert {:error, :invalid_plan_dependencies} = TaskPlan.validate(incomplete)

    assert {:error, :invalid_plan_schema} = TaskPlan.validate(reseal(%{pinned | "schema_version" => 3}))
    assert {:error, :invalid_plan_schema} = TaskPlan.seal(Map.put(draft(), "schema_version", 3))
  end

  test "a changed selection invalidates only the repinned consumer while an independent sibling stays reusable" do
    assert {:ok, old} = TaskPlan.seal(pinned_draft("b1"))
    assert {:ok, new} = TaskPlan.seal(pinned_draft("b2"))
    [a, b, c, integration] = Enum.map(old["members"], & &1["work"])
    b1 = [%{"work" => a, "artifact" => "code", "version" => "b1"}]
    b2 = [%{"work" => a, "artifact" => "code", "version" => "b2"}]

    refute new["revision"] == old["revision"]
    assert TaskPlan.compatible?(old, c, "previous_revision", b1)
    refute TaskPlan.compatible?(new, c, "previous_revision", b1)
    assert TaskPlan.compatible?(new, c, "previous_revision", b2)
    refute TaskPlan.compatible?(new, c, "previous_revision", [%{"work" => a, "artifact" => "code"}])

    # The independent sibling keeps the selection it already recorded.
    assert TaskPlan.compatible?(old, b, "previous_revision", b1)
    assert TaskPlan.compatible?(new, b, "previous_revision", b1)

    # An intentionally unpinned edge accepts whatever version the upstream produced.
    unpinned = [%{"work" => b, "artifact" => "code", "version" => "i1"}, %{"work" => c, "artifact" => "code", "version" => "i2"}]
    assert TaskPlan.compatible?(new, integration, "previous_revision", unpinned)

    # A legacy v1 edge stays version-agnostic instead of pinning a revision.
    assert {:ok, legacy} = TaskPlan.seal(draft())
    assert TaskPlan.compatible?(legacy, b, "previous_revision", [%{"work" => a, "artifact" => "code", "version" => "b9"}])
    assert TaskPlan.compatible?(new, a, "previous_revision", [])
  end
end
