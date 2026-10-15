defmodule SymphonyElixir.Beads.Recovery do
  @moduledoc "Explicit recovery of an observed native session after its executor stopped."
  alias SymphonyElixir.Beads.{Adapter, RunJournal}
  alias SymphonyElixir.Codex.AppServer

  @spec resume(map(), String.t(), boolean()) :: :ok | {:error, term()}
  def resume(settings, issue_id, executor_stopped) do
    directory = RunJournal.directory(Adapter.journal_root(settings), issue_id)

    with true <- executor_stopped || {:error, :executor_stop_confirmation_required},
         {:ok, %{} = record} <- RunJournal.read(directory),
         :ok <- recoverable(record, settings, issue_id),
         :ok <- recover_native(settings, record) do
      release_for_resume(settings, record)
    else
      {:ok, nil} -> {:error, :missing_run_record}
      error -> error
    end
  end

  @doc "Resume a parked native run while its scheduler stays alive; never steal an executor."
  @spec resume_online(map(), String.t()) :: :ok | {:error, term()}
  def resume_online(settings, issue_id) do
    directory = RunJournal.directory(Adapter.journal_root(settings), issue_id)
    with {:ok, %{} = record} <- RunJournal.read(directory),
         true <- record["issue_id"] == issue_id and record["beads_dir"] == Adapter.beads_dir(settings) || {:error, :run_scope_mismatch},
         true <- record["phase"] == "blocked" || {:error, :run_not_parked},
         false <- File.exists?(Path.join(directory, "executor.lock")),
         {:ok, record} <- prove_parked(record),
         true <- record["native_stop_confirmed"] == true || {:error, :native_stop_unconfirmed},
         :ok <- recover_native(settings, record) do
      release_for_resume(settings, record)
    else
      true -> {:error, :executor_active}
      {:error, _} = error -> error
      _ -> {:error, :run_not_safely_resumable}
    end
  end

  defp prove_parked(%{"native_stop_confirmed" => true, "pre_session_blocked" => true} = record),
    do: {:ok, record |> Map.put_new("thread_id", nil) |> Map.put_new("turn_id", nil)}
  defp prove_parked(%{"native_stop_confirmed" => true} = record), do: {:ok, record}
  defp prove_parked(record) do
    phases = Enum.map(record["events"] || [], & &1["phase"])
    if is_nil(record["thread_id"]) and is_nil(record["turn_id"]) and record["turn_count"] == 0 and
         record["thread_allocation_intent"] != true and "admitted" in phases and
         Enum.all?(phases, &(&1 in [nil, "admitted", "claimed", "blocked"])) do
      RunJournal.checkpoint(record, %{"pre_session_blocked" => true, "native_stop_confirmed" => true, "thread_id" => nil, "turn_id" => nil})
    else
      {:error, :native_stop_unconfirmed}
    end
  end

  @spec resume_completed(map(), String.t(), map()) :: :ok | {:error, term()}
  def resume_completed(settings, issue_id, feedback) do
    directory = RunJournal.directory(Adapter.journal_root(settings), issue_id)

    with false <- File.exists?(Path.join(directory, "executor.lock")),
         {:ok, %{"phase" => "awaiting_human"} = record} <- RunJournal.read(directory),
         true <- record["issue_id"] == issue_id and record["beads_dir"] == Adapter.beads_dir(settings),
         true <- native_identity?(record),
         {:ok, changes} <- recovery_changes(settings, record, feedback),
         {:ok, session} <- inspect_native_session(settings, record) do
      AppServer.stop_session(session)

      with {:ok, record} <- RunJournal.checkpoint(record, changes) do
        release_for_resume(settings, record)
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :run_not_safely_resumable}
    end
  end

  @spec recovery_changes(map(), map(), map()) :: {:ok, map()} | {:error, term()}
  def recovery_changes(settings, record, feedback) do
    cause = field(feedback, :cause) || "review"
    fingerprint_key = if cause == "runtime", do: "runtime_recovery_fingerprint", else: "repair_fingerprint"

    with {:ok, counter, limit} <- recovery_budget(settings.provider, cause),
         true <- (record[counter] || 0) < limit || {:error, :recovery_budget_exhausted} do
      {:ok,
       %{
         "feedback" => feedback,
         fingerprint_key => field(feedback, :fingerprint),
         counter => (record[counter] || 0) + 1,
         "recovery_cause" => cause,
         "trigger_actor" => field(feedback, :actor),
         "caused_by_event" => field(feedback, :caused_by_event)
       }}
    end
  end

  defp recovery_budget(provider, "runtime"), do: budget("runtime_recovery_count", provider["max_runtime_recoveries"] || 2)
  defp recovery_budget(provider, "review"), do: budget("repair_count", provider["max_repair_runs"] || 3)
  defp recovery_budget(_provider, _cause), do: {:error, :unknown_recovery_cause}
  defp budget(counter, limit) when is_integer(limit) and limit >= 0, do: {:ok, counter, limit}
  defp budget(_counter, _limit), do: {:error, :invalid_recovery_budget}
  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp recover_native(_settings, %{"pre_session_blocked" => true, "thread_id" => nil, "turn_id" => nil, "turn_count" => 0}), do: :ok

  defp recover_native(_settings, %{"thread_id" => nil, "turn_count" => 0, "pre_turn_recovered" => true, "phase" => phase}) when phase in ["admitted", "claimed"], do: :ok

  defp recover_native(settings, record) do
    case inspect_native_session(settings, record) do
      {:ok, session} ->
        AppServer.stop_session(session)
        :ok

      {:error, {:response_error, %{"code" => -32_600, "message" => message}}} = error ->
        recover_absent_rollout(record, message, error)

      error ->
        error
    end
  end

  defp recover_absent_rollout(record, message, error) do
    if unstarted_thread?(record) and message == "no rollout found for thread id " <> record["thread_id"] do
      checkpoint_recovery(record)
    else
      error
    end
  end

  defp unstarted_thread?(record),
    do: record["phase"] == "thread_ready" and record["turn_count"] == 0 and is_nil(record["turn_id"])

  defp checkpoint_recovery(record) do
    case RunJournal.checkpoint(record, %{"abandoned_pre_turn_thread_id" => record["thread_id"]}) do
      {:ok, _} -> :ok
      failure -> failure
    end
  end

  defp inspect_native_session(settings, record) do
    opts = [
      inspect_only: true,
      tracker_settings: settings,
      resume_thread_id: record["thread_id"],
      expected_turn_id: record["turn_id"] || :no_turns
    ]

    AppServer.start_session(record["workspace"], opts)
  end

  defp recoverable(record, settings, issue_id) do
    cond do
      record["issue_id"] != issue_id ->
        {:error, :run_identity_mismatch}

      record["beads_dir"] != Adapter.beads_dir(settings) ->
        {:error, :run_scope_mismatch}

      not (native_identity?(record) or recovered_before_thread?(record) or pre_session_blocked?(record)) ->
        {:error, :missing_native_identity}

      true ->
        stopped_executor?(record)
    end
  end

  defp stopped_executor?(record) do
    cond do
      record["host"] != hostname() -> {:error, :unknown_executor_host}
      not is_binary(record["executor_os_pid"]) -> {:error, :unknown_executor_process}
      File.exists?(Path.join("/proc", record["executor_os_pid"])) -> {:error, :executor_may_still_be_alive}
      not File.dir?("/proc") -> {:error, :executor_liveness_unavailable}
      true -> :ok
    end
  end

  defp pre_session_blocked?(record),
    do: record["pre_session_blocked"] == true and is_nil(record["thread_id"]) and is_nil(record["turn_id"]) and record["turn_count"] == 0

  defp recovered_before_thread?(record) do
    record["phase"] in ["admitted", "claimed"] and record["pre_turn_recovered"] == true and
      is_nil(record["thread_id"]) and is_nil(record["turn_id"]) and record["turn_count"] == 0
  end

  defp native_identity?(record),
    do:
      is_binary(record["thread_id"]) and
        (is_binary(record["turn_id"]) or (record["phase"] == "thread_ready" and record["turn_count"] == 0 and is_nil(record["turn_id"])))

  defp pre_turn?(record) do
    pre_session_blocked?(record) or
      (record["phase"] in ["admitted", "claimed", "thread_ready"] and record["turn_count"] == 0 and is_nil(record["turn_id"]))
  end

  defp release_for_resume(settings, record) do
    {:ok, record} = RunJournal.read(record["directory"])
    pre_turn = pre_turn?(record)
    reset_thread = pre_turn and record["abandoned_pre_turn_thread_id"] == record["thread_id"]

    with {:ok, [issue]} <- Adapter.command(settings, ["show", record["issue_id"], "--json"]),
         true <- issue["status"] in ["blocked", "in_progress"] || {:error, :issue_not_resumable},
         {:ok, _} <-
           RunJournal.checkpoint(record, %{
             "phase" => "completed",
             "resume_authorized" => true,
             "blocker_reason" => nil,
             "thread_id" => if(reset_thread, do: nil, else: record["thread_id"]),
             "turn_id" => record["turn_id"],
             "pre_turn_recovered" => pre_turn,
             "delivery" => nil,
             "recovery" => "operator confirmed stopped; native resume proved idle"
           }),
         {:ok, _} <-
           Adapter.command(settings, [
             "update",
             record["issue_id"],
             "--if-assignee",
             record["owner"],
             "--if-status",
             issue["status"],
             "--status",
             "in_progress",
             "--remove-label",
             "human",
             "--set-metadata",
             "symphony_gate=resumed",
             "--json"
           ]) do
      case File.rmdir(Path.join(record["directory"], "executor.lock")) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        error -> error
      end
    end
  end

  defp hostname do
    {:ok, host} = :inet.gethostname()
    to_string(host)
  end
end
