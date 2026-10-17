defmodule SymphonyElixir.TaskLifecycle do
  @moduledoc """
  Derive a plan member's phase, required role and restrictions from current facts.

  Provider adapters own native identity, source readback and artifact retrieval.
  This reducer consumes their resolved evidence; it never interprets an Issue
  being closed, an agent exit or an author-supplied boolean as verification.
  A projection is not a replacement task store or permission to perform an effect.
  """
  alias SymphonyElixir.{ExecutionBinding, TaskDecision, TaskPlan, TaskWorkflow, WorkRef}

  @stages %{"verified" => 1, "delivered" => 2, "published" => 3}

  @doc "Assess one member of a completely preflighted plan without performing side effects."
  @spec assess(map(), integer()) :: {:ok, map()} | {:error, atom()}
  def assess(%{plan: %{plan: _, members: _, authority: _, parent: _}, work: _, runtime: runtime, evidence: evidence, policy: _} = context, now)
      when is_map(runtime) and is_map(evidence) and is_integer(now) do
    with :ok <- TaskPlan.validate(context.plan.plan),
         :ok <- WorkRef.validate(context.work),
         %{} = member <- context.plan.members[WorkRef.key(context.work)],
         {:ok, _} <- TaskPlan.member(context.plan.plan, context.work, member.contract["contract_sha"]),
         true <- native_scope?(context, member) or {:error, :inconsistent_plan_evidence},
         :ok <- policy(context.policy, member.contract),
         :ok <- observation(context.evidence, context.runtime),
         {:ok, flow} <- ledger(context.runtime["workflow"], member.contract["budget_ms"], now) do
      context = Map.put(context, :member, member)
      flow = flow |> TaskWorkflow.tick(now) |> baseline(context) |> select_inputs(context)
      flow = flow |> select_candidate(context) |> select_verification(context) |> select_delivery(context)
      {:ok, flow |> limits(context) |> execution(context) |> projection(context)}
    else
      {:error, _} = error -> error
      _ -> {:error, :missing_plan_member}
    end
  end

  def assess(_, _), do: {:error, :incomplete_observation}

  defp native_scope?(context, member) do
    plan = context.plan.plan
    authority = context.plan.authority
    contract = member.contract

    authority_matches?(authority, plan, context.plan.parent.notes) and member.work == context.work and
      contract["work"] == context.work and contract["parent"] == plan["parent"] and
      contract["contract_sha"] == TaskWorkflow.digest(Map.delete(contract, "contract_sha"))
  end

  defp authority_matches?(authority, plan, notes) do
    authority["work"] == plan["parent"] and authority["actor"] == plan["authorizer"] and authority["revision"] == plan["revision"] and
      authority["source"] in Enum.map(notes, &TaskDecision.source_ref/1)
  end

  defp policy(policy, contract) when is_map(policy) do
    valid =
      nonnegative?(policy["max_retries"]) and nonnegative?(policy["max_repairs"]) and text?(policy["engine_actor"]) and
        check_assignments?(policy["checks"], contract["verification_checks"], contract["criteria"])

    if valid, do: :ok, else: {:error, :incomplete_verification_policy}
  end

  defp policy(_, _), do: {:error, :incomplete_verification_policy}

  defp check_assignments?(checks, assignments, criteria) when is_map(checks) and is_map(assignments) do
    map_size(checks) > 0 and Enum.all?(checks, &check_policy?/1) and
      Enum.sort(Map.keys(assignments)) == Enum.sort(criteria) and
      Enum.all?(Map.values(assignments), &(strings?(&1) and Enum.all?(&1, fn id -> Map.has_key?(checks, id) end)))
  end

  defp check_assignments?(_, _, _), do: false
  defp check_policy?({id, %{"kind" => "review"}}), do: text?(id)
  defp check_policy?({id, %{"kind" => "command", "command" => command}}), do: text?(id) and text?(command)
  defp check_policy?(_), do: false

  defp observation(evidence, runtime) do
    lists = ~w(sources restrictions releases dependencies deliveries)
    objects = ~w(candidate verification acceptance)

    valid =
      Enum.all?(lists, &is_list(evidence[&1])) and Enum.all?(objects, &nullable_object?(evidence, &1)) and
        is_boolean(evidence["active"]) and is_list(Map.get(runtime, "execution_history", [])) and
        nonnegative?(Map.get(runtime, "retry_count", 0))

    if valid do
      case ExecutionBinding.bind(runtime, runtime["execution_binding"]) do
        {:ok, _} -> :ok
        {:error, _} = error -> error
      end
    else
      {:error, :incomplete_observation}
    end
  end

  defp nullable_object?(evidence, key), do: Map.has_key?(evidence, key) and (is_nil(evidence[key]) or is_map(evidence[key]))

  defp ledger(nil, budget, now), do: {:ok, TaskWorkflow.new(budget, now) |> Map.put("schema_version", 2) |> Map.put("repair_history", %{})}

  defp ledger(%{"schema_version" => 2} = flow, budget, _now) do
    if nonnegative?(flow["used_ms"]) and is_integer(flow["clock_at"]) and is_boolean(flow["charging"]) and
         restrictions?(flow["restrictions"]) and repair_history?(flow["repair_history"]) and is_boolean(flow["started"]),
       do: {:ok, Map.put(flow, "budget_ms", budget)},
       else: {:error, :invalid_lifecycle_accounting}
  end

  defp ledger(_, _, _), do: {:error, :legacy_lifecycle_requires_migration}

  defp restrictions?(items) when is_map(items), do: Enum.all?(items, fn {id, item} -> text?(id) and is_map(item) end)
  defp restrictions?(_), do: false
  defp repair_history?(items) when is_map(items), do: Enum.all?(items, fn {id, generation} -> digest?(id) and is_integer(generation) and generation > 0 end)
  defp repair_history?(_), do: false

  defp baseline(flow, context) do
    previous = Map.take(flow, ~w(candidate verification outcome contract_sha))
    restrictions = Map.filter(flow["restrictions"], fn {id, item} -> id == "clock" or item["native"] == true end)

    flow =
      Map.merge(flow, %{
        "work" => context.work,
        "plan_revision" => context.plan.plan["revision"],
        "contract_sha" => context.member.contract["contract_sha"],
        "authority" => context.plan.authority,
        "phase" => "ready",
        "outcome" => "open",
        "action" => "implement",
        "evidence" => "current",
        "candidate" => nil,
        "verification" => nil,
        "repair_signature" => nil,
        "restrictions" => restrictions,
        "previous" => previous,
        "contract" => Map.take(context.member.contract, ~w(criteria acceptance_mode acceptor))
      })

    flow = Enum.reduce(context.evidence["releases"], flow, &native_release(&2, &1, context))
    flow = Enum.reduce(context.evidence["restrictions"], flow, &native_restriction(&2, &1, context))
    flow = if context.plan.parent.raw["state"] in ["open", "opened"], do: flow, else: restrict(flow, "parent_closed", "evidence")
    if context.member.raw["state"] in ["open", "opened"], do: flow, else: restrict(flow, "native_closed", "evidence")
  end

  defp native_restriction(flow, %{"id" => id, "kind" => kind, "source" => source, "scope" => scope} = restriction, context) do
    if text?(id) and kind in ~w(pause cancel decision scope dependency budget evidence acceptance) and source?(context, source) and
         (scope == "task" or (strings?(scope) and Enum.all?(scope, &(&1 in context.member.contract["criteria"])))) do
      put_in(flow, ["restrictions", "native:" <> id], Map.take(restriction, ~w(kind source scope)) |> Map.put("native", true))
    else
      restrict(flow, "unresolved_control", "decision")
    end
  end

  defp native_restriction(flow, _, _), do: restrict(flow, "unresolved_control", "decision")

  defp native_release(flow, %{"id" => id, "restriction_source" => prior, "source" => source}, context) when is_binary(id) do
    current = flow["restrictions"]["native:" <> id]

    cond do
      is_nil(current) -> flow
      current["source"] == prior and source?(context, source) -> clear(flow, "native:" <> id)
      true -> restrict(flow, "unresolved_control_release", "decision")
    end
  end

  defp native_release(flow, _, _), do: restrict(flow, "unresolved_control_release", "decision")

  defp select_inputs(flow, context) do
    edges = Enum.filter(context.plan.plan["dependencies"], &(&1["to"] == context.work))
    inputs = Enum.map(edges, &input(&1, context))

    if Enum.all?(inputs, &is_map/1),
      do: Map.put(flow, "inputs", Enum.sort_by(inputs, &{WorkRef.key(&1["work"]), &1["artifact"]})),
      else: flow |> Map.put("inputs", []) |> restrict("dependencies", "dependency")
  end

  defp input(edge, context) do
    matches = Enum.filter(context.evidence["dependencies"] || [], &(is_map(&1) and &1["work"] == edge["from"] and &1["artifact"] == edge["artifact"]))

    case matches do
      [proof] -> if dependency?(proof, edge, context), do: Map.take(proof, ~w(work artifact version verification))
      _ -> nil
    end
  end

  defp dependency?(proof, edge, context) do
    text?(proof["version"]) and source?(context, proof["verification"]) and source?(context, proof["retrieval"]) and
      is_list(proof["criteria"]) and Enum.all?(edge["criteria"], &(&1 in proof["criteria"])) and
      Map.get(@stages, proof["stage"], 0) >= @stages[edge["stage"]]
  end

  defp select_candidate(flow, %{evidence: %{"candidate" => nil}}) do
    if flow["previous"]["candidate"], do: restrict(flow, "candidate_source_missing", "evidence"), else: flow
  end

  defp select_candidate(flow, context) do
    candidate = context.evidence["candidate"]

    if candidate?(candidate, flow, context) do
      Map.merge(flow, %{"candidate" => candidate["digest"], "phase" => "verifying", "action" => "verify"})
    else
      flow |> Map.put("evidence", "unknown") |> restrict("candidate_invalid", "evidence")
    end
  end

  defp candidate?(candidate, flow, context) do
    payload = Map.take(candidate, ~w(work contract_sha inputs artifacts))

    candidate["digest"] == TaskWorkflow.digest(payload) and candidate["work"] == context.work and
      candidate["contract_sha"] == flow["contract_sha"] and candidate["inputs"] == flow["inputs"] and
      publication?(candidate, context) and execution_receipt?(candidate["execution"], "developer", nil, flow, context) and
      artifacts?(candidate["artifacts"], context.member.contract["deliverables"], context)
  end

  defp artifacts?(artifacts, outputs, context) when is_list(artifacts) do
    Enum.all?(artifacts, &is_map/1) and length(artifacts) == length(outputs) and length(Enum.uniq_by(artifacts, & &1["id"])) == length(outputs) and
      Enum.all?(outputs, fn output ->
        case Enum.find(artifacts, &(&1["id"] == output["id"])) do
          %{"kind" => kind, "version" => version, "source" => source} ->
            kind == output["kind"] and text?(version) and source?(context, source)

          _ ->
            false
        end
      end)
  end

  defp artifacts?(_, _, _), do: false

  defp execution_receipt?(%{"generation" => generation, "thread_id" => thread}, role, candidate, flow, context) do
    receipts = [context.runtime | context.runtime["execution_history"] || []]

    Enum.any?(receipts, fn record ->
      is_map(record) and record["execution_generation"] == generation and text?(thread) and record["thread_id"] == thread and
        receipt_binding?(record["execution_binding"], role, candidate, flow, context)
    end)
  end

  defp execution_receipt?(_, _, _, _, _), do: false

  defp receipt_binding?(binding, role, candidate, flow, context) when is_map(binding) do
    binding["work"] == context.work and binding["role"] == role and binding["contract_sha"] == flow["contract_sha"] and
      binding["authority"] == flow["authority"] and binding["inputs"] == flow["inputs"] and
      (is_nil(candidate) or binding["candidate"] == candidate) and current_policy?(binding, role, context)
  end

  defp receipt_binding?(_, _, _, _, _), do: false
  defp current_policy?(binding, "verifier", context), do: binding["policy_sha"] == TaskWorkflow.digest(context.policy)
  defp current_policy?(_, _, _), do: true

  defp select_verification(%{"candidate" => nil} = flow, _), do: flow
  defp select_verification(flow, %{evidence: %{"verification" => nil}}), do: flow

  defp select_verification(flow, context) do
    verification = context.evidence["verification"]

    cond do
      not verification_target?(verification, flow, context) ->
        Map.put(flow, "evidence", "stale")

      verification?(verification, flow, context) ->
        flow |> Map.put("verification", verification["source"]) |> findings(verification, context)

      true ->
        flow |> Map.put("evidence", "unknown") |> restrict("verification_invalid", "evidence")
    end
  end

  defp verification_target?(verification, flow, context) do
    verification["candidate"] == flow["candidate"] and verification["policy_sha"] == TaskWorkflow.digest(context.policy) and
      verification["inputs"] == flow["inputs"]
  end

  defp verification?(verification, flow, context) do
    publication?(verification, context) and
      execution_receipt?(verification["execution"], "verifier", flow["candidate"], flow, context) and
      verification["execution"]["thread_id"] != context.evidence["candidate"]["execution"]["thread_id"] and
      checks?(verification["checks"], flow, context) and is_list(verification["findings"])
  end

  defp checks?(checks, flow, context) when is_list(checks) do
    required = context.member.contract["verification_checks"] |> Map.values() |> List.flatten() |> Enum.uniq()

    Enum.all?(checks, &is_map/1) and Enum.sort(Enum.map(checks, & &1["id"])) == Enum.sort(required) and
      Enum.all?(checks, fn check ->
        check["candidate"] == flow["candidate"] and source?(context, check["source"]) and check_result?(check, context.policy["checks"][check["id"]])
      end)
  end

  defp checks?(_, _, _), do: false

  defp check_result?(check, %{"kind" => "command", "command" => command}),
    do: check["command"] == command and is_integer(check["exit_code"]) and digest?(check["output_sha"])

  defp check_result?(check, %{"kind" => "review"}), do: check["result"] in ["passed", "failed"] and text?(check["rationale"])
  defp passed?(check, %{"kind" => "command"}), do: check["exit_code"] == 0
  defp passed?(check, %{"kind" => "review"}), do: check["result"] == "passed"

  defp findings(flow, verification, context) do
    findings = verification["findings"]

    if Enum.all?(findings, &finding?(&1, context)) do
      required = Enum.filter(findings, &(&1["required"] and &1["status"] == "valid"))

      cond do
        Enum.any?(findings, &(&1["status"] == "unknown")) ->
          restrict(flow, "unresolved_finding", "decision")

        required != [] ->
          repair(flow, required, context)

        Enum.all?(verification["checks"], &passed?(&1, context.policy["checks"][&1["id"]])) ->
          Map.merge(flow, %{"phase" => "verified", "action" => "deliver"})

        true ->
          restrict(flow, "failed_check_without_repair_evidence", "decision")
      end
    else
      restrict(flow, "unresolved_finding", "decision")
    end
  end

  defp finding?(finding, context) when is_map(finding) do
    text?(finding["id"]) and finding["criterion"] in context.member.contract["criteria"] and
      finding["status"] in ["valid", "fixed", "unsubstantiated", "unknown"] and is_boolean(finding["required"]) and
      text?(finding["rationale"]) and Enum.all?(~w(problem_sha repair_basis_sha), &digest?(finding[&1])) and
      strings?(finding["evidence"]) and Enum.all?(finding["evidence"], &source?(context, &1))
  end

  defp finding?(_, _), do: false

  defp repair(flow, findings, context) do
    signature = findings |> Enum.map(&Map.take(&1, ~w(criterion problem_sha repair_basis_sha))) |> Enum.uniq() |> Enum.sort() |> TaskWorkflow.digest()
    flow = Map.merge(flow, %{"phase" => "ready", "action" => "repair", "repair_signature" => signature})
    prior = flow["repair_history"][signature]
    retrying = prior == context.runtime["execution_generation"] and context.runtime["last_result"] == "retryable_error"
    active = prior == context.runtime["execution_generation"] and context.evidence["active"] == true
    if is_nil(prior) or retrying or active, do: flow, else: restrict(flow, "repair_without_progress", "decision")
  end

  defp select_delivery(%{"phase" => "verified"} = flow, context) do
    artifacts = context.evidence["candidate"]["artifacts"]
    delivered = Enum.all?(artifacts, &delivered?(&1, context))
    accepted = context.member.contract["acceptance_mode"] == "technical" or accepted?(flow, context)

    cond do
      not delivered -> Map.put(flow, "phase", "delivering")
      not accepted -> flow |> Map.put("phase", "delivering") |> restrict("child_acceptance", "acceptance")
      true -> flow |> Map.merge(%{"phase" => "completed", "outcome" => "delivered", "action" => "close"}) |> clear("native_closed")
    end
  end

  defp select_delivery(flow, _), do: flow

  defp delivered?(artifact, context) do
    case Enum.filter(context.evidence["deliveries"] || [], &(is_map(&1) and &1["artifact"] == artifact["id"])) do
      [receipt] ->
        receipt["source_version"] == artifact["version"] and text?(receipt["delivered_version"]) and
          source?(context, receipt["source"]) and delivery_mapping?(receipt, context)

      _ ->
        false
    end
  end

  defp delivery_mapping?(%{"source_version" => version, "delivered_version" => version}, _), do: true
  defp delivery_mapping?(receipt, context), do: source?(context, receipt["mapping"]) and source?(context, receipt["delivered_checks"])

  defp accepted?(flow, context) do
    acceptance = context.evidence["acceptance"] || %{}
    acceptance["candidate"] == flow["candidate"] and acceptance["actor"] == context.member.contract["acceptor"] and source?(context, acceptance["source"])
  end

  defp limits(flow, context) do
    flow = if flow["used_ms"] >= flow["budget_ms"], do: restrict(flow, "budget", "budget"), else: flow
    flow = if (context.runtime["retry_count"] || 0) > context.policy["max_retries"], do: restrict(flow, "retry_limit", "decision"), else: flow
    prior = flow["repair_history"][flow["repair_signature"]]
    count = map_size(flow["repair_history"])
    if flow["action"] == "repair" and is_nil(prior) and count >= context.policy["max_repairs"], do: restrict(flow, "repair_limit", "decision"), else: flow
  end

  defp execution(flow, context) do
    state = execution_state(context.runtime, context.evidence["active"])
    flow = Map.put(flow, "execution", state)
    flow = if state == "uncertain", do: restrict(flow, "native_stop", "evidence"), else: flow
    if flow["phase"] == "completed" and state not in ["idle", "stopped"], do: %{flow | "phase" => "delivering", "outcome" => "open"}, else: flow
  end

  defp execution_state(record, active) do
    cond do
      record["native_stop_confirmed"] == true and text?(record["thread_id"]) -> "stopped"
      active and text?(record["thread_id"]) -> "active"
      record["thread_allocation_intent"] == true or text?(record["thread_id"]) -> "uncertain"
      true -> "idle"
    end
  end

  defp projection(flow, context) do
    flow = conclusion(flow)
    role = if flow["action"] == "verify", do: "verifier", else: "developer"

    binding = %{
      "work" => context.work,
      "role" => role,
      "plan_revision" => flow["plan_revision"],
      "contract_sha" => flow["contract_sha"],
      "authority" => flow["authority"],
      "inputs" => flow["inputs"],
      "candidate" => flow["candidate"],
      "policy_sha" => TaskWorkflow.digest(context.policy)
    }

    can_run = map_size(flow["restrictions"]) == 0 and flow["action"] in ~w(implement verify repair deliver)
    same = context.runtime["execution_binding"] == binding
    stop = flow["execution"] == "active" and (not can_run or not same)
    allowed = if can_run, do: context.member.contract["criteria"], else: []

    flow =
      Map.merge(flow, %{
        "next_binding" => if(can_run, do: binding),
        "dispatchable" => can_run and stopped?(flow),
        "stop_required" => stop,
        "closeable" => closeable?(flow),
        "allowed_criteria" => allowed,
        "state" => run_state(can_run, flow["execution"], stop)
      })

    flow = if stop, do: Map.put(flow, "execution", "stopping"), else: flow
    flow |> charge() |> Map.delete("previous")
  end

  defp conclusion(flow) do
    if flow["previous"]["outcome"] == "delivered" and flow["outcome"] != "delivered",
      do: restrict(flow, "conclusion_changed", "decision"),
      else: flow
  end

  defp stopped?(flow), do: flow["execution"] in ["idle", "stopped"]
  defp closeable?(flow), do: flow["phase"] == "completed" and map_size(flow["restrictions"]) == 0

  defp charge(flow) do
    waiting = TaskWorkflow.human_wait?(flow) or flow["phase"] == "completed"
    Map.put(flow, "charging", flow["started"] and not (stopped?(flow) and waiting))
  end

  defp run_state(true, "active", false), do: "running"
  defp run_state(true, state, _) when state in ["idle", "stopped"], do: "ready"
  defp run_state(_, _, _), do: "waiting"

  @doc "Record an admitted role start; counting a repair requires an actual execution generation."
  @spec start(map(), map(), integer()) :: {:ok, map()} | {:error, atom()}
  def start(flow, record, now) do
    with true <- flow["dispatchable"] == true and map_size(flow["restrictions"]) == 0,
         {:ok, binding} <- ExecutionBinding.normalize(flow["next_binding"]),
         true <- record["execution_binding"] == binding,
         {:ok, ^record} <- ExecutionBinding.bind(record, binding),
         flow = TaskWorkflow.tick(flow, now),
         true <- map_size(flow["restrictions"]) == 0 and flow["used_ms"] < flow["budget_ms"] do
      history = flow["repair_history"]
      history = if flow["action"] == "repair", do: Map.put_new(history, flow["repair_signature"], record["execution_generation"]), else: history
      {:ok, flow |> TaskWorkflow.start(now) |> Map.put("repair_history", history) |> Map.put("repair_count", map_size(history))}
    else
      _ -> {:error, :lifecycle_start_not_admitted}
    end
  end

  defp publication?(value, context), do: value["actor"] == context.policy["engine_actor"] and source?(context, value["source"])
  defp source?(context, source), do: text?(source) and source in context.evidence["sources"]
  defp restrict(flow, id, kind), do: put_in(flow, ["restrictions", id], %{"kind" => kind, "scope" => "task", "source" => "reconciliation"})
  defp clear(flow, id), do: Map.update!(flow, "restrictions", &Map.delete(&1, id))
  defp text?(value), do: is_binary(value) and String.trim(value) != ""
  defp digest?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)
  defp strings?(values) when is_list(values) and values != [], do: Enum.all?(values, &text?/1) and Enum.uniq(values) == values
  defp strings?(_), do: false
  defp nonnegative?(value), do: is_integer(value) and value >= 0
end
