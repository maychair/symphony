defmodule SymphonyElixir.TaskDependencies do
  @moduledoc "Resolve approved dependency edges from native publications, owning journals and retained immutable bytes."
  alias SymphonyElixir.{ArtifactStore, NativeWork, RunJournal, TaskEvidence, TaskLifecycle}
  alias SymphonyElixir.{TaskPlan, TaskPlanPreflight, TaskWorkflow, WorkRef}

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

  defp dependency(context, %{"stage" => "verified"} = edge, reference, observed) do
    with {:ok, facts, runtime, policy} <- member(context, edge["from"], reference),
         %{} = candidate <- facts.candidate,
         {:ok, upstream} <- dependencies(context, edge["from"], candidate["inputs"], observed),
         evidence = %{"candidate" => candidate, "verification" => facts.verification, "dependencies" => upstream.dependencies, "sources" => Enum.uniq(facts.sources ++ upstream.sources)},
         assessment = %{plan: context.plan, work: edge["from"], runtime: runtime, policy: policy, evidence: evidence},
         {:ok, artifacts} <- TaskLifecycle.verified_artifacts(assessment),
         %{} = artifact <- Enum.find(artifacts, &(&1["id"] == edge["artifact"])),
         proof = proof(edge, artifact, facts.verification),
         :ok <- retain(context, edge, proof, runtime),
         {:ok, observed} <- observe(upstream.observed, runtime, facts.snapshot) do
      {:ok, proof, evidence["sources"], observed}
    else
      {:error, _} = error -> error
      _ -> {:error, :dependency_not_verified}
    end
  end

  defp dependency(_, _, _, _), do: {:error, :dependency_delivery_evidence_unavailable}

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

  defp retain(context, edge, proof, runtime) do
    revision = TaskWorkflow.digest(%{"plan_revision" => context.plan.plan["revision"], "input" => proof})
    owner = %{"kind" => "dependency", "work" => edge["to"], "revision" => revision}
    root = Keyword.get(context.opts, :artifact_store_root, Path.join(Path.dirname(runtime["directory"]), ".artifacts"))

    case ArtifactStore.retain(root, edge["from"], proof["version"], owner, context.opts) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  defp observe(observed, runtime, snapshot) do
    key = WorkRef.key(snapshot.work)
    value = %{directory: runtime["directory"], version: runtime["journal_version"], snapshot: NativeWork.snapshot_ref(snapshot)}

    if Map.has_key?(observed, key) and observed[key] != value,
      do: {:error, :dependency_changed_during_read},
      else: {:ok, Map.put(observed, key, value)}
  end

  defp unchanged(_, observed) when map_size(observed) == 0, do: :ok

  defp unchanged(context, observed) do
    with {:ok, current} <- TaskPlanPreflight.inspect_plan(context.plan.plan["parent"], context.opts),
         true <- current.plan == context.plan.plan and current.authority == context.plan.authority,
         true <- NativeWork.snapshot_ref(current.parent) == NativeWork.snapshot_ref(context.plan.parent),
         key = WorkRef.key(context.work),
         true <- NativeWork.snapshot_ref(current.members[key]) == NativeWork.snapshot_ref(context.plan.members[key]),
         true <- Enum.all?(observed, fn {key, value} -> unchanged_member?(current.members[key], value) end) do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :dependency_changed_during_read}
    end
  end

  defp unchanged_member?(snapshot, value) do
    case RunJournal.read(value.directory) do
      {:ok, %{} = runtime} -> runtime["journal_version"] == value.version and NativeWork.snapshot_ref(snapshot) == value.snapshot
      _ -> false
    end
  end
end
