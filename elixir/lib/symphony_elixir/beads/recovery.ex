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

  @spec resume_completed(map(), String.t(), map()) :: :ok | {:error, term()}
  def resume_completed(settings, issue_id, feedback) do
    directory = RunJournal.directory(Adapter.journal_root(settings), issue_id)

    with false <- File.exists?(Path.join(directory, "executor.lock")),
         {:ok, %{"phase" => "awaiting_human"} = record} <- RunJournal.read(directory),
         true <- record["issue_id"] == issue_id and record["beads_dir"] == Adapter.beads_dir(settings),
         true <- native_identity?(record),
         {:ok, session} <- inspect_native_session(settings, record) do
      AppServer.stop_session(session)

      with {:ok, record} <- RunJournal.checkpoint(record, %{"feedback" => feedback, "repair_fingerprint" => feedback[:fingerprint], "repair_count" => (record["repair_count"] || 0) + 1}) do
        release_for_resume(settings, record)
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :run_not_safely_resumable}
    end
  end

  defp recover_native(_settings, %{"thread_id" => nil, "turn_count" => 0, "pre_turn_recovered" => true, "phase" => phase}) when phase in ["admitted", "claimed"], do: :ok

  defp recover_native(settings, record) do
    case inspect_native_session(settings, record) do
      {:ok, session} ->
        AppServer.stop_session(session)
        :ok

      {:error, {:response_error, %{"code" => -32_600, "message" => message}}} = error ->
        if record["phase"] == "thread_ready" and record["turn_count"] == 0 and is_nil(record["turn_id"]) and
             message == "no rollout found for thread id " <> record["thread_id"] do
          case RunJournal.checkpoint(record, %{"abandoned_pre_turn_thread_id" => record["thread_id"]}) do
            {:ok, _} -> :ok
            failure -> failure
          end
        else
          error
        end

      error ->
        error
    end
  end

  defp inspect_native_session(settings, record) do
    opts = [
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

      not (native_identity?(record) or recovered_before_thread?(record)) ->
        {:error, :missing_native_identity}

      record["host"] != hostname() ->
        {:error, :unknown_executor_host}

      not is_binary(record["executor_os_pid"]) ->
        {:error, :unknown_executor_process}

      File.exists?(Path.join("/proc", record["executor_os_pid"])) ->
        {:error, :executor_may_still_be_alive}

      not File.dir?("/proc") ->
        {:error, :executor_liveness_unavailable}

      true ->
        :ok
    end
  end

  defp recovered_before_thread?(record) do
    record["phase"] in ["admitted", "claimed"] and record["pre_turn_recovered"] == true and
      is_nil(record["thread_id"]) and is_nil(record["turn_id"]) and record["turn_count"] == 0
  end

  defp native_identity?(record),
    do:
      is_binary(record["thread_id"]) and
        (is_binary(record["turn_id"]) or (record["phase"] == "thread_ready" and record["turn_count"] == 0 and is_nil(record["turn_id"])))

  defp release_for_resume(settings, record) do
    {:ok, record} = RunJournal.read(record["directory"])
    pre_turn = record["phase"] in ["admitted", "claimed", "thread_ready"] and record["turn_count"] == 0 and is_nil(record["turn_id"])
    reset_thread = pre_turn and record["abandoned_pre_turn_thread_id"] == record["thread_id"]

    with {:ok, [issue]} <- Adapter.command(settings, ["show", record["issue_id"], "--json"]),
         true <- issue["status"] in ["blocked", "in_progress"] || {:error, :issue_not_resumable},
         {:ok, _} <-
           RunJournal.checkpoint(record, %{
             "phase" => "completed",
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
