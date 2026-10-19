defmodule SymphonyElixir.TaskPlan do
  @moduledoc """
  Sealed parent-plan membership and dependency graph.

  The plan is native Issue content, not a task database. This module validates
  its complete shape before any member may be admitted and computes the affected
  subgraph. It neither schedules executions nor grants merge/creation authority.

  Plans are versioned. Schema v1 edges are version-agnostic: the edge names the
  required upstream artifact and stage, and the consumer records the exact
  version it consumed, so a later upstream candidate restricts the member
  instead of silently re-pointing an existing conclusion.

  Schema v2 requires every edge to declare a `selects` slot. A version string
  pins that exact upstream version: `TaskDependencies` resolves only that
  version, and `compatible?/4` refuses to reuse input evidence recorded against
  any other version. A `null` selection states that the edge is intentionally
  unpinned because its upstream artifact does not exist when the plan is
  authored. An absent slot in a v2 edge is rejected, never downgraded to v1.
  """

  alias SymphonyElixir.{TaskDecision, TaskWorkflow, WorkRef}
  alias SymphonyElixir.Tracker.Issue

  @fields ~w(schema_version parent contract_sha authorizer criteria members dependencies integration budget_ms revision)
  @member_fields ~w(work contract_sha criteria budget_ms human_gate)
  @edge_fields ~w(from to artifact stage criteria)
  @selection "selects"
  @edge_fields_v2 @edge_fields ++ [@selection]
  @schemas [1, 2]
  @marker ~r/<!--\s*symphony-plan(?=\s|-->|$)/
  @decision ~r/(?:^|\n)<!--\s*symphony-plan-decision\s+(\{.*?\})\s*-->\s*$/s

  @doc "Project a parent Issue as coordination work; malformed plans never fall through to execution."
  @spec project(Issue.t()) :: Issue.t()
  def project(%Issue{description: description} = issue) when is_binary(description) do
    if Regex.match?(@marker, description) do
      native = Map.drop(issue.native_ref || %{}, ["plan", "plan_error"])
      result = parse(description)

      native =
        case result do
          {:ok, plan} -> Map.put(native, "plan", plan)
          {:error, reason} -> Map.put(native, "plan_error", Atom.to_string(reason))
        end

      %{issue | kind: :plan, dispatchable: false, native_ref: native}
    else
      issue
    end
  end

  def project(%Issue{} = issue), do: issue

  @doc "Keep versioned plan contracts out of legacy execution, including invalid or unsupported contracts."
  @spec requires_plan_lifecycle?(Issue.t()) :: boolean()
  def requires_plan_lifecycle?(%Issue{description: description}) when is_binary(description) do
    if Regex.match?(~r/<!--\s*symphony-contract\b/, description) do
      case SymphonyElixir.TaskReconciler.description_contract(description) do
        %{} = contract -> Map.has_key?(contract, "parent") or contract["schema_version"] not in [nil, 1]
        _ -> true
      end
    else
      false
    end
  end

  def requires_plan_lifecycle?(%Issue{}), do: false

  @doc "Read the single sealed native plan block without treating prose as authority."
  @spec parse(String.t()) :: {:ok, map()} | {:error, atom()}
  def parse(description) do
    with [_] <- Regex.scan(@marker, description),
         [[_, json]] <- Regex.scan(~r/<!--\s*symphony-plan\s+(\{.*?\})\s*-->/s, description),
         {:ok, plan} <- Jason.decode(json),
         :ok <- validate(plan) do
      {:ok, plan}
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :invalid_plan_block}
    end
  end

  @doc "Seal a complete draft. Every member and edge participates in the revision."
  @spec seal(map()) :: {:ok, map()} | {:error, atom()}
  def seal(draft) when is_map(draft) do
    plan =
      draft
      |> Map.delete("revision")
      |> Map.put_new("budget_ms", nil)
      |> default_schema()
      |> normalize_edges()

    plan = Map.put(plan, "revision", TaskWorkflow.digest(plan))
    with :ok <- validate(plan), do: {:ok, plan}
  end

  @doc "Reject malformed, unsealed, cyclic or incomplete integration plans."
  @spec validate(term()) :: :ok | {:error, atom()}
  def validate(plan) when is_map(plan) do
    cond do
      Enum.sort(Map.keys(plan)) != Enum.sort(@fields) or plan["schema_version"] not in @schemas ->
        {:error, :invalid_plan_schema}

      plan["revision"] != TaskWorkflow.digest(Map.delete(plan, "revision")) ->
        {:error, :plan_revision_changed}

      not plan_identity?(plan) ->
        {:error, :invalid_plan_identity}

      not members?(plan) ->
        {:error, :invalid_plan_members}

      not dependencies?(plan) ->
        {:error, :invalid_plan_dependencies}

      not budget?(plan) ->
        {:error, :invalid_plan_budget}

      true ->
        validate_graph(plan)
    end
  end

  def validate(_), do: {:error, :invalid_plan_schema}

  @doc "Resolve an approved member only when its current contract still matches."
  @spec member(map(), WorkRef.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def member(plan, work, contract_sha) do
    with :ok <- validate(plan), :ok <- WorkRef.validate(work) do
      case Enum.find(plan["members"], &(&1["work"] == work)) do
        nil -> {:error, :not_plan_member}
        %{"contract_sha" => ^contract_sha} = member -> {:ok, member}
        _ -> {:error, :member_contract_changed}
      end
    end
  end

  @doc "Return changed members and their transitive consumers, in dependency order."
  @spec affected(map(), [WorkRef.t()]) :: {:ok, [WorkRef.t()]} | {:error, atom()}
  def affected(plan, changed) when is_list(changed) do
    with :ok <- validate(plan) do
      members = Enum.map(plan["members"], & &1["work"])

      if Enum.all?(changed, &(&1 in members)) do
        selected = descendants(MapSet.new(changed, &WorkRef.key/1), plan["dependencies"])
        {:ok, Enum.filter(ordered_members(plan), &MapSet.member?(selected, WorkRef.key(&1)))}
      else
        {:error, :not_plan_member}
      end
    end
  end

  @doc """
  Whether a result produced under `revision` still applies to this approved plan.

  An unaffected member keeps its evidence across a newly approved revision; a
  member whose declared input set changed must be redone before its conclusions
  are reused (§9.1.7, §12 scenario 5).
  """
  @spec compatible?(map(), WorkRef.t(), term(), term()) :: boolean()
  def compatible?(plan, work, revision, inputs) do
    revision == plan["revision"] or selections_match?(declared_inputs(plan, work), input_pairs(inputs))
  end

  @doc "Reuse a prior member result only when its old grant remains native-verifiable and the member scope still matches."
  @spec compatible_binding?(map(), map(), map(), WorkRef.t(), [map()]) :: boolean()
  def compatible_binding?(plan, authority, binding, work, notes) do
    prior = binding["authority"]
    member = Enum.find(plan["members"], &(&1["work"] == work))

    is_map(prior) and is_map(member) and binding["work"] == work and
      binding["contract_sha"] == member["contract_sha"] and
      compatible_authority?(plan, authority, binding, prior, work, notes)
  end

  defp compatible_authority?(plan, authority, binding, prior, work, notes) do
    exact = prior == authority and binding["plan_revision"] == plan["revision"]

    historical =
      binding["plan_revision"] != plan["revision"] and prior["work"] == authority["work"] and
        prior["actor"] == authority["actor"] and prior["revision"] == binding["plan_revision"] and
        native_grant?(prior, notes) and compatible?(plan, work, binding["plan_revision"], binding["inputs"])

    exact or historical
  end

  defp native_grant?(grant, notes) do
    Enum.any?(notes, fn note ->
      is_binary(grant["revision"]) and note["system"] != true and
        is_integer(get_in(note, ["author", "id"])) and get_in(note, ["author", "id"]) > 0 and
        TaskDecision.source_ref(note) == grant["source"] and
        to_string(get_in(note, ["author", "id"])) == grant["actor"] and
        authorization?(note, grant["revision"])
    end)
  end

  # A historical grant must be a genuine sealed-plan authorization for the exact
  # revision it claims, not merely a note that shares the recorded source and
  # actor. Mirror TaskControl's strict marker parse so a forged or unrelated note
  # cannot resurrect a stale binding.
  defp authorization?(note, revision) do
    with {:ok, payload} <- decision_payload(note),
         %{"action" => "authorize", "revision" => ^revision} <- payload,
         true <- Enum.sort(Map.keys(payload)) == ~w(action revision) do
      true
    else
      _ -> false
    end
  end

  defp decision_payload(note) do
    with true <- is_binary(note["body"]),
         true <- is_integer(note["id"]) and note["id"] > 0,
         at when is_integer(at) <- TaskDecision.timestamp(note["created_at"]),
         true <- at == TaskDecision.timestamp(note["updated_at"]),
         [[_, json]] <- Regex.scan(@decision, note["body"]),
         {:ok, payload} <- Jason.decode(json) do
      {:ok, payload}
    else
      _ -> :error
    end
  end

  defp declared_inputs(plan, work) do
    plan["dependencies"]
    |> Enum.filter(&(&1["to"] == work))
    |> Enum.map(&{WorkRef.key(&1["from"]), &1["artifact"], Map.get(&1, @selection)})
    |> Enum.sort()
  end

  defp input_pairs(inputs) when is_list(inputs) do
    pairs =
      Enum.map(inputs, fn
        %{"work" => work, "artifact" => artifact} = input when is_map(work) ->
          {WorkRef.key(work), artifact, Map.get(input, "version")}

        _ ->
          :invalid
      end)

    if :invalid in pairs, do: :invalid, else: Enum.sort(pairs)
  end

  defp input_pairs(_), do: :invalid

  defp selections_match?(declared, recorded) when is_list(recorded) and length(declared) == length(recorded) do
    index = Map.new(recorded, fn {key, artifact, version} -> {{key, artifact}, version} end)

    Enum.all?(declared, fn {key, artifact, selection} ->
      case Map.fetch(index, {key, artifact}) do
        {:ok, version} -> is_nil(selection) or selection == version
        :error -> false
      end
    end)
  end

  defp selections_match?(_, _), do: false

  defp default_schema(%{"schema_version" => _} = plan), do: plan

  defp default_schema(plan),
    do: Map.put(plan, "schema_version", if(selection_declared?(plan), do: 2, else: 1))

  defp selection_declared?(%{"dependencies" => edges}) when is_list(edges),
    do: Enum.any?(edges, &(is_map(&1) and Map.has_key?(&1, @selection)))

  defp selection_declared?(_), do: false

  defp normalize_edges(%{"schema_version" => 2, "dependencies" => edges} = plan) when is_list(edges),
    do: Map.put(plan, "dependencies", Enum.map(edges, &declared_edge/1))

  defp normalize_edges(plan), do: plan

  defp declared_edge(%{} = edge), do: Map.put_new(edge, @selection, nil)
  defp declared_edge(edge), do: edge

  defp members?(%{"members" => members, "criteria" => criteria, "parent" => parent})
       when is_list(members) and members != [] do
    Enum.all?(members, &valid_member?(&1, criteria, parent)) and
      distinct?(members, & &1["work"]) and
      MapSet.new(Enum.flat_map(members, & &1["criteria"])) == MapSet.new(criteria)
  end

  defp members?(_), do: false

  defp plan_identity?(plan) do
    WorkRef.validate(plan["parent"]) == :ok and plan["parent"]["kind"] == "issue" and
      digest?(plan["contract_sha"]) and nonempty?(plan["authorizer"]) and names?(plan["criteria"])
  end

  defp valid_member?(member, criteria, parent) when is_map(member) do
    Enum.sort(Map.keys(member)) == Enum.sort(@member_fields) and
      WorkRef.validate(member["work"]) == :ok and member["work"]["kind"] == "issue" and
      member["work"] != parent and member_contract?(member, criteria)
  end

  defp valid_member?(_, _, _), do: false

  defp member_contract?(member, criteria) do
    digest?(member["contract_sha"]) and names?(member["criteria"]) and
      Enum.all?(member["criteria"], &(&1 in criteria)) and
      positive?(member["budget_ms"]) and is_boolean(member["human_gate"])
  end

  defp dependencies?(%{"dependencies" => edges, "members" => members} = plan) when is_list(edges) do
    works = Enum.map(members, & &1["work"])
    fields = edge_fields(plan)

    Enum.all?(edges, &valid_edge?(&1, works, fields)) and
      distinct?(edges, &{&1["from"], &1["to"], &1["artifact"]})
  end

  defp dependencies?(_), do: false

  defp valid_edge?(edge, works, fields) do
    is_map(edge) and Enum.sort(Map.keys(edge)) == Enum.sort(fields) and
      edge["from"] in works and edge["to"] in works and edge["from"] != edge["to"] and
      nonempty?(edge["artifact"]) and edge["stage"] in ["verified", "delivered", "published"] and
      names?(edge["criteria"]) and selection?(edge)
  end

  defp edge_fields(%{"schema_version" => 2}), do: @edge_fields_v2
  defp edge_fields(_), do: @edge_fields

  defp selection?(%{@selection => nil}), do: true
  defp selection?(%{@selection => version}), do: nonempty?(version)
  defp selection?(edge), do: not Map.has_key?(edge, @selection)

  defp budget?(plan) do
    is_nil(plan["budget_ms"]) or
      (positive?(plan["budget_ms"]) and
         Enum.sum(Enum.map(plan["members"], & &1["budget_ms"])) <= plan["budget_ms"])
  end

  defp validate_graph(plan) do
    works = Enum.map(plan["members"], & &1["work"])
    ordered = ordered_members(plan)
    integration = plan["integration"]

    cond do
      length(ordered) != length(works) ->
        {:error, :cyclic_plan}

      integration not in works ->
        {:error, :missing_integration_member}

      not Enum.all?(works, fn work ->
        MapSet.member?(descendants(MapSet.new([WorkRef.key(work)]), plan["dependencies"]), WorkRef.key(integration))
      end) ->
        {:error, :incomplete_integration_graph}

      true ->
        :ok
    end
  end

  defp ordered_members(plan) do
    works = plan["members"] |> Enum.map(& &1["work"]) |> Enum.sort_by(&WorkRef.key/1)
    order(works, plan["dependencies"], [])
  end

  defp order([], _edges, done), do: done

  defp order(remaining, edges, done) do
    {ready, waiting} = Enum.split_with(remaining, fn work -> Enum.all?(edges, &(&1["to"] != work or &1["from"] in done)) end)
    if ready == [], do: done, else: order(waiting, edges, done ++ ready)
  end

  defp descendants(selected, edges) do
    expanded =
      Enum.reduce(edges, selected, fn edge, found ->
        if MapSet.member?(found, WorkRef.key(edge["from"])),
          do: MapSet.put(found, WorkRef.key(edge["to"])),
          else: found
      end)

    if expanded == selected, do: selected, else: descendants(expanded, edges)
  end

  defp nonempty?(value), do: is_binary(value) and String.trim(value) != ""
  defp positive?(value), do: is_integer(value) and value > 0
  defp digest?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)
  defp names?(values) when is_list(values) and values != [], do: Enum.all?(values, &nonempty?/1) and distinct?(values, & &1)
  defp names?(_), do: false
  defp distinct?(values, key), do: length(Enum.uniq_by(values, key)) == length(values)
end
