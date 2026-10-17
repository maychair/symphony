defmodule SymphonyElixir.Taskboard.GitLab do
  @moduledoc "GitLab Taskboard provider backed by the repository Issues API."

  @behaviour SymphonyElixir.Taskboard.Provider

  alias SymphonyElixir.GitLab.Client
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
         {:ok, notes} <- pages(settings, issue_path(settings, number) <> "/notes", opts, []),
         {:ok, merge_requests} <- related_merge_requests(settings, number, opts) do
      {:ok,
       %{
         issue: issue,
         description: raw["description"],
         labels: raw["labels"] || [],
         comments: Enum.map(notes, &normalize_comment/1),
         deliveries: merge_requests,
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
  def create_issue(settings, attrs, opts) do
    body =
      %{
        "title" => attrs["title"],
        "description" => attrs["description"] || "",
        "labels" => Enum.join(List.wrap(attrs["labels"]), ",")
      }
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> Map.new()

    with {:ok, raw} <- request(settings, "POST", project_path(settings) <> "/issues", %{}, body, opts) do
      {:ok, %{"id" => raw["iid"], "identifier" => "GL-#{raw["iid"]}", "url" => raw["web_url"]}}
    end
  end

  @impl true
  def comment(settings, identifier, body, opts) do
    with {:ok, issue} <- fetch_issue(settings, identifier, opts),
         number when is_integer(number) <- Provider.issue_number(issue),
         true <- issue.state != "closed" || {:error, :issue_closed},
         {:ok, note} <-
           request(
             settings,
             "POST",
             issue_path(settings, number) <> "/notes",
             %{},
             %{"body" => body},
             opts
           ) do
      {:ok, normalize_comment(note)}
    end
  end

  @impl true
  def add_label(settings, identifier, label, opts) do
    with {:ok, issue} <- fetch_issue(settings, identifier, opts),
         number when is_integer(number) <- Provider.issue_number(issue),
         true <- normalized_label(label) not in issue.labels || {:ok, :already_present} do
      request(
        settings,
        "PUT",
        issue_path(settings, number),
        %{},
        %{"add_labels" => label},
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
        "PUT",
        issue_path(settings, number),
        %{},
        %{"remove_labels" => label},
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
    case Regex.run(~r/^GL-([1-9][0-9]*)$/, identifier) do
      [_, number] -> [number]
      _ -> []
    end
  end

  defp matches_identifier?(%Issue{identifier: identifier}, identifier), do: true
  defp matches_identifier?(%Issue{id: id}, identifier), do: id == identifier
  defp matches_identifier?(_issue, _identifier), do: false

  defp related_merge_requests(settings, issue_iid, opts) do
    path = issue_path(settings, issue_iid) <> "/related_merge_requests"

    case request(settings, "GET", path, %{"per_page" => @per_page}, nil, opts) do
      {:ok, merge_requests} when is_list(merge_requests) ->
        {:ok, Enum.map(merge_requests, &merge_request_details(settings, &1, opts))}

      {:ok, _payload} ->
        {:error, :gitlab_invalid_related_merge_requests}

      {:error, _reason} ->
        # Related MRs is an optional enrichment. Older GitLab versions may not
        # expose it, while issue detail and comments remain usable.
        {:ok, []}
    end
  end

  defp merge_request_details(settings, merge_request, opts) do
    iid = merge_request["iid"]
    path = project_path(settings) <> "/merge_requests/#{iid}"
    details = get_or(settings, path, opts, merge_request)
    approvals = get_or(settings, path <> "/approvals", opts, %{})
    discussions = pages_or_empty(settings, path <> "/discussions", opts)

    unresolved =
      discussions
      |> Enum.flat_map(&(&1["notes"] || []))
      |> Enum.filter(&(&1["resolvable"] == true and &1["resolved"] == false))
      |> Enum.reject(&(&1["system"] == true))

    %{
      kind: "mr",
      number: iid,
      title: details["title"],
      url: details["web_url"] || merge_request["web_url"],
      state: details["state"],
      merged: details["state"] == "merged",
      merge_status: details["detailed_merge_status"] || details["merge_status"],
      review_state: if(List.wrap(approvals["approved_by"]) == [], do: "pending", else: "approved"),
      approvals: length(List.wrap(approvals["approved_by"])),
      unresolved_comments: length(unresolved),
      unresolved_supported: true,
      checks: get_in(details, ["head_pipeline", "status"]),
      updated_at: details["updated_at"]
    }
  end

  defp get_or(settings, path, opts, fallback) do
    case get(settings, path, opts) do
      {:ok, value} when is_map(value) -> value
      _ -> fallback
    end
  end

  defp pages_or_empty(settings, path, opts) do
    case pages(settings, path, opts, []) do
      {:ok, values} -> values
      _ -> []
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
        {:error, :gitlab_invalid_page}

      error ->
        error
    end
  end

  defp get(settings, path, opts) do
    case request(settings, "GET", path, %{}, nil, opts) do
      {:ok, payload} when is_map(payload) -> {:ok, payload}
      {:ok, _payload} -> {:error, :gitlab_invalid_payload}
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
      {:ok, %{status: status, body: payload}} -> {:error, {:gitlab_api_status, status, payload}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_comment(note) do
    body = note["body"] || ""

    %{
      id: note["id"],
      author: get_in(note, ["author", "username"]) || get_in(note, ["author", "name"]) || "unknown",
      body: body,
      system: note["system"] == true,
      engine: TaskReconciler.engine_notice?(%{"body" => body}),
      created_at: Provider.iso8601(note["created_at"]),
      updated_at: Provider.iso8601(note["updated_at"]),
      url: nil
    }
  end

  defp normalized_label(label), do: label |> String.trim() |> String.downcase()

  defp project_path(settings) do
    provider = settings.provider || %{}
    path = Provider.resolve_secret(provider["project_path"], System.get_env("GITLAB_PROJECT_PATH"))
    "/projects/" <> Provider.encode(path || "")
  end

  defp issue_path(settings, iid), do: project_path(settings) <> "/issues/#{iid}"
end
