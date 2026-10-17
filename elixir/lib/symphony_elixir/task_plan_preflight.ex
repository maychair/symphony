defmodule SymphonyElixir.TaskPlanPreflight do
  @moduledoc "Resolve the whole sealed plan and its native approval before any member can be considered for execution."

  alias SymphonyElixir.{Config, NativeWork, TaskControl, TaskDecision, TaskPlan, TaskReconciler, TaskWorkflow, WorkRef}
  alias SymphonyElixir.Tracker.Issue

  @doc "Discover and check configured parents even when they have no execution journal."
  @spec project([Issue.t()], keyword()) :: [Issue.t()]
  def project(issues, opts \\ []) do
    roots = Keyword.get_lazy(opts, :roots, fn -> Config.settings!().tracker.provider["plan_roots"] || [] end)
    Enum.map(issues, &project_parent(&1, roots, opts))
  end

  defp project_parent(%Issue{kind: :plan, native_ref: %{"plan" => plan}} = issue, roots, opts) when is_list(roots) do
    status =
      if plan["parent"] in roots do
        case inspect_plan(plan["parent"], opts) do
          {:ok, evidence} -> projection(issue, plan, evidence)
          {:error, reason} -> %{"status" => "blocked", "reason" => reason_name(reason)}
        end
      else
        %{"status" => "unconfigured"}
      end

    %{issue | native_ref: Map.put(issue.native_ref, "plan_preflight", status)}
  end

  defp project_parent(issue, _, _) do
    if TaskPlan.requires_plan_lifecycle?(issue) do
      native = Map.put(issue.native_ref || %{}, "plan_preflight", %{"status" => "blocked", "reason" => "plan_execution_unavailable"})
      %{issue | dispatchable: false, native_ref: native}
    else
      issue
    end
  end

  defp projection(issue, plan, evidence) do
    if issue.url == evidence.parent.url and plan["revision"] == evidence.plan["revision"] do
      restrictions = Enum.map(evidence.controls.restrictions, & &1["kind"]) |> Enum.uniq() |> Enum.sort()
      status = if restrictions == [], do: "approved", else: "restricted"
      %{"status" => status, "restrictions" => restrictions, "revision" => evidence.plan["revision"], "authority" => evidence.authority, "members" => map_size(evidence.members)}
    else
      %{"status" => "blocked", "reason" => "parent_projection_changed"}
    end
  end

  defp reason_name({reason, _}), do: reason_name(reason)
  defp reason_name(reason) when is_atom(reason), do: Atom.to_string(reason)

  @doc "Return native evidence for every member; no partial plan, grant, mutation or executor is returned on failure."
  @spec inspect_plan(WorkRef.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def inspect_plan(parent, opts \\ []) do
    with {:ok, root} <- NativeWork.read(parent, opts),
         {:ok, plan} <- TaskPlan.parse(root.description),
         true <- plan["parent"] == parent or {:error, :parent_identity_mismatch},
         {:ok, contract} <- scope(root, nil),
         true <- (contract["contract_sha"] == plan["contract_sha"] and contract["authorizer"] == plan["authorizer"]) or {:error, :parent_contract_changed},
         true <- Enum.sort(contract["criteria"]) == Enum.sort(plan["criteria"]) or {:error, :parent_criteria_changed},
         true <- plan["budget_ms"] == contract["budget_ms"] or {:error, :parent_budget_changed},
         {:ok, authority} <- TaskControl.authority(root, plan),
         {:ok, members} <- members(plan, opts),
         :ok <- edges(plan, members),
         {:ok, current} <- NativeWork.read(parent, opts),
         true <- snapshot_version(current) == snapshot_version(root) or {:error, :parent_changed_during_preflight} do
      result = %{plan: plan, authority: authority, parent: root, members: members}
      with {:ok, controls} <- TaskControl.observe(result, parent), do: {:ok, Map.put(result, :controls, controls)}
    end
  end

  defp members(plan, opts) do
    Enum.reduce_while(plan["members"], {:ok, %{}}, fn member, {:ok, found} ->
      case read_member(member, plan["parent"], opts) do
        {:ok, snapshot} -> {:cont, {:ok, Map.put(found, WorkRef.key(member["work"]), snapshot)}}
        {:error, reason} -> {:halt, {:error, {reason, member["work"]}}}
      end
    end)
  end

  defp read_member(member, parent, opts) do
    with {:ok, snapshot} <- NativeWork.read(member["work"], opts),
         {:ok, contract} <- scope(snapshot, parent),
         true <- contract["contract_sha"] == member["contract_sha"] or {:error, :member_contract_changed},
         true <- contract["budget_ms"] == member["budget_ms"] or {:error, :member_budget_changed},
         expected_mode = if(member["human_gate"], do: "separate", else: "technical"),
         true <- contract["acceptance_mode"] == expected_mode or {:error, :member_gate_changed} do
      {:ok, Map.put(snapshot, :contract, contract)}
    end
  end

  # New parent plans need complete scope inside the seal. Legacy contracts with
  # only criterion IDs and mutable prose outside the block cannot be promoted.
  defp scope(snapshot, parent) do
    contract = TaskReconciler.description_contract(snapshot.description)

    if is_map(contract) and contract["schema_version"] == 2 and contract["work"] == snapshot.work and
         Map.has_key?(contract, "parent") and contract["parent"] == parent and semantic_scope?(contract, parent) and
         assigned_authorizer?(snapshot.raw, contract["authorizer"]) do
      {:ok, contract}
    else
      {:error, :incomplete_sealed_scope}
    end
  end

  defp semantic_scope?(contract, parent) do
    exclusions = contract["non_goals"]

    text?(contract["goal"]) and criteria?(contract["criteria"], contract["criteria_details"]) and
      is_list(exclusions) and Enum.all?(exclusions, &text?/1) and text?(contract["authorizer"]) and
      scope_budget?(contract["budget_ms"], parent) and acceptance?(contract, parent) and outputs?(contract["deliverables"], contract["criteria"])
  end

  defp scope_budget?(nil, nil), do: true
  defp scope_budget?(value, _), do: positive?(value)
  defp acceptance?(%{"acceptance_mode" => "technical", "acceptor" => nil}, parent), do: is_map(parent)
  defp acceptance?(%{"acceptance_mode" => "separate", "acceptor" => acceptor}, _), do: text?(acceptor)
  defp acceptance?(_, _), do: false

  defp criteria?(criteria, details),
    do: strings?(criteria) and is_map(details) and Enum.sort(Map.keys(details)) == Enum.sort(criteria) and Enum.all?(Map.values(details), &text?/1)

  defp positive?(value), do: is_integer(value) and value > 0

  defp outputs?(outputs, criteria) when is_list(outputs) and outputs != [] do
    Enum.all?(outputs, fn
      %{"id" => id, "kind" => kind, "criteria" => covered} = output ->
        text?(id) and kind in ["mr", "pr", "report", "publication"] and strings?(covered) and Enum.all?(covered, &(&1 in criteria)) and output_scope?(output)

      _ ->
        false
    end) and length(Enum.uniq_by(outputs, & &1["id"])) == length(outputs) and
      MapSet.new(Enum.flat_map(outputs, & &1["criteria"])) == MapSet.new(criteria)
  end

  defp outputs?(_, _), do: false

  defp output_scope?(%{"kind" => kind} = output) when kind in ["pr", "mr"], do: text?(output["target_branch"])
  defp output_scope?(_), do: true

  defp assigned_authorizer?(%{"assignees" => [%{"id" => id}]}, authorizer) when is_integer(id), do: to_string(id) == authorizer
  defp assigned_authorizer?(_, _), do: false

  defp edges(plan, members) do
    valid = Enum.all?(plan["dependencies"], &edge?(&1, members))
    if valid, do: :ok, else: {:error, :unresolved_dependency_artifact}
  end

  defp edge?(edge, members) do
    producer = members[WorkRef.key(edge["from"])].contract
    artifact = Enum.find(producer["deliverables"], &(&1["id"] == edge["artifact"]))
    is_map(artifact) and Enum.all?(edge["criteria"], &(&1 in artifact["criteria"]))
  end

  defp snapshot_version(snapshot), do: {snapshot.version, TaskWorkflow.digest(Enum.map(snapshot.notes, &TaskDecision.source_ref/1) |> Enum.sort())}
  defp text?(value), do: is_binary(value) and String.trim(value) != ""
  defp strings?(values) when is_list(values) and values != [], do: Enum.all?(values, &text?/1) and length(Enum.uniq(values)) == length(values)
  defp strings?(_), do: false
end
