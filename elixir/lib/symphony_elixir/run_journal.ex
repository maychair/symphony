defmodule SymphonyElixir.RunJournal do
  @moduledoc """
  Durable execution checkpoints, separate from repository Issue data.

  An exclusive directory fences admission across processes. Thread allocation uncertainty requires recovery; recorded threads are resumed
  only after native idle validation.
  """

  @spec admit(Path.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def admit(root, issue_id) do
    directory = Path.join(root, key(issue_id))

    with :ok <- File.mkdir_p(directory),
         :ok <- File.mkdir(Path.join(directory, "executor.lock")) do
      result = admit_locked(directory, issue_id)
      if match?({:error, _}, result), do: File.rmdir(Path.join(directory, "executor.lock"))
      result
    else
      {:error, reason} -> {:error, {:run_admission_blocked, issue_id, reason}}
    end
  end

  defp admit_locked(directory, issue_id) do
    with {:ok, previous} <- read(directory),
         {:ok, record} <- admission(previous, issue_id) do
      {:ok, host} = :inet.gethostname()

      record =
        record
        |> Map.drop(["handoff", "handoff_pending", "handoff_notice", "delivery", "stage_results", "blocker_reason", "control_restart"])
        |> Map.put("attempt_count", (record["attempt_count"] || 0) + 1)
        |> Map.put("attempt_id", Base.encode16(:crypto.strong_rand_bytes(16), case: :lower))
        |> Map.put("directory", directory)
        |> Map.put("host", to_string(host))
        |> Map.put("executor_os_pid", System.pid())

      with {:ok, record} <- carry_pending_review(previous, record) do
        checkpoint(record, %{"phase" => "admitted"})
      end
    end
  end

  defp carry_pending_review(%{"thread_id" => thread} = previous, record) when is_binary(thread) do
    old = Path.join(record["directory"], "review-request-#{previous["attempt_id"]}.json")

    if previous["handoff"] || not File.exists?(old) do
      {:ok, record}
    else
      path = Path.join(record["directory"], "review-request-#{record["attempt_id"]}.json")

      with {:ok, data} <- File.read(old),
           {:ok, %{} = request} <- Jason.decode(data),
           true <- request["attempt_id"] == previous["attempt_id"] and request["issue_url"] == previous["issue_url"],
           :ok <- write_synced(path <> ".pending", Jason.encode!(Map.put(request, "attempt_id", record["attempt_id"]))),
           :ok <- File.rename(path <> ".pending", path) do
        {:ok, Map.put(record, "handoff_notice", previous["handoff_notice"])}
      else
        error -> {:error, {:pending_review_recovery_failed, error}}
      end
    end
  end

  defp carry_pending_review(_, record), do: {:ok, record}

  @spec checkpoint(map(), map()) :: {:ok, map()} | {:error, term()}
  def checkpoint(%{"directory" => directory} = record, changes) do
    now = DateTime.to_iso8601(DateTime.utc_now())
    event = Map.take(changes, ["phase", "thread_id", "turn_id"]) |> Map.put("at", now) |> Map.put("attempt_id", record["attempt_id"])
    events = Enum.take((record["events"] || []) ++ [event], -200)
    updated = record |> Map.merge(changes) |> Map.put("updated_at", now) |> Map.put("events", events)
    updated = account_budget(updated, changes)
    updated = Map.put(updated, "stage_results", stage_results(updated))
    path = Path.join(directory, "run.json")
    temporary = path <> ".pending"

    with :ok <- write_synced(temporary, Jason.encode!(updated)),
         :ok <- File.rename(temporary, path) do
      {:ok, updated}
    end
  end

  defp account_budget(%{"workflow" => %{} = flow} = record, changes) do
    flow = SymphonyElixir.TaskWorkflow.tick(flow, System.system_time(:millisecond))
    human = Enum.any?(Map.values(flow["restrictions"]), &(&1["scope"] == "task" and &1["kind"] in ["pause", "decision", "review", "acceptance", "scope", "cancel"]))
    flow = if changes["native_stop_confirmed"] == true and (human or flow["manifest"]), do: Map.put(flow, "charging", false), else: flow
    Map.put(record, "workflow", flow)
  end

  defp account_budget(record, _changes), do: record

  @spec stage_results(map()) :: map()
  def stage_results(record) do
    %{
      "execution_admitted" => if(record["attempt_id"], do: "passed", else: "not_verified"),
      "mr_publication" => if(get_in(record, ["delivery", "mr_verified"]) == true, do: "passed", else: "not_verified"),
      "review_handoff" => if(get_in(record, ["handoff", "kind"]) == "review", do: "passed", else: "not_verified"),
      "native_execution_stopped" => if(record["native_stop_confirmed"] == true, do: "passed", else: "not_verified"),
      "business_validation" => "see_mr_evidence",
      "error" => record["blocker_reason"]
    }
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

  @spec executor_state(map()) :: :alive | :stopped | :unknown
  def executor_state(record) do
    {:ok, host} = :inet.gethostname()
    pid = record["executor_os_pid"]

    cond do
      record["host"] != to_string(host) -> :unknown
      not is_binary(pid) or not String.match?(pid, ~r/^[1-9][0-9]*$/) -> :unknown
      not File.dir?("/proc") -> :unknown
      File.exists?(Path.join("/proc", pid)) -> :alive
      true -> :stopped
    end
  end

  @spec directory(Path.t(), String.t()) :: Path.t()
  def directory(root, issue_id), do: Path.join(root, key(issue_id))

  defp admission(nil, issue_id) do
    {:ok, host} = :inet.gethostname()

    {:ok,
     %{"host" => to_string(host), "executor_os_pid" => System.pid(), "issue_id" => issue_id, "owner" => "symphony-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower), "turn_count" => 0}}
  end

  defp admission(%{"phase" => "completed"} = record, issue_id) do
    cond do
      record["issue_id"] != issue_id or not is_binary(record["owner"]) -> {:error, :issue_identity_mismatch}
      is_binary(record["thread_id"]) or record["thread_allocation_intent"] != true -> {:ok, record}
      true -> {:error, :uncertain_thread_allocation}
    end
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
