defmodule SymphonyElixir.Beads.RunJournal do
  @moduledoc """
  Durable execution checkpoints, separate from Beads task data.

  An exclusive directory fences admission across processes. An uncertain checkpoint
  is never reclaimed automatically, including when its recorded process has exited.
  """

  @spec admit(Path.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def admit(root, issue_id) do
    directory = Path.join(root, key(issue_id))

    with :ok <- File.mkdir_p(directory),
         :ok <- File.mkdir(Path.join(directory, "executor.lock")),
         {:ok, previous} <- read(directory),
         {:ok, record} <- admission(previous, issue_id) do
      {:ok, host} = :inet.gethostname()

      record =
        record
        |> Map.delete("delivery")
        |> Map.delete("pre_session_blocked")
        |> Map.delete("blocker_reason")
        |> Map.put("attempt_count", (record["attempt_count"] || 0) + 1)
        |> Map.put("attempt_id", Base.encode16(:crypto.strong_rand_bytes(16), case: :lower))
        |> Map.put("directory", directory)
        |> Map.put("host", to_string(host))
        |> Map.put("executor_os_pid", System.pid())

      case checkpoint(record, %{"phase" => "admitted"}) do
        {:ok, record} -> {:ok, record}
        error -> error
      end
    else
      {:error, reason} -> {:error, {:run_admission_blocked, issue_id, reason}}
    end
  end

  @spec checkpoint(map(), map()) :: {:ok, map()} | {:error, term()}
  def checkpoint(%{"directory" => directory} = record, changes) do
    now = DateTime.to_iso8601(DateTime.utc_now())
    event = Map.take(changes, ["phase", "thread_id", "turn_id"]) |> Map.put("at", now) |> Map.put("attempt_id", record["attempt_id"])
    events = Enum.take((record["events"] || []) ++ [event], -200)
    updated = record |> Map.merge(changes) |> Map.put("updated_at", now) |> Map.put("events", events)
    path = Path.join(directory, "run.json")
    temporary = path <> ".pending"

    with :ok <- write_synced(temporary, Jason.encode!(updated)),
         :ok <- File.rename(temporary, path) do
      {:ok, updated}
    end
  end

  @spec complete(map(), String.t()) :: :ok | {:error, term()}
  def complete(record, phase) do
    with {:ok, _record} <- checkpoint(record, %{"phase" => phase}) do
      File.rmdir(Path.join(record["directory"], "executor.lock"))
    end
  end

  @spec read(Path.t()) :: {:ok, map() | nil} | {:error, term()}
  def read(directory) do
    case File.read(Path.join(directory, "run.json")) do
      {:ok, data} -> Jason.decode(data)
      {:error, :enoent} -> {:ok, nil}
      error -> error
    end
  end

  @spec directory(Path.t(), String.t()) :: Path.t()
  def directory(root, issue_id), do: Path.join(root, key(issue_id))

  defp admission(nil, issue_id) do
    {:ok, host} = :inet.gethostname()

    {:ok,
     %{"host" => to_string(host), "executor_os_pid" => System.pid(), "issue_id" => issue_id, "owner" => "symphony-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower), "turn_count" => 0}}
  end

  defp admission(%{"phase" => "completed", "thread_id" => thread, "turn_id" => turn} = record, issue_id)
       when is_binary(thread) and is_binary(turn) do
    if record["issue_id"] == issue_id and is_binary(record["owner"]), do: {:ok, record}, else: {:error, :issue_identity_mismatch}
  end

  defp admission(%{"phase" => "completed", "thread_id" => thread, "turn_id" => nil, "turn_count" => 0, "recovery" => "operator confirmed stopped; native resume proved idle"} = record, issue_id)
       when is_binary(thread) do
    if record["issue_id"] == issue_id and is_binary(record["owner"]), do: {:ok, record}, else: {:error, :issue_identity_mismatch}
  end

  defp admission(%{"phase" => "completed", "thread_id" => nil, "turn_id" => nil, "turn_count" => 0, "pre_turn_recovered" => true, "abandoned_pre_turn_thread_id" => abandoned} = record, issue_id)
       when is_binary(abandoned) do
    if record["issue_id"] == issue_id and is_binary(record["owner"]), do: {:ok, record}, else: {:error, :issue_identity_mismatch}
  end

  defp admission(%{"phase" => "completed", "thread_id" => nil, "turn_id" => nil, "turn_count" => 0, "pre_session_blocked" => true} = record, issue_id) do
    if record["issue_id"] == issue_id and is_binary(record["owner"]),
      do: {:ok, Map.put(record, "pre_turn_recovered", true)},
      else: {:error, :issue_identity_mismatch}
  end

  defp admission(_record, _issue_id), do: {:error, :uncertain_or_awaiting_run}

  defp key(issue_id), do: Base.encode16(:crypto.hash(:sha256, issue_id), case: :lower)

  defp write_synced(path, data) do
    with {:ok, file} <- :file.open(String.to_charlist(path), [:write, :binary, :raw]) do
      try do
        with :ok <- :file.write(file, data), do: :file.sync(file)
      after
        :file.close(file)
      end
    end
  end
end
