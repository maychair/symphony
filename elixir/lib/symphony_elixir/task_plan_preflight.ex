defmodule SymphonyElixir.TaskPlanPreflight do
  @moduledoc "Resolve the whole sealed plan and its native approval before any member can be considered for execution."

  alias SymphonyElixir.{Config, Execution, NativeWork, RunJournal}
  alias SymphonyElixir.{TaskControl, TaskDecision, TaskPlan, TaskPlanManifest}
  alias SymphonyElixir.{TaskReconciler, TaskWorkflow, WorkRef}
  alias SymphonyElixir.Tracker.Issue

  # Resolving a configured repository is a deployment capability, not a member
  # fact, so these failures still stop the whole plan rather than restricting a
  # single branch.
  @repository_failures [
    :invalid_plan_repositories,
    :invalid_plan_repository,
    :unregistered_plan_repository,
    :ambiguous_plan_repository
  ]

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
          {:ok, evidence} -> projection(issue, plan, evidence, opts)
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

  defp projection(issue, plan, evidence, opts) do
    if issue.url == evidence.parent.url and plan["revision"] == evidence.plan["revision"] do
      restrictions = Enum.map(evidence.controls.restrictions, & &1["kind"]) |> Enum.uniq() |> Enum.sort()
      blocked = blocked(evidence)
      status = if restrictions == [] and blocked == [], do: "approved", else: "restricted"

      %{
        "status" => status,
        "restrictions" => restrictions,
        "revision" => evidence.plan["revision"],
        "authority" => evidence.authority,
        "members" => map_size(evidence.members),
        "blocked" => blocked,
        "manifest" => TaskPlanManifest.facts(evidence.parent, evidence.plan, opts)
      }
    else
      %{"status" => "blocked", "reason" => "parent_projection_changed"}
    end
  end

  # A member that cannot be re-derived restricts itself and its transitive
  # consumers without blocking independent branches of the same approved plan.
  defp blocked(evidence) do
    evidence.restricted
    |> Enum.map(fn {key, entry} -> %{"work" => key, "reason" => reason_label(entry.reason)} end)
    |> Enum.sort_by(& &1["work"])
  end

  defp reason_label({reason, _}), do: reason_label(reason)
  defp reason_label(reason) when is_atom(reason), do: Atom.to_string(reason)

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
         :ok <- completed_parent(root, plan, opts),
         {:ok, authority} <- TaskControl.authority(root, plan, authority_mode(opts)),
         {:ok, {members, restricted}} <- members(plan, opts),
         :ok <- completed_members(root, plan, members, restricted, opts),
         :ok <- edges(plan, members),
         {:ok, current} <- NativeWork.read(parent, opts),
         true <-
           snapshot_version(current) == snapshot_version(root) or
             {:error, :parent_changed_during_preflight} do
      result = %{
        plan: plan,
        authority: authority,
        parent: root,
        members: members,
        restricted: restrict(plan, restricted)
      }

      with {:ok, controls} <- TaskControl.observe(result, parent), do: {:ok, Map.put(result, :controls, controls)}
    end
  end

  defp completed_parent(%{raw: %{"state" => state}}, _plan, opts) when state in ["open", "opened"] do
    if opts[:completed_plan_read] == true, do: {:error, :parent_not_closed}, else: :ok
  end

  defp completed_parent(root, plan, opts) do
    if opts[:completed_plan_read] == true and root.raw["state"] == "closed",
      do: verify_completed_parent(root, plan, opts),
      else: {:error, :parent_not_open}
  end

  defp verify_completed_parent(root, plan, opts) do
    directory = close_directory(plan, opts)

    with {:ok, %{"parent_close_intent" => %{"status" => "confirmed"} = intent, "parent_manifest_intent" => %{"status" => "confirmed", "source" => published, "revision" => revision}}} <-
           RunJournal.read(directory),
         :ok <- stable_parent(root, intent),
         %{"source" => ^published, "payload" => %{"revision" => ^revision}} = manifest <-
           List.last(TaskPlanManifest.manifests(root)),
         true <- manifest["payload"]["plan_revision"] == plan["revision"] or {:error, :parent_manifest_changed},
         {:ok, %{"action" => "accept", "source" => acceptance}} <- TaskPlanManifest.decision(root, plan, manifest),
         true <- accepted_intent?(intent, published, revision, acceptance) or {:error, :parent_acceptance_changed},
         :ok <- TaskPlanManifest.current_acceptance(root, plan, manifest, %{"source" => acceptance}) do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :parent_close_unconfirmed}
    end
  end

  defp stable_parent(root, intent) do
    cond do
      intent["source"] != "issue:" <> NativeWork.snapshot_ref(root) -> {:error, :parent_close_source_changed}
      intent["parent_description"] != TaskWorkflow.digest(root.description) -> {:error, :parent_description_changed}
      intent["parent_notes"] != note_sources(root.notes) -> {:error, :parent_decisions_changed}
      true -> :ok
    end
  end

  defp accepted_intent?(intent, published, revision, acceptance) do
    intent["manifest"] == published and intent["revision"] == revision and intent["acceptance"] == acceptance
  end

  defp completed_members(root, plan, members, restricted, opts) do
    if opts[:completed_plan_read] == true do
      verify_completed_members(root, plan, members, restricted, opts)
    else
      :ok
    end
  end

  defp verify_completed_members(root, plan, members, restricted, opts) do
    with true <- map_size(restricted) == 0 or {:error, :completed_member_unavailable},
         {:ok, %{"parent_close_intent" => %{"members" => sources}}} <- RunJournal.read(close_directory(plan, opts)),
         true <- matching_member_count?(sources, members) or {:error, :parent_member_sources_changed},
         true <- Enum.all?(members, &same_member_source?(&1, sources)) or {:error, :parent_member_sources_changed},
         true <- root.raw["state"] == "closed" or {:error, :parent_not_closed} do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :parent_member_sources_changed}
    end
  end

  defp same_member_source?({key, member}, sources) do
    sources[key] == %{"work" => member.work, "source" => NativeWork.snapshot_ref(member)}
  end

  defp matching_member_count?(sources, members), do: is_map(sources) and map_size(sources) == map_size(members)

  defp close_directory(plan, opts) do
    root = Keyword.get_lazy(opts, :journal_root, &Execution.journal_root/0)
    RunJournal.directory(root, WorkRef.key(plan["integration"]))
  end

  defp authority_mode(opts), do: if(opts[:completed_plan_read] == true, do: :completed_read, else: :dispatch)

  defp note_sources(notes) do
    notes |> Enum.reject(&(&1["system"] == true)) |> Enum.map(&TaskDecision.source_ref/1) |> Enum.sort()
  end

  # One drifted or unavailable member restricts itself and its consumers; the
  # remaining branches of the approved plan stay independently executable.
  # A repository the deployment cannot resolve is a capability gap rather than a
  # member-level fact, so it still fails the whole preflight.
  defp members(plan, opts) do
    Enum.reduce_while(plan["members"], {:ok, {%{}, %{}}}, fn member, {:ok, {found, restricted}} ->
      case read_member(member, plan["parent"], opts) do
        {:ok, snapshot} ->
          {:cont, {:ok, {Map.put(found, WorkRef.key(member["work"]), snapshot), restricted}}}

        {:error, reason} when reason in @repository_failures ->
          {:halt, {:error, {reason, member}}}

        {:error, reason} ->
          restricted = Map.put(restricted, WorkRef.key(member["work"]), %{work: member["work"], reason: reason})
          {:cont, {:ok, {found, restricted}}}
      end
    end)
  end

  # Inputs that can no longer be proven against the approved plan cannot unlock a
  # consumer; an inactive branch keeps its own restriction instead.
  defp restrict(plan, restricted) do
    expanded =
      Enum.reduce(plan["dependencies"], restricted, fn edge, acc ->
        from = WorkRef.key(edge["from"])
        to = WorkRef.key(edge["to"])

        if Map.has_key?(acc, from) and not Map.has_key?(acc, to),
          do: Map.put(acc, to, %{work: edge["to"], reason: {:dependency_restricted, from}}),
          else: acc
      end)

    if expanded == restricted, do: restricted, else: restrict(plan, expanded)
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
    valid =
      Enum.all?(plan["dependencies"], fn edge ->
        case members[WorkRef.key(edge["from"])] do
          %{contract: contract} -> edge?(edge, contract)
          _ -> true
        end
      end)

    if valid, do: :ok, else: {:error, :unresolved_dependency_artifact}
  end

  defp edge?(edge, contract) do
    artifact = Enum.find(contract["deliverables"], &(&1["id"] == edge["artifact"]))
    is_map(artifact) and Enum.all?(edge["criteria"], &(&1 in artifact["criteria"]))
  end

  defp snapshot_version(snapshot), do: {snapshot.version, TaskWorkflow.digest(Enum.map(snapshot.notes, &TaskDecision.source_ref/1) |> Enum.sort())}
  defp text?(value), do: is_binary(value) and String.trim(value) != ""
  defp strings?(values) when is_list(values) and values != [], do: Enum.all?(values, &text?/1) and length(Enum.uniq(values)) == length(values)
  defp strings?(_), do: false
end
