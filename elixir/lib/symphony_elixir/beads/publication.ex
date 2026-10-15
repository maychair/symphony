defmodule SymphonyElixir.Beads.Publication do
  @moduledoc "Opt-in host publication of an explicitly scoped delivery; never merges."
  alias SymphonyElixir.Beads.{Adapter, RemoteReview, Repository, RunJournal, SourceIssue, Validation}

  @spec publish(map(), map()) :: {:ok, map()} | {:error, term()}
  def publish(settings, issue) do
    with {:ok, context} <- prepare_commit(settings, issue),
         :ok <- Validation.gate(context.record),
         {:ok, _} <- push(context.workspace, context.remote, context.branch, context.repo),
         {:ok, url} <- review(context.repo, context.branch, issue, context.record, settings) do
      {:ok, %{review_url: url, head_sha: context.sha}}
    end
  end

  @spec checkpoint(map(), map()) :: {:ok, map()} | {:error, term()}
  def checkpoint(settings, issue) do
    with {:ok, context} <- prepare_commit(settings, issue) do
      {:ok, %{head_sha: context.sha, published: false}}
    end
  end

  defp prepare_commit(settings, issue) do
    paths = settings.provider["publish_paths"] || []
    remote_name = settings.provider["git_remote"] || "origin"

    with :ok <- authorized_task(settings, issue),
         :ok <- authorized_paths(issue, paths),
         true <- Enum.all?(paths, &safe_path?/1) || {:error, :invalid_publication_paths},
         {:ok, record} <- RunJournal.read(issue.native_ref["run_directory"]),
         true <- record["owner"] == issue.assignee_id || {:error, :publication_owner_mismatch},
         workspace when is_binary(workspace) <- record["workspace"],
         true <- Enum.all?(paths, &(File.lstat(Path.join(workspace, &1)) |> regular?())) || {:error, :invalid_publication_file},
         {:ok, branch} <- git(workspace, ["branch", "--show-current"]),
         true <- String.starts_with?(branch, "codex/") || {:error, :publication_requires_task_branch},
         {:ok, remote} <- git(workspace, ["remote", "get-url", remote_name]),
         {:ok, repo} <- publication_repo(settings, remote),
         {:ok, staged} <- git(workspace, ["diff", "--cached", "--name-only"]),
         true <- Enum.all?(String.split(staged, "\n", trim: true), &(&1 in paths)) || {:error, :unrelated_staged_changes},
         {:ok, record} <- RunJournal.checkpoint(record, %{"checkpoint_intent" => %{branch: branch, paths: paths}}),
         {:ok, _} <- git(workspace, ["add", "--" | paths]),
         :ok <- commit_if_changed(workspace, issue.id),
         {:ok, sha} <- git(workspace, ["rev-parse", "HEAD"]) do
      {:ok, %{record: record, workspace: workspace, remote: remote_name, repo: repo, branch: branch, sha: sha}}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_publication_binding}
    end
  end

  defp authorized_paths(issue, paths) do
    if "symphony:publish" in issue.labels and paths != [], do: :ok, else: {:error, :publication_not_authorized}
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

  defp publication_repo(settings, remote) do
    configured = Repository.resolve(settings.provider["review_repository"])

    case String.split(configured || "", "/", parts: 2) do
      [host, project] when host != "" and project != "" ->
        remotes = [
          "https://" <> configured,
          "https://" <> configured <> ".git",
          "ssh://git@" <> configured,
          "ssh://git@" <> configured <> ".git",
          "git@" <> host <> ":" <> project,
          "git@" <> host <> ":" <> project <> ".git"
        ]

        cond do
          remote not in remotes ->
            {:error, :publication_remote_mismatch}

          host == "github.com" ->
            {:ok, %{provider: :github, project: project}}

          configured_gitlab?(settings, host, project) ->
            {:ok, %{provider: :gitlab, host: host, project: project}}

          true ->
            {:error, :publication_provider_unsupported}
        end

      _ ->
        {:error, :publication_provider_unsupported}
    end
  end

  defp configured_gitlab?(settings, host, project) do
    origin = Repository.gitlab_origin(settings)
    Repository.gitlab_url?(settings, origin <> "/" <> project) and URI.parse(origin).host == host
  end

  defp push(workspace, remote, branch, %{provider: :github}),
    do: git(workspace, ["-c", "credential.helper=", "-c", "credential.helper=!gh auth git-credential", "push", "-u", remote, branch])

  defp push(workspace, remote, branch, %{provider: :gitlab}),
    do: git(workspace, ["push", "-u", remote, branch])

  defp commit_if_changed(workspace, id) do
    with {:ok, staged} <- git(workspace, ["diff", "--cached", "--name-only"]) do
      commit_staged(workspace, id, staged)
    end
  end

  defp commit_staged(_workspace, _id, ""), do: :ok

  defp commit_staged(workspace, id, _staged) do
    case git(workspace, ["commit", "-m", "chore: deliver " <> id]) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp review(%{provider: :github, project: repo}, branch, issue, record, _settings) do
    with {:ok, reviews} <- RemoteReview.json_command("gh", ["pr", "list", "--repo", repo, "--head", branch, "--state", "all", "--json", "url,state"]) do
      case reviews do
        [%{"url" => url, "state" => "OPEN"}] ->
          {:ok, url}

        [] ->
          create_github_review(repo, branch, issue, record)

        _ ->
          {:error, :existing_review_not_open_or_ambiguous}
      end
    end
  end

  defp review(%{provider: :gitlab, host: host, project: project}, branch, issue, record, settings) do
    endpoint = "projects/" <> URI.encode_www_form(project) <> "/merge_requests"
    query = endpoint <> "?state=all&source_branch=" <> URI.encode_www_form(branch)

    with {:ok, reviews} <- RemoteReview.json_command("glab", ["api", "--hostname", host, query]) do
      case reviews do
        [%{"web_url" => url, "state" => "opened", "source_project_id" => id, "target_project_id" => id}] ->
          {:ok, url}

        [] ->
          create_gitlab_review(host, endpoint, branch, issue, record, settings)

        _ ->
          {:error, :existing_review_not_open_or_ambiguous}
      end
    end
  end

  defp create_github_review(repo, branch, issue, record) do
    body = Path.join(record["directory"], "pr-body.md")

    text =
      "#### Context\n\nControlled native execution proof. Refs " <>
        (issue.native_ref["external_ref"] || "") <>
        "\n\n#### TL;DR\n\n*Deliver the scoped runnable result.*\n\n#### Summary\n\n- Publish only the configured paths.\n\n#### Alternatives\n\n- Keep the result local.\n\n#### Test Plan\n\n- [x] Read back the scoped artifact.\n- [ ] Full suite intentionally omitted by rapid-development policy.\n"

    with :ok <- File.write(body, text) do
      command("gh", ["pr", "create", "--repo", repo, "--head", branch, "--title", "Native loop proof: " <> issue.id, "--body-file", body], record["directory"])
    end
  end

  defp create_gitlab_review(host, endpoint, branch, issue, record, settings) do
    description =
      issue.description <>
        "\n\nRefs " <>
        (issue.native_ref["external_ref"] || "") <>
        "\n\nValidation and independent review evidence will be recorded before merge."

    body = Path.join(record["directory"], "mr-body.json")
    payload = %{source_branch: branch, target_branch: Repository.resolve(settings.provider["publish_base"]) || "main", title: issue.title, description: description, remove_source_branch: false}

    with :ok <- File.write(body, Jason.encode!(payload)),
         {:ok, mr} <- RemoteReview.json_command("glab", ["api", "--hostname", host, "--method", "POST", endpoint, "--header", "Content-Type: application/json", "--input", body]),
         url when is_binary(url) <- mr["web_url"] do
      {:ok, url}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_created_merge_request}
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
