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
         {:ok, session} <- inspect_native_session(settings, record) do
      AppServer.stop_session(session)
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

  defp inspect_native_session(settings, record) do
    opts = [
      tracker_settings: settings,
      resume_thread_id: record["thread_id"],
      expected_turn_id: record["turn_id"]
    ]

    AppServer.start_session(record["workspace"], opts)
  end

  defp recoverable(record, settings, issue_id) do
    cond do
      record["issue_id"] != issue_id -> {:error, :run_identity_mismatch}
      record["beads_dir"] != Adapter.beads_dir(settings) -> {:error, :run_scope_mismatch}
      not native_identity?(record) -> {:error, :missing_native_identity}
      record["host"] != hostname() -> {:error, :unknown_executor_host}
      not is_binary(record["executor_os_pid"]) -> {:error, :unknown_executor_process}
      File.exists?(Path.join("/proc", record["executor_os_pid"])) -> {:error, :executor_may_still_be_alive}
      not File.dir?("/proc") -> {:error, :executor_liveness_unavailable}
      true -> :ok
    end
  end

  defp native_identity?(record), do: is_binary(record["thread_id"]) and is_binary(record["turn_id"])

  defp release_for_resume(settings, record) do
    with {:ok, [issue]} <- Adapter.command(settings, ["show", record["issue_id"], "--json"]),
         true <- issue["status"] in ["blocked", "in_progress"] || {:error, :issue_not_resumable},
         {:ok, _} <- RunJournal.checkpoint(record, %{"phase" => "completed", "delivery" => nil, "recovery" => "operator confirmed stopped; native resume proved idle"}),
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
