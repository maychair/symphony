defmodule SymphonyElixir.CommandCheck do
  @moduledoc "Run a configured verifier command on a fixed Git artifact with durable process and output receipts."
  alias SymphonyElixir.{ExecutionBinding, RunJournal, TaskWorkflow}

  @runner_path Path.expand("../../priv/check_runner.py", __DIR__)
  @external_resource @runner_path
  @runner File.read!(@runner_path)

  @doc "Run once for this fixed verifier binding and check; an uncertain earlier launch is only recovered."
  @spec run(map(), map(), String.t(), map()) :: {:ok, map(), map()} | {:error, term()}
  def run(record, candidate, check_id, policy) do
    with {:ok, spec} <- specification(record, candidate, check_id, policy),
         {:ok, current} <- RunJournal.checkpoint(record, %{}),
         {:ok, current, entry} <- prepare(current, spec) do
      case entry["status"] do
        "prepared" -> execute(current, entry)
        _ -> recover(current, entry["id"])
      end
    end
  end

  @doc "Read a supervisor receipt without restarting an unknown check process."
  @spec recover(map(), String.t()) :: {:ok, map(), map()} | {:error, term()}
  def recover(record, id) do
    with %{} = entry <- check_entry(record, id),
         true <- entry["id"] == id and entry["status"] in ["running", "completed"],
         directory = directory(record, id),
         {:ok, raw} <- File.read(Path.join(directory, "receipt.json")),
         {:ok, %{} = receipt} <- Jason.decode(raw),
         :ok <- receipt_matches(receipt, entry["launch_spec"], directory),
         {:ok, current} <- save(record, Map.merge(entry, %{"status" => "completed", "receipt" => receipt})) do
      {:ok, current, receipt}
    else
      _ -> {:error, :check_receipt_unconfirmed}
    end
  end

  @doc "Read a bounded output preview only when its bytes still match the completed host receipt."
  @spec output(map(), String.t()) :: {:ok, map()} | {:error, atom()}
  def output(record, id) do
    with %{"id" => ^id, "status" => "completed", "receipt" => %{} = receipt} <- check_entry(record, id),
         {:ok, bytes} <- File.read(Path.join(directory(record, id), "output")),
         sha = Base.encode16(:crypto.hash(:sha256, bytes), case: :lower),
         true <- byte_size(bytes) == receipt["output_bytes"] and sha == receipt["output_sha"] do
      preview = binary_part(bytes, 0, min(byte_size(bytes), 16_384))
      utf8 = String.valid?(preview)
      output = if utf8, do: preview, else: Base.encode64(preview)
      encoding = if utf8, do: "utf8", else: "base64"
      truncated = byte_size(bytes) > byte_size(preview)
      {:ok, %{"output" => output, "output_encoding" => encoding, "output_truncated" => truncated}}
    else
      _ -> {:error, :check_output_unconfirmed}
    end
  end

  @doc "A stopped agent thread cannot permit replacement while a host check still has unknown stop state."
  @spec stopped?(map()) :: boolean()
  def stopped?(record) do
    case Map.get(record, "check_runs", %{}) do
      entries when is_map(entries) -> Enum.all?(entries, fn {_id, entry} -> terminal?(entry) end)
      _ -> false
    end
  end

  defp terminal?(%{"status" => "completed", "receipt" => %{"native_stop_confirmed" => true}}), do: true
  defp terminal?(%{"status" => "prepared"}), do: true
  defp terminal?(_), do: false

  @doc "Match published command results to actual host receipts for this verifier generation."
  @spec attest(map(), map(), map()) :: :ok | {:error, atom()}
  def attest(record, payload, policy) do
    if is_list(payload["checks"]) and Enum.all?(payload["checks"], &attested?(&1, record, policy)),
      do: :ok,
      else: {:error, :command_evidence_not_attested}
  end

  defp attested?(%{"id" => id} = check, record, policy) do
    case get_in(policy, ["checks", id, "kind"]) do
      "review" -> true
      "command" -> command_attested?(check, record)
      _ -> false
    end
  end

  defp attested?(_, _, _), do: false

  defp command_attested?(check, record) do
    matches =
      Enum.filter(record["check_runs"] || %{}, fn {_id, entry} ->
        entry["spec"]["check"] == check["id"] and entry["spec"]["binding"] == record["execution_binding"] and
          entry["spec"]["generation"] == record["execution_generation"]
      end)

    with [{id, %{"status" => "completed"} = entry}] <- matches,
         {:ok, raw} <- File.read(Path.join(directory(record, id), "receipt.json")),
         {:ok, receipt} <- Jason.decode(raw),
         :ok <- receipt_matches(receipt, entry["launch_spec"], directory(record, id)) do
      Enum.all?(~w(candidate command exit_code output_sha reason), &(check[&1] == receipt[&1])) and
        check["snapshot_valid"] == true and receipt["snapshot_valid"] == true
    else
      _ -> false
    end
  end

  @doc "Request cancellation of a recorded running check; only its later receipt confirms stop."
  @spec cancel(map(), String.t()) :: :ok | {:error, term()}
  def cancel(record, id) do
    case check_entry(record, id) do
      %{"status" => "running", "id" => ^id} ->
        with {:ok, _} <- RunJournal.checkpoint(record, %{}), do: File.write(Path.join(directory(record, id), "cancel"), "")

      _ ->
        {:error, :check_not_running}
    end
  end

  defp check_entry(record, id) do
    if is_binary(id) and Regex.match?(~r/\A[0-9a-f]{64}\z/, id) and is_map(record["check_runs"]),
      do: record["check_runs"][id]
  end

  defp specification(record, candidate, check_id, policy) do
    binding = record["execution_binding"]
    check = get_in(policy, ["checks", check_id])

    with {:ok, %{"role" => "verifier"} = binding} <- ExecutionBinding.normalize(binding),
         {:ok, ^record} <- ExecutionBinding.bind(record, binding),
         true <- is_binary(record["thread_id"]) and is_binary(record["workspace"]),
         true <- is_map(Map.get(record, "check_runs", %{})),
         true <- TaskWorkflow.digest(policy) == binding["policy_sha"],
         true <- candidate_matches?(candidate, binding),
         %{"kind" => "command", "command" => command, "artifact" => artifact, "timeout_ms" => timeout} <- check,
         true <- is_binary(command) and String.trim(command) != "" and is_integer(timeout) and timeout > 0,
         true <- tool_paths?(Map.get(check, "read_roots", [])) and tool_paths?(Map.get(check, "path", ["/usr/bin", "/bin"])),
         [%{"version" => revision}] <- Enum.filter(candidate["artifacts"], &(&1["id"] == artifact)),
         true <- is_binary(revision) and Regex.match?(~r/\A(?:[a-f0-9]{40}|[a-f0-9]{64})\z/, revision),
         {:ok, %{type: :regular}} <- File.lstat(Path.join(record["workspace"], ".git")),
         {git_directory, 0} <- git(record["workspace"], ["rev-parse", "--path-format=absolute", "--git-common-dir"]) do
      data = %{"binding" => binding, "generation" => record["execution_generation"], "check" => check_id, "revision" => revision}
      id = TaskWorkflow.digest(data)

      {:ok,
       Map.merge(data, %{
         "id" => id,
         "candidate" => binding["candidate"],
         "policy_sha" => binding["policy_sha"],
         "command" => command,
         "timeout_ms" => timeout,
         "max_output_bytes" => 1_048_576,
         "source" => record["workspace"],
         "git_directory" => String.trim(git_directory),
         "read_roots" => Map.get(check, "read_roots", []),
         "path" => Map.get(check, "path", ["/usr/bin", "/bin"]),
         "workspace" => Path.join(directory(record, id), "worktree")
       })}
    else
      _ -> {:error, :invalid_command_check}
    end
  end

  defp candidate_matches?(candidate, binding) when is_map(candidate) do
    payload = Map.take(candidate, ~w(work contract_sha inputs artifacts))

    candidate["digest"] == binding["candidate"] and TaskWorkflow.digest(payload) == binding["candidate"] and
      Enum.all?(~w(work contract_sha inputs), &(candidate[&1] == binding[&1])) and is_list(candidate["artifacts"]) and
      Enum.all?(candidate["artifacts"], &is_map/1)
  end

  defp candidate_matches?(_, _), do: false
  defp tool_paths?(paths) when is_list(paths), do: Enum.all?(paths, &(is_binary(&1) and Path.type(&1) == :absolute and &1 != "/" and File.dir?(&1)))
  defp tool_paths?(_), do: false

  defp prepare(record, spec) do
    case (record["check_runs"] || %{})[spec["id"]] do
      nil ->
        prepare_new(record, spec)

      %{"spec" => ^spec, "status" => status} = entry when status in ["prepared", "running", "completed"] ->
        {:ok, record, entry}

      _ ->
        {:error, :command_check_intent_changed}
    end
  end

  defp prepare_new(record, spec) do
    entry = %{"id" => spec["id"], "spec" => spec, "status" => "prepared"}

    if stopped?(record) do
      with {:ok, current} <- save(record, entry), do: {:ok, current, entry}
    else
      {:error, :another_check_running}
    end
  end

  defp execute(record, entry) do
    spec = entry["spec"]
    directory = directory(record, entry["id"])

    with :ok <- own_directory(record, entry["id"]),
         :ok <- checkout(spec),
         {:ok, current} <- RunJournal.checkpoint(record, %{}),
         {:ok, launch} <- launch_spec(current, spec),
         :ok <- write_spec(directory, launch),
         {:ok, current} <- save(current, Map.merge(entry, %{"status" => "running", "launch_spec" => launch})) do
      # The source is embedded into the release; removing the development checkout
      # cannot change the running supervisor implementation.
      System.cmd("python3", ["-c", @runner, Path.join(directory, "spec.json")], stderr_to_stdout: true)
      recover(current, entry["id"])
    end
  end

  defp own_directory(record, id) do
    parent = Path.join(record["directory"], "checks")
    directory = directory(record, id)

    with :ok <- File.mkdir_p(parent),
         {:ok, %{type: :directory}} <- File.lstat(parent) do
      case File.mkdir(directory) do
        :ok -> File.write(Path.join(directory, ".owner"), id, [:exclusive])
        error -> directory_error(error, directory, id)
      end
    else
      _ -> {:error, :unsafe_check_directory}
    end
  end

  defp directory_error(error, directory, id), do: if(error == {:error, :eexist}, do: check_owner(directory, id), else: error)

  defp check_owner(directory, id) do
    with {:ok, %{type: :directory}} <- File.lstat(directory),
         {:ok, %{type: :regular}} <- File.lstat(Path.join(directory, ".owner")),
         {:ok, ^id} <- File.read(Path.join(directory, ".owner")) do
      :ok
    else
      _ -> {:error, :unowned_check_directory}
    end
  end

  defp launch_spec(%{"workflow" => %{"schema_version" => 2, "budget_ms" => budget, "used_ms" => used}} = record, spec)
       when is_integer(budget) and is_integer(used) and used >= 0 do
    if budget > used and map_size(record["workflow"]["restrictions"]) == 0,
      do: {:ok, Map.merge(spec, %{"timeout_ms" => min(spec["timeout_ms"], budget - used), "deadline_ms" => System.system_time(:millisecond) + budget - used})},
      else: {:error, :check_budget_or_control_blocked}
  end

  defp launch_spec(_, _), do: {:error, :check_budget_unavailable}

  defp checkout(spec) do
    if File.exists?(spec["workspace"]) do
      snapshot(spec["workspace"], spec["revision"])
    else
      case git(spec["source"], ["worktree", "add", "--detach", spec["workspace"], spec["revision"]]) do
        {_, 0} -> snapshot(spec["workspace"], spec["revision"])
        _ -> {:error, :check_checkout_failed}
      end
    end
  end

  defp snapshot(workspace, revision) do
    with {head, 0} <- git(workspace, ["rev-parse", "HEAD"]),
         true <- String.trim(head) == revision,
         {_, 0} <- git(workspace, ["diff", "--quiet", "--no-ext-diff", "--ignore-submodules=none", "HEAD", "--"]),
         {"", 0} <- git(workspace, ["status", "--porcelain=v1", "--untracked-files=all", "--ignored"]) do
      :ok
    else
      _ -> {:error, :check_snapshot_changed}
    end
  end

  defp write_spec(directory, spec) do
    path = Path.join(directory, "spec.json")
    body = TaskWorkflow.canonical_json(spec)

    case File.lstat(path) do
      {:error, :enoent} -> File.write(path, body, [:exclusive])
      {:ok, %{type: :regular}} -> File.write(path, body)
      _ -> {:error, :unsafe_check_spec_path}
    end
  end

  defp receipt_matches(receipt, spec, directory) when is_map(receipt) and is_map(spec) do
    with true <- Enum.all?(~w(id candidate policy_sha command revision timeout_ms deadline_ms), &(receipt[&1] == spec[&1])),
         true <- receipt["native_stop_confirmed"] == true,
         true <- receipt["reason"] != "completed" or is_integer(receipt["exit_code"]),
         {:ok, output} <- File.read(Path.join(directory, "output")),
         true <- receipt["output_sha"] == Base.encode16(:crypto.hash(:sha256, output), case: :lower),
         true <- receipt["output_bytes"] == byte_size(output),
         true <- byte_size(output) <= spec["max_output_bytes"],
         true <- is_boolean(receipt["snapshot_valid"]),
         true <- receipt["reason"] in ~w(completed timeout cancelled output_limit supervisor_error snapshot_changed) do
      :ok
    else
      _ -> {:error, :invalid_command_receipt}
    end
  end

  defp receipt_matches(_, _, _), do: {:error, :invalid_command_receipt}

  defp git(workspace, arguments) do
    System.cmd("env", ["-i", "PATH=" <> System.get_env("PATH", "/usr/bin:/bin"), "git", "-c", "core.hooksPath=/dev/null", "-C", workspace | arguments], stderr_to_stdout: true)
  end

  defp directory(record, id), do: Path.join([record["directory"], "checks", id])
  defp save(record, entry), do: RunJournal.checkpoint(record, %{"check_runs" => Map.put(record["check_runs"] || %{}, entry["id"], entry)})
end
