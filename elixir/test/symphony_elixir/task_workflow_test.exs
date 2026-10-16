defmodule SymphonyElixir.TaskWorkflowTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.TaskWorkflow, as: Flow
  @mr "https://gitlab.test/group/project/-/merge_requests/9"

  defp facts(extra \\ %{}) do
    Map.merge(
      %{
        "owner" => "1",
        "type" => "development",
        "issue_version" => "body",
        "source_refs" => ["auth", "manifest", "accept"],
        "versions" => %{@mr => "v1"},
        "deliveries_ready" => true,
        "closed" => false,
        "stopped" => true,
        "active" => false,
        "now" => 0
      },
      extra
    )
  end

  defp event(action, ref, at, data \\ %{}, actor \\ "1") do
    %{"id" => ref, "version" => ref, "ref" => ref, "at" => at, "actor" => actor, "action" => action, "contract" => "auth", "data" => data}
  end

  defp authorization(extra \\ %{}) do
    event(
      "authorize",
      "auth",
      1,
      Map.merge(
        %{
          "issue_version" => "body",
          "type" => "development",
          "acceptor" => "2",
          "reviewers" => ["3"],
          "criteria" => ["a", "b"],
          "acceptance_mode" => "separate",
          "deliverables" => [%{"id" => "code", "kind" => "mr"}]
        },
        extra
      )
    )
  end

  defp authorized(extra \\ %{}), do: Flow.reconcile(Flow.new(1_000, 0), facts(), [authorization(extra)], 0)

  defp manifest(extra \\ %{}) do
    Map.merge(%{"ref" => "manifest", "contract" => "auth", "items" => [%{"id" => "code", "kind" => "mr", "url" => @mr, "version" => "v1", "criteria" => ["a", "b"]}]}, extra)
  end

  test "authorization is versioned, typed and explicitly owned" do
    flow = Flow.new(1_000, 0)
    rejected = Flow.reconcile(flow, facts(), [event("pause", "p", 2)], 0)
    assert rejected["events"]["p"] == "missing_authorization"
    assert rejected["state"] == "waiting"
    assert Flow.reconcile(flow, facts(), [%{authorization() | "actor" => "stranger"}], 0)["contract"] == nil

    for invalid <- [%{"type" => "mixed"}, %{"issue_version" => "edited"}, %{"criteria" => []}, %{"deliverables" => []}, %{"acceptance_mode" => "merge", "type" => "research"}] do
      assert Flow.reconcile(flow, facts(), [authorization(invalid)], 0)["contract"] == nil
    end

    flow = authorized()
    assert flow["state"] == "ready"
    assert flow["allowed_criteria"] == ["a", "b"]
    stale = %{authorization() | "ref" => "old", "at" => 0}
    assert Flow.reconcile(flow, facts(), [stale], 0)["contract"]["ref"] == "auth"
    changed = Flow.reconcile(flow, facts(%{"source_refs" => []}), [], 0)
    assert changed["state"] == "waiting"
    assert Flow.reconcile(flow, facts(%{"issue_version" => "changed"}), [], 0)["state"] == "waiting"
    refute Flow.valid_conclusion?(changed)
  end

  test "multiple restrictions release separately and resume never overrides a newer pause" do
    flow = authorized()
    pause = event("pause", "p", 3)
    dependency = event("restrict", "d", 2, %{"restriction" => "dependency", "kind" => "dependency", "scope" => "task"})
    flow = Flow.reconcile(flow, facts(), [pause, dependency], 10)
    assert flow["state"] == "waiting"
    resume = event("resume", "r", 4, %{"restrictions" => ["p"]})
    flow = Flow.reconcile(flow, facts(), [resume], 20)
    assert Map.keys(flow["restrictions"]) == ["dependency"]
    assert flow["state"] == "waiting"
    flow = Flow.reconcile(flow, facts(%{"satisfied" => ["dependency"]}), [], 30)
    assert flow["state"] == "ready"
    # A late old pause is harmless only when a newer decision names that source.
    flow = Flow.reconcile(flow, facts(), [%{pause | "version" => "late", "ref" => "p", "id" => "late"}], 30)
    assert flow["state"] == "ready"
    newer = event("pause", "new", 6, %{"restriction" => "p"})
    older_resume = event("resume", "older-r", 5, %{"restrictions" => ["p"]})
    flow = Flow.reconcile(flow, facts(), [newer], 30)
    assert Flow.reconcile(flow, facts(), [older_resume], 30)["restrictions"]["p"]
    assert Flow.reconcile(flow, facts(), [event("release", "release", 7, %{"restrictions" => ["p"]})], 30)["state"] == "ready"
    late = Flow.reconcile(authorized(), facts(), [event("resume", "early-delivery", 10, %{"restrictions" => ["late-p"]})], 0)
    assert Flow.reconcile(late, facts(), [event("pause", "late-p", 9)], 0)["state"] == "ready"
    assert Flow.reconcile(flow, facts(), [event("resume", "unauthorized", 8, %{"restrictions" => ["p"]}, "2")], 30)["restrictions"]["p"]
  end

  test "scoped dependencies leave independent authorized criteria available" do
    flow =
      Flow.reconcile(
        authorized(),
        facts(%{"active" => true, "stopped" => false}),
        [event("restrict", "d", 2, %{"kind" => "dependency", "scope" => ["a"], "condition" => %{"kind" => "issue", "number" => 4}})],
        0
      )

    assert flow["state"] == "running"
    assert flow["allowed_criteria"] == ["b"]
    assert flow["restrictions"]["d"]["condition"]["number"] == 4
    assert Flow.reconcile(flow, facts(), [event("pause", "p", 3)], 0)["allowed_criteria"] == []
  end

  test "event versions deduplicate without resetting budget or replaying side effects" do
    flow = authorized()
    budget = event("budget", "b1", 2, %{"add_ms" => 500})
    flow = Flow.reconcile(flow, facts(), [budget, budget], 0)
    assert flow["budget_ms"] == 1_500
    flow = Jason.decode!(Jason.encode!(flow))
    assert Flow.reconcile(flow, facts(), [budget], 0)["budget_ms"] == 1_500
    stale = %{event("budget", "stale", 3, %{"add_ms" => 99}) | "contract" => "old-contract"}
    assert Flow.reconcile(flow, facts(), [stale], 0)["budget_ms"] == 1_500
    assert Flow.reconcile(flow, facts(), [event("budget", "negative", 4, %{"add_ms" => -1})], 0)["budget_ms"] == 1_500
  end

  test "in-scope rework needs an existing criterion and cannot enlarge the agreement" do
    {:ok, flow} = Flow.submit(authorized(), manifest())
    flow = Flow.handoff(flow, %{"kind" => "review"})
    flow = Flow.reconcile(flow, facts(), [event("rework", "fix", 2, %{"criteria" => ["a"], "changes" => []}, "3")], 0)
    assert flow["manifest"] == nil
    assert flow["resume_requested"]
    assert flow["state"] == "ready"
    expanded = Flow.reconcile(flow, facts(), [event("rework", "expand", 3, %{"criteria" => ["new"], "changes" => ["platform"]}, "2")], 0)
    assert expanded["restrictions"]["expand"]["kind"] == "scope"
    assert expanded["state"] == "waiting"
    assert Flow.reconcile(flow, facts(), [event("rework", "stranger", 4, %{"criteria" => ["a"], "changes" => []}, "4")], 0)["events"]["stranger"] == "no_authorized_transition"
    paused = Flow.reconcile(flow, facts(), [event("pause", "p", 5)], 0)
    assert Flow.reconcile(paused, facts(), [event("rework", "fix2", 6, %{"criteria" => ["a"], "changes" => []}, "2")], 0)["state"] == "waiting"
  end

  test "cumulative charging includes stopped automatic waits and retry backoff, excludes confirmed human waiting" do
    flow = Flow.start(authorized(), 0)
    flow = Flow.reconcile(flow, facts(%{"active" => true, "stopped" => false}), [event("pause", "p", 2)], 100)
    assert flow["used_ms"] == 100
    assert flow["charging"]
    flow = Flow.reconcile(flow, facts(), [], 150)
    refute flow["charging"]
    flow = Flow.reconcile(Jason.decode!(Jason.encode!(flow)), facts(), [], 900)
    assert flow["used_ms"] == 150
    flow = Flow.reconcile(flow, facts(), [event("resume", "r", 3, %{"restrictions" => ["p"]})], 900)
    assert flow["charging"]
    flow = Flow.reconcile(flow, facts(), [], 1_750)
    assert flow["used_ms"] == 1_000
    assert flow["restrictions"]["budget"]
    assert flow["state"] == "waiting"
    refute flow["charging"]
    assert Flow.reconcile(flow, facts(), [], 2_750)["used_ms"] == 1_000
    flow = Flow.reconcile(flow, facts(), [event("budget", "extra", 4, %{"add_ms" => 100})], 1_750)
    assert flow["state"] == "ready"
    assert Flow.tick(flow, 1_000)["used_ms"] == 1_000
    pending = Flow.reconcile(authorized(), facts(), [event("restrict", "dep", 3, %{"kind" => "dependency"})], 500)
    assert Flow.reconcile(pending, facts(), [], 800)["used_ms"] == 0
  end

  test "manifest must cover every agreed deliverable and acceptance criterion" do
    flow = authorized()
    assert {:error, :manifest_does_not_cover_contract} = Flow.submit(flow, manifest(%{"contract" => "old"}))
    assert {:error, _} = Flow.submit(flow, manifest(%{"items" => []}))
    assert {:error, _} = Flow.submit(flow, manifest(%{"items" => [%{"id" => "code", "kind" => "mr", "url" => @mr, "version" => "v1", "criteria" => ["a"]}]}))
    assert {:ok, _} = Flow.submit(flow, manifest())
    flow = Flow.reconcile(flow, facts(), [event("manifest", "manifest", 2, Map.delete(manifest(), "ref"))], 0)
    assert flow["state"] == "review"
    pending = Flow.reconcile(flow, facts(%{"deliveries_ready" => false}), [], 0)
    assert pending["state"] == "waiting"
    assert Flow.reconcile(pending, facts(), [], 0)["state"] == "review"
    assert Flow.reconcile(authorized(), facts(), [event("manifest", "bad-manifest", 2, %{})], 0)["events"]["bad-manifest"] == "manifest_rejected"
  end

  test "acceptance binds the current manifest, source versions and decision contents" do
    {:ok, flow} = Flow.submit(authorized(), manifest())
    accepted = event("accept", "accept", 3, %{"manifest" => "manifest"}, "2")
    flow = Flow.reconcile(flow, facts(), [accepted], 0)
    assert Flow.valid_conclusion?(flow)
    assert flow["state"] == "review"
    assert Flow.reconcile(flow, facts(%{"closed" => true, "stopped" => false}), [], 0)["state"] == "waiting"
    assert Flow.reconcile(flow, facts(%{"closed" => true}), [], 0)["state"] == "ended"
    changed = Flow.reconcile(flow, facts(%{"versions" => %{@mr => "v2"}}), [], 0)
    refute changed["acceptance"]
    assert changed["state"] == "waiting"
    assert Flow.reconcile(flow, facts(%{"source_refs" => ["auth", "manifest"]}), [], 0)["acceptance"] == nil
    refute Flow.reconcile(flow, facts(%{"source_refs" => ["auth", "accept"]}), [], 0)["acceptance"]
    refute Flow.reconcile(authorized(), facts(%{"closed" => true}), [], 0)["acceptance"]
    assert Flow.reconcile(authorized(), facts(%{"closed" => true}), [], 0)["restrictions"]["closure"]
    assert Flow.handoff(authorized(), %{"kind" => "decision"})["restrictions"]["handoff"]["kind"] == "decision"
  end

  test "merge acceptance works during pause, without dispatching another executor" do
    flow = authorized(%{"acceptance_mode" => "merge"})
    {:ok, flow} = Flow.submit(flow, manifest())
    flow = Flow.reconcile(flow, facts(%{"merge_verified" => true, "closed" => true}), [event("pause", "p", 2)], 0)
    assert flow["acceptance"]["ref"] == "verified_merge"
    assert flow["state"] == "ended"
    refute flow["charging"]
    cancelled = Flow.reconcile(authorized(), facts(%{"closed" => true, "source_refs" => ["auth", "cancel"]}), [event("cancel", "cancel", 2, %{"reason" => "No longer needed"})], 0)
    assert cancelled["state"] == "ended"
    refute cancelled["acceptance"]
  end

  test "intermediate merge clears only its review wait, and calendar deadlines survive pause" do
    flow = Flow.handoff(authorized(), %{"kind" => "review"}) |> Map.put("intermediate", %{"url" => @mr, "version" => "v1"})
    flow = Flow.reconcile(flow, facts(%{"merged_urls" => [@mr]}), [], 0)
    assert flow["state"] == "ready"
    assert flow["resume_requested"]
    refute flow["manifest"]
    deadline = authorized(%{"deadline" => 100})
    assert Flow.reconcile(deadline, facts(%{"now" => 101}), [event("pause", "p", 3)], 0)["restrictions"]["deadline"]
  end

  test "malformed agreements and manifests cannot authorize work; reopening requires an explicit release" do
    for invalid <- [
          %{"acceptance_mode" => "unknown"},
          %{"deadline" => "tomorrow"},
          %{"reviewers" => "invalid"},
          %{"budget_ms" => -1},
          %{"criteria" => ["a", "a"]},
          %{"deliverables" => [nil]},
          %{"type" => "unknown"},
          %{"reviewers" => []}
        ] do
      result = Flow.reconcile(Flow.new(1_000, 0), facts(%{"type" => invalid["type"] || "development"}), [authorization(invalid)], 0)
      if invalid == %{"reviewers" => []}, do: assert(result["contract"]), else: refute(result["contract"])
    end

    mixed = %{"type" => "mixed", "deliverables" => [%{"id" => "code", "kind" => "mr"}, %{"id" => "answer", "kind" => "report"}]}
    assert Flow.reconcile(Flow.new(1_000, 0), facts(%{"type" => "mixed"}), [authorization(mixed)], 0)["contract"]
    assert {:error, _} = Flow.submit(authorized(), manifest(%{"items" => "invalid"}))
    assert {:error, _} = Flow.submit(authorized(), manifest(%{"items" => [%{"id" => "code"}]}))
    flow = Flow.reconcile(authorized(), facts(), [event("unknown", "discussion", 5)], 0)
    assert flow["events"]["discussion"] == "no_authorized_transition"
    flow = Flow.reconcile(flow, facts(%{"closed" => true}), [], 0)
    flow = Flow.reconcile(flow, facts(), [], 0)
    assert flow["restrictions"]["reopen"]
    assert Flow.reconcile(flow, facts(), [event("release", "reopen-approved", 6, %{"restrictions" => ["reopen"]})], 0)["state"] == "ready"
  end

  test "initial dependencies, late delivery decisions and contradictory conclusions remain fenced" do
    dependency = %{"id" => "input", "kind" => "issue", "number" => 7}
    flow = authorized(%{"dependencies" => [dependency]})
    assert flow["restrictions"]["dependency:input"]
    assert Flow.reconcile(flow, facts(%{"satisfied" => ["dependency:input"]}), [], 0)["state"] == "ready"

    for dependencies <- ["invalid", [nil], [%{"id" => "x", "kind" => "issue", "number" => -1}], [dependency, dependency]] do
      refute Flow.reconcile(Flow.new(1_000, 0), facts(), [authorization(%{"dependencies" => dependencies})], 0)["contract"]
    end

    rework = event("rework", "rework", 5, %{"criteria" => ["a"], "changes" => []}, "2")
    flow = Flow.reconcile(authorized(), facts(), [rework], 0)
    late = event("manifest", "late-manifest", 2, Map.delete(manifest(), "ref"))
    flow = Flow.reconcile(flow, facts(), [late], 0)
    refute flow["manifest"]
    assert flow["events"]["late-manifest"] == "obsolete_delivery_decision"
    {:ok, flow} = Flow.submit(authorized(%{"acceptance_mode" => "merge"}), manifest())
    flow = Flow.reconcile(flow, facts(%{"merge_verified" => true, "closed" => true}), [event("cancel", "cancel", 6, %{"reason" => "Cancel"})], 0)
    assert flow["state"] == "waiting"
    refute Flow.valid_conclusion?(flow)
    assert flow["restrictions"]["conclusion_conflict"]
  end

  test "late restrictions cannot overwrite newer pauses and natural resume survives a late older pause" do
    newer = event("pause", "new", 30, %{"restriction" => "pause"})
    older = event("pause", "old", 10, %{"restriction" => "pause"})
    flow = Flow.reconcile(authorized(), facts(), [newer], 0)
    flow = Flow.reconcile(flow, facts(), [older], 0)
    flow = Flow.reconcile(flow, facts(), [event("resume", "resume", 20, %{"restrictions" => ["pause"]})], 0)
    assert flow["state"] == "waiting"
    assert flow["restrictions"]["pause"]["at"] == 30
    resume = Map.put(event("resume", "natural", 20), "natural", true)
    flow = Flow.reconcile(authorized(), facts(), [resume], 0)
    flow = Flow.reconcile(flow, facts(), [Map.put(event("pause", "late", 10), "natural", true), resume], 0)
    assert flow["state"] == "ready"
    assert Flow.reconcile(flow, facts(), [event("pause", "later", 30)], 0)["state"] == "waiting"
    report = %{"id" => "code", "kind" => "report", "url" => "https://gitlab.test/group/project/-/issues/42#note_2", "version" => "v1", "criteria" => ["a", "b"]}
    assert {:error, _} = Flow.submit(authorized(), manifest(%{"items" => [report]}))
    assert {:error, _} = Flow.submit(authorized(), manifest(%{"items" => [%{report | "kind" => "mr"}]}))
  end

  test "unorderable edits and unclear control requests stop; legacy release times remain conservative" do
    budget = event("budget", "budget", 5, %{"add_ms" => 10})
    flow = Flow.reconcile(authorized(), facts(), [budget], 0)
    edit = %{budget | "version" => "edited", "ref" => "edited"}
    assert Flow.reconcile(flow, facts(), [edit], 0)["restrictions"]["event_conflict:budget"]
    flow = put_in(authorized(), ["released", "legacy"], 20)
    assert Flow.reconcile(flow, facts(), [event("pause", "legacy", 10)], 0)["state"] == "ready"
    assert Flow.reconcile(authorized(), facts(), [event("clarify", "clarify", 2)], 0)["state"] == "waiting"
    {:ok, flow} = Flow.submit(authorized(), manifest())
    flow = Flow.reconcile(flow, facts(%{"deliveries_ready" => false, "closed" => true}), [event("accept", "accept", 5, %{"manifest" => "manifest"}, "2")], 0)
    assert flow["state"] == "waiting"
    refute Flow.valid_conclusion?(flow)
  end

  test "invalid restriction scopes and kinds cannot silently leave work unrestricted" do
    flow = Flow.reconcile(authorized(), facts(), [event("restrict", "d", 2, %{"kind" => "unknown", "scope" => ["unknown"]})], 0)
    assert flow["restrictions"]["d"]["scope"] == "task"
    assert flow["restrictions"]["d"]["kind"] == "decision"
    assert flow["state"] == "waiting"
  end

  test "late releases cannot lower the resume boundary and reopening cancellation needs a decision" do
    newer = event("release", "new-release", 30, %{"restrictions" => ["pause"]})
    older = event("release", "old-release", 20, %{"restrictions" => ["pause"]})
    flow = Flow.reconcile(authorized(), facts(), [newer], 0)
    flow = Flow.reconcile(flow, facts(), [older], 0)
    flow = Flow.reconcile(flow, facts(), [event("pause", "late-pause", 25, %{"restriction" => "pause"})], 0)
    assert flow["state"] == "ready"
    cancelled = Flow.reconcile(authorized(), facts(%{"source_refs" => ["auth", "cancel"], "closed" => true}), [event("cancel", "cancel", 2, %{"reason" => "Cancel"})], 0)
    assert cancelled["state"] == "ended"
    reopened = Flow.reconcile(cancelled, facts(%{"source_refs" => ["auth", "cancel"]}), [], 0)
    assert reopened["state"] == "waiting"
    refute Flow.valid_conclusion?(reopened)
  end
end
