defmodule SymphonyElixir.ExecutionBinding do
  @moduledoc """
  Bind one native execution generation to a work item, role and fixed inputs.

  This is an execution fence, not authorization. The lifecycle must validate the
  native plan, controls, input evidence and remaining budget before admission.
  It never converts an existing unbound session into approved plan execution.
  """

  alias SymphonyElixir.{TaskWorkflow, WorkRef}

  @fields ~w(work role plan_revision contract_sha authority inputs candidate policy_sha)
  @input_fields ~w(work artifact version verification)
  @binding_fields ~w(execution_binding execution_binding_sha execution_generation execution_history)
  @native_fields ~w(thread_id turn_id thread_allocation_intent native_stop_confirmed goal_thread_id goal_status execution_mode recovery native_stop_recovery)
  @receipt_fields ~w(execution_binding execution_generation attempt_id thread_id turn_id thread_allocation_intent native_stop_confirmed backend worker_host workspace execution_mode goal_status)

  @doc "Bind under the journal's admission lock; preserve all cumulative accounting and evidence receipts."
  @spec bind(map(), map() | nil) :: {:ok, map()} | {:error, atom()}
  def bind(record, nil) do
    if Enum.any?(@binding_fields, &Map.has_key?(record, &1)), do: {:error, :execution_binding_required}, else: {:ok, record}
  end

  def bind(record, binding) do
    with {:ok, binding} <- normalize(binding),
         :ok <- valid_record(record),
         :ok <- same_work(record, binding) do
      cond do
        record["execution_binding"] == binding -> {:ok, record}
        not rotatable?(record) -> {:error, :execution_generation_requires_native_stop}
        is_nil(record["execution_binding"]) and allocated?(record) -> {:error, :unbound_execution_requires_migration}
        true -> {:ok, rotate(record, binding)}
      end
    end
  end

  @doc "A new role cannot reuse a developer thread, and an existing generation cannot switch its native identity."
  @spec check_native_identity(map(), map()) :: :ok | {:error, atom()}
  def check_native_identity(%{"execution_binding" => binding} = record, changes) when is_map(binding) do
    thread = changes["thread_id"]

    cond do
      binding_changed?(record, changes) -> {:error, :execution_binding_changed_outside_admission}
      not Map.has_key?(changes, "thread_id") -> :ok
      not text?(thread) -> {:error, :invalid_bound_native_thread}
      is_binary(record["thread_id"]) and record["thread_id"] != thread -> {:error, :bound_native_thread_changed}
      Enum.any?(record["execution_history"] || [], &(&1["thread_id"] == thread)) -> {:error, :native_thread_reused_across_generations}
      true -> :ok
    end
  end

  def check_native_identity(_, _), do: :ok

  defp binding_changed?(record, changes), do: Enum.any?(@binding_fields, &(Map.has_key?(changes, &1) and changes[&1] != record[&1]))

  defp valid_record(%{"execution_binding" => %{} = binding} = record) do
    with {:ok, ^binding} <- normalize(binding),
         true <- record["execution_binding_sha"] == TaskWorkflow.digest(binding),
         true <- is_integer(record["execution_generation"]) and record["execution_generation"] > 0,
         true <- native_fields?(record),
         true <- valid_history?(record) do
      :ok
    else
      _ -> {:error, :invalid_persisted_execution_binding}
    end
  end

  defp valid_record(record) do
    if Enum.any?(@binding_fields, &Map.has_key?(record, &1)), do: {:error, :invalid_persisted_execution_binding}, else: :ok
  end

  defp valid_history?(%{"execution_history" => history} = record) when is_list(history) do
    length(history) == record["execution_generation"] - 1 and
      Enum.with_index(history, 1) |> Enum.all?(fn {receipt, generation} -> valid_receipt?(receipt, generation, record) end)
  end

  defp valid_history?(_), do: false

  defp valid_receipt?(receipt, generation, record) when is_map(receipt) do
    match?({:ok, _}, normalize(receipt["execution_binding"])) and
      get_in(receipt, ["execution_binding", "work"]) == record["execution_binding"]["work"] and
      receipt["execution_generation"] == generation and native_fields?(receipt) and rotatable?(receipt)
  end

  defp valid_receipt?(_, _, _), do: false

  defp native_fields?(record) do
    thread = record["thread_id"]
    turn = record["turn_id"]

    (is_nil(thread) or text?(thread)) and (is_nil(turn) or (text?(thread) and text?(turn))) and
      record["thread_allocation_intent"] in [nil, false, true] and record["native_stop_confirmed"] in [nil, false, true]
  end

  @doc "Canonicalize bindings so reordering the same input set does not create another execution."
  @spec normalize(term()) :: {:ok, map()} | {:error, atom()}
  def normalize(binding) when is_map(binding) do
    if Enum.sort(Map.keys(binding)) == Enum.sort(@fields) and valid_subject?(binding) and
         valid_authority?(binding["authority"], binding["plan_revision"]) and inputs?(binding["inputs"]) do
      {:ok, Map.update!(binding, "inputs", &Enum.sort_by(&1, fn input -> {WorkRef.key(input["work"]), input["artifact"]} end))}
    else
      {:error, :invalid_execution_binding}
    end
  end

  def normalize(_), do: {:error, :invalid_execution_binding}

  defp valid_subject?(binding) do
    WorkRef.validate(binding["work"]) == :ok and binding["work"]["kind"] == "issue" and
      Enum.all?(~w(plan_revision contract_sha policy_sha), &digest?(binding[&1])) and
      case binding["role"] do
        "developer" -> is_nil(binding["candidate"]) or digest?(binding["candidate"])
        "verifier" -> digest?(binding["candidate"])
        _ -> false
      end
  end

  defp valid_authority?(%{"work" => work, "source" => source, "actor" => actor, "revision" => revision} = authority, revision) do
    map_size(authority) == 4 and WorkRef.validate(work) == :ok and work["kind"] == "issue" and text?(source) and text?(actor)
  end

  defp valid_authority?(_, _), do: false

  defp inputs?(inputs) when is_list(inputs) do
    Enum.all?(inputs, fn
      %{"work" => work, "artifact" => artifact, "version" => version, "verification" => verification} = input ->
        Enum.sort(Map.keys(input)) == Enum.sort(@input_fields) and WorkRef.validate(work) == :ok and
          work["kind"] == "issue" and Enum.all?([artifact, version, verification], &text?/1)

      _ ->
        false
    end) and length(Enum.uniq_by(inputs, &{&1["work"], &1["artifact"]})) == length(inputs)
  end

  defp inputs?(_), do: false

  defp same_work(%{"execution_binding" => %{"work" => work}}, %{"work" => work}), do: :ok
  defp same_work(%{"execution_binding" => %{}}, _), do: {:error, :execution_work_changed}
  defp same_work(_, _), do: :ok

  defp allocated?(record), do: is_binary(record["thread_id"]) or record["thread_allocation_intent"] == true

  defp rotatable?(record) do
    SymphonyElixir.CommandCheck.stopped?(record) and
      (not allocated?(record) or (text?(record["thread_id"]) and record["native_stop_confirmed"] == true))
  end

  defp rotate(record, binding) do
    history = record["execution_history"] || []
    history = if record["execution_binding"], do: history ++ [Map.take(record, @receipt_fields)], else: history

    record
    |> Map.drop(@native_fields)
    |> Map.put("execution_binding", binding)
    |> Map.put("execution_binding_sha", TaskWorkflow.digest(binding))
    |> Map.put("execution_generation", (record["execution_generation"] || 0) + 1)
    |> Map.put("execution_history", history)
  end

  defp digest?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)
  defp text?(value), do: is_binary(value) and String.trim(value) != ""
end
