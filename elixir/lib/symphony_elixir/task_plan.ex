defmodule SymphonyElixir.TaskPlan do
  @moduledoc """
  Sealed parent-plan membership and dependency graph.

  The plan is native Issue content, not a task database. This module validates
  its complete shape before any member may be admitted and computes the affected
  subgraph. It neither schedules executions nor grants merge/creation authority.
  """

  alias SymphonyElixir.{TaskWorkflow, WorkRef}
  alias SymphonyElixir.Tracker.Issue

  @fields ~w(schema_version parent contract_sha authorizer criteria members dependencies integration budget_ms revision)
  @member_fields ~w(work contract_sha criteria budget_ms human_gate)
  @edge_fields ~w(from to artifact stage criteria)

  @doc "Project a parent Issue as coordination work; malformed plans never fall through to execution."
  @spec project(Issue.t()) :: Issue.t()
  def project(%Issue{description: description} = issue) when is_binary(description) do
    if String.contains?(description, "<!-- symphony-plan") do
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

  @doc "Read the single sealed native plan block without treating prose as authority."
  @spec parse(String.t()) :: {:ok, map()} | {:error, atom()}
  def parse(description) do
    with [[_, json]] <- Regex.scan(~r/<!-- symphony-plan\s+(\{.*?\})\s*-->/s, description),
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
    plan = draft |> Map.delete("revision") |> Map.put_new("schema_version", 1) |> Map.put_new("budget_ms", nil)
    plan = Map.put(plan, "revision", TaskWorkflow.digest(plan))
    with :ok <- validate(plan), do: {:ok, plan}
  end

  @doc "Reject malformed, unsealed, cyclic or incomplete integration plans."
  @spec validate(term()) :: :ok | {:error, atom()}
  def validate(plan) when is_map(plan) do
    cond do
      Enum.sort(Map.keys(plan)) != Enum.sort(@fields) or plan["schema_version"] != 1 ->
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

  defp dependencies?(%{"dependencies" => edges, "members" => members}) when is_list(edges) do
    works = Enum.map(members, & &1["work"])

    Enum.all?(edges, fn edge ->
      is_map(edge) and Enum.sort(Map.keys(edge)) == Enum.sort(@edge_fields) and
        edge["from"] in works and edge["to"] in works and edge["from"] != edge["to"] and
        nonempty?(edge["artifact"]) and edge["stage"] in ["verified", "delivered", "published"] and
        names?(edge["criteria"])
    end) and distinct?(edges, &{&1["from"], &1["to"], &1["artifact"]})
  end

  defp dependencies?(_), do: false

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
