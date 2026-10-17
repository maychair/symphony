defmodule SymphonyElixir.Taskboard.GitHub do
  @moduledoc "GitHub Taskboard provider backed by repository Issues and pull requests."

  @behaviour SymphonyElixir.Taskboard.Provider

  alias SymphonyElixir.GitHub.Client
  alias SymphonyElixir.Taskboard.Provider
  alias SymphonyElixir.TaskReconciler
  alias SymphonyElixir.Tracker.Issue

  @per_page 100

  @impl true
  def list_issues(settings, opts) do
    states = (List.wrap(settings.active_states) ++ List.wrap(settings.terminal_states)) |> Enum.uniq()

    case Keyword.get(opts, :issues_fun) do
      fun when is_function(fun, 1) -> fun.(states)
      _ -> Client.fetch_issues_by_states(states, settings)
    end
  end

  @impl true
  def issue_detail(settings, identifier, opts) do
    with {:ok, issue} <- fetch_issue(settings, identifier, opts),
         number when is_integer(number) <- Provider.issue_number(issue),
         {:ok, raw} <- get(settings, issue_path(settings, number), opts),
         {:ok, comments} <- pages(settings, issue_path(settings, number) <> "/comments", opts, []),
         {:ok, deliveries} <- pull_requests(settings, issue, raw, comments, opts) do
      {:ok,
       %{
         issue: issue,
         description: raw["body"],
         labels: Enum.map(raw["labels"] || [], &label_name/1),
         comments: Enum.map(comments, &normalize_comment/1),
         deliveries: deliveries,
         execution: Keyword.get(opts, :execution),
         capabilities: %{
           create_issue: true,
           comment: issue.state != "closed",
           dispatch: issue.state != "closed",
           retry: true,
           rework: true,
           accept: true
         }
       }}
    else
      nil -> {:error, :taskboard_issue_not_found}
      error -> error
    end
  end

  @impl true
  def delivery_summaries(settings, %Issue{} = issue, opts) do
    body_urls = pull_request_urls(settings, issue.description)

    timeline_urls =
      if body_urls == [] and delivery_enrichment_candidate?(issue) do
        pull_request_timeline_urls(settings, issue, opts)
      else
        []
      end

    summaries =
      (body_urls ++ timeline_urls)
      |> Enum.uniq()
      |> Enum.map(&pull_request_summary/1)
      |> Enum.reject(&is_nil/1)

    {:ok, summaries}
  end

  @impl true
  def create_issue(settings, attrs, opts) do
    body =
      %{
        "title" => attrs["title"],
        "body" => attrs["description"] || "",
        "labels" => List.wrap(attrs["labels"])
      }
      |> Enum.reject(fn {_key, value} -> value in [nil, "", []] end)
      |> Map.new()

    with {:ok, raw} <- request(settings, "POST", issues_path(settings), %{}, body, opts) do
      {:ok, %{"id" => raw["number"], "identifier" => "GH-#{raw["number"]}", "url" => raw["html_url"]}}
    end
  end

  @impl true
  def comment(settings, identifier, body, opts) do
    with {:ok, issue} <- fetch_issue(settings, identifier, opts),
         number when is_integer(number) <- Provider.issue_number(issue),
         true <- issue.state != "closed" || {:error, :issue_closed},
         {:ok, comment} <-
           request(
             settings,
             "POST",
             issue_path(settings, number) <> "/comments",
             %{},
             %{"body" => body},
             opts
           ) do
      {:ok, normalize_comment(comment)}
    end
  end

  @impl true
  def add_label(settings, identifier, label, opts) do
    with {:ok, issue} <- fetch_issue(settings, identifier, opts),
         number when is_integer(number) <- Provider.issue_number(issue),
         true <- normalized_label(label) not in issue.labels || {:ok, :already_present} do
      request(
        settings,
        "POST",
        issue_path(settings, number) <> "/labels",
        %{},
        %{"labels" => [label]},
        opts
      )
      |> result_only()
    else
      {:ok, :already_present} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def remove_label(settings, identifier, label, opts) do
    with {:ok, issue} <- fetch_issue(settings, identifier, opts),
         number when is_integer(number) <- Provider.issue_number(issue),
         true <- normalized_label(label) in issue.labels || {:ok, :already_absent} do
      request(
        settings,
        "DELETE",
        issue_path(settings, number) <> "/labels/" <> Provider.encode(label),
        %{},
        nil,
        opts
      )
      |> result_only()
    else
      {:ok, :already_absent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp result_only({:ok, _body}), do: :ok
  defp result_only(error), do: error

  defp fetch_issue(settings, identifier, opts) do
    fetch_fun =
      Keyword.get(opts, :issue_fun, fn ids -> Client.fetch_issues_by_ids(ids, settings) end)

    if is_function(fetch_fun, 1) do
      fetch_issue_identifier(fetch_fun, identifier)
    else
      {:error, :invalid_issue_fetcher}
    end
  end

  defp fetch_issue_identifier(fetch_fun, identifier) do
    identifiers = (identifier_candidates(identifier) ++ [identifier]) |> Enum.uniq()

    Enum.reduce_while(identifiers, {:error, :taskboard_issue_not_found}, fn candidate, _acc ->
      case fetch_fun.([candidate]) do
        {:ok, issues} -> fetched_issue_result(issues, identifier)
        error -> {:halt, error}
      end
    end)
  end

  defp fetched_issue_result(issues, identifier) do
    case Enum.find(issues, &matches_identifier?(&1, identifier)) do
      %Issue{} = issue -> {:halt, {:ok, issue}}
      nil -> {:cont, {:error, :taskboard_issue_not_found}}
    end
  end

  defp identifier_candidates(identifier) do
    case Regex.run(~r/^GH-([1-9][0-9]*)$/, identifier) do
      [_, number] -> [number]
      _ -> []
    end
  end

  defp matches_identifier?(%Issue{identifier: identifier}, identifier), do: true
  defp matches_identifier?(%Issue{id: id}, identifier), do: id == identifier
  defp matches_identifier?(_issue, _identifier), do: false

  defp pull_requests(settings, issue, raw, comments, opts) do
    urls =
      [raw["body"] | Enum.map(comments, & &1["body"])]
      |> Enum.filter(&is_binary/1)
      |> Enum.flat_map(&pull_request_urls(settings, &1))
      |> Enum.uniq()

    timeline_urls = pull_request_timeline_urls(settings, issue, opts)

    urls
    |> Kernel.++(timeline_urls)
    |> Enum.uniq()
    |> Enum.map(&pull_request_details(settings, &1, opts))
    |> then(&{:ok, Enum.reject(&1, fn delivery -> delivery.url == nil end)})
  end

  defp pull_request_timeline_urls(settings, issue, opts) do
    case pages(settings, issue_path(settings, Provider.issue_number(issue)) <> "/timeline", opts, []) do
      {:ok, events} ->
        events
        |> Enum.filter(&(&1["event"] == "cross-referenced"))
        |> Enum.map(fn event ->
          get_in(event, ["source", "issue"]) || %{}
        end)
        |> Enum.filter(&(get_in(&1, ["pull_request"]) != nil))
        |> Enum.map(& &1["html_url"])
        |> Enum.filter(&is_binary/1)

      _ ->
        []
    end
  end

  defp delivery_enrichment_candidate?(%Issue{labels: labels}) do
    labels
    |> Enum.map(&String.downcase/1)
    |> Enum.any?(
      &(&1 in [
          "symphony:running",
          "symphony:review",
          "symphony:blocked",
          "symphony:failed",
          "symphony:accept"
        ])
    )
  end

  defp pull_request_summary(url) do
    case Regex.run(~r{/pull/([1-9][0-9]*)$}, url) do
      [_, number] ->
        %{kind: "pr", number: String.to_integer(number), title: nil, url: url, state: nil}

      _ ->
        nil
    end
  end

  defp pull_request_urls(settings, body) do
    repo = repo(settings)

    Regex.scan(
      ~r{https?://(?:www\.)?github\.com/#{Regex.escape(repo)}/pull/([1-9][0-9]*)},
      body,
      capture: :all
    )
    |> Enum.map(&List.first/1)
  end

  defp pull_request_details(settings, url, opts) do
    with [_, number] <- Regex.run(~r{/pull/([1-9][0-9]*)$}, url),
         {:ok, pull} <- get(settings, pulls_path(settings) <> "/" <> number, opts),
         {:ok, reviews} <- pages(settings, pulls_path(settings) <> "/" <> number <> "/reviews", opts, []),
         {:ok, comments} <- pages(settings, pulls_path(settings) <> "/" <> number <> "/comments", opts, []) do
      thread_status = unresolved_review_threads(settings, String.to_integer(number), opts)

      %{
        kind: "pr",
        number: pull["number"],
        title: pull["title"],
        url: pull["html_url"],
        state: pull["state"],
        draft: pull["draft"] == true,
        merged: pull["merged"] == true,
        merge_status: if(pull["merged"], do: "merged", else: pull["mergeable_state"] || pull["state"]),
        review_state: review_state(reviews),
        approvals: Enum.count(reviews, &(&1["state"] == "APPROVED")),
        unresolved_comments: thread_status.count,
        unresolved_supported: thread_status.supported,
        unresolved_reason: thread_status.reason,
        review_comments: length(comments),
        checks: get_in(pull, ["head", "sha"]),
        updated_at: pull["updated_at"]
      }
    else
      _ -> %{kind: "pr", number: nil, title: nil, url: url, merge_status: "unavailable"}
    end
  end

  defp review_state(reviews) do
    cond do
      Enum.any?(reviews, &(&1["state"] == "CHANGES_REQUESTED")) -> "changes_requested"
      Enum.any?(reviews, &(&1["state"] == "APPROVED")) -> "approved"
      true -> "pending"
    end
  end

  defp unresolved_review_threads(settings, number, opts) do
    case Keyword.get(opts, :graphql_fun) do
      fun when is_function(fun, 2) ->
        graphql_threads(fun, settings, number)

      _ ->
        graphql_threads(fn query, variables -> graphql_request(settings, query, variables) end, settings, number)
    end
  end

  defp graphql_threads(fun, settings, number) do
    [owner, name] = repo(settings) |> String.split("/", parts: 2)

    query = """
    query ($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) {
          reviewThreads(first: 100) {
            nodes { isResolved }
          }
        }
      }
    }
    """

    case fun.(query, %{"owner" => owner, "name" => name, "number" => number}) do
      {:ok,
       %{
         "data" => %{
           "repository" => %{
             "pullRequest" => %{"reviewThreads" => %{"nodes" => nodes}}
           }
         }
       }}
      when is_list(nodes) ->
        %{supported: true, count: Enum.count(nodes, &(&1["isResolved"] == false)), reason: nil}

      {:error, reason} ->
        %{supported: false, count: nil, reason: inspect(reason)}

      _ ->
        %{supported: false, count: nil, reason: "GitHub GraphQL did not return review threads"}
    end
  end

  defp graphql_request(settings, query, variables) do
    provider = settings.provider
    token = Provider.resolve_secret(provider["token"], System.get_env("GITHUB_TOKEN"))
    url = provider["graphql_url"] || "https://api.github.com/graphql"

    if token do
      case Req.post(url,
             json: %{"query" => query, "variables" => variables},
             headers: [
               {"Authorization", "Bearer #{token}"},
               {"Accept", "application/vnd.github+json"},
               {"User-Agent", "symphony"}
             ],
             connect_options: [timeout: 30_000]
           ) do
        {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, body}
        {:ok, %{status: status}} -> {:error, {:github_graphql_status, status}}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :missing_github_token}
    end
  end

  defp pages(settings, path, opts, acc, page \\ 1) do
    case request(settings, "GET", path, %{"per_page" => @per_page, "page" => page}, nil, opts) do
      {:ok, values} when is_list(values) ->
        next = acc ++ values

        if length(values) == @per_page do
          pages(settings, path, opts, next, page + 1)
        else
          {:ok, next}
        end

      {:ok, _payload} ->
        {:error, :github_invalid_page}

      error ->
        error
    end
  end

  defp get(settings, path, opts) do
    case request(settings, "GET", path, %{}, nil, opts) do
      {:ok, payload} when is_map(payload) -> {:ok, payload}
      {:ok, _payload} -> {:error, :github_invalid_payload}
      error -> error
    end
  end

  defp request(settings, method, path, query, body, opts) do
    request_opts =
      opts
      |> Keyword.take([:request_fun])
      |> Keyword.put(:tracker_settings, settings)

    case Client.request(method, path, query, body, request_opts) do
      {:ok, %{status: status, body: payload}} when status in 200..299 -> {:ok, payload}
      {:ok, %{status: status, body: payload}} -> {:error, {:github_api_status, status, payload}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_comment(comment) do
    body = comment["body"] || ""

    %{
      id: comment["id"],
      author: get_in(comment, ["user", "login"]) || "unknown",
      body: body,
      system: false,
      engine: TaskReconciler.engine_notice?(%{"body" => body}),
      created_at: Provider.iso8601(comment["created_at"]),
      updated_at: Provider.iso8601(comment["updated_at"]),
      url: comment["html_url"]
    }
  end

  defp label_name(%{"name" => name}), do: name
  defp label_name(name) when is_binary(name), do: name
  defp normalized_label(label), do: label |> String.trim() |> String.downcase()

  defp repo(settings), do: settings.provider["repo"] || System.get_env("GITHUB_REPO") || ""
  defp issues_path(settings), do: "/repos/#{repo(settings)}/issues"
  defp issue_path(settings, number), do: issues_path(settings) <> "/#{number}"
  defp pulls_path(settings), do: "/repos/#{repo(settings)}/pulls"
end
