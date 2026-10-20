defmodule SymphonyElixir.TaskRecovery do
  @moduledoc "Recover a proven interrupted local member without replacing its attempt or native session."
  alias SymphonyElixir.{CommandCheck, NativeStop, RunJournal, TaskExecution, TaskWorkspace}

  @spec recover(map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def recover(record, executions, opts) do
    with {:ok, owned} <- RunJournal.recover_member(record),
         result = stop(owned),
         {:ok, current} <- RunJournal.read(owned["directory"]) do
      reason = if match?({:ok, _}, result), do: :executor_exited, else: {:recovery_stop_unconfirmed, result}
      TaskExecution.finish(current, {:error, reason}, executions, opts)
    end
  end

  defp stop(record) do
    native = capture(fn -> stop_native(record) end)

    with {:ok, current} <- RunJournal.read(record["directory"]) do
      checks = capture(fn -> stop_checks(current) end)

      case {native, checks} do
        {{:ok, _}, {:ok, stopped}} -> {:ok, stopped}
        {{:error, _} = error, _} -> error
        {_, error} -> error
      end
    end
  end

  defp stop_checks(record) do
    with {:ok, current} <- cancel_checks(record),
         do: await_checks(current, System.monotonic_time(:millisecond) + 2_000)
  end

  defp capture(fun) do
    fun.()
  catch
    kind, reason -> {:error, {:recovery_failed, kind, inspect(reason)}}
  end

  defp stop_native(%{"native_stop_confirmed" => true} = record), do: {:ok, record}

  defp stop_native(record) do
    result =
      if is_nil(record["thread_id"]) and record["thread_allocation_intent"] != true do
        {:ok, %{"native_stop_confirmed" => true}}
      else
        with :ok <- TaskWorkspace.validate(record), do: NativeStop.confirm(record)
      end

    with {:ok, evidence} <- result do
      RunJournal.checkpoint(record, Map.put(evidence, "task_session_phase", "stopped"))
    end
  end

  defp cancel_checks(record) do
    entries = Map.get(record, "check_runs", %{})

    if is_map(entries) do
      Enum.reduce_while(entries, {:ok, record}, &cancel_check/2)
    else
      {:error, :check_stop_unconfirmed}
    end
  end

  defp cancel_check({id, %{"status" => "running"}}, {:ok, current}) do
    with :ok <- CommandCheck.cancel(current, id),
         {:ok, current} <- RunJournal.read(current["directory"]) do
      {:cont, {:ok, current}}
    else
      error -> {:halt, error}
    end
  end

  defp cancel_check(_, result), do: {:cont, result}

  defp await_checks(record, deadline) do
    cond do
      CommandCheck.stopped?(record) ->
        {:ok, record}

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :check_stop_unconfirmed}

      true ->
        current = recover_checks(record)
        Process.sleep(25)
        await_checks(current, deadline)
    end
  end

  defp recover_checks(record) do
    Enum.reduce(record["check_runs"] || %{}, record, fn {id, _entry}, current ->
      case CommandCheck.recover(current, id) do
        {:ok, updated, _receipt} -> updated
        _ -> current
      end
    end)
  end
end
