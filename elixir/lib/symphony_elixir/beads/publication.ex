defmodule SymphonyElixir.Beads.Publication do
  @moduledoc "Opt-in host publication of an explicitly scoped delivery; never merges."
  alias SymphonyElixir.Beads.{Adapter, RemoteReview, RunJournal, SourceIssue}

  @spec publish(map(), map()) :: {:ok, map()} | {:error, term()}
  def publish(settings, issue) do
    paths = settings.provider["publish_paths"] || []

    with :ok <- authorized_task(settings, issue),
         true <- ("symphony:publish" in issue.labels and paths != []) || {:error, :publication_not_authorized},
         true <- Enum.all?(paths, &safe_path?/1) || {:error, :invalid_publication_paths},
         {:ok, record} <- RunJournal.read(issue.native_ref["run_directory"]),
         true <- record["owner"] == issue.assignee_id || {:error, :publication_owner_mismatch},
         workspace when is_binary(workspace) <- record["workspace"],
         true <- Enum.all?(paths, &(File.lstat(Path.join(workspace, &1)) |> regular?())) || {:error, :invalid_publication_file},
         {:ok, branch} <- git(workspace, ["branch", "--show-current"]),
         true <- String.starts_with?(branch, "codex/") || {:error, :publication_requires_task_branch},
         {:ok, remote} <- git(workspace, ["remote", "get-url", "origin"]),
         {:ok, repo} <- github_repo(settings, remote),
         {:ok, staged} <- git(workspace, ["diff", "--cached", "--name-only"]),
         true <- Enum.all?(String.split(staged, "\n", trim: true), &(&1 in paths)) || {:error, :unrelated_staged_changes},
         {:ok, _} <- RunJournal.checkpoint(record, %{"publication_intent" => %{branch: branch, paths: paths}}),
         {:ok, _} <- git(workspace, ["add", "--" | paths]),
         :ok <- commit_if_changed(workspace, issue.id),
         {:ok, sha} <- git(workspace, ["rev-parse", "HEAD"]),
         {:ok, _} <- git(workspace, ["-c", "credential.helper=", "-c", "credential.helper=!gh auth git-credential", "push", "-u", "origin", branch]),
         {:ok, url} <- review(repo, branch, issue, record) do
      {:ok, %{review_url: url, head_sha: sha}}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_publication_binding}
    end
  end

  defp authorized_task(settings, issue) do
    with {:ok, [current]} <- Adapter.command(settings, ["show", issue.id, "--json"]),
         true <-
           (current["status"] == "in_progress" and current["assignee"] == issue.assignee_id and
              "symphony:publish" in (current["labels"] || [])) || {:error, :publication_not_currently_authorized},
         {:ok, %{closed: false}} <- SourceIssue.read(settings, current["external_ref"] || "") do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :publication_source_not_open}
    end
  end

  defp safe_path?(path), do: is_binary(path) and Path.type(path) == :relative and not Enum.any?(Path.split(path), &(&1 in ["..", ".git"]))
  defp regular?({:ok, %{type: :regular}}), do: true
  defp regular?(_), do: false

  defp github_repo(settings, remote) do
    configured =
      case settings.provider["review_repository"] do
        "$" <> key -> System.get_env(key)
        value -> value
      end

    case configured do
      "github.com/" <> repo ->
        if remote in ["https://github.com/" <> repo <> ".git", "https://github.com/" <> repo, "git@github.com:" <> repo <> ".git"], do: {:ok, repo}, else: {:error, :publication_remote_mismatch}

      _ ->
        {:error, :publication_provider_unsupported}
    end
  end

  defp commit_if_changed(workspace, id) do
    with {:ok, staged} <- git(workspace, ["diff", "--cached", "--name-only"]) do
      if staged == "" do
        :ok
      else
        case git(workspace, ["commit", "-m", "chore: deliver " <> id]) do
          {:ok, _} -> :ok
          error -> error
        end
      end
    end
  end

  defp review(repo, branch, issue, record) do
    with {:ok, reviews} <- RemoteReview.json_command("gh", ["pr", "list", "--repo", repo, "--head", branch, "--state", "all", "--json", "url,state"]) do
      case reviews do
        [%{"url" => url, "state" => "OPEN"}] ->
          {:ok, url}

        [] ->
          body = Path.join(record["directory"], "pr-body.md")

          text =
            "#### Context\n\nControlled native execution proof. Refs " <>
              (issue.native_ref["external_ref"] || "") <>
              "\n\n#### TL;DR\n\n*Deliver the scoped runnable result.*\n\n#### Summary\n\n- Publish only the configured paths.\n\n#### Alternatives\n\n- Keep the result local.\n\n#### Test Plan\n\n- [x] Read back the scoped artifact.\n- [ ] Full suite intentionally omitted by rapid-development policy.\n"

          with :ok <- File.write(body, text) do
            command("gh", ["pr", "create", "--repo", repo, "--head", branch, "--title", "Native loop proof: " <> issue.id, "--body-file", body], record["directory"])
          end

        _ ->
          {:error, :existing_review_not_open_or_ambiguous}
      end
    end
  end

  defp git(workspace, args), do: command("git", args, workspace)

  defp run(bin, args, cwd) do
    System.cmd(bin, args, cd: cwd, stderr_to_stdout: false)
  rescue
    _ -> {:error, :command_unavailable}
  end

  defp command(bin, args, cwd) do
    task = Task.async(fn -> run(bin, args, cwd) end)

    case Task.yield(task, 15_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} -> {:ok, String.trim(output)}
      {:ok, {:error, reason}} -> {:error, {:publication_command_failed, reason}}
      {:ok, {_, status}} -> {:error, {:publication_command_failed, status}}
      nil -> {:error, :publication_timeout}
    end
  rescue
    _ -> {:error, :publication_command_unavailable}
  end
end
