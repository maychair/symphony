defmodule SymphonyElixir.TaskDependencies do
  @moduledoc "Resolve approved dependency edges from native publications, owning journals and retained immutable bytes."
  alias SymphonyElixir.{ArtifactStore, NativeWork, RunJournal, TaskEvidence, TaskLifecycle}
  alias SymphonyElixir.{TaskDelivery, TaskPlan, TaskPlanPreflight, TaskWorkflow, WorkRef}

  @doc "Read current inputs (nil) or revalidate pinned inputs. Execution locations and policies are host configuration, never agent arguments."
  @spec read(map(), map(), [map()] | nil, map(), keyword()) :: {:ok, map()} | {:error, term()}
  def read(plan, work, inputs, executions, opts) do
    with :ok <- TaskPlan.validate(plan.plan),
         :ok <- WorkRef.validate(work),
         %{} <- plan.members[WorkRef.key(work)] do
      context = %{plan: plan, work: work, executions: executions, opts: opts}

      with {:ok, result} <- dependencies(context, work, inputs, %{}),
           :ok <- unchanged(context, result.observed) do
        {:ok, Map.take(result, [:dependencies, :sources])}
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :not_plan_member}
    end
  end

  defp dependencies(context, work, inputs, observed) do
    edges = Enum.filter(context.plan.plan["dependencies"], &(&1["to"] == work))

    if input_set?(inputs, edges) do
      initial = {:ok, %{dependencies: [], sources: [], observed: observed}}
      Enum.reduce_while(edges, initial, &collect_dependency(context, &1, inputs, &2))
    else
      {:error, :dependency_inputs_do_not_match_plan}
    end
  end

  defp collect_dependency(context, edge, inputs, {:ok, result}) do
    reference = if inputs, do: Enum.find(inputs, &(&1["work"] == edge["from"] and &1["artifact"] == edge["artifact"]))

    case dependency(context, edge, reference, result.observed) do
      {:ok, proof, sources, observed} ->
        {:cont, {:ok, %{dependencies: result.dependencies ++ [proof], sources: Enum.uniq(result.sources ++ sources), observed: observed}}}

      {:error, _} = error ->
        {:halt, error}
    end
  end

  defp input_set?(nil, _), do: true

  defp input_set?(inputs, edges) when is_list(inputs) do
    Enum.all?(inputs, &(is_map(&1) and Enum.sort(Map.keys(&1)) == Enum.sort(~w(work artifact version verification)))) and
      length(inputs) == length(edges) and
      Enum.sort(Enum.map(inputs, &{&1["work"], &1["artifact"]})) == Enum.sort(Enum.map(edges, &{&1["from"], &1["artifact"]}))
  end

  defp input_set?(_, _), do: false

  defp dependency(context, edge, reference, observed) do
    with {:ok, facts, runtime, policy} <- member(context, edge["from"], reference),
         %{} = candidate <- facts.candidate,
         {:ok, upstream} <- dependencies(context, edge["from"], candidate["inputs"], observed),
         evidence = %{"candidate" => candidate, "verification" => facts.verification, "dependencies" => upstream.dependencies, "sources" => Enum.uniq(facts.sources ++ upstream.sources)},
         assessment = %{plan: context.plan, work: edge["from"], runtime: runtime, policy: policy, evidence: evidence},
         {:ok, artifacts} <- TaskLifecycle.verified_artifacts(assessment),
         %{} = artifact <- Enum.find(artifacts, &(&1["id"] == edge["artifact"])),
         true <- selected?(edge, artifact) or {:error, :dependency_selection_unconfirmed},
         delivery_context = %{context | opts: Keyword.merge(context.opts, candidate: candidate, runtime: runtime)},
         {:ok, proof, changes} <- delivery_proof(delivery_context, edge, artifact, facts.verification),
         :ok <- retain(context, edge, proof, runtime, artifact),
         {:ok, observed} <- observe(upstream.observed, runtime, facts.snapshot, changes) do
      {:ok, proof, Enum.uniq(evidence["sources"] ++ Enum.map(changes, & &1.source)), observed}
    else
      {:error, _} = error -> error
      _ -> {:error, :dependency_not_verified}
    end
  end

  defp delivery_proof(_context, %{"stage" => "verified"} = edge, artifact, verification), do: {:ok, proof(edge, artifact, verification), []}

  defp delivery_proof(_, %{"stage" => "published"}, %{"kind" => kind}, _) when kind not in ["report", "publication"],
    do: {:error, :dependency_delivery_evidence_unavailable}

  defp delivery_proof(context, edge, artifact, verification) do
    case TaskDelivery.read(edge["from"], artifact, context.opts) do
      {:ok, %{status: "delivered", snapshot: snapshot}} ->
        {:ok, proof(edge, artifact, verification) |> Map.put("stage", edge["stage"]) |> Map.put("delivery", snapshot.source), [snapshot]}

      {:ok, %{status: "verification_required"}} ->
        {:error, :dependency_delivery_verification_required}

      {:ok, %{status: "unsupported"}} ->
        {:error, :dependency_delivery_evidence_unavailable}

      {:ok, _} ->
        {:error, :dependency_delivery_unconfirmed}

      {:error, _} = error ->
        error
    end
  end

  defp member(context, work, reference) do
    with %{directory: directory, policy: policy} when is_binary(directory) and is_map(policy) <- context.executions[WorkRef.key(work)],
         {:ok, %{} = runtime} <- RunJournal.read(directory),
         true <- runtime["directory"] == directory and get_in(runtime, ["execution_binding", "work"]) == work,
         {:ok, facts} <- read_result(context, work, reference, runtime, policy) do
      {:ok, facts, runtime, policy}
    else
      {:error, _} = error -> error
      _ -> {:error, :dependency_execution_unavailable}
    end
  end

  defp read_result(context, work, nil, runtime, policy),
    do: TaskEvidence.read_member(context.plan, work, runtime, policy, Keyword.delete(context.opts, :candidate_only))

  defp read_result(context, _work, reference, runtime, policy),
    do: TaskEvidence.read_input(context.plan, reference, runtime, policy, context.opts)

  defp proof(edge, artifact, verification) do
    %{
      "work" => edge["from"],
      "artifact" => edge["artifact"],
      "version" => artifact["version"],
      "verification" => verification["source"],
      "retrieval" => artifact["source"],
      "criteria" => edge["criteria"],
      "stage" => "verified"
    }
  end

  # An edge that declares an explicit selection yields only that exact upstream
  # version; a newer candidate may not silently replace the approved input (§9.2).
  defp selected?(edge, artifact), do: Map.get(edge, "selects") in [nil, artifact["version"]]

  defp retain(context, edge, proof, runtime, artifact) do
    revision = TaskWorkflow.digest(%{"plan_revision" => context.plan.plan["revision"], "input" => proof})
    owner = %{"kind" => "dependency", "work" => edge["to"], "revision" => revision}
    root = Keyword.get(context.opts, :artifact_store_root, Path.join(Path.dirname(runtime["directory"]), ".artifacts"))

    result =
      if Map.has_key?(artifact, "body"),
        do: ArtifactStore.retain_report(root, edge["from"], artifact, owner, context.opts),
        else: ArtifactStore.retain(root, edge["from"], proof["version"], owner, context.opts)

    case result do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  defp observe(observed, runtime, snapshot, changes) do
    key = WorkRef.key(snapshot.work)
    value = %{directory: runtime["directory"], version: runtime["journal_version"], snapshot: NativeWork.snapshot_ref(snapshot)}
    prior = observed[key]
    changes = Enum.uniq(if(prior, do: prior.changes, else: []) ++ changes)

    if (not is_nil(prior) and Map.delete(prior, :changes) != value) or length(Enum.uniq_by(changes, & &1.work)) != length(changes),
      do: {:error, :dependency_changed_during_read},
      else: {:ok, Map.put(observed, key, Map.put(value, :changes, changes))}
  end

  defp unchanged(_, observed) when map_size(observed) == 0, do: :ok

  defp unchanged(context, observed) do
    with {:ok, current} <- TaskPlanPreflight.inspect_plan(context.plan.plan["parent"], context.opts),
         true <- current.plan == context.plan.plan and current.authority == context.plan.authority,
         true <- NativeWork.snapshot_ref(current.parent) == NativeWork.snapshot_ref(context.plan.parent),
         key = WorkRef.key(context.work),
         true <- NativeWork.snapshot_ref(current.members[key]) == NativeWork.snapshot_ref(context.plan.members[key]),
         true <- Enum.all?(observed, fn {key, value} -> unchanged_member?(current.members[key], value, context.opts) end) do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :dependency_changed_during_read}
    end
  end

  defp unchanged_member?(snapshot, value, opts) do
    changes_current = Enum.all?(value.changes, &TaskDelivery.current?(&1, opts))

    case RunJournal.read(value.directory) do
      {:ok, %{} = runtime} ->
        changes_current and runtime["journal_version"] == value.version and NativeWork.snapshot_ref(snapshot) == value.snapshot

      _ ->
        false
    end
  end
end
