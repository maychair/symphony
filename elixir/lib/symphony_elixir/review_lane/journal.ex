defmodule SymphonyElixir.ReviewLane.Journal do
  @moduledoc "Exclusive native journal transport with predecessor-controller exclusion."
  alias SymphonyElixir.ReviewLane.Owner

  @broker_path Path.expand("../../../priv/review_journal.py", __DIR__)
  @external_resource @broker_path
  @broker File.read!(@broker_path)
  @timeout 5_000

  @spec open(Path.t()) :: {:ok, map(), String.t() | nil} | {:error, term()}
  def open(directory) do
    with :ok <- File.mkdir_p(directory),
         python when is_binary(python) <- System.find_executable("python3") do
      port = Port.open({:spawn_executable, String.to_charlist(python)}, [:binary, :exit_status, {:packet, 4}, args: ["-u", "-c", @broker, directory, System.pid()]])
      journal = %{port: port, listener: Owner.new(self())}
      acquire(journal)
    else
      nil -> {:error, :review_journal_python_unavailable}
      error -> error
    end
  end

  defp acquire(journal) do
    with {:ok, %{"previous" => previous, "process_state" => status}} <- receive_reply(journal.port),
         :ok <- predecessor(previous, status),
         {:ok, true} <- request(journal, %{"op" => "claim", "listener" => journal.listener}),
         {:ok, body} <- request(journal, %{"op" => "read"}) do
      {:ok, journal, body}
    else
      error ->
        disconnect(journal.port)
        error
    end
  end

  defp predecessor(nil, _), do: :ok

  defp predecessor(%{"schema_version" => 1, "listener" => owner, "process" => process, "released" => released}, status)
       when is_map(process) and is_boolean(released) do
    if Owner.valid?(owner) and valid_process?(process) do
      if released or predecessor_stopped?(Owner.local_pid(owner), status),
        do: :ok,
        else: {:error, :previous_review_controller_not_stopped}
    else
      {:error, :invalid_review_journal_owner}
    end
  end

  defp predecessor(_, _), do: {:error, :invalid_review_journal_owner}

  defp predecessor_stopped?(nil, "stopped"), do: true
  defp predecessor_stopped?(pid, "alive") when is_pid(pid), do: not Process.alive?(pid)
  defp predecessor_stopped?(_, _), do: false

  defp valid_process?(process) do
    Enum.sort(Map.keys(process)) == ~w(boot machine namespace pid start) and
      Enum.all?(Map.values(process), &(is_binary(&1) and &1 != "")) and
      Enum.all?(~w(pid start), &Regex.match?(~r/^\d+$/, process[&1]))
  end

  @spec check(map() | nil) :: :ok | {:error, term()}
  def check(nil), do: {:error, :review_journal_not_owned}
  def check(journal), do: acknowledge(request(journal, %{"op" => "check"}))

  @spec write!(map(), String.t()) :: :ok
  def write!(journal, body) do
    case acknowledge(request(journal, %{"op" => "write", "body" => body})) do
      :ok -> :ok
      error -> raise "Review journal persistence failed: #{inspect(error)}"
    end
  end

  @spec close(map() | nil) :: :ok
  def close(nil), do: :ok

  def close(%{port: port} = journal) do
    if Port.info(port, :connected) == {:connected, self()} do
      request(journal, %{"op" => "release"})
      disconnect(port)
    end

    :ok
  end

  defp disconnect(port) do
    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp acknowledge({:ok, true}), do: :ok
  defp acknowledge({:error, _} = error), do: error

  defp request(%{port: port}, message) do
    if Port.info(port, :connected) == {:connected, self()} do
      Port.command(port, Jason.encode!(message))
      receive_reply(port)
    else
      {:error, :review_journal_not_owned}
    end
  rescue
    ArgumentError -> {:error, :review_journal_transport_closed}
  end

  defp receive_reply(port) do
    receive do
      {^port, {:data, data}} ->
        case decode(data) do
          {:ok, _} = reply ->
            reply

          error ->
            disconnect(port)
            error
        end

      {^port, {:exit_status, status}} ->
        {:error, {:review_journal_exit, status}}
    after
      @timeout ->
        disconnect(port)
        {:error, :review_journal_timeout}
    end
  end

  defp decode(data) do
    case Jason.decode(data) do
      {:ok, %{"ok" => value}} -> {:ok, value}
      {:ok, %{"error" => reason}} -> {:error, reason}
      _ -> {:error, :invalid_review_journal_response}
    end
  end
end
