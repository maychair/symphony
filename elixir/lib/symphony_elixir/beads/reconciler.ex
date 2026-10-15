defmodule SymphonyElixir.Beads.Reconciler do
  @moduledoc "Reconcile remote business facts inside Symphony's existing polling cycle."
  require Logger
  alias SymphonyElixir.Beads.{Acceptance, Adapter, Recovery, RemoteReview, RunJournal, SourceIssue}

  @spec poll(map()) :: :ok
  def poll(settings) do
    if settings.kind == "beads" do
      case Adapter.command(settings, ["list", "--all", "--limit", "0", "--json"]) do
        {:ok, issues} when is_list(issues) ->
          issues
          |> Enum.filter(&routed?(&1, settings))
          |> Enum.each(fn issue ->
            reconcile_runtime(settings, issue)
            if settings.provider["remote_reconcile"] == true, do: reconcile(settings, issue)
          end)

        error ->
          Logger.warning("Remote reconciliation queue unavailable: #{inspect(error)}")
      end
    end

    :ok
  end

  @doc "Park a lost local scheduler executor without replaying an uncertain native Goal."
  @spec reconcile_runtime(map(), map()) :: :ok | {:error, term()}
  def reconcile_runtime(settings, issue) do
    directory = RunJournal.directory(Adapter.journal_root(settings), issue["id"])

    with {:ok, %{} = record} <- RunJournal.read(directory),
         true <- record["beads_dir"] == Adapter.beads_dir(settings),
         true <- issue["status"] == "in_progress" and issue["assignee"] == record["owner"],
         true <- is_nil(record["delivery"]),
         false <- record["phase"] == "completed" and record["resume_authorized"] == true,
         true <- record["phase"] == "blocked" or RunJournal.executor_state(record) == :stopped do
      reason = record["blocker_reason"] || "Scheduler executor exited before a terminal handoff; reconcile the recorded native Goal/thread/turn before resuming. Butler session is not required."

      with :ok <- Adapter.block_undelivered(settings, issue["id"], record, reason),
           {:ok, current} <- RunJournal.read(directory),
           {:ok, _} <- RunJournal.checkpoint(current, %{"phase" => "blocked", "native_stop_confirmed" => false}) do
        :ok
      end
    else
      {:error, _} = error -> error
      _ -> :ok
    end
  end

  @doc "Called only after the scheduler observes its Coordinator worker terminate."
  @spec park_worker_exit(map(), String.t(), term()) :: :ok | {:error, term()}
  def park_worker_exit(settings, issue_id, reason) do
    directory = RunJournal.directory(Adapter.journal_root(settings), issue_id)

    with {:ok, %{} = record} <- RunJournal.read(directory),
         true <- record["beads_dir"] == Adapter.beads_dir(settings),
         true <- record["executor_os_pid"] == System.pid(),
         true <- record["phase"] not in ["blocked", "awaiting_human"],
         true <- is_nil(record["delivery"]),
         :ok <- Adapter.block_undelivered(settings, issue_id, record, "Coordinator executor exited before terminal handoff: #{inspect(reason)}"),
         {:ok, current} <- RunJournal.read(directory),
         {:ok, _} <- RunJournal.checkpoint(current, %{"phase" => "blocked", "native_stop_confirmed" => false}) do
      :ok
    else
      {:error, _} = error -> error
      _ -> :ok
    end
  end

  defp routed?(issue, settings) do
    issue["status"] != "closed" and Enum.all?(settings.required_labels, &(&1 in (issue["labels"] || [])))
  end

  @spec reconcile(map(), map()) :: :ok | {:error, term()}
  def reconcile(settings, issue) do
    directory = RunJournal.directory(Adapter.journal_root(settings), issue["id"])

    with {:ok, record} <- RunJournal.read(directory) do
      result = reconcile_record(settings, issue, record)

      case result do
        {:error, reason} -> Logger.warning("Remote reconciliation parked issue_id=#{issue["id"]}: #{inspect(reason)}")
        _ -> :ok
      end

      result
    end
  rescue
    _ -> {:error, :remote_reconciliation_failed}
  end

  defp reconcile_record(settings, issue, nil) do
    case SourceIssue.read(settings, issue["external_ref"] || "") do
      {:ok, %{closed: false}} -> reopen_unstarted(settings, issue)
      {:ok, %{closed: true}} -> park_unstarted(settings, issue, "source_issue_closed")
      {:error, _} -> park_unstarted(settings, issue, "source_issue_unavailable")
    end
  end

  defp reconcile_record(_settings, _issue, %{"phase" => "blocked"}), do: :ok

  # Older runs parked every completed turn as a delivery, including preparation.
  # Migrate only absent deliveries; partial bindings remain strict review errors.
  defp reconcile_record(settings, issue, %{"phase" => "awaiting_human"} = record) do
    if is_nil(record["delivery"]) and is_nil(get_in(issue, ["metadata", "symphony_review_url"])) do
      park_undelivered(settings, issue, record)
    else
      reconcile_delivery(settings, issue, record)
    end
  end

  defp reconcile_record(settings, issue, record) do
    case {issue["status"], SourceIssue.read(settings, issue["external_ref"] || "")} do
      {"in_progress", {:ok, %{closed: true}}} ->
        case Adapter.command(settings, [
               "update",
               issue["id"],
               "--if-status",
               "in_progress",
               "--if-assignee",
               record["owner"],
               "--status",
               "blocked",
               "--add-label",
               "human",
               "--set-metadata",
               "symphony_gate=source_issue_closed",
               "--json"
             ]) do
          {:ok, _} -> checkpoint(record, "source_issue_closed")
          error -> error
        end

      _ ->
        :ok
    end
  end

  defp park_undelivered(settings, issue, record) do
    reason = record["blocker_reason"] || issue["notes"] || "Legacy run ended without delivery; inspect native session evidence and resolve preparation before resuming."

    with false <- File.exists?(Path.join(record["directory"], "executor.lock")),
         :ok <- Adapter.block_undelivered(settings, issue["id"], record, reason),
         {:ok, _} <- RunJournal.checkpoint(Map.put(record, "blocker_reason", reason), %{"phase" => "blocked"}) do
      :ok
    else
      true -> {:error, :run_may_have_live_executor}
      error -> error
    end
  end

  defp reconcile_delivery(settings, issue, record) do
    url = get_in(record, ["delivery", "review_url"]) || get_in(issue, ["metadata", "symphony_review_url"])

    with true <- is_binary(url) || {:error, :missing_review_binding},
         false <- File.exists?(Path.join(record["directory"], "executor.lock")),
         {:ok, review} <- RemoteReview.fetch(settings, url) do
      case SourceIssue.read(settings, issue["external_ref"] || "") do
        {:ok, %{closed: true}} when review.state != "merged" -> checkpoint(record, "source_issue_closed")
        {:ok, _} -> act(decide(review, settings.provider), settings, issue, record, review)
        error -> error
      end
    else
      true -> {:error, :run_may_have_live_executor}
      {:error, _} = error -> error
      _ -> {:error, :incomplete_review_binding}
    end
  end

  @spec decide(map(), map()) :: atom()
  def decide(review, provider) do
    feedback = review.feedback
    failed = Enum.any?(feedback.checks, &failed_check?/1)

    cond do
      review.state == "closed" -> :closed_unmerged
      review.state == "merged" and acceptable?(review, provider) -> :accepted
      review.state == "merged" -> :merged_conditions_unmet
      repair_needed?(feedback, failed) -> :repair
      Enum.any?(feedback.checks, &(not passed_check?(&1))) -> :waiting_ci
      not required_checks_passed?(feedback.checks, provider) -> :waiting_ci
      true -> :awaiting_merge
    end
  end

  defp repair_needed?(feedback, failed), do: feedback.threads != [] or feedback.changes_requested or failed

  defp required_checks_passed?(checks, provider) do
    Enum.all?(provider["required_checks"] || [], fn name ->
      Enum.any?(checks, &(&1.name == name and passed_check?(&1)))
    end)
  end

  defp acceptable?(review, provider) do
    required = provider["required_checks"] || []
    actors = provider["accepted_merge_actors"] || []

    review.actor in actors and review.feedback.threads == [] and not review.feedback.changes_requested and
      Enum.all?(review.feedback.checks, &passed_check?/1) and
      Enum.all?(required, fn name -> Enum.any?(review.feedback.checks, &(&1.name == name and passed_check?(&1))) end)
  end

  defp passed_check?(check), do: String.downcase(check.status || "") in ["success", "neutral", "skipped"]
  defp failed_check?(check), do: String.downcase(check.status || "") in ["failure", "failed", "error", "timed_out", "action_required"]

  defp act(:accepted, settings, issue, record, review) do
    with true <- get_in(record, ["delivery", "head_sha"]) == review.head || {:error, :delivery_commit_mismatch},
         :ok <- Acceptance.accept(settings, issue["id"], review.url, review.actor, close_source: true, verifier: fn _ -> {:ok, review.proof} end),
         {:ok, _} <- RunJournal.checkpoint(record, %{"remote_state" => "accepted", "merge_actor" => review.actor}) do
      :ok
    end
  end

  defp act(:repair, settings, issue, record, review) do
    fingerprint = hash(%{head: review.head, feedback: review.feedback})

    cond do
      record["repair_fingerprint"] == fingerprint ->
        :ok

      (record["repair_count"] || 0) >= (settings.provider["max_repair_runs"] || 3) ->
        checkpoint(record, "budget_exhausted")

      true ->
        with {:ok, record} <- RunJournal.checkpoint(record, %{"remote_state" => "repair_requested"}),
             {:ok, _} <-
               Adapter.command(settings, ["update", issue["id"], "--if-assignee", record["owner"], "--if-status", "blocked", "--set-metadata", "symphony_review_url=" <> review.url, "--json"]),
             {:ok, %{closed: false}} <- SourceIssue.read(settings, issue["external_ref"] || ""),
             :ok <-
               Recovery.resume_completed(settings, issue["id"], %{
                 review_url: review.url,
                 head: review.head,
                 facts: review.feedback,
                 fingerprint: fingerprint,
                 cause: "review",
                 actor: "remote_review",
                 caused_by_event: fingerprint
               }) do
          :ok
        else
          {:ok, %{closed: true}} -> checkpoint(record, "source_issue_closed")
          error -> error
        end
    end
  end

  defp act(decision, _settings, _issue, record, _review), do: checkpoint(record, Atom.to_string(decision))

  defp checkpoint(record, state) do
    if record["remote_state"] == state do
      :ok
    else
      case RunJournal.checkpoint(record, %{"remote_state" => state}) do
        {:ok, _} -> :ok
        error -> error
      end
    end
  end

  defp reopen_unstarted(settings, issue) do
    gate = get_in(issue, ["metadata", "symphony_gate"])

    if issue["status"] == "blocked" and gate in ["source_issue_closed", "source_issue_unavailable"] do
      case Adapter.command(settings, [
             "update",
             issue["id"],
             "--if-status",
             "blocked",
             "--if-assignee",
             issue["assignee"] || "",
             "--status",
             "open",
             "--remove-label",
             "human",
             "--set-metadata",
             "symphony_gate=ready",
             "--json"
           ]) do
        {:ok, _} -> :ok
        error -> error
      end
    else
      :ok
    end
  end

  defp park_unstarted(settings, issue, reason) do
    if issue["status"] == "open" do
      case Adapter.command(settings, [
             "update",
             issue["id"],
             "--if-status",
             "open",
             "--if-assignee",
             issue["assignee"] || "",
             "--status",
             "blocked",
             "--add-label",
             "human",
             "--set-metadata",
             "symphony_gate=" <> reason,
             "--json"
           ]) do
        {:ok, _} -> :ok
        error -> error
      end
    else
      :ok
    end
  end

  defp hash(value), do: Base.encode16(:crypto.hash(:sha256, Jason.encode!(value)), case: :lower)
end
