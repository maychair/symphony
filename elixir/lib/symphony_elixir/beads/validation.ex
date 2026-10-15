defmodule SymphonyElixir.Beads.Validation do
  @moduledoc "Frozen, opt-in task verification executed by the host, separate from acceptance."
  alias SymphonyElixir.Beads.{Adapter, RunJournal}

  @spec policy(map(), map()) :: {:ok, map()} | {:error, term()}
  def policy(settings, issue) do
    metadata = issue.native_ref["metadata"] || %{}
    configured = metadata["symphony_validation"] || settings.provider["validation_policy"]
    normalize(configured)
  end

  defp normalize(nil), do: {:ok, %{"mode" => "repository", "review" => "repository", "commands" => []}}

  defp normalize(%{"mode" => mode, "commands" => commands} = policy) do
    review = policy["review"] || "required"
    timeout = policy["timeout_ms"] || 60_000

    cond do
      mode not in ["targeted", "full", "baseline_diff"] -> {:error, :invalid_validation_mode}
      review not in ["required", "none"] -> {:error, :invalid_review_policy}
      not valid_commands?(commands) -> {:error, :validation_requires_commands}
      not valid_timeout?(timeout) -> {:error, :invalid_validation_timeout}
      not baseline_allowed?(mode, policy) -> {:error, :baseline_requires_explicit_authorization}
      true -> {:ok, Map.take(policy, ["mode", "commands", "baseline_authorization"]) |> Map.put("review", review) |> Map.put("timeout_ms", timeout)}
    end
  end

  defp normalize(_), do: {:error, :invalid_validation_policy}

  defp valid_timeout?(timeout), do: is_integer(timeout) and timeout >= 100 and timeout <= 300_000
  defp baseline_allowed?("baseline_diff", policy), do: authority?(policy["baseline_authorization"])
  defp baseline_allowed?(_mode, _policy), do: true

  defp authority?(value), do: is_binary(value) and String.trim(value) != ""

  defp valid_commands?(commands) when is_list(commands) and commands != [] and length(commands) <= 8 do
    Enum.all?(commands, fn argv -> is_list(argv) and argv != [] and Enum.all?(argv, &(is_binary(&1) and &1 != "")) end)
  end

  defp valid_commands?(_), do: false

  @spec owned_record(map(), map()) :: {:ok, map()} | {:error, term()}
  def owned_record(settings, issue) do
    with {:ok, [current]} <- Adapter.command(settings, ["show", issue.id, "--json"]),
         true <- (current["status"] == "in_progress" and current["assignee"] == issue.assignee_id) || {:error, :not_owned_by_symphony},
         {:ok, %{} = record} <- RunJournal.read(issue.native_ref["run_directory"]),
         true <- (record["issue_id"] == issue.id and record["owner"] == issue.assignee_id) || {:error, :run_owner_mismatch} do
      {:ok, record}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_task_binding}
    end
  end

  @spec run(map(), map()) :: {:ok, map()} | {:error, term()}
  def run(settings, issue) do
    with {:ok, record} <- owned_record(settings, issue),
         true <- settings.provider["allow_host_validation"] == true || {:error, :host_validation_not_enabled},
         %{"commands" => [_ | _]} = policy <- record["validation_policy"],
         {:ok, before} <- identity(record["workspace"]),
         {:ok, _} <- RunJournal.checkpoint(record, %{"validation_receipt" => nil}),
         results <- Enum.map(policy["commands"], &execute(&1, record, policy)),
         {:ok, after_run} <- identity(record["workspace"]),
         receipt <- receipt(record, policy, before, after_run, results),
         {:ok, current} <- RunJournal.read(record["directory"]),
         {:ok, _} <- RunJournal.checkpoint(current, %{"validation_receipt" => receipt}) do
      {:ok, receipt}
    else
      {:error, _} = error -> error
      _ -> {:error, :validation_not_configured}
    end
  end

  defp receipt(record, policy, before, after_run, results) do
    %{
      "attempt_id" => record["attempt_id"],
      "policy" => policy,
      "identity" => before,
      "passed" => before == after_run and Enum.all?(results, &(&1["exit_code"] == 0)),
      "results" => results,
      "at" => DateTime.to_iso8601(DateTime.utc_now())
    }
  end

  defp execute(argv, record, policy) do
    started = System.monotonic_time(:millisecond)
    at = DateTime.to_iso8601(DateTime.utc_now())
    log = Path.join(record["directory"], "validation-#{System.unique_integer([:positive])}.log")
    timeout = "#{policy["timeout_ms"] / 1000}s"
    # GNU timeout bounds the entire command group; the log avoids unbounded output in memory.
    {_, status} = System.cmd("timeout", ["--kill-after=5s", timeout | argv], cd: record["workspace"], into: File.stream!(log), stderr_to_stdout: true)
    duration = System.monotonic_time(:millisecond) - started
    result = %{"argv" => argv, "exit_code" => status, "log" => log, "log_sha256" => log_hash(log)}
    Map.merge(result, %{"started_at" => at, "duration_ms" => duration})
  rescue
    _ -> %{"argv" => argv, "exit_code" => nil, "error" => "validation_command_unavailable"}
  end

  defp log_hash(log) do
    log
    |> File.stream!([], 65_536)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  @spec gate(map()) :: :ok | {:error, term()}
  def gate(record) do
    case record["validation_policy"] do
      %{"commands" => [_ | _]} -> check_receipt(record)
      _ -> :ok
    end
  end

  defp check_receipt(record) do
    with %{"passed" => true, "identity" => expected, "attempt_id" => attempt, "policy" => policy} <- record["validation_receipt"],
         true <- attempt == record["attempt_id"] and policy == record["validation_policy"],
         {:ok, ^expected} <- identity(record["workspace"]) do
      :ok
    else
      _ -> {:error, :current_validation_required}
    end
  end

  @spec delivery_head(map(), String.t()) :: :ok | {:error, term()}
  def delivery_head(record, sha) do
    case record["validation_policy"] do
      %{"commands" => [_ | _]} ->
        if get_in(record, ["validation_receipt", "identity", "head_sha"]) == sha,
          do: :ok,
          else: {:error, :validation_delivery_head_mismatch}

      _ ->
        :ok
    end
  end

  @spec preflight_workspace(Path.t(), map() | nil) :: :ok | {:error, term()}
  def preflight_workspace(workspace, %{"validation_policy" => %{"commands" => [_ | _]}} = record) do
    case identity(workspace) do
      {:ok, _} ->
        :ok

      {:error, _} = error ->
        checkpoint_workspace_block(record, workspace, error)
    end
  end

  def preflight_workspace(_workspace, _record), do: :ok

  defp checkpoint_workspace_block(%{"directory" => directory}, workspace, error) do
    with {:ok, current} <- RunJournal.read(directory),
         changes <- workspace_block_changes(current, workspace),
         {:ok, _} <- RunJournal.checkpoint(current, changes) do
      error
    end
  end

  defp checkpoint_workspace_block(_record, _workspace, error), do: error

  defp workspace_block_changes(current, workspace) do
    if is_nil(current["thread_id"]) and is_nil(current["turn_id"]),
      do: %{"pre_session_blocked" => true, "thread_id" => nil, "turn_id" => nil, "workspace" => workspace},
      else: %{"workspace" => workspace}
  end

  defp status_arguments(workspace) do
    args = ["status", "--porcelain", "--untracked-files=normal"]
    marker = Path.join(workspace, ".symphony-retain")

    case File.lstat(marker) do
      {:error, :enoent} -> {:ok, args}
      {:ok, %{type: :regular}} -> marker_arguments(workspace, marker, args)
      _ -> {:error, :unowned_retention_marker}
    end
  end

  defp marker_arguments(workspace, marker, args) do
    {_, tracked} = System.cmd("git", ["ls-files", "--error-unmatch", ".symphony-retain"], cd: workspace, stderr_to_stdout: true)

    if File.read!(marker) == "retained by Symphony\n" and tracked == 1,
      do: {:ok, args ++ ["--", ".", ":(exclude).symphony-retain"]},
      else: {:error, :unowned_retention_marker}
  end

  @spec identity(Path.t() | nil) :: {:ok, map()} | {:error, term()}
  def identity(workspace) when is_binary(workspace) do
    with {:ok, args} <- status_arguments(workspace),
         {top, 0} <- System.cmd("git", ["rev-parse", "--show-toplevel"], cd: workspace, stderr_to_stdout: true),
         true <- String.trim(top) == Path.expand(workspace),
         {head, 0} <- System.cmd("git", ["rev-parse", "HEAD"], cd: workspace, stderr_to_stdout: true),
         {status, 0} <- System.cmd("git", args, cd: workspace, stderr_to_stdout: true),
         true <- status == "" do
      {:ok, %{"head_sha" => String.trim(head), "worktree" => workspace}}
    else
      {:error, _} = error -> error
      _ -> {:error, :validation_requires_clean_commit}
    end
  rescue
    _ -> {:error, :validation_workspace_unavailable}
  end

  def identity(_), do: {:error, :validation_workspace_unavailable}
end
