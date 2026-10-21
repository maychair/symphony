defmodule SymphonyElixir.NativeStop do
  @moduledoc """
  Halt and read back a recorded native thread without resuming or allocating work.
  The caller owns execution fencing and persistence; this module only supplies
  native stop evidence. Closing a transport is never stop confirmation.
  """
  alias SymphonyElixir.{Codex.AppServer, Config}

  def confirm(record, opts \\ [])

  @spec confirm(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def confirm(%{"thread_id" => thread, "workspace" => workspace} = record, opts)
      when is_binary(thread) and thread != "" and is_binary(workspace) and workspace != "" do
    backend = Keyword.get(opts, :backend, AppServer)
    ref = make_ref()

    session_opts =
      [
        resume_thread_id: thread,
        expected_turn_id: record["turn_id"] || :no_turns,
        suspend_goal: true,
        interrupt_active: true,
        halt_only: true,
        reconcile_terminal_turns: true,
        worker_host: record["worker_host"],
        tracker_settings: Config.settings!().tracker,
        on_thread_observed: fn observation -> send(self(), {:native_stop_observed, ref, observation}) end
      ] ++ Keyword.take(opts, [:review_only, :dynamic_tool_binding])

    with {:ok, session} <- backend.start_session(workspace, session_opts) do
      try do
        observation(record, thread, workspace, ref)
      after
        backend.stop_session(session)
      end
    end
  end

  def confirm(_record, _opts), do: {:error, :native_stop_identity_missing}

  @spec confirm_session(AppServer.session()) :: {:ok, map()} | {:error, term()}
  def confirm_session(session) do
    ref = make_ref()
    record = %{"worker_host" => session.worker_host}
    observer = fn result -> send(self(), {:native_stop_observed, ref, result}) end
    opts = [expected_turn_id: :no_turns, on_thread_observed: observer]

    with {:ok, _thread} <- AppServer.halt_session(session, opts) do
      observation(record, session.thread_id, session.workspace, ref)
    end
  end

  defp observation(record, thread, workspace, ref) do
    receive do
      {:native_stop_observed, ^ref, observation} ->
        turn = if is_binary(observation[:turn_id]), do: observation[:turn_id]

        receipt = %{
          "thread_id" => thread,
          "turn_id" => turn,
          "workspace" => workspace,
          "worker_host" => record["worker_host"],
          "source" => "thread/read",
          "history_source" => "thread/turns/list",
          "observed_at" => DateTime.to_iso8601(DateTime.utc_now())
        }

        {:ok, %{"native_stop_confirmed" => true, "turn_id" => turn, "native_stop_receipt" => receipt}}
    after
      0 -> {:error, :native_stop_observation_missing}
    end
  end
end
