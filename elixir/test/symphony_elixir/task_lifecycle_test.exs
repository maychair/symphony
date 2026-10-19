defmodule SymphonyElixir.TaskLifecycleTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.{ExecutionBinding, RunJournal, TaskDecision, TaskLifecycle, TaskPlan, TaskWorkflow, WorkRef}

  defp fixture(opts \\ []) do
    parent = %{"provider" => "github", "host" => "github.test", "repository_id" => "1", "kind" => "issue", "number" => 1}
    work = %{parent | "number" => 2}

    contract = %{
      "schema_version" => 2,
      "work" => work,
      "parent" => parent,
      "goal" => "Deliver the approved result",
      "non_goals" => ["No new scope"],
      "authorizer" => "1",
      "criteria" => ["result"],
      "criteria_details" => %{"result" => "The result reproduces the approved behavior"},
      "verification_checks" => %{"result" => ["test", "review"]},
      "budget_ms" => 10_000,
      "acceptance_mode" => if(opts[:human_gate], do: "separate", else: "technical"),
      "acceptor" => if(opts[:human_gate], do: "2"),
      "deliverables" => [%{"id" => "result", "kind" => "report", "criteria" => ["result"]}]
    }

    contract = Map.put(contract, "contract_sha", TaskWorkflow.digest(contract))
    member = %{"work" => work, "contract_sha" => contract["contract_sha"], "criteria" => ["result"], "budget_ms" => 10_000, "human_gate" => opts[:human_gate] == true}

    {:ok, plan} =
      TaskPlan.seal(%{
        "parent" => parent,
        "authorizer" => "1",
        "contract_sha" => TaskWorkflow.digest("parent scope"),
        "criteria" => ["result"],
        "members" => [member],
        "dependencies" => [],
        "integration" => work,
        "budget_ms" => 10_000
      })

    note = plan_decision(1, plan["revision"], "2026-10-16T00:00:00Z")
    authority = %{"work" => parent, "actor" => "1", "revision" => plan["revision"], "source" => TaskDecision.source_ref(note)}

    %{
      plan: %{plan: plan, authority: authority, parent: %{notes: [note], raw: %{"state" => "open"}}, members: %{WorkRef.key(work) => %{work: work, contract: contract, raw: %{"state" => "open"}}}},
      work: work,
      runtime: %{},
      policy: %{"engine_actor" => "99", "max_retries" => 2, "max_repairs" => 2, "checks" => %{"test" => %{"kind" => "command", "command" => "make check"}, "review" => %{"kind" => "review"}}},
      evidence: %{
        "sources" => ~w(candidate artifact verification test review finding delivery mapping delivered_checks accept pause resume),
        "restrictions" => [],
        "releases" => [],
        "dependencies" => [],
        "deliveries" => [],
        "candidate" => nil,
        "verification" => nil,
        "acceptance" => nil,
        "active" => false
      }
    }
  end

  defp assess(context, now \\ 0) do
    assert {:ok, flow} = TaskLifecycle.assess(context, now)
    flow
  end

  test "dependency verification uses technical evidence independently of delivery and runtime activity" do
    context = fixture() |> candidate() |> verified()
    assert {:ok, artifacts} = TaskLifecycle.verified_artifacts(context)
    assert artifacts == context.evidence["candidate"]["artifacts"]
    narrow = Map.update!(context, :evidence, &Map.take(&1, ~w(sources candidate verification dependencies)))
    assert {:ok, ^artifacts} = TaskLifecycle.verified_artifacts(narrow)
    assert {:error, :dependency_not_verified} = TaskLifecycle.verified_artifacts(fixture())
    assert {:error, :dependency_not_verified} = TaskLifecycle.verified_artifacts(put_in(context.evidence["verification"]["checks"], []))
    failed = put_in(context.evidence["verification"]["findings"], [finding()])
    assert {:error, :dependency_not_verified} = TaskLifecycle.verified_artifacts(failed)
    unknown = put_in(context.evidence["verification"]["findings"], [Map.put(finding(), "status", "unknown")])
    assert {:error, :dependency_not_verified} = TaskLifecycle.verified_artifacts(unknown)
    changed = update_in(context.runtime["execution_history"], &Enum.map(&1, fn r -> put_in(r["execution_binding"]["plan_revision"], TaskWorkflow.digest("old")) end))
    assert {:error, :invalid_persisted_execution_binding} = TaskLifecycle.verified_artifacts(changed)
    assert {:error, :incomplete_verification_policy} = TaskLifecycle.verified_artifacts(%{context | policy: %{}})
  end

  test "a newly approved plan reuses verified evidence only for an unchanged member and fixed inputs" do
    old = fixture() |> candidate() |> verified()
    assert {:ok, revised} = TaskPlan.seal(%{old.plan.plan | "budget_ms" => 10_001})
    note = plan_decision(2, revised["revision"], "2026-10-17T00:00:00Z")
    authority = %{"work" => revised["parent"], "actor" => "1", "revision" => revised["revision"], "source" => TaskDecision.source_ref(note)}
    plan = %{old.plan | plan: revised, authority: authority, parent: %{old.plan.parent | notes: old.plan.parent.notes ++ [note]}}
    current = %{old | plan: plan}

    assert {:ok, artifacts} = TaskLifecycle.verified_artifacts(current)
    assert artifacts == old.evidence["candidate"]["artifacts"]

    changed = put_in(current.plan.parent.notes, [note])
    assert {:error, :dependency_not_verified} = TaskLifecycle.verified_artifacts(changed)
  end

  defp plan_decision(id, revision, at) do
    body = "<!-- symphony-plan-decision " <> Jason.encode!(%{"action" => "authorize", "revision" => revision}) <> " -->"
    %{"id" => id, "body" => body, "author" => %{"id" => 1}, "created_at" => at, "updated_at" => at}
  end

  defp candidate(context) do
    flow = assess(context)
    assert {:ok, record} = ExecutionBinding.bind(context.runtime, flow["next_binding"])
    record = Map.merge(record, %{"thread_id" => "developer-#{record["execution_generation"]}", "native_stop_confirmed" => true})

    payload = %{
      "work" => context.work,
      "contract_sha" => flow["contract_sha"],
      "inputs" => flow["inputs"],
      "artifacts" => [%{"id" => "result", "kind" => "report", "version" => "v1", "source" => "artifact"}]
    }

    candidate = Map.merge(payload, %{"digest" => TaskWorkflow.digest(payload), "actor" => "99", "source" => "candidate", "execution" => receipt(record)})
    context |> Map.put(:runtime, record) |> put_in([:evidence, "candidate"], candidate)
  end

  defp receipt(record), do: %{"generation" => record["execution_generation"], "thread_id" => record["thread_id"]}

  defp verified(context) do
    flow = assess(context)
    assert flow["next_binding"]["role"] == "verifier"
    assert {:ok, record} = ExecutionBinding.bind(context.runtime, flow["next_binding"])
    record = Map.merge(record, %{"thread_id" => "verifier-#{record["execution_generation"]}", "native_stop_confirmed" => true})

    verification = %{
      "candidate" => flow["candidate"],
      "policy_sha" => TaskWorkflow.digest(context.policy),
      "inputs" => flow["inputs"],
      "actor" => "99",
      "source" => "verification",
      "execution" => receipt(record),
      "checks" => [
        %{
          "id" => "test",
          "candidate" => flow["candidate"],
          "source" => "test",
          "command" => "make check",
          "exit_code" => 0,
          "output_sha" => TaskWorkflow.digest("actual output"),
          "reason" => "completed",
          "snapshot_valid" => true
        },
        %{"id" => "review", "candidate" => flow["candidate"], "source" => "review", "result" => "passed", "rationale" => "All original criteria checked"}
      ],
      "findings" => []
    }

    context |> Map.put(:runtime, record) |> put_in([:evidence, "verification"], verification)
  end

  defp delivered(context) do
    put_in(context.evidence["deliveries"], [%{"artifact" => "result", "source_version" => "v1", "delivered_version" => "v1", "source" => "delivery"}])
  end

  defp finding do
    %{
      "id" => "F1",
      "criterion" => "result",
      "status" => "valid",
      "required" => true,
      "rationale" => "Reproduction fails",
      "evidence" => ["finding"],
      "problem_sha" => TaskWorkflow.digest("result: reproducible missing output"),
      "repair_basis_sha" => TaskWorkflow.digest("reproduction: all inputs fail")
    }
  end

  defp with_finding(context, finding \\ finding()), do: put_in(context.evidence["verification"]["findings"], [finding])
  defp persist(context, flow), do: put_in(context.runtime["workflow"], flow)

  test "a sealed approval drives developer, independent verifier and delivery without child acceptance" do
    context = fixture()
    first = assess(context)
    assert first["dispatchable"]
    assert first["action"] == "implement"
    assert first["next_binding"]["authority"] == context.plan.authority
    refute first["charging"]

    context = candidate(context)
    verification = assess(context)
    assert verification["dispatchable"]
    assert verification["action"] == "verify"
    assert verification["next_binding"]["role"] == "verifier"

    context = verified(context)
    delivery = assess(context)
    assert delivery["dispatchable"]
    assert delivery["phase"] == "delivering"
    assert delivery["next_binding"]["role"] == "developer"
    assert delivery["next_binding"]["candidate"] == context.evidence["candidate"]["digest"]

    finished = assess(delivered(context))
    assert finished["phase"] == "completed"
    assert finished["outcome"] == "delivered"
    assert finished["action"] == "close"
    assert finished["closeable"]
    refute finished["dispatchable"]
    refute finished["charging"]
  end

  test "a closed native Issue or a successful check alone is not completion" do
    context = fixture()
    context = put_in(context.plan.members[WorkRef.key(context.work)].raw["state"], "closed")
    assert assess(context)["restrictions"]["native_closed"]
    parent_closed = put_in(context.plan.parent.raw["state"], "closed")
    assert assess(parent_closed)["restrictions"]["parent_closed"]
    context = fixture() |> candidate() |> verified()
    partial = put_in(context.evidence["verification"]["checks"], [hd(context.evidence["verification"]["checks"])])
    assert assess(partial)["restrictions"]["verification_invalid"]
    context = context |> delivered() |> put_in([:plan, :members, WorkRef.key(context.work), :raw, "state"], "closed")
    refute assess(context)["restrictions"]["native_closed"]
    assert assess(context)["outcome"] == "delivered"
  end

  test "policy and scope must be complete before producing an executable binding" do
    context = fixture()

    for policy <- [
          nil,
          %{},
          Map.put(context.policy, "max_retries", -1),
          Map.put(context.policy, "checks", nil),
          Map.put(context.policy, "checks", %{}),
          put_in(context.policy, ["checks", "review"], %{"kind" => "unknown"})
        ] do
      assert {:error, :incomplete_verification_policy} = TaskLifecycle.assess(%{context | policy: policy}, 0)
    end

    assert {:error, :incomplete_observation} = TaskLifecycle.assess(%{}, 0)
    assert {:error, :missing_plan_member} = TaskLifecycle.assess(put_in(context.plan.members, %{}), 0)
    assert {:error, :inconsistent_plan_evidence} = TaskLifecycle.assess(put_in(context.plan.authority["source"], "unread note"), 0)
    assert {:error, :inconsistent_plan_evidence} = TaskLifecycle.assess(put_in(context.plan.members[WorkRef.key(context.work)].contract["goal"], "Expanded"), 0)

    for {field, value} <- [{"dependencies", %{}}, {"deliveries", 2}, {"candidate", []}, {"active", nil}] do
      assert {:error, :incomplete_observation} = TaskLifecycle.assess(put_in(context.evidence[field], value), 0)
    end

    assert {:error, :incomplete_observation} = TaskLifecycle.assess(put_in(context.runtime["retry_count"], -1), 0)
    assert {:error, :legacy_lifecycle_requires_migration} = TaskLifecycle.assess(put_in(context.runtime["workflow"], TaskWorkflow.new(10_000, 0)), 0)
    assert {:error, :invalid_lifecycle_accounting} = TaskLifecycle.assess(put_in(context.runtime["workflow"], %{"schema_version" => 2}), 0)

    for {field, value} <- [{"restrictions", []}, {"restrictions", %{"pause" => nil}}, {"repair_history", []}, {"repair_history", %{"unknown" => -1}}, {"started", nil}] do
      broken = assess(context) |> Map.put(field, value)
      assert {:error, :invalid_lifecycle_accounting} = TaskLifecycle.assess(persist(context, broken), 0)
    end

    assert {:error, :incomplete_observation} = TaskLifecycle.assess(%{context | evidence: Map.delete(context.evidence, "candidate")}, 0)
  end

  test "only candidate artifacts from a recorded developer can select verification" do
    context = fixture() |> candidate()
    payload = context.evidence["candidate"]

    for change <- [%{"digest" => "fake"}, %{"actor" => "1"}, %{"source" => "deleted"}, %{"execution" => nil}, %{"execution" => %{"generation" => 99, "thread_id" => "invented"}}] do
      flow = assess(put_in(context.evidence["candidate"], Map.merge(payload, change)))
      assert flow["restrictions"]["candidate_invalid"]
      refute flow["dispatchable"]
    end

    for artifacts <- [nil, [nil], [], [%{"id" => "result", "kind" => "report", "version" => "v1", "source" => "deleted"}], [%{"id" => "result", "version" => "v1"}]] do
      changed = Map.put(payload, "artifacts", artifacts)
      changed = Map.put(changed, "digest", TaskWorkflow.digest(Map.take(changed, ~w(work contract_sha inputs artifacts))))
      assert assess(put_in(context.evidence["candidate"], changed))["restrictions"]["candidate_invalid"]
    end

    previous = assess(context)
    vanished = context |> persist(previous) |> put_in([:evidence, "candidate"], nil)
    assert assess(vanished)["restrictions"]["candidate_source_missing"]

    assert {:error, :invalid_persisted_execution_binding} =
             TaskLifecycle.assess(put_in(context.runtime["execution_binding_sha"], "corrupted"), 0)

    unbound = %{context | runtime: Map.take(context.runtime, ~w(thread_id execution_generation))}
    assert {:error, :execution_binding_required} = TaskLifecycle.assess(unbound, 0)
    unbound = %{context | runtime: %{"thread_id" => context.runtime["thread_id"]}}
    sample = put_in(unbound.evidence["candidate"]["execution"]["generation"], nil)
    assert assess(sample)["restrictions"]["candidate_invalid"]
  end

  test "verification cannot be self-review, fabricated execution or weaker replacement checks" do
    context = fixture() |> candidate() |> verified()
    verification = context.evidence["verification"]

    for change <- [
          %{"actor" => "1"},
          %{"source" => "deleted"},
          %{"execution" => context.evidence["candidate"]["execution"]},
          %{"execution" => nil},
          %{"checks" => nil},
          %{"checks" => [nil]},
          %{"findings" => nil}
        ] do
      assert assess(put_in(context.evidence["verification"], Map.merge(verification, change)))["restrictions"]["verification_invalid"]
    end

    [command, review] = verification["checks"]

    for check <- [Map.put(command, "command", "true"), Map.put(command, "output_sha", ""), Map.put(command, "candidate", "old"), Map.put(command, "source", "deleted")] do
      assert assess(put_in(context.evidence["verification"]["checks"], [check, review]))["restrictions"]["verification_invalid"]
    end

    # A command's result cannot be overridden by a review-shaped field, or vice versa.
    failed = Map.merge(command, %{"exit_code" => 1, "result" => "passed"})
    assert assess(put_in(context.evidence["verification"]["checks"], [failed, review]))["restrictions"]["failed_check_without_repair_evidence"]
    failed_review = Map.merge(review, %{"result" => "failed", "exit_code" => 0})
    assert assess(put_in(context.evidence["verification"]["checks"], [command, failed_review]))["restrictions"]["failed_check_without_repair_evidence"]
  end

  test "an older candidate, policy or input conclusion selects a new verifier instead of passing or deadlocking" do
    context = fixture() |> candidate() |> verified()

    for {field, value} <- [{"candidate", TaskWorkflow.digest("old")}, {"policy_sha", TaskWorkflow.digest("old policy")}, {"inputs", [%{"version" => "old"}]}] do
      flow = assess(put_in(context.evidence["verification"][field], value))
      assert flow["action"] == "verify"
      assert flow["dispatchable"]
      assert flow["evidence"] == "stale"
      refute flow["verification"]
    end
  end

  test "only valid findings within original criteria authorize repair" do
    context = fixture() |> candidate() |> verified()
    assert assess(with_finding(context))["action"] == "repair"

    for finding <- [nil, Map.put(finding(), "criterion", "new scope"), Map.put(finding(), "status", "unknown"), Map.put(finding(), "evidence", []), Map.put(finding(), "evidence", ["deleted"])] do
      flow = assess(with_finding(context, finding))
      assert flow["restrictions"]["unresolved_finding"]
      refute flow["dispatchable"]
    end

    for status <- ["fixed", "unsubstantiated"] do
      assert assess(with_finding(context, Map.put(finding(), "status", status)))["action"] == "deliver"
    end

    assert assess(with_finding(context, Map.put(finding(), "required", false)))["action"] == "deliver"
  end

  test "repair accounting survives reassessment, retries and republished unchanged findings" do
    context = fixture() |> candidate() |> verified() |> with_finding()
    flow = assess(context)
    assert {:ok, record} = ExecutionBinding.bind(context.runtime, flow["next_binding"])
    assert {:ok, started} = TaskLifecycle.start(flow, record, 1)
    assert started["repair_count"] == 1
    context = %{context | runtime: record} |> persist(started)
    retry = put_in(context.runtime["last_result"], "retryable_error")
    refute assess(retry, 2)["restrictions"]["repair_without_progress"]
    active = context |> put_in([:runtime, "thread_id"], "repair") |> put_in([:evidence, "active"], true)
    assert assess(active, 2)["state"] == "running"

    repeated = assess(context, 2)
    assert repeated["restrictions"]["repair_without_progress"]
    assert repeated["used_ms"] == 1
    renamed = Map.merge(finding(), %{"id" => "new-comment", "rationale" => "Different words; same failure", "evidence" => ["review"]})
    assert assess(with_finding(context, renamed), 2)["restrictions"]["repair_without_progress"]
    progress = Map.put(finding(), "repair_basis_sha", TaskWorkflow.digest("new reproduction: only empty input fails after the previous fix"))
    assert assess(with_finding(context, progress), 2)["dispatchable"]
    assert {:error, :lifecycle_start_not_admitted} = TaskLifecycle.start(repeated, record, 3)
    assert {:error, :lifecycle_start_not_admitted} = TaskLifecycle.start(flow, Map.put(record, "execution_generation", 0), 3)
    assert {:error, :lifecycle_start_not_admitted} = TaskLifecycle.start(flow, %{}, 3)
  end

  test "retry and repair caps are separate and waiting does not reset cumulative budget" do
    context = fixture() |> candidate() |> verified() |> with_finding()
    assert assess(put_in(context.policy["max_repairs"], 0))["action"] == "verify"
    # Reverify under the new policy before the repair cap is applied.
    capped = context |> put_in([:policy, "max_repairs"], 0) |> put_in([:evidence, "verification"], nil) |> verified() |> with_finding()
    assert assess(capped)["restrictions"]["repair_limit"]
    assert assess(put_in(context.runtime["retry_count"], 3))["restrictions"]["retry_limit"]
    flow = assess(context)
    assert {:ok, record} = ExecutionBinding.bind(context.runtime, flow["next_binding"])
    assert {:ok, started} = TaskLifecycle.start(flow, record, 0)
    spent = context |> persist(started) |> assess(10_000)
    assert spent["restrictions"]["budget"]
    assert spent["used_ms"] == 10_000
    assert assess(persist(context, spent), 9_000)["restrictions"]["clock"]
    assert {:error, :lifecycle_start_not_admitted} = TaskLifecycle.start(started |> Map.put("dispatchable", true), record, 10_000)
    assert {:error, :lifecycle_start_not_admitted} = TaskLifecycle.start(started |> Map.put("dispatchable", true), record, -1)
  end

  test "native controls survive disappearance and only their specific release clears them" do
    context = fixture()
    pause = %{"id" => "P1", "kind" => "pause", "source" => "pause", "scope" => "task"}
    paused = assess(put_in(context.evidence["restrictions"], [pause]))
    refute paused["dispatchable"]
    missing = context |> persist(paused)
    assert assess(missing)["restrictions"]["native:P1"]
    bad = put_in(missing.evidence["releases"], [%{"id" => "P1", "restriction_source" => "other", "source" => "resume"}])
    assert assess(bad)["restrictions"]["unresolved_control_release"]
    good = put_in(missing.evidence["releases"], [%{"id" => "P1", "restriction_source" => "pause", "source" => "resume"}])
    assert assess(good)["dispatchable"]
    assert assess(persist(good, assess(good)))["dispatchable"]
    assert assess(put_in(context.evidence["releases"], [nil]))["restrictions"]["unresolved_control_release"]

    for restriction <- [nil, Map.put(pause, "scope", ["new scope"]), Map.put(pause, "source", "deleted")] do
      assert assess(put_in(context.evidence["restrictions"], [restriction]))["restrictions"]["unresolved_control"]
    end
  end

  test "released controls remain source-bound across restart and missing evidence prevents execution" do
    context = fixture()
    receipts = %{"pause-note" => "pause", "resume-note" => "resume"}
    context = put_in(context.evidence["control_receipts"], receipts)
    flow = assess(context)
    assert flow["dispatchable"]
    assert flow["control_receipts"] == receipts
    restored = persist(context, flow)
    assert assess(restored)["dispatchable"]

    for current <- [%{}, %{"pause-note" => "pause"}, %{"pause-note" => "changed"}, [], %{"resume-note" => nil}] do
      changed = put_in(restored.evidence["control_receipts"], current)
      assert assess(changed)["restrictions"]["native_control_source"]
      refute assess(changed)["dispatchable"]
    end

    missing = put_in(restored.evidence["sources"], ["pause"])
    assert assess(missing)["restrictions"]["native_control_source"]
    publisher = put_in(context.runtime["control_receipts"], %{"newer" => "different"})
    assert assess(publisher)["restrictions"]["native_control_source"]
  end

  test "delivery transformations and optional child gates bind the exact candidate" do
    context = fixture(human_gate: true) |> candidate() |> verified() |> delivered()
    assert assess(context)["restrictions"]["child_acceptance"]
    acceptance = %{"actor" => "2", "source" => "accept", "candidate" => context.evidence["candidate"]["digest"]}
    assert assess(put_in(context.evidence["acceptance"], acceptance))["outcome"] == "delivered"
    assert assess(put_in(context.evidence["acceptance"], Map.put(acceptance, "candidate", "old")))["outcome"] == "open"

    context = fixture() |> candidate() |> verified()
    transformed = %{"artifact" => "result", "source_version" => "v1", "delivered_version" => "merged", "source" => "delivery"}
    assert assess(put_in(context.evidence["deliveries"], [transformed]))["outcome"] == "open"
    transformed = Map.merge(transformed, %{"mapping" => "mapping", "delivered_checks" => "delivered_checks"})
    assert assess(put_in(context.evidence["deliveries"], [transformed]))["outcome"] == "delivered"
    assert assess(put_in(context.evidence["deliveries"], [transformed, transformed]))["outcome"] == "open"
    assert assess(put_in(context.evidence["deliveries"], [nil]))["outcome"] == "open"
  end

  test "live or uncertain executions cannot be replaced or closed, and changed conclusions cannot silently reopen" do
    context = fixture() |> candidate()
    active = context |> put_in([:runtime, "native_stop_confirmed"], false) |> put_in([:evidence, "active"], true)
    flow = assess(active)
    assert flow["stop_required"]
    assert flow["execution"] == "stopping"
    refute flow["dispatchable"]
    assert assess(put_in(active.evidence["active"], false))["restrictions"]["native_stop"]
    uncertain = fixture() |> put_in([:runtime, "thread_allocation_intent"], true)
    assert assess(uncertain)["restrictions"]["native_stop"]
    pending_check = put_in(context.runtime["check_runs"], %{"pending" => %{"status" => "running"}})
    assert assess(pending_check)["restrictions"]["native_stop"]

    complete = context |> verified() |> delivered()
    active = complete |> put_in([:runtime, "native_stop_confirmed"], false) |> put_in([:evidence, "active"], true)
    refute assess(active)["outcome"] == "delivered"
    assert assess(active)["stop_required"]
    changed = complete |> persist(assess(complete)) |> put_in([:evidence, "deliveries"], [])
    assert assess(changed)["restrictions"]["conclusion_changed"]
    refute assess(changed)["dispatchable"]
    pause = %{"id" => "P1", "kind" => "pause", "source" => "pause", "scope" => "task"}
    refute assess(put_in(complete.evidence["restrictions"], [pause]))["closeable"]
  end

  test "real journal admission refuses verifier replacement until the developer native stop is recorded" do
    root = Path.join(System.tmp_dir!(), "lifecycle-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    context = fixture()
    now = System.system_time(:millisecond)
    first = assess(context, now)
    {:ok, developer} = RunJournal.admit(root, "member", execution_binding: first["next_binding"])
    assert {:ok, started} = TaskLifecycle.start(first, developer, now)
    {:ok, developer} = RunJournal.checkpoint(developer, %{"workflow" => started, "thread_id" => "native-developer", "thread_allocation_intent" => true})
    sample = candidate(context).evidence["candidate"]
    context = %{context | runtime: developer} |> put_in([:evidence, "candidate"], Map.put(sample, "execution", receipt(developer)))
    projection = assess(context, System.system_time(:millisecond))
    refute projection["dispatchable"]
    # The journal independently fences a caller attempting to bypass that projection.
    assert :ok = RunJournal.complete(developer, "completed")
    binding = %{first["next_binding"] | "role" => "verifier", "candidate" => sample["digest"]}
    assert {:error, :execution_generation_requires_native_stop} = RunJournal.admit(root, "member", execution_binding: binding)
    {:ok, developer} = RunJournal.admit(root, "member", execution_binding: first["next_binding"])
    {:ok, developer} = RunJournal.checkpoint(developer, %{"native_stop_confirmed" => true})
    assert :ok = RunJournal.complete(developer, "completed")
    context = %{context | runtime: developer}
    ready = assess(context, System.system_time(:millisecond))
    assert ready["dispatchable"]
    {:ok, verifier} = RunJournal.admit(root, "member", execution_binding: ready["next_binding"])
    assert verifier["execution_generation"] == 2
    refute verifier["thread_id"]
    assert {:ok, _} = TaskLifecycle.start(ready, verifier, System.system_time(:millisecond))
    assert :ok = RunJournal.complete(verifier, "completed")
  end

  defp dependent(context, stage) do
    producer = %{context.work | "provider" => "gitlab", "host" => "gitlab.test", "repository_id" => "2"}
    member = hd(context.plan.plan["members"]) |> Map.put("work", producer)
    edge = %{"from" => producer, "to" => context.work, "artifact" => "upstream", "stage" => stage, "criteria" => ["result"]}

    {:ok, plan} =
      context.plan.plan
      |> Map.put("members", context.plan.plan["members"] ++ [member])
      |> Map.put("dependencies", [edge])
      |> Map.put("budget_ms", 20_000)
      |> TaskPlan.seal()

    context = context |> put_in([:plan, :plan], plan) |> put_in([:plan, :authority, "revision"], plan["revision"])
    proof = %{"work" => producer, "artifact" => "upstream", "version" => "fixed", "stage" => "verified", "criteria" => ["result"], "verification" => "verification", "retrieval" => "artifact"}
    {context, proof}
  end

  test "dependencies require unique retrievable evidence at the sealed stage and pin consumer input versions" do
    {context, proof} = dependent(fixture(), "verified")
    assert assess(context)["restrictions"]["dependencies"]

    for proofs <- [[nil], [proof, proof], [Map.put(proof, "criteria", [])], [Map.put(proof, "retrieval", "deleted")], [Map.put(proof, "stage", "closed")]] do
      flow = assess(put_in(context.evidence["dependencies"], proofs))
      assert flow["restrictions"]["dependencies"]
      refute flow["dispatchable"]
    end

    ready = put_in(context.evidence["dependencies"], [proof])
    assert assess(ready)["dispatchable"]
    assert assess(ready)["next_binding"]["inputs"] == [Map.take(proof, ~w(work artifact version verification))]
    executing = candidate(ready)
    changed = put_in(executing.evidence["dependencies"], [Map.put(proof, "version", "new")])
    assert assess(changed)["restrictions"]["candidate_invalid"]
    {published, proof} = dependent(fixture(), "published")
    assert assess(put_in(published.evidence["dependencies"], [proof]))["restrictions"]["dependencies"]
    assert assess(put_in(published.evidence["dependencies"], [Map.put(proof, "stage", "published")]))["dispatchable"]
  end

  test "budget charging stops only after a human wait is natively stopped and resumes without a reset" do
    context = fixture()
    flow = assess(context)
    {:ok, record} = ExecutionBinding.bind(context.runtime, flow["next_binding"])
    {:ok, started} = TaskLifecycle.start(flow, record, 0)
    record = Map.merge(record, %{"workflow" => started, "thread_id" => "running", "native_stop_confirmed" => false})
    pause = %{"id" => "P1", "kind" => "pause", "source" => "pause", "scope" => "task"}
    context = %{context | runtime: record} |> put_in([:evidence, "active"], true) |> put_in([:evidence, "restrictions"], [pause])
    stopping = assess(context, 5)
    assert stopping["charging"]
    assert stopping["stop_required"]
    context = context |> persist(stopping) |> put_in([:runtime, "native_stop_confirmed"], true) |> put_in([:evidence, "active"], false)
    stopped = assess(context, 10)
    refute stopped["charging"]
    assert stopped["used_ms"] == 10
    assert assess(persist(context, stopped), 100)["used_ms"] == 10
    context = context |> persist(stopped) |> put_in([:evidence, "restrictions"], [])
    context = put_in(context.evidence["releases"], [%{"id" => "P1", "restriction_source" => "pause", "source" => "resume"}])
    resumed = assess(context, 100)
    assert resumed["charging"]
    assert resumed["used_ms"] == 10
    assert resumed["dispatchable"]
  end
end
