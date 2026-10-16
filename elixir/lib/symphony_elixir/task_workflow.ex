defmodule SymphonyElixir.TaskWorkflow do
  @moduledoc "Execution controls and evidence references derived from repository decisions."

  @human ["pause", "decision", "review", "acceptance", "scope", "cancel"]

  @spec digest(term()) :: String.t()
  def digest(value), do: :crypto.hash(:sha256, Jason.encode!(value)) |> Base.encode16(case: :lower)

  @spec new(non_neg_integer(), integer()) :: map()
  def new(budget, now) do
    %{
      "schema_version" => 1,
      "state" => "ready",
      "budget_ms" => budget,
      "used_ms" => 0,
      "clock_at" => now,
      "charging" => false,
      "restrictions" => %{},
      "released" => %{},
      "events" => %{},
      "contract" => nil,
      "manifest" => nil,
      "acceptance" => nil,
      "resume_requested" => false,
      "routing_removed" => false,
      "started" => false
    }
  end

  @spec reconcile(map(), map(), [map()], integer()) :: map()
  def reconcile(flow, facts, events, now) do
    flow
    |> tick(now)
    |> check_reopen(facts)
    |> apply_events(events, facts)
    |> check_baseline(facts)
    |> check_decision_sources(facts)
    |> check_manifest(facts)
    |> check_conditions(facts)
    |> check_budget()
    |> check_conclusion_conflict()
    |> check_closure(facts)
    |> derive(facts)
  end

  @spec tick(map(), integer()) :: map()
  def tick(flow, now) do
    elapsed = if flow["charging"], do: max(0, now - flow["clock_at"]), else: 0
    flow = if now < flow["clock_at"], do: automatic(flow, "clock", "decision"), else: flow
    flow |> Map.update!("used_ms", &(&1 + elapsed)) |> Map.put("clock_at", max(now, flow["clock_at"]))
  end

  defp apply_events(flow, events, facts) do
    events
    |> Enum.sort_by(&{&1["at"], &1["id"], &1["version"]})
    |> Enum.reduce(flow, fn event, acc ->
      key = event["ref"]

      if Map.has_key?(acc["events"], key) do
        acc
      else
        {updated, outcome} = apply_event(acc, event, facts)
        put_in(updated, ["events", key], outcome)
      end
    end)
  end

  defp apply_event(flow, %{"action" => "authorize"} = event, facts) do
    data = event["data"]
    owner = get_in(flow, ["contract", "authorizer"]) || facts["owner"]

    if event["actor"] == owner and valid_contract?(data, facts) and newer?(event, flow["contract"]) do
      contract = Map.take(data, ["issue_version", "type", "criteria", "deliverables", "acceptance_mode", "acceptor", "reviewers", "deadline"])
      contract = Map.merge(contract, Map.put(order(event), "authorizer", owner))
      updated = %{flow | "contract" => contract, "manifest" => nil, "acceptance" => nil, "budget_ms" => data["budget_ms"] || flow["budget_ms"]}
      updated = Map.put(updated, "cancellation", nil)
      updated = updated |> Map.put("delivery_order", order(event)) |> Map.put("acceptance_order", order(event))
      {updated |> clear("baseline") |> install_dependencies(event), "authorized"}
    else
      {flow, "rejected_authorization"}
    end
  end

  defp apply_event(%{"contract" => nil} = flow, _event, _facts), do: {flow, "missing_authorization"}

  defp apply_event(flow, event, _facts) do
    cond do
      event["contract"] != flow["contract"]["ref"] -> {flow, "stale_contract"}
      obsolete_delivery?(flow, event) -> {flow, "obsolete_delivery_decision"}
      permitted?(flow["contract"], event) -> transition(flow, event)
      true -> {flow, "no_authorized_transition"}
    end
  end

  defp permitted?(contract, event) do
    actor = event["actor"]

    case event["action"] do
      action when action in ["pause", "cancel", "restrict", "resume", "release", "budget"] -> actor == contract["authorizer"]
      "rework" -> actor in [contract["acceptor"] | contract["reviewers"] || []]
      "manifest" -> actor in [contract["authorizer"], contract["acceptor"]]
      "accept" -> actor == contract["acceptor"]
      _ -> false
    end
  end

  defp transition(flow, %{"action" => action} = event) when action in ["pause", "cancel", "restrict"] do
    data = event["data"]
    kind = if action == "restrict", do: data["kind"] || "decision", else: action
    id = data["restriction"] || event["ref"]
    scope = if action in ["pause", "cancel"], do: "task", else: data["scope"] || "task"
    updated = restrict(flow, id, kind, scope, event) |> add_condition(id, data["condition"])
    updated = record_cancellation(updated, event)
    {updated, "restricted"}
  end

  defp transition(flow, %{"action" => action} = event) when action in ["resume", "release"] do
    updated = Enum.reduce(event["data"]["restrictions"] || [], flow, &release(&2, &1, event))
    {Map.put(updated, "resume_requested", true), "released_selected_restrictions"}
  end

  defp transition(flow, %{"action" => "budget", "data" => %{"add_ms" => amount}}) when is_integer(amount) and amount > 0 do
    updated = flow |> Map.update!("budget_ms", &(&1 + amount)) |> clear("budget") |> Map.put("resume_requested", true)
    {updated, "budget_extended"}
  end

  defp transition(flow, %{"action" => "rework"} = event), do: rework(flow, event)

  defp transition(flow, %{"action" => "manifest"} = event) do
    case submit(flow, Map.put(event["data"], "ref", event["ref"])) do
      {:ok, updated} -> {Map.put(updated, "delivery_order", order(event)), "manifest_submitted"}
      {:error, _} -> {flow, "manifest_rejected"}
    end
  end

  defp transition(flow, %{"action" => "accept"} = event) do
    manifest = flow["manifest"]

    if is_map(manifest) and event["data"]["manifest"] == manifest["ref"],
      do: {flow |> Map.put("acceptance", %{"ref" => event["ref"], "manifest" => manifest["ref"]}) |> Map.put("acceptance_order", order(event)), "accepted_version"},
      else: {flow, "no_authorized_transition"}
  end

  defp transition(flow, _), do: {flow, "no_authorized_transition"}

  defp order(event), do: Map.take(event, ["at", "id", "version", "ref"])

  defp obsolete_delivery?(flow, %{"action" => action} = event) when action in ["manifest", "rework", "accept"] do
    latest = [flow["delivery_order"], flow["acceptance_order"]] |> Enum.reject(&is_nil/1) |> Enum.max_by(&source_order/1, fn -> nil end)
    not newer?(event, latest)
  end

  defp obsolete_delivery?(_, _), do: false

  defp add_condition(flow, _id, nil), do: flow

  defp add_condition(flow, id, condition) do
    if flow["restrictions"][id], do: put_in(flow, ["restrictions", id, "condition"], condition), else: flow
  end

  defp record_cancellation(flow, %{"action" => "cancel", "data" => %{"reason" => reason}} = event)
       when is_binary(reason) and reason != "", do: Map.put(flow, "cancellation", event["ref"])

  defp record_cancellation(flow, _), do: flow

  defp valid_contract?(data, facts) do
    baseline = data["issue_version"] == facts["issue_version"] and data["type"] == facts["type"]

    baseline and valid_controls?(data) and nonempty_strings?(data["criteria"]) and
      valid_deliverables?(data["deliverables"], data["type"]) and valid_mode?(data)
  end

  defp valid_controls?(data) do
    owner = is_binary(data["acceptor"]) and data["acceptor"] != ""
    budget = is_nil(data["budget_ms"]) or (is_integer(data["budget_ms"]) and data["budget_ms"] > 0)
    reviewers = data["reviewers"] || []

    owner and budget and is_list(reviewers) and Enum.all?(reviewers, &is_binary/1) and
      valid_dependencies?(data["dependencies"] || [])
  end

  defp valid_dependencies?(dependencies) when is_list(dependencies) do
    Enum.all?(dependencies, fn
      %{"id" => id, "kind" => kind, "number" => number} ->
        is_binary(id) and kind in ["issue", "mr"] and is_integer(number) and number > 0

      _ ->
        false
    end)
  end

  defp valid_dependencies?(_), do: false

  defp install_dependencies(flow, event) do
    Enum.reduce(event["data"]["dependencies"] || [], flow, fn dependency, current ->
      id = "dependency:" <> dependency["id"]
      restriction = %{"kind" => "dependency", "scope" => dependency["scope"] || "task", "condition" => dependency, "source" => event["ref"], "at" => event["at"]}
      put_in(current, ["restrictions", id], restriction)
    end)
  end

  defp nonempty_strings?(values) when is_list(values) and values != [] do
    Enum.all?(values, &(is_binary(&1) and &1 != "")) and length(Enum.uniq(values)) == length(values)
  end

  defp nonempty_strings?(_), do: false

  defp valid_deliverables?(items, type) when is_list(items) and items != [] do
    valid = Enum.all?(items, &deliverable?/1)

    if valid do
      kinds = Enum.map(items, & &1["kind"]) |> Enum.uniq() |> Enum.sort()

      expected =
        case type do
          "research" -> ["report"]
          "development" -> ["mr"]
          "mixed" -> ["mr", "report"]
          _ -> []
        end

      kinds == expected and length(Enum.uniq_by(items, & &1["id"])) == length(items)
    else
      false
    end
  end

  defp valid_deliverables?(_, _), do: false

  defp deliverable?(%{"id" => id, "kind" => kind}), do: is_binary(id) and kind in ["mr", "report"]
  defp deliverable?(_), do: false

  defp valid_mode?(%{"acceptance_mode" => "separate"}), do: true
  defp valid_mode?(%{"acceptance_mode" => "merge", "type" => "development", "deliverables" => [%{"kind" => "mr"}]}), do: true
  defp valid_mode?(_), do: false

  defp newer?(event, nil), do: is_integer(event["at"])
  defp newer?(event, previous), do: source_order(event) > source_order(previous)
  defp source_order(event), do: {event["at"], event["id"], event["version"]}

  defp rework(flow, event) do
    data = event["data"]
    criteria = data["criteria"] || []

    if criteria != [] and Enum.all?(criteria, &(&1 in flow["contract"]["criteria"])) and data["changes"] == [] do
      updated = flow |> Map.put("manifest", nil) |> Map.put("acceptance", nil) |> clear("handoff") |> Map.put("delivery_order", order(event))
      {Map.put(updated, "resume_requested", true), "in_scope_rework"}
    else
      {restrict(flow, event["ref"], "scope", data["scope"] || "task", event), "scope_confirmation_required"}
    end
  end

  defp restrict(flow, id, kind, scope, event) do
    released = flow["released"][id]

    if released && released >= event["at"],
      do: flow,
      else: put_in(flow, ["restrictions", id], %{"kind" => kind, "scope" => scope, "source" => event["ref"], "at" => event["at"]})
  end

  defp release(flow, id, event) do
    restriction = flow["restrictions"][id]

    if is_nil(restriction) or restriction["at"] <= event["at"] do
      flow |> clear(id) |> put_in(["released", id], event["at"])
    else
      flow
    end
  end

  defp clear(flow, id), do: Map.update!(flow, "restrictions", &Map.delete(&1, id))
  defp automatic(flow, id, kind), do: put_in(flow, ["restrictions", id], %{"kind" => kind, "scope" => "task", "source" => "reconciliation", "at" => 0})

  defp check_baseline(flow, facts) do
    contract = flow["contract"]

    if is_map(contract) and contract["issue_version"] == facts["issue_version"] and contract["type"] == facts["type"] and
         contract["ref"] in facts["source_refs"], do: clear(flow, "baseline"), else: automatic(flow, "baseline", "decision")
  end

  defp check_decision_sources(flow, facts) do
    if is_binary(flow["cancellation"]) and flow["cancellation"] not in facts["source_refs"], do: automatic(flow, "cancellation_source", "decision"), else: clear(flow, "cancellation_source")
  end

  @spec submit(map(), map()) :: {:ok, map()} | {:error, atom()}
  def submit(flow, manifest) do
    contract = flow["contract"]
    items = manifest["items"] || []

    if is_map(contract) and manifest["contract"] == contract["ref"] and manifest_items?(items, contract) do
      {:ok, flow |> Map.put("manifest", manifest) |> Map.put("acceptance", nil) |> clear("handoff")}
    else
      {:error, :manifest_does_not_cover_contract}
    end
  end

  defp manifest_items?(items, contract) when is_list(items) do
    if Enum.all?(items, &manifest_item?(&1, contract["criteria"])) do
      expected = Enum.map(contract["deliverables"], & &1["id"]) |> Enum.sort()
      actual = Enum.map(items, & &1["id"]) |> Enum.sort()
      coverage = Enum.flat_map(items, & &1["criteria"]) |> Enum.uniq() |> Enum.sort()
      actual == expected and coverage == Enum.sort(contract["criteria"])
    else
      false
    end
  end

  defp manifest_items?(_, _), do: false

  defp manifest_item?(%{"version" => version, "url" => url, "criteria" => criteria}, allowed)
       when is_binary(version) and is_binary(url) do
    nonempty_strings?(criteria) and Enum.all?(criteria, &(&1 in allowed))
  end

  defp manifest_item?(_, _), do: false

  defp check_manifest(%{"manifest" => nil} = flow, _facts), do: flow

  defp check_manifest(flow, facts) do
    manifest = flow["manifest"]

    valid =
      manifest["ref"] in facts["source_refs"] and
        Enum.all?(manifest["items"], fn item -> facts["versions"][item["url"]] == item["version"] end)

    flow =
      if is_map(flow["acceptance"]) and flow["acceptance"]["ref"] != "verified_merge" and
           flow["acceptance"]["ref"] not in facts["source_refs"], do: Map.put(flow, "acceptance", nil), else: flow

    cond do
      not valid ->
        flow |> Map.put("acceptance", nil) |> automatic("delivery_changed", "decision")

      flow["contract"]["acceptance_mode"] == "merge" and facts["merge_verified"] == true ->
        flow |> clear("delivery_changed") |> Map.put("acceptance", %{"ref" => "verified_merge", "manifest" => manifest["ref"]})

      true ->
        clear(flow, "delivery_changed")
    end
  end

  defp check_budget(flow) do
    if flow["used_ms"] >= flow["budget_ms"], do: automatic(flow, "budget", "budget"), else: clear(flow, "budget")
  end

  defp check_conditions(flow, facts) do
    flow =
      Enum.reduce(facts["satisfied"] || [], flow, fn id, current ->
        if current["restrictions"][id], do: current |> clear(id) |> Map.put("resume_requested", true), else: current
      end)

    intermediate = flow["intermediate"]

    flow =
      if is_map(intermediate) and intermediate["url"] in (facts["merged_urls"] || []) and
           facts["versions"][intermediate["url"]] == intermediate["version"] do
        flow |> clear("handoff") |> Map.put("intermediate", nil) |> Map.put("resume_requested", true)
      else
        flow
      end

    deadline = get_in(flow, ["contract", "deadline"])
    if is_integer(deadline) and facts["now"] >= deadline, do: automatic(flow, "deadline", "decision"), else: clear(flow, "deadline")
  end

  defp check_closure(flow, facts) do
    if facts["closed"] and not valid_conclusion?(flow), do: automatic(flow, "closure", "decision"), else: clear(flow, "closure")
  end

  defp check_conclusion_conflict(flow) do
    if is_binary(flow["cancellation"]) and is_map(flow["acceptance"]), do: automatic(flow, "conclusion_conflict", "decision"), else: flow
  end

  defp check_reopen(flow, facts) do
    flow = if flow["closed_seen"] == true and not facts["closed"], do: automatic(flow, "reopen", "decision"), else: flow
    Map.put(flow, "closed_seen", facts["closed"])
  end

  @spec valid_conclusion?(map()) :: boolean()
  def valid_conclusion?(flow) do
    not Map.has_key?(flow["restrictions"], "baseline") and
      not Map.has_key?(flow["restrictions"], "conclusion_conflict") and
      not Map.has_key?(flow["restrictions"], "cancellation_source") and
      (is_binary(flow["cancellation"]) or (is_map(flow["acceptance"]) and not Map.has_key?(flow["restrictions"], "delivery_changed")))
  end

  @spec allowed_criteria(map()) :: [String.t()]
  def allowed_criteria(flow) do
    restrictions = Map.values(flow["restrictions"])

    if Enum.any?(restrictions, &(&1["scope"] == "task")) do
      []
    else
      criteria = get_in(flow, ["contract", "criteria"]) || []
      Enum.reject(criteria, fn id -> Enum.any?(restrictions, &(id in List.wrap(&1["scope"]))) end)
    end
  end

  defp derive(flow, facts) do
    allowed = allowed_criteria(flow)
    human = Enum.any?(Map.values(flow["restrictions"]), &(&1["scope"] == "task" and &1["kind"] in @human))
    state = logical_state(flow, facts, allowed)
    charging = flow["started"] and state != "ended" and billable?(flow, facts, human)
    flow |> Map.put("state", state) |> Map.put("charging", charging) |> Map.put("allowed_criteria", allowed)
  end

  defp billable?(flow, facts, human), do: facts["stopped"] != true or (not human and not review?(flow))
  defp review?(flow), do: is_map(flow["manifest"]) and not Map.has_key?(flow["restrictions"], "delivery_changed")

  defp logical_state(flow, facts, allowed) do
    ended = ended?(flow, facts)
    waiting = facts["closed"] or Enum.any?(Map.values(flow["restrictions"]), &human_block?/1)

    cond do
      ended -> "ended"
      waiting -> "waiting"
      review?(flow) -> "review"
      allowed == [] -> "waiting"
      facts["active"] == true -> "running"
      true -> "ready"
    end
  end

  defp ended?(flow, facts), do: valid_conclusion?(flow) and facts["closed"] and facts["stopped"] == true

  defp human_block?(restriction), do: restriction["scope"] == "task" and restriction["kind"] in ["pause", "cancel", "scope", "decision"]

  @spec handoff(map(), map()) :: map()
  def handoff(flow, args) do
    kind = if args["kind"] == "review", do: "review", else: "decision"
    flow |> automatic("handoff", kind) |> Map.put("routing_removed", true) |> Map.put("resume_requested", false)
  end

  @spec start(map(), integer()) :: map()
  def start(flow, now), do: flow |> tick(now) |> Map.merge(%{"clock_at" => now, "charging" => true, "started" => true, "state" => "running", "resume_requested" => false})
end
