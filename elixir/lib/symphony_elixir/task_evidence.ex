defmodule SymphonyElixir.TaskEvidence do
  @moduledoc """
  Resolve candidate and verification evidence from native publications and actual artifacts.

  This supplies result and native control facts, including pinned historical inputs.
  TaskDependencies composes technical dependency proofs; delivery, acceptance and
  native execution activity still need their own facts before lifecycle assessment.
  """
  alias SymphonyElixir.ArtifactStore
  alias SymphonyElixir.{CommandCheck, ExecutionBinding, GitArtifact, NativeWork, TaskPublication, TaskWorkflow, WorkRef}
  alias SymphonyElixir.{TaskControl, TaskPlanPreflight}

  @doc "Read a member's current native results; never replace unavailable current evidence with an older success."
  @spec read_member(map(), map(), map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def read_member(plan, work, runtime, policy, opts) do
    with :ok <- WorkRef.validate(work),
         {:ok, current_plan} <- TaskPlanPreflight.inspect_plan(plan.plan["parent"], opts),
         true <- current_plan.plan == plan.plan and current_plan.authority == plan.authority,
         %{} = member <- plan.members[WorkRef.key(work)],
         true <- member.work == work,
         {:ok, _} <- ExecutionBinding.bind(runtime, runtime["execution_binding"]),
         {:ok, snapshot} <- NativeWork.read(work, opts),
         true <- snapshot.description == member.description,
         current_plan = put_in(current_plan.members[WorkRef.key(work)], Map.put(snapshot, :contract, member.contract)),
         {:ok, controls} <- TaskControl.observe(current_plan, work, TaskControl.recorded(runtime)),
         {:ok, results} <- TaskPublication.observe(runtime, snapshot, policy["engine_actor"]),
         current = Enum.filter(results, &scope?(&1.envelope, plan, member, policy)),
         {:ok, selected} <- select_candidate(current, opts),
         {:ok, candidate, artifacts} <- candidate(selected, runtime, work, opts),
         {:ok, selected} <- select_verification(current, candidate, policy, opts),
         {:ok, verification} <- verification(selected, runtime, policy),
         {:ok, after_read} <- NativeWork.read(work, opts),
         true <- NativeWork.snapshot_ref(snapshot) == NativeWork.snapshot_ref(after_read),
         {:ok, parent_after} <- NativeWork.read(plan.plan["parent"], opts),
         true <- NativeWork.snapshot_ref(current_plan.parent) == NativeWork.snapshot_ref(parent_after) do
      sources = Enum.map(artifacts, & &1.receipt["source"]) ++ result_sources([candidate, verification]) ++ controls.sources
      {:ok, %{candidate: candidate, verification: verification, sources: Enum.uniq(sources), artifacts: artifacts, snapshot: snapshot, controls: controls}}
    else
      {:error, _} = error -> error
      _ -> {:error, :member_evidence_scope_changed}
    end
  end

  @doc "Read the current candidate without requiring the current verifier publication to be complete."
  @spec read_candidate(map(), map(), map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def read_candidate(plan, work, runtime, policy, opts),
    do: read_member(plan, work, runtime, policy, Keyword.put(opts, :candidate_only, true))

  @doc "Revalidate a consumer's pinned input against its original native verification, without selecting a newer candidate."
  @spec read_input(map(), map(), map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def read_input(plan, reference, runtime, policy, opts) do
    opts = opts |> Keyword.delete(:candidate_only) |> Keyword.put(:input_reference, reference)

    with {:ok, facts} <- read_member(plan, reference["work"], runtime, policy, opts),
         %{candidate: %{} = candidate, verification: %{} = verification} <- facts,
         true <-
           verification["source"] == reference["verification"] and
             Enum.any?(candidate["artifacts"], &(&1["id"] == reference["artifact"] and &1["version"] == reference["version"])) do
      {:ok, facts}
    else
      {:error, _} = error -> error
      _ -> {:error, :pinned_input_unconfirmed}
    end
  end

  defp select_candidate(current, opts) do
    case opts[:input_reference] do
      nil ->
        latest(current, "candidate")

      reference ->
        case Enum.filter(pinned_results(current, reference), &(&1.envelope["kind"] == "verification")) do
          [%{envelope: envelope}] ->
            current
            |> Enum.filter(&(&1.envelope["kind"] == "candidate" and TaskWorkflow.digest(&1.envelope["payload"]) == envelope["payload"]["candidate"]))
            |> latest("candidate")

          _ ->
            {:error, :pinned_input_unconfirmed}
        end
    end
  end

  defp pinned_results(current, reference), do: Enum.filter(current, &(&1.receipt && &1.receipt["source"] == reference["verification"]))

  defp select_verification(current, candidate, policy, opts) do
    if opts[:candidate_only], do: {:ok, nil}, else: latest_verification(current, candidate, policy)
  end

  defp scope?(%{"binding" => binding} = envelope, plan, member, policy) do
    binding["work"] == member.work and binding["contract_sha"] == member.contract["contract_sha"] and
      binding["authority"] == plan.authority and binding["plan_revision"] == plan.plan["revision"] and envelope["actor"] == policy["engine_actor"]
  end

  defp latest(results, kind) do
    candidates = Enum.filter(results, &(&1.envelope["kind"] == kind))

    case candidates do
      [] -> {:ok, nil}
      _ -> unique_generation(candidates)
    end
  end

  defp unique_generation(candidates) do
    generation = candidates |> Enum.map(& &1.envelope["generation"]) |> Enum.max()

    case Enum.filter(candidates, &(&1.envelope["generation"] == generation)) do
      [%{receipt: %{} = _receipt} = result] -> {:ok, result}
      [_] -> {:error, :current_result_unconfirmed}
      _ -> {:error, :ambiguous_execution_result}
    end
  end

  defp latest_verification(_, nil, _), do: {:ok, nil}

  defp latest_verification(results, candidate, policy) do
    results
    |> Enum.filter(fn result ->
      payload = result.envelope["payload"]
      payload["candidate"] == candidate["digest"] and payload["inputs"] == candidate["inputs"] and payload["policy_sha"] == TaskWorkflow.digest(policy)
    end)
    |> latest("verification")
  end

  defp candidate(nil, _, _, _), do: {:ok, nil, []}

  defp candidate(result, runtime, _work, opts) do
    envelope = result.envelope
    payload = envelope["payload"]
    digest = TaskWorkflow.digest(Map.take(payload, ~w(work contract_sha inputs artifacts)))

    with {:ok, _execution} <- execution(envelope, runtime, "developer"),
         {:ok, artifacts} <- retain_candidate(runtime, payload, opts) do
      value = Map.merge(payload, metadata(result)) |> Map.put("digest", digest)
      {:ok, value, artifacts}
    end
  end

  @doc "Retain candidate Git outputs and exact report bytes before publishing or consuming immutable references."
  @spec retain_candidate(map(), map(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def retain_candidate(runtime, payload, opts) do
    digest = TaskWorkflow.digest(Map.take(payload, ~w(work contract_sha inputs artifacts)))
    work = payload["work"]
    owner = %{"kind" => "candidate", "work" => work, "revision" => digest}
    root = Keyword.get_lazy(opts, :artifact_store_root, fn -> if is_binary(runtime["directory"]), do: Path.join(Path.dirname(runtime["directory"]), ".artifacts") end)
    acquire(payload["artifacts"], root, work, owner, opts)
  end

  defp acquire(artifacts, root, work, owner, opts) do
    Enum.reduce_while(artifacts, {:ok, []}, fn artifact, {:ok, acquired} ->
      case acquire_one(artifact, root, work, owner, opts) do
        {:ok, snapshot} -> {:cont, {:ok, acquired ++ [snapshot]}}
        error -> {:halt, error}
      end
    end)
  end

  defp acquire_one(%{"kind" => "report", "body" => _} = report, root, work, owner, opts),
    do: ArtifactStore.retain_report(root, work, report, owner, opts)

  defp acquire_one(%{"version" => version, "source" => source}, root, work, owner, opts) when is_binary(version) do
    if source == GitArtifact.source_ref(work, version),
      do: ArtifactStore.retain(root, work, version, owner, opts),
      else: {:error, :artifact_source_mismatch}
  end

  defp acquire_one(_, _, _, _, _), do: {:error, :artifact_source_mismatch}

  defp verification(nil, _, _), do: {:ok, nil}

  defp verification(result, runtime, policy) do
    envelope = result.envelope
    payload = envelope["payload"]

    with {:ok, execution} <- execution(envelope, runtime, "verifier"),
         :ok <- CommandCheck.attest(Map.merge(runtime, execution), payload, policy) do
      checks = Enum.map(payload["checks"], &Map.put(&1, "source", result.receipt["source"]))
      {:ok, Map.merge(payload, metadata(result)) |> Map.put("checks", checks)}
    end
  end

  defp execution(envelope, runtime, role) do
    matches =
      Enum.filter([runtime | runtime["execution_history"] || []], fn receipt ->
        receipt["execution_binding"] == envelope["binding"] and receipt["execution_generation"] == envelope["generation"] and
          receipt["thread_id"] == envelope["thread_id"] and is_binary(receipt["thread_id"]) and envelope["binding"]["role"] == role
      end)

    case matches do
      [receipt] -> {:ok, receipt}
      _ -> {:error, :result_execution_unconfirmed}
    end
  end

  defp metadata(result) do
    execution = Map.take(result.envelope, ~w(generation thread_id))
    %{"actor" => result.envelope["actor"], "source" => result.receipt["source"], "execution" => execution}
  end

  defp result_sources(results), do: Enum.flat_map(results, fn value -> if value, do: [value["source"]], else: [] end)
end
