defmodule SymphonyElixir.RunJournal do
  @moduledoc """
  Durable execution checkpoints, separate from repository Issue data.

  An exclusive directory fences admission across processes. Thread allocation uncertainty requires recovery; recorded threads are resumed
  only after native idle validation.
  """

  @spec admit(Path.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def admit(root, issue_id, opts \\ []) do
    directory = Path.join(root, key(issue_id))

    with :ok <- File.mkdir_p(directory),
         :ok <- File.mkdir(Path.join(directory, "executor.lock")) do
      result = admit_locked(directory, issue_id, opts)

      if match?({:error, _}, result) do
        File.rm(Path.join([directory, "executor.lock", "executor-owner.json"]))
        File.rmdir(Path.join(directory, "executor.lock"))
      end

      result
    else
      {:error, reason} -> {:error, {:run_admission_blocked, issue_id, reason}}
    end
  end

  defp admit_locked(directory, issue_id, opts) do
    with {:ok, previous} <- read(directory),
         true <- SymphonyElixir.CommandCheck.stopped?(previous || %{}) or {:error, :check_execution_requires_recovery},
         {:ok, record} <- admission(previous, issue_id),
         {:ok, record} <- SymphonyElixir.ExecutionBinding.bind(record, opts[:execution_binding]) do
      {:ok, host} = :inet.gethostname()

      record =
        record
        |> Map.drop(["handoff", "handoff_pending", "handoff_notice", "delivery", "stage_results", "blocker_reason", "control_restart"])
        |> Map.put("attempt_count", (record["attempt_count"] || 0) + 1)
        |> Map.put("attempt_id", Base.encode16(:crypto.strong_rand_bytes(16), case: :lower))
        |> Map.put("directory", directory)
        |> Map.put("host", to_string(host))
        |> Map.put("executor_os_pid", System.pid())

      with {:ok, record} <- carry_review_for_execution(previous, record),
           :ok <- save_lock_owner(record) do
        checkpoint(record, %{"phase" => "admitted"})
      end
    end
  end

  defp carry_review_for_execution(previous, record) do
    if record["execution_binding"], do: {:ok, record}, else: carry_pending_review(previous, record)
  end

  defp save_lock_owner(record) do
    owner = Map.take(record, ["attempt_id", "host", "executor_os_pid"])
    write_synced(Path.join([record["directory"], "executor.lock", "executor-owner.json"]), Jason.encode!(owner))
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
    :global.trans({{__MODULE__, directory}, self()}, fn -> write_checkpoint(record, changes) end, [node()])
  end

  defp write_checkpoint(%{"directory" => directory} = record, changes) do
    now = DateTime.to_iso8601(DateTime.utc_now())
    event = Map.take(changes, ["phase", "thread_id", "turn_id"]) |> Map.put("at", now) |> Map.put("attempt_id", record["attempt_id"])
    events = Enum.take((record["events"] || []) ++ [event], -200)
    updated = record |> Map.merge(changes) |> Map.put("updated_at", now) |> Map.put("events", events)
    updated = account_budget(updated, changes)
    updated = Map.put(updated, "stage_results", stage_results(updated))
    updated = if record["execution_binding"], do: Map.put(updated, "journal_version", (record["journal_version"] || 0) + 1), else: updated
    path = Path.join(directory, "run.json")
    temporary = path <> ".pending"

    with :ok <- bound_checkpoint_owner(record),
         :ok <- SymphonyElixir.ExecutionBinding.check_native_identity(record, changes),
         :ok <- write_synced(temporary, Jason.encode!(updated)),
         :ok <- File.rename(temporary, path) do
      {:ok, updated}
    end
  end

  # A late developer callback must not overwrite the verifier generation, even
  # when both workers run in the same scheduler OS process. The admission lock
  # and monotonically increasing journal version fence these independent races.
  defp bound_checkpoint_owner(%{"execution_binding" => %{}, "directory" => directory} = record) do
    with {:ok, current} <- read(directory),
         true <- is_nil(current) or current["journal_version"] == record["journal_version"],
         true <- executor_checkpoint_owner?(record) or reconciler_checkpoint_owner?(record, current) do
      :ok
    else
      _ -> {:error, :stale_or_unowned_execution_checkpoint}
    end
  end

  defp bound_checkpoint_owner(record) do
    case read(record["directory"]) do
      {:ok, %{"execution_binding" => %{}}} -> {:error, :execution_binding_required}
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp executor_checkpoint_owner?(record) do
    with true <- record["executor_os_pid"] == System.pid(),
         {:ok, data} <- File.read(Path.join([record["directory"], "executor.lock", "executor-owner.json"])),
         {:ok, owner} <- Jason.decode(data) do
      owner == Map.take(record, ["attempt_id", "host", "executor_os_pid"])
    else
      _ -> false
    end
  end

  defp reconciler_checkpoint_owner?(record, current) do
    is_map(current) and current["attempt_id"] == record["attempt_id"] and
      File.read(Path.join([record["directory"], "executor.lock", "reconcile-owner"])) == {:ok, System.pid()}
  end

  defp account_budget(%{"workflow" => %{} = flow} = record, changes) do
    flow = SymphonyElixir.TaskWorkflow.tick(flow, System.system_time(:millisecond))
    human = SymphonyElixir.TaskWorkflow.human_wait?(flow)
    flow = if changes["native_stop_confirmed"] == true and (human or flow["manifest"]), do: Map.put(flow, "charging", false), else: flow
    Map.put(record, "workflow", flow)
  end

  defp account_budget(record, _changes), do: record

  @spec stage_results(map()) :: map()
  def stage_results(record) do
    stages = %{
      "execution_admitted" => if(record["attempt_id"], do: "passed", else: "not_verified"),
      "mr_publication" => if(get_in(record, ["delivery", "mr_verified"]) == true, do: "passed", else: "not_verified"),
      "review_handoff" => if(get_in(record, ["handoff", "kind"]) == "review", do: "passed", else: "not_verified"),
      "native_execution_stopped" => if(record["native_stop_confirmed"] == true, do: "passed", else: "not_verified"),
      "business_validation" => business_evidence(record),
      "error" => record["blocker_reason"]
    }

    if get_in(record, ["workflow", "contract", "type"]) == "research",
      do: Map.merge(stages, %{"mr_publication" => "not_applicable", "review_handoff" => "not_applicable"}),
      else: stages
  end

  defp business_evidence(record) do
    Map.get(%{"research" => "see_issue_evidence", "mixed" => "see_manifest_evidence"}, get_in(record, ["workflow", "contract", "type"]), "see_mr_evidence")
  end

  @spec complete(map(), String.t()) :: :ok | {:error, term()}
  def complete(record, phase) do
    with {:ok, _record} <- checkpoint(record, %{"phase" => phase}) do
      release_lock(record)
    end
  end

  @spec release_lock(map()) :: :ok | {:error, term()}
  def release_lock(record) do
    path = Path.join([record["directory"], "executor.lock", "executor-owner.json"])

    case File.read(path) do
      {:ok, body} ->
        with {:ok, owner} <- Jason.decode(body),
             true <- owner == Map.take(record, ["attempt_id", "host", "executor_os_pid"]),
             {:ok, ["executor-owner.json"]} <- File.ls(Path.dirname(path)),
             :ok <- File.rm(path) do
          File.rmdir(Path.dirname(path))
        else
          error -> {:error, {:execution_lock_owner_changed, error}}
        end

      {:error, :enoent} ->
        File.rmdir(Path.dirname(path))

      error ->
        error
    end
  end

  @spec recoverable_lock?(map()) :: boolean()
  def recoverable_lock?(record) do
    lock = Path.join(record["directory"], "executor.lock")

    if File.exists?(lock) do
      with {:ok, body} <- File.read(Path.join(lock, "executor-owner.json")),
           {:ok, owner} <- Jason.decode(body) do
        owner == Map.take(record, ["attempt_id", "host", "executor_os_pid"])
      else
        _ -> false
      end
    else
      true
    end
  end

  @spec read(Path.t()) :: {:ok, map() | nil} | {:error, term()}
  def read(directory) do
    case File.read(Path.join(directory, "run.json")) do
      {:ok, data} -> decode_record(data)
      {:error, :enoent} -> {:ok, nil}
      error -> error
    end
  end

  defp decode_record(data) do
    case Jason.decode(data) do
      {:ok, %{} = record} -> {:ok, record}
      {:ok, _} -> {:error, :invalid_run_journal}
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
