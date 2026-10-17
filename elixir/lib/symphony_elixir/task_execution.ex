defmodule SymphonyElixir.TaskExecution do
  @moduledoc "Resolve native member evidence and admit the derived role under its owning execution journal lock."
  alias SymphonyElixir.{ExecutionBinding, NativeWork, RunJournal, TaskControl, TaskDelivery, TaskDependencies}
  alias SymphonyElixir.{TaskEvidence, TaskLifecycle, TaskPlanPreflight, WorkRef}

  @identity ~w(directory issue_id attempt_id execution_binding execution_generation)
  @running_identity @identity ++ ~w(workspace task_workspace task_session_id thread_id)
  @native_progress ~w(events updated_at journal_version turn_id turn_count phase goal_status goal_thread_id)

  @doc "Assemble a current member assessment from native facts and host execution locations/policies. No executor is allocated."
  @spec observe(map(), map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def observe(parent, work, executions, opts), do: do_observe(parent, work, executions, opts, :exact)

  defp do_observe(parent, work, executions, opts, mode) do
    with :ok <- WorkRef.validate(work),
         {:ok, plan} <- TaskPlanPreflight.inspect_plan(parent, opts),
         :ok <- configuration(plan, executions),
         %{directory: directory, policy: policy} <- executions[WorkRef.key(work)],
         true <- Map.has_key?(plan.members, WorkRef.key(work)),
         {:ok, stored} <- RunJournal.read(directory),
         {:ok, record} <- runtime(stored, directory, work),
         {:ok, facts} <- TaskEvidence.read_member(plan, work, record, policy, opts),
         inputs = get_in(record, ["execution_binding", "inputs"]),
         {:ok, dependencies} <- TaskDependencies.read(plan, work, inputs, executions, opts),
         {:ok, deliveries} <- TaskDelivery.read_candidate(work, facts.candidate, Keyword.put(opts, :runtime, record)),
         evidence = evidence(facts, dependencies, deliveries, opts[:active] == true),
         context = %{plan: plan, work: work, runtime: record, policy: policy, evidence: evidence},
         {:ok, flow} <- TaskLifecycle.assess(context, System.system_time(:millisecond)),
         :ok <- unchanged(plan, directory, stored, deliveries, opts, mode) do
      {:ok, %{record: record, flow: flow, plan: plan, policy: policy, evidence: evidence}}
    else
      {:error, _} = error -> error
      _ -> {:error, :member_execution_unavailable}
    end
  end

  defp configuration(plan, executions) when is_map(executions) do
    Enum.reduce_while(plan.members, :ok, fn {key, member}, :ok ->
      result =
        with %{directory: directory, policy: policy} when is_binary(directory) <- executions[key],
             true <- Path.type(directory) == :absolute and directory == RunJournal.directory(Path.dirname(directory), key),
             :ok <- TaskLifecycle.validate_policy(policy, member.contract) do
          :ok
        else
          _ -> {:error, :incomplete_plan_execution_configuration}
        end

      if result == :ok, do: {:cont, :ok}, else: {:halt, result}
    end)
  end

  defp configuration(_, _), do: {:error, :incomplete_plan_execution_configuration}

  defp runtime(nil, directory, work), do: {:ok, %{"directory" => directory, "issue_id" => WorkRef.key(work)}}

  defp runtime(record, directory, work) when is_map(record) do
    with true <- record["directory"] == directory and record["issue_id"] == WorkRef.key(work),
         binding = record["execution_binding"],
         true <- is_nil(binding) or (is_map(binding) and binding["work"] == work),
         {:ok, ^record} <- ExecutionBinding.bind(record, binding) do
      {:ok, record}
    else
      _ -> {:error, :member_execution_identity_changed}
    end
  end

  defp evidence(facts, dependencies, deliveries, active) do
    receipts = deliveries |> Enum.map(& &1.receipt) |> Enum.reject(&is_nil/1)

    %{
      "candidate" => facts.candidate,
      "verification" => facts.verification,
      "acceptance" => nil,
      "active" => active,
      "dependencies" => dependencies.dependencies,
      "deliveries" => receipts,
      "restrictions" => facts.controls.restrictions,
      "releases" => facts.controls.releases,
      "control_receipts" => facts.controls.receipts,
      "sources" => Enum.uniq(facts.sources ++ dependencies.sources ++ Enum.map(receipts, & &1["source"]))
    }
  end

  defp unchanged(plan, directory, stored, deliveries, opts, mode) do
    with {:ok, current} <- TaskPlanPreflight.inspect_plan(plan.plan["parent"], opts),
         true <- fingerprint(current) == fingerprint(plan),
         true <- Enum.all?(deliveries, &(is_nil(&1.snapshot) or TaskDelivery.current?(&1.snapshot, opts))),
         {:ok, current_record} <- RunJournal.read(directory),
         true <- same_runtime?(stored, current_record, mode) do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :execution_evidence_changed_during_read}
    end
  end

  defp same_runtime?(before, after_read, :exact), do: before == after_read
  defp same_runtime?(before, after_read, :running), do: runtime_revision(before) == runtime_revision(after_read)

  defp runtime_revision(record) when is_map(record) do
    record
    |> Map.drop(@native_progress)
    |> Map.update("workflow", nil, fn flow -> if is_map(flow), do: Map.drop(flow, ~w(used_ms clock_at)), else: flow end)
  end

  defp runtime_revision(record), do: record

  @doc "Read active-role facts off the native event loop; tolerate only native progress and clock ticks during the read."
  @spec observe_running(map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def observe_running(record, executions, opts) do
    with {:ok, binding} <- ExecutionBinding.normalize(record["execution_binding"]),
         {:ok, observation} <- do_observe(binding["authority"]["work"], binding["work"], executions, Keyword.put(opts, :active, true), :running),
         true <- Map.take(observation.record, @running_identity) == Map.take(record, @running_identity) do
      {:ok, observation}
    else
      false -> {:error, :execution_attempt_changed}
      error -> error
    end
  end

  @doc "Apply an observed active-role result under the current owner, preserving intervening native progress and charging."
  @spec apply_running(map(), map()) :: {:ok, map()} | {:error, term()}
  def apply_running(record, observation) do
    with true <- same_runtime?(record, observation.record, :running),
         binding = record["execution_binding"],
         context = %{plan: observation.plan, work: binding["work"], runtime: record, policy: observation.policy, evidence: Map.put(observation.evidence, "active", true)},
         {:ok, flow} <- TaskLifecycle.assess(context, System.system_time(:millisecond)),
         {:ok, record} <- RunJournal.checkpoint(record, %{"workflow" => flow, "control_receipts" => observation.evidence["control_receipts"]}) do
      {:ok, %{observation | record: record, flow: record["workflow"]}}
    else
      false -> {:error, :execution_observation_superseded}
      error -> error
    end
  end

  defp fingerprint(plan),
    do: {plan.plan, plan.authority, NativeWork.snapshot_ref(plan.parent), Map.new(plan.members, fn {key, member} -> {key, NativeWork.snapshot_ref(member)} end)}

  @doc "Admit only the derived role, rechecking native facts after the journal lock. Waiting never starts budget charging."
  @spec admit(map(), map(), map(), keyword()) :: {:ok, map()} | {:waiting, map()} | {:error, term()}
  def admit(parent, work, executions, opts) do
    opts = Keyword.put(opts, :active, false)

    with {:ok, observation} <- observe(parent, work, executions, opts) do
      cond do
        observation.flow["dispatchable"] ->
          admit_locked(observation, executions, opts, observation.flow["next_binding"], :start)

        observation.evidence["control_receipts"] != TaskControl.recorded(observation.record) ->
          admit_locked(observation, executions, opts, observation.record["execution_binding"], :wait)

        true ->
          {:waiting, observation}
      end
    end
  end

  defp admit_locked(observation, executions, opts, binding, action) do
    root = Path.dirname(observation.record["directory"])

    with {:ok, record} <- RunJournal.admit(root, observation.record["issue_id"], execution_binding: binding) do
      result =
        with {:ok, record} <- remember(record, observation.evidence["control_receipts"]) do
          continue_admission(record, observation, executions, opts, action)
        end

      case result do
        {:ok, _} -> result
        {:waiting, _} -> result
        error -> abandon(record, error)
      end
    end
  end

  defp remember(record, receipts) do
    with prior when is_map(prior) <- TaskControl.recorded(record) || {:error, :control_source_unconfirmed} do
      # Preserve the first observed source on conflict. The following native
      # read rejects a changed/missing decision instead of replacing its receipt.
      RunJournal.checkpoint(record, %{"control_receipts" => Map.merge(receipts, prior)})
    end
  end

  defp continue_admission(record, observation, executions, opts, action) do
    parent = observation.plan.plan["parent"]
    work = observation.flow["work"]

    with {:ok, current} <- observe(parent, work, executions, opts),
         true <- Map.take(current.record, @identity) == Map.take(record, @identity),
         changes = %{"workflow" => current.flow, "control_receipts" => current.evidence["control_receipts"], "issue_url" => current.plan.members[WorkRef.key(work)].url},
         {:ok, record} <- RunJournal.checkpoint(current.record, changes) do
      conclude_admission(action, %{current | record: record, flow: record["workflow"]})
    else
      {:error, _} = error -> error
      _ -> {:error, :execution_admission_changed}
    end
  end

  defp conclude_admission(:start, current) do
    with {:ok, flow} <- TaskLifecycle.start(current.flow, current.record, System.system_time(:millisecond)),
         {:ok, record} <- RunJournal.checkpoint(current.record, %{"workflow" => flow}) do
      {:ok, %{current | record: record, flow: record["workflow"]}}
    end
  end

  defp conclude_admission(:wait, current) do
    with :ok <- RunJournal.complete(current.record, "completed"),
         {:ok, record} <- RunJournal.read(current.record["directory"]) do
      {:waiting, %{current | record: record, flow: record["workflow"]}}
    end
  end

  # This attempt has not allocated or resumed a native thread. Releasing its
  # lock does not confirm stop for any prior uncertain executor.
  defp abandon(record, error) do
    with {:ok, %{} = current} <- RunJournal.read(record["directory"]),
         true <- Map.take(current, @identity) == Map.take(record, @identity),
         :ok <- RunJournal.complete(current, "completed") do
      error
    else
      _ -> {:error, :execution_admission_recovery_required}
    end
  end

  @doc "Refresh an owned generation's controls and next action. The caller still owns stopping its native execution."
  @spec refresh(map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def refresh(record, executions, opts) do
    with {:ok, binding} <- ExecutionBinding.normalize(record["execution_binding"]),
         {:ok, observation} <- observe(binding["authority"]["work"], binding["work"], executions, opts),
         true <- Map.take(observation.record, @identity) == Map.take(record, @identity),
         :ok <- recorded_controls(record, observation.record),
         {:ok, current} <- RunJournal.checkpoint(observation.record, %{"workflow" => observation.flow, "control_receipts" => observation.evidence["control_receipts"]}) do
      {:ok, %{observation | record: current, flow: current["workflow"]}}
    else
      {:error, _} = error -> error
      _ -> {:error, :execution_attempt_changed}
    end
  end

  defp recorded_controls(record, current) do
    prior = TaskControl.recorded(record)
    known = TaskControl.recorded(current)
    if is_map(prior) and is_map(known) and Enum.all?(prior, fn {id, source} -> known[id] == source end), do: :ok, else: {:error, :control_source_unconfirmed}
  end
end
