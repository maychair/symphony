defmodule SymphonyElixir.Beads.Acceptance do
  @moduledoc "Explicit human acceptance bound to this run's delivered review and commit."
  alias SymphonyElixir.Beads.{Adapter, RunJournal, SourceIssue}

  @spec accept(map(), String.t(), String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def accept(settings, issue_id, review_url, accepted_by, opts \\ []) do
    verifier = Keyword.get(opts, :verifier, &merged_review/1)

    with true <- (is_binary(accepted_by) and String.trim(accepted_by) != "") || {:error, :human_identity_required},
         :ok <- validate_review_scope(settings, review_url),
         {:ok, record} <- delivered_run(settings, issue_id, review_url),
         {:ok, proof} <- verifier.(review_url),
         :ok <- verify_delivery(record, proof),
         {:ok, [issue]} <- Adapter.command(settings, ["show", issue_id, "--json"]),
         :ok <- verify_issue(settings, issue, record),
         :ok <- close_source(settings, issue, opts) do
      close_delivery(settings, issue, accepted_by, proof)
    end
  end

  @spec validate_review_scope(map(), String.t()) :: :ok | {:error, term()}
  def validate_review_scope(settings, url) do
    repository = resolve(settings.provider["review_repository"])

    case review_repository(url) do
      {:ok, ^repository} when is_binary(repository) -> :ok
      _ -> {:error, :review_outside_configured_repository}
    end
  end

  defp delivered_run(settings, id, review_url) do
    directory = RunJournal.directory(Adapter.journal_root(settings), id)

    with true <- not File.exists?(Path.join(directory, "executor.lock")) || {:error, :run_may_have_live_executor},
         {:ok, %{} = record} <- RunJournal.read(directory),
         true <- matching_delivery?(record, review_url) || {:error, :missing_matching_delivery},
         :ok <- matching_run_scope(record, settings, id),
         true <- (is_binary(record["thread_id"]) and is_binary(record["turn_id"])) || {:error, :missing_native_identity} do
      {:ok, record}
    else
      {:error, _} = error -> error
      _ -> {:error, :missing_matching_delivery}
    end
  end

  defp matching_run_scope(record, settings, id) do
    if record["issue_id"] == id and record["beads_dir"] == Adapter.beads_dir(settings) do
      :ok
    else
      {:error, :delivery_identity_mismatch}
    end
  end

  defp verify_delivery(record, proof) do
    head = get_in(record, ["delivery", "head_sha"])
    actual_head = proof["headRefOid"] || proof["sha"]
    if is_binary(head) and head != "" and head == actual_head, do: :ok, else: {:error, :delivery_commit_mismatch}
  end

  defp verify_issue(settings, issue, record) do
    cond do
      issue["assignee"] != record["owner"] -> {:error, :delivery_owner_mismatch}
      not Enum.all?(settings.required_labels, &(&1 in (issue["labels"] || []))) -> {:error, :issue_outside_scope}
      acceptable_status?(issue) -> :ok
      true -> {:error, :issue_not_awaiting_human}
    end
  end

  defp acceptable_status?(%{"status" => "closed"} = issue), do: get_in(issue, ["metadata", "symphony_gate"]) == "accepted"
  defp acceptable_status?(%{"status" => "blocked"} = issue), do: "human" in (issue["labels"] || [])
  defp acceptable_status?(_issue), do: false

  defp matching_delivery?(record, url),
    do:
      record["phase"] == "awaiting_human" and get_in(record, ["delivery", "review_url"]) == url and
        get_in(record, ["delivery", "attempt_id"]) == record["attempt_id"] and
        get_in(record, ["delivery", "turn_id"]) == record["turn_id"]

  defp resolve("$" <> name), do: System.get_env(name)
  defp resolve(value), do: value

  defp close_source(settings, issue, opts) do
    case issue["external_ref"] do
      nil ->
        :ok

      "" ->
        :ok

      url ->
        if opts[:close_source] do
          Keyword.get(opts, :source_closer, &SourceIssue.close/2).(settings, url)
        else
          {:error, :explicit_source_issue_closure_required}
        end
    end
  end

  defp close_delivery(_settings, %{"status" => "closed"}, _human, _proof), do: :ok

  defp close_delivery(settings, issue, human, proof) do
    case Adapter.command(settings, [
           "update",
           issue["id"],
           "--if-assignee",
           issue["assignee"],
           "--if-status",
           "blocked",
           "--status",
           "closed",
           "--remove-label",
           "human",
           "--set-metadata",
           "symphony_gate=accepted",
           "--set-metadata",
           "symphony_accepted_by=" <> human,
           "--set-metadata",
           "symphony_merged_review=" <> Jason.encode!(proof),
           "--json"
         ]) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  @spec merged_review(String.t()) :: {:ok, map()} | {:error, term()}
  def merged_review(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: "github.com", path: path} -> github_review(path, url)
      %URI{scheme: "https", host: "gitlab.com", path: path} -> gitlab_review(path, url)
      _ -> {:error, :unsupported_review_host}
    end
  end

  defp github_review(path, url) do
    case Regex.run(~r{^/([^/]+)/([^/]+)/pull/(\d+)$}, path) do
      [_, owner, repo, number] ->
        verify("gh", ["pr", "view", number, "--repo", owner <> "/" <> repo, "--json", "state,mergedAt,mergeCommit,url,headRefOid"], url, "github")

      _ ->
        {:error, :invalid_review_url}
    end
  end

  defp gitlab_review(path, url) do
    case Regex.run(~r{^/(.+)/-/merge_requests/(\d+)$}, path) do
      [_, project, number] -> verify("glab", ["api", "projects/" <> URI.encode_www_form(project) <> "/merge_requests/" <> number], url, "gitlab")
      _ -> {:error, :invalid_review_url}
    end
  end

  defp review_repository(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: "github.com", path: path, query: nil, fragment: nil} ->
        case Regex.run(~r{^/([^/]+/[^/]+)/pull/\d+$}, path) do
          [_, project] -> {:ok, "github.com/" <> project}
          _ -> :error
        end

      %URI{scheme: "https", host: "gitlab.com", path: path, query: nil, fragment: nil} ->
        case Regex.run(~r{^/(.+)/-/merge_requests/\d+$}, path) do
          [_, project] -> {:ok, "gitlab.com/" <> project}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp verify(bin, args, url, provider) do
    task = Task.async(fn -> run_verifier(bin, args) end)

    case Task.yield(task, 15_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} -> decode_proof(output, url, provider)
      {:ok, {:error, reason}} -> {:error, {:review_verification_failed, reason}}
      {:ok, {_output, status}} -> {:error, {:review_verification_failed, status}}
      nil -> {:error, :review_verification_timeout}
    end
  end

  defp run_verifier(bin, args) do
    System.cmd(bin, args, stderr_to_stdout: false)
  rescue
    error in [ErlangError, ArgumentError] -> {:error, Exception.message(error)}
  end

  defp decode_proof(output, url, provider) do
    with {:ok, proof} <- Jason.decode(output),
         true <- merged?(provider, proof) || {:error, :review_not_merged},
         true <- (proof["url"] || proof["web_url"]) == url || {:error, :review_identity_mismatch} do
      {:ok, Map.put(proof, "verified_at", DateTime.to_iso8601(DateTime.utc_now()))}
    end
  end

  defp merged?("github", proof) do
    proof["state"] == "MERGED" and is_binary(proof["mergedAt"]) and is_binary(get_in(proof, ["mergeCommit", "oid"]))
  end

  defp merged?("gitlab", proof) do
    proof["state"] == "merged" and is_binary(proof["merged_at"]) and is_binary(proof["merge_commit_sha"])
  end
end
