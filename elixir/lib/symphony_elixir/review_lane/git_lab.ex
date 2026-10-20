defmodule SymphonyElixir.ReviewLane.GitLab do
  @moduledoc "Authenticated, bounded GitLab reads and review-discussion publication via native glab credentials."

  @spec request(map(), String.t(), String.t(), map()) :: {:ok, term()} | {:error, term()}
  def request(config, method, path, fields \\ %{}) do
    if permitted?(config, method, path, fields),
      do: native_request(config, method, path, fields),
      else: {:error, :review_write_not_permitted}
  end

  @doc "Reject slash-command lines, including in code examples; GitLab comments can otherwise execute native actions."
  @spec comment_body?(term()) :: boolean()
  def comment_body?(body), do: SymphonyElixir.NativeWork.comment_body?("gitlab", body)

  defp permitted?(_config, "GET", _path, fields), do: fields == %{}

  defp permitted?(config, "POST", path, %{"body" => body} = fields) do
    Map.keys(fields) == ["body"] and comment_body?(body) and discussion_path?(config, path)
  end

  defp permitted?(_, _, _, _), do: false

  defp discussion_path?(config, path) do
    case Regex.run(~r{\Aprojects/([^/]+)/merge_requests/([1-9][0-9]*)/discussions\z}, path) do
      [_, project, _iid] -> Enum.any?(Map.keys(config["projects"]), &(URI.encode_www_form(&1) == project))
      _ -> false
    end
  end

  defp native_request(config, method, path, fields) do
    args = ["api", "--hostname", config["host"], "--method", method, path]
    args = args ++ Enum.flat_map(fields, fn {key, value} -> ["--raw-field", "#{key}=#{value}"] end)

    case command(config["glab_bin"] || "glab", args) do
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
  def mr_path(project, iid), do: "projects/#{URI.encode_www_form(project)}/merge_requests/#{iid}"

  @spec discussions(map(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def discussions(config, path), do: pages(config, path <> "/discussions", 1, [])

  @doc "Discover assigned open MRs in one explicitly registered native project, including previously unseen work."
  @spec assigned(map(), String.t()) :: {:ok, [pos_integer()]} | {:error, term()}
  def assigned(config, project) do
    path = "projects/" <> URI.encode_www_form(project)

    with {:ok, repository} <- request(config, "GET", path),
         true <- repository?(repository, config, project) or {:error, :review_repository_mismatch},
         query = URI.encode_query(%{"state" => "opened", "scope" => "all", "reviewer_id" => config["reviewer_id"]}),
         {:ok, entries} <- pages(config, path <> "/merge_requests?" <> query, 1, []),
         true <- Enum.all?(entries, &(is_integer(&1["iid"]) and &1["iid"] > 0 and &1["project_id"] == repository["id"])) or {:error, :invalid_review_discovery} do
      {:ok, Enum.map(entries, & &1["iid"])}
    end
  end

  @doc "Confirm the native repository identity and registered URL before using its review data or clone remote."
  @spec repository?(term(), map(), String.t()) :: boolean()
  def repository?(%{} = repository, config, project) do
    repository["id"] == get_in(config, ["projects", project, "id"]) and repository["path_with_namespace"] == project and
      web_url?(repository["web_url"], config, "/" <> project)
  end

  def repository?(_, _, _), do: false

  @doc "Match an exact native path, permitting HTTP only for an explicitly configured private instance."
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
