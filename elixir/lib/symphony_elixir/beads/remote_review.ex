defmodule SymphonyElixir.Beads.RemoteReview do
  @moduledoc "Read current PR/MR facts through the operator's native authenticated CLIs."
  alias SymphonyElixir.Beads.Acceptance

  @github_query """
  query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){pullRequest(number:$number){
    url state headRefOid mergedAt mergeCommit{oid} mergedBy{login}
    reviewDecision
    reviewThreads(first:100){pageInfo{hasNextPage} nodes{id isResolved isOutdated comments(first:100){pageInfo{hasNextPage} nodes{id body updatedAt author{login}}}}}
    commits(last:1){nodes{commit{statusCheckRollup{contexts(first:100){pageInfo{hasNextPage} nodes{
      __typename ... on CheckRun{name status conclusion} ... on StatusContext{context state description targetUrl}
    }}}}}}
  }}}
  """

  @spec fetch(map(), String.t()) :: {:ok, map()} | {:error, term()}
  def fetch(settings, url) do
    with :ok <- Acceptance.validate_review_scope(settings, url) do
      case URI.parse(url) do
        %URI{host: "github.com", path: path} -> github(path)
        %URI{host: "gitlab.com", path: path} -> gitlab(path)
        _ -> {:error, :unsupported_review_host}
      end
    end
  end

  defp github(path) do
    [_, owner, name, number] = Regex.run(~r{^/([^/]+)/([^/]+)/pull/(\d+)$}, path)

    with {:ok, result} <- json_command("gh", ["api", "graphql", "-f", "query=" <> @github_query, "-f", "owner=" <> owner, "-f", "name=" <> name, "-F", "number=" <> number]),
         nil <- result["errors"],
         %{} = pr <- get_in(result, ["data", "repository", "pullRequest"]),
         :ok <- complete_threads(pr["reviewThreads"]),
         {:ok, checks} <- github_checks(pr) do
      threads = Enum.reject(pr["reviewThreads"]["nodes"], & &1["isResolved"])
      feedback = %{threads: threads, changes_requested: pr["reviewDecision"] == "CHANGES_REQUESTED", checks: checks}
      {:ok, %{url: pr["url"], state: String.downcase(pr["state"]), head: pr["headRefOid"], actor: get_in(pr, ["mergedBy", "login"]), proof: pr, feedback: feedback}}
    else
      {:error, _} = error -> error
      _ -> {:error, :incomplete_remote_review}
    end
  end

  defp complete_threads(%{"nodes" => nodes, "pageInfo" => %{"hasNextPage" => false}}) do
    if Enum.any?(nodes, &(get_in(&1, ["comments", "pageInfo", "hasNextPage"]) != false)), do: {:error, :review_comments_need_pagination}, else: :ok
  end

  defp complete_threads(_), do: {:error, :review_threads_need_pagination}

  defp github_checks(pr) do
    case get_in(pr, ["commits", "nodes"]) do
      [%{"commit" => %{"statusCheckRollup" => nil}}] ->
        {:ok, []}

      [%{"commit" => %{"statusCheckRollup" => %{"contexts" => %{"pageInfo" => %{"hasNextPage" => false}, "nodes" => nodes}}}}] ->
        {:ok, Enum.map(nodes, fn c -> %{name: c["name"] || c["context"], status: c["conclusion"] || c["state"] || c["status"], description: c["description"], url: c["targetUrl"]} end)}

      _ ->
        {:error, :incomplete_remote_checks}
    end
  end

  defp gitlab(path) do
    [_, project, number] = Regex.run(~r{^/(.+)/-/merge_requests/(\d+)$}, path)
    endpoint = "projects/" <> URI.encode_www_form(project) <> "/merge_requests/" <> number

    with {:ok, mr} <- json_command("glab", ["api", endpoint]),
         {:ok, pages} <- json_command("glab", ["api", "--paginate", "--output", "json", endpoint <> "/discussions?per_page=100"]),
         true <- is_list(pages) || {:error, :invalid_gitlab_discussions} do
      threads = Enum.filter(pages, fn thread -> Enum.any?(thread["notes"] || [], &(&1["resolvable"] == true and &1["resolved"] != true)) end)

      checks =
        case mr["head_pipeline"] do
          nil -> []
          pipeline -> [%{name: "pipeline", status: pipeline["status"]}]
        end

      feedback = %{threads: threads, changes_requested: mr["detailed_merge_status"] == "requested_changes", checks: checks}
      {:ok, %{url: mr["web_url"], state: mr["state"], head: mr["sha"], actor: get_in(mr, ["merge_user", "username"]), proof: mr, feedback: feedback}}
    end
  end

  @spec json_command(String.t(), [String.t()]) :: {:ok, term()} | {:error, term()}
  def json_command(bin, args) do
    task = Task.async(fn -> run(bin, args) end)

    case Task.yield(task, 15_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} -> decode(output)
      {:ok, {_, status}} when is_integer(status) -> {:error, {:remote_command_failed, status}}
      {:ok, {:error, reason}} -> {:error, {:remote_command_failed, reason}}
      nil -> {:error, :remote_command_timeout}
    end
  end

  defp decode(output) do
    case Jason.decode(output) do
      {:ok, value} ->
        {:ok, value}

      {:error, _} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.reduce_while({:ok, []}, fn line, {:ok, acc} ->
          case Jason.decode(line) do
            {:ok, values} when is_list(values) -> {:cont, {:ok, acc ++ values}}
            {:ok, value} when is_map(value) -> {:cont, {:ok, acc ++ [value]}}
            _ -> {:halt, {:error, :invalid_remote_json}}
          end
        end)
    end
  end

  defp run(bin, args) do
    System.cmd(bin, args, stderr_to_stdout: false)
  rescue
    _ -> {:error, :command_unavailable}
  end
end
