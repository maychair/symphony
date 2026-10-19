defmodule SymphonyElixir.TaskExecution do
  @moduledoc "Resolve native member evidence and admit the derived role under its owning execution journal lock."
  alias SymphonyElixir.CommandCheck
  alias SymphonyElixir.{ExecutionBinding, NativeWork, RunJournal, TaskControl, TaskDelivery, TaskDependencies}
  alias SymphonyElixir.{TaskEvidence, TaskLifecycle, TaskPlan, TaskPlanPreflight, WorkRef}

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
         inputs = selected_inputs(plan, work, record),
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

  defp selected_inputs(plan, work, record) do
    binding = record["execution_binding"]

    cond do
      TaskLifecycle.authorized_rework?(plan, work, record) ->
        nil

      is_map(binding) and not TaskPlan.compatible?(plan.plan, work, binding["plan_revision"], binding["inputs"]) ->
        nil

      true ->
        get_in(record, ["execution_binding", "inputs"])
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
      "acceptance" => facts.acceptance,
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

    with {:ok, observation} <- admission_observation(parent, work, executions, opts) do
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

  defp admission_observation(parent, work, executions, opts) do
    observe(parent, work, executions, opts)
  catch
    kind, reason -> {:error, {:admission_observation_failed, kind, inspect(reason)}}
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

    with {:ok, current} <- admission_observation(parent, work, executions, opts),
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

  @doc "Finalize one owned attempt exactly once. Native stop, task evidence and retry accounting remain separate facts."
  @spec finish(map(), term(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def finish(record, result, executions, opts) do
    with {:ok, %{} = current} <- RunJournal.read(record["directory"]),
         true <- Map.take(current, @running_identity) == Map.take(record, @running_identity) and current["executor_os_pid"] == System.pid(),
         {:ok, _} <- ExecutionBinding.normalize(current["execution_binding"]),
         true <- is_map(current["workflow"]) and is_map(current["workflow"]["restrictions"]),
         {:ok, ^current} <- ExecutionBinding.bind(current, current["execution_binding"]),
         {:ok, current} <- finish_intent(current, result, executions, opts),
         {:ok, current} <- release_finished(current) do
      receipt = current["task_attempt_results"][current["attempt_id"]]
      {:ok, %{record: current, flow: current["workflow"], outcome: receipt["outcome"], reason: receipt["reason"]}}
    else
      {:error, _} = error -> error
      _ -> {:error, :execution_attempt_changed}
    end
  end

  defp finish_intent(record, result, executions, opts) do
    case get_in(record, ["task_attempt_results", record["attempt_id"]]) do
      nil -> prepare_finish(record, result, executions, opts)
      receipt -> if valid_finish?(receipt, record), do: {:ok, record}, else: {:error, :invalid_attempt_result}
    end
  end

  defp valid_finish?(receipt, record) do
    is_map(receipt) and receipt["generation"] == record["execution_generation"] and receipt["session_id"] == record["task_session_id"] and
      receipt["phase"] in ["completed", "incident"] and receipt["outcome"] in ["continue", "waiting", "retry", "incident"] and
      record["phase"] in ["finalizing", receipt["phase"]] and (receipt["phase"] == "incident" or stopped?(record))
  end

  @doc "Validate a captured completed attempt without adopting a successor's journal or treating an exit as evidence."
  @spec completed_result(term()) :: {:ok, map()} | {:error, term()}
  def completed_result(%{"directory" => directory} = record) when is_binary(directory) do
    receipt = get_in(record, ["task_attempt_results", record["attempt_id"]])

    with {:ok, ^record} <- RunJournal.read(record["directory"]),
         true <- record["phase"] == "completed" and valid_finish?(receipt, record),
         true <- not File.exists?(Path.join(record["directory"], "executor.lock")) do
      {:ok, receipt}
    else
      _ -> {:error, :member_result_unconfirmed}
    end
  end

  def completed_result(_), do: {:error, :member_result_unconfirmed}

  defp stopped?(record),
    do: CommandCheck.stopped?(record) and (record["native_stop_confirmed"] == true or (is_nil(record["thread_id"]) and record["thread_allocation_intent"] != true))

  defp prepare_finish(record, result, executions, opts) do
    if stopped?(record) do
      with {:ok, record} <- RunJournal.checkpoint(record, %{"phase" => "attempt_stopped", "last_result" => result_class(result)}) do
        finish_stopped(record, result, executions, opts)
      end
    else
      persist_finish(record, result, "incident", :task_execution_stop_unconfirmed, unknown_flow(record, "native_stop"))
    end
  end

  defp result_class({:ok, %{goal_status: status}}) when status != "complete", do: "interrupted"
  defp result_class({:ok, _}), do: "completed"
  defp result_class({:error, :scheduler_stop}), do: "interrupted"
  defp result_class(_), do: "retryable_error"

  defp finish_stopped(record, result, executions, opts) do
    case observe_stopped(record, executions, opts) do
      {:ok, observation} ->
        finish_observed(record, result, observation)

      {:error, reason} ->
        flow = unknown_flow(record, "finalization_evidence")
        persist_finish(record, result, "waiting", {:finalization_evidence_unconfirmed, reason}, flow)
    end
  end

  defp observe_stopped(record, executions, opts) do
    binding = record["execution_binding"]

    with {:ok, observation} <- observe(binding["authority"]["work"], binding["work"], executions, Keyword.put(opts, :active, false)),
         true <- observation.record == record do
      {:ok, observation}
    else
      false -> {:error, :execution_observation_superseded}
      error -> error
    end
  rescue
    error -> {:error, {:finalization_observation_failed, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:finalization_observation_failed, kind, inspect(reason)}}
  end

  defp finish_observed(record, result, observation) do
    {outcome, reason} = finish_outcome(record, result, observation.flow)
    record = if outcome == "retry", do: Map.update(record, "retry_count", 1, &(&1 + 1)), else: record
    binding = record["execution_binding"]
    context = %{plan: observation.plan, work: binding["work"], runtime: record, policy: observation.policy, evidence: observation.evidence}

    with {:ok, flow} <- TaskLifecycle.assess(context, System.system_time(:millisecond)) do
      record = Map.put(record, "control_receipts", observation.evidence["control_receipts"])
      outcome = if outcome == "retry" and not flow["dispatchable"], do: "waiting", else: outcome
      persist_finish(record, result, outcome, reason, flow)
    end
  end

  defp finish_outcome(record, result, flow) do
    cond do
      not flow["dispatchable"] -> {"waiting", nil}
      flow["next_binding"] != record["execution_binding"] -> {"continue", nil}
      result == {:error, :scheduler_stop} -> {"continue", nil}
      match?({:ok, _}, result) -> {"retry", :task_execution_no_progress}
      true -> {"retry", result}
    end
  end

  defp unknown_flow(record, id) do
    flow = record["workflow"]
    restriction = %{"kind" => "evidence", "scope" => "task", "source" => "finalization"}
    flow = put_in(flow, ["restrictions", id], restriction)
    execution = if id == "native_stop", do: "uncertain", else: if(record["thread_id"], do: "stopped", else: "idle")
    Map.merge(flow, %{"state" => "waiting", "execution" => execution, "evidence" => "unknown", "dispatchable" => false, "stop_required" => false, "closeable" => false, "next_binding" => nil})
  end

  defp persist_finish(record, result, outcome, reason, flow) do
    phase = if outcome == "incident", do: "incident", else: "completed"

    receipt = %{
      "generation" => record["execution_generation"],
      "session_id" => record["task_session_id"],
      "phase" => phase,
      "outcome" => outcome,
      "reason" => if(reason, do: inspect(reason)),
      "native_result" => inspect(result)
    }

    receipts = Map.put(record["task_attempt_results"] || %{}, record["attempt_id"], receipt)

    changes = %{
      "phase" => "finalizing",
      "workflow" => flow,
      "retry_count" => record["retry_count"] || 0,
      "control_receipts" => record["control_receipts"],
      "task_attempt_results" => receipts,
      "blocker_reason" => receipt["reason"]
    }

    RunJournal.checkpoint(record, changes)
  end

  defp release_finished(%{"phase" => "finalizing"} = record) do
    phase = record["task_attempt_results"][record["attempt_id"]]["phase"]

    with {:ok, record} <- RunJournal.checkpoint(record, %{"phase" => phase}),
         :ok <- RunJournal.release_lock(record) do
      {:ok, record}
    end
  end

  defp release_finished(record) do
    result = if File.exists?(Path.join(record["directory"], "executor.lock")), do: RunJournal.release_lock(record), else: :ok
    with :ok <- result, do: {:ok, record}
  end
end
