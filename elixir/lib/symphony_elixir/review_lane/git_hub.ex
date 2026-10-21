defmodule SymphonyElixir.ReviewLane.GitHub do
  @moduledoc """
  Authenticated, bounded GitHub reads and review-discussion publication via native gh credentials.
  Follows design §18.1 by using event=COMMENT for review submissions and validating native identities.
  """

  @spec request(map(), String.t(), String.t(), map()) :: {:ok, term()} | {:error, term()}
  def request(config, method, path, fields \\ %{}) do
    if permitted?(config, method, path, fields),
      do: native_request(config, method, path, fields),
      else: {:error, :review_write_not_permitted}
  end

  @doc "Validate comment body text before publication."
  @spec comment_body?(term()) :: boolean()
  def comment_body?(body), do: SymphonyElixir.NativeWork.comment_body?("github", body)

  defp permitted?(config, "GET", path, fields) do
    fields == %{} and get_path_permitted?(config, path)
  end

  defp permitted?(config, "POST", path, %{"body" => body, "event" => "COMMENT"} = fields) do
    match?(["body", "commit_id", "event"], Enum.sort(Map.keys(fields))) and
      comment_body?(body) and valid_sha?(fields["commit_id"]) and reviews_path?(config, path)
  end

  defp permitted?(config, "POST", path, %{"body" => body} = fields) do
    Map.keys(fields) == ["body"] and comment_body?(body) and issue_comments_path?(config, path)
  end

  defp permitted?(_, _, _, _), do: false

  defp get_path_permitted?(_config, "user"), do: true

  defp get_path_permitted?(%{"projects" => projects}, path) when is_map(projects) do
    clean_path = path |> String.split("?") |> hd()

    case Regex.run(~r{\Arepos/([^/]+/[^/]+)(?:/.*)?\z}, clean_path) do
      [_, project] -> Map.has_key?(projects, project)
      _ -> false
    end
  end

  defp get_path_permitted?(_, _), do: false

  defp reviews_path?(config, path) do
    case Regex.run(~r{\Arepos/([^/]+/[^/]+)/pulls/([1-9][0-9]*)/reviews\z}, path) do
      [_, project, _number] -> is_map(config["projects"]) and Map.has_key?(config["projects"], project)
      _ -> false
    end
  end

  defp issue_comments_path?(config, path) do
    case Regex.run(~r{\Arepos/([^/]+/[^/]+)/issues/([1-9][0-9]*)/comments\z}, path) do
      [_, project, _number] -> is_map(config["projects"]) and Map.has_key?(config["projects"], project)
      _ -> false
    end
  end

  defp valid_sha?(sha), do: is_binary(sha) and Regex.match?(~r/^(?:[a-f0-9]{40}|[a-f0-9]{64})$/, sha)

  defp native_request(config, method, path, fields) do
    args = ["api", "--hostname", config["host"], "--method", method, path]
    args = args ++ Enum.flat_map(fields, fn {key, value} -> ["--raw-field", "#{key}=#{value}"] end)

    case command(config["gh_bin"] || "gh", args) do
      {:ok, output} -> Jason.decode(output)
      error -> error
    end
  end

  @spec command(String.t(), [String.t()]) :: {:ok, String.t()} | {:error, term()}
  def command(executable, args) do
    case System.cmd("timeout", ["--signal=TERM", "30s", executable | args], stderr_to_stdout: false, env: Map.to_list(SymphonyElixir.RuntimeContext.environment())) do
      {output, 0} when byte_size(output) <= 8_388_608 -> {:ok, output}
      {_output, status} -> {:error, {:command_failed, executable, status}}
    end
  rescue
    error -> {:error, {:command_unavailable, Exception.message(error)}}
  end

  @spec mr_path(String.t(), pos_integer()) :: String.t()
  def mr_path(project, number), do: "repos/#{project}/pulls/#{number}"

  @spec issues_path(String.t(), pos_integer()) :: String.t()
  def issues_path(project, number), do: "repos/#{project}/issues/#{number}"

  @spec web_url_path(String.t(), pos_integer()) :: String.t()
  def web_url_path(project, number), do: "/#{project}/pull/#{number}"

  @doc "Read a PR and bind its target repository and fixed head/base to the review lane's native shape."
  @spec read_pull(map(), String.t(), pos_integer()) :: {:ok, map()} | {:error, term()}
  def read_pull(config, project, number) do
    with {:ok, %{} = pull} <- request(config, "GET", mr_path(project, number)),
         true <-
           (pull["number"] == number and get_in(pull, ["base", "repo", "id"]) == get_in(config, ["projects", project, "id"])) or
             {:error, :invalid_native_review},
         %{"sha" => head} <- pull["head"],
         %{"sha" => base, "ref" => target_branch} <- pull["base"],
         %{"id" => author_id} <- pull["user"],
         reviewers when is_list(reviewers) <- pull["requested_reviewers"],
         true <- web_url?(pull["html_url"], config, web_url_path(project, number)) or {:error, :invalid_native_review} do
      state = if pull["merged"] == true, do: "merged", else: github_state(pull["state"])

      {:ok,
       %{
         "iid" => number,
         "project_id" => get_in(config, ["projects", project, "id"]),
         "sha" => head,
         "diff_refs" => %{"base_sha" => base},
         "target_branch" => target_branch,
         "title" => pull["title"] || "",
         "description" => pull["body"] || "",
         "author" => %{"id" => author_id},
         "reviewers" => Enum.map(reviewers, &Map.take(&1, ["id"])),
         "state" => state,
         "web_url" => pull["html_url"]
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_native_review}
    end
  end

  defp github_state("open"), do: "opened"
  defp github_state("closed"), do: "closed"
  defp github_state(_), do: "unknown"

  @doc """
  Read all review comments, pull reviews, and issue comments for a pull request,
  returning them in a normalized discussions shape compatible with Policy and Publication.
  """
  @spec discussions(map(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def discussions(config, path) do
    case Regex.run(~r{\Arepos/([^/]+/[^/]+)/pulls/([1-9][0-9]*)\z}, path) do
      [_, project, number] ->
        with {:ok, issue_comments} <- pages(config, "repos/#{project}/issues/#{number}/comments", 1, []),
             {:ok, reviews} <- pages(config, "repos/#{project}/pulls/#{number}/reviews", 1, []),
             {:ok, review_comments} <- pages(config, "repos/#{project}/pulls/#{number}/comments", 1, []) do
          issue_discussions = Enum.map(issue_comments, &normalize_comment_discussion/1)
          review_discussions = Enum.map(reviews, &normalize_review_discussion/1)
          inline_discussions = normalize_review_comment_discussions(review_comments)
          {:ok, issue_discussions ++ review_discussions ++ inline_discussions}
        end

      _ ->
        {:error, :invalid_github_path}
    end
  end

  defp normalize_comment_discussion(entry) when is_map(entry) do
    id = entry["id"]
    body = entry["body"] || ""
    user = entry["user"] || %{}
    created_at = entry["created_at"] || "1970-01-01T00:00:00Z"

    %{
      "id" => "issue_comment_#{id}",
      "notes" => [
        %{
          "id" => id,
          "body" => body,
          "resolved" => false,
          "created_at" => created_at,
          "author" => %{"id" => user["id"] || 0, "username" => user["login"] || "unknown"}
        }
      ]
    }
  end

  defp normalize_review_discussion(entry) when is_map(entry) do
    id = entry["id"]
    body = entry["body"] || ""
    user = entry["user"] || %{}
    submitted_at = entry["submitted_at"] || entry["created_at"] || "1970-01-01T00:00:00Z"

    %{
      "id" => "pull_review_#{id}",
      "notes" => [
        %{
          "id" => id,
          "body" => body,
          "state" => entry["state"],
          "resolved" => false,
          "created_at" => submitted_at,
          "author" => %{"id" => user["id"] || 0, "username" => user["login"] || "unknown"}
        }
      ]
    }
  end

  defp normalize_review_comment_discussions(entries) do
    entries
    |> Enum.group_by(&(&1["in_reply_to_id"] || &1["id"]))
    |> Enum.sort_by(fn {id, _} -> id end)
    |> Enum.map(fn {root_id, comments} ->
      %{
        "id" => "pull_comment_#{root_id}",
        "notes" => comments |> Enum.sort_by(&{&1["created_at"] || "", &1["id"]}) |> Enum.map(&normalize_review_comment_note/1)
      }
    end)
  end

  defp normalize_review_comment_note(entry) do
    id = entry["id"]
    body = entry["body"] || ""
    user = entry["user"] || %{}
    created_at = entry["created_at"] || "1970-01-01T00:00:00Z"

    %{
      "id" => id,
      "body" => body,
      "resolved" => false,
      "created_at" => created_at,
      "author" => %{"id" => user["id"] || 0, "username" => user["login"] || "unknown"}
    }
  end

  @doc "Discover assigned open PRs in one explicitly registered native project."
  @spec assigned(map(), String.t()) :: {:ok, [pos_integer()]} | {:error, term()}
  def assigned(config, project) do
    path = "repos/" <> project

    with {:ok, repository} <- request(config, "GET", path),
         true <- repository?(repository, config, project) or {:error, :review_repository_mismatch},
         {:ok, entries} <- pages(config, "repos/#{project}/pulls?state=open", 1, []),
         true <- Enum.all?(entries, &(is_integer(&1["number"]) and &1["number"] > 0)) or {:error, :invalid_review_discovery} do
      reviewer_id = config["reviewer_id"]

      assigned_prs =
        entries
        |> Enum.filter(&has_reviewer?(&1, reviewer_id))
        |> Enum.map(& &1["number"])

      {:ok, assigned_prs}
    end
  end

  @doc "Resolve an existing review assignment from the latest native reviewer request event."
  @spec review_assignment(map(), String.t(), pos_integer(), pos_integer()) :: {:ok, boolean()} | {:error, term()}
  def review_assignment(config, project, number, reviewer_id) do
    path = issues_path(project, number) <> "/timeline"

    with {:ok, events} <- pages(config, path, 1, []) do
      events
      |> Enum.filter(&(&1["event"] in ["review_requested", "review_request_removed"] and get_in(&1, ["requested_reviewer", "id"]) == reviewer_id))
      |> Enum.sort_by(&{&1["created_at"], &1["id"]})
      |> List.last()
      |> case do
        %{"event" => "review_requested"} -> {:ok, true}
        %{"event" => "review_request_removed"} -> {:ok, false}
        _ -> {:error, :review_assignment_unconfirmed}
      end
    end
  end

  defp has_reviewer?(pr, reviewer_id) when is_map(pr) do
    reviewers = pr["requested_reviewers"] || []
    Enum.any?(reviewers, &(&1["id"] == reviewer_id))
  end

  @doc "Confirm native repository identity and URL."
  @spec repository?(term(), map(), String.t()) :: boolean()
  def repository?(%{} = repository, config, project) do
    repository["id"] == get_in(config, ["projects", project, "id"]) and
      repository["full_name"] == project and
      web_url?(repository["html_url"], config, "/" <> project)
  end

  def repository?(_, _, _), do: false

  @doc "Match exact web path."
  @spec web_url?(term(), map(), String.t()) :: boolean()
  def web_url?(url, config, path) do
    url == "https://" <> config["host"] <> path or
      (config["allow_insecure_http"] == true and url == "http://" <> config["host"] <> path)
  end

  defp pages(_config, _path, 101, _acc), do: {:error, :discussion_page_limit}

  defp pages(config, path, page, acc) do
    separator = if String.contains?(path, "?"), do: "&", else: "?"

    case request(config, "GET", path <> separator <> "per_page=100&page=#{page}") do
      {:ok, entries} when is_list(entries) -> collect_page(config, path, page, acc, entries)
      {:ok, _} -> {:error, :invalid_discussions_response}
      error -> error
    end
  end

  defp collect_page(config, path, page, acc, entries) do
    combined = acc ++ entries
    valid = Enum.all?(combined, &(is_map(&1) and &1["id"] not in [nil, ""])) and length(Enum.uniq_by(combined, & &1["id"])) == length(combined)

    cond do
      not valid or length(entries) > 100 -> {:error, :invalid_review_page}
      length(entries) < 100 -> {:ok, combined}
      true -> pages(config, path, page + 1, combined)
    end
  end
end
