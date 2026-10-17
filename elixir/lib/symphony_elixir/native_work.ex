defmodule SymphonyElixir.NativeWork do
  @moduledoc "Read versioned Issue material only through explicitly configured repository identities."

  alias SymphonyElixir.{Config, TaskWorkflow, WorkRef}
  alias SymphonyElixir.GitHub.Client, as: GitHub
  alias SymphonyElixir.GitLab.Client, as: GitLab

  @identity ~w(provider host repository_id)

  @doc "Read an Issue and all its comments, checking identity and concurrent Issue changes."
  @spec read(WorkRef.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def read(work, opts \\ []) do
    catalog = Keyword.get_lazy(opts, :repositories, fn -> Config.settings!().tracker.provider["plan_repositories"] || [] end)
    request = Keyword.get(opts, :request, &request/5)

    with :ok <- WorkRef.validate(work),
         true <- work["kind"] == "issue" or {:error, :expected_issue},
         {:ok, repository} <- resolve(work, catalog),
         {:ok, native_repo} <- get(request, repository, repository_path(repository)),
         :ok <- verify_repository(repository, native_repo),
         path = issue_path(repository, work["number"]),
         {:ok, before} <- get(request, repository, path),
         :ok <- verify_issue(repository, work, before),
         {:ok, notes} <- comments(request, repository, path, 1, []),
         {:ok, after_read} <- get(request, repository, path),
         true <- issue_version(before) == issue_version(after_read) or {:error, :native_issue_changed} do
      {:ok,
       %{
         work: work,
         raw: before,
         description: before[description_field(repository)],
         notes: notes,
         version: issue_version(before),
         url: before[url_field(repository)]
       }}
    end
  end

  @doc "Resolve exact host/provider/native-ID membership before making any request."
  @spec resolve(WorkRef.t(), term()) :: {:ok, map()} | {:error, atom()}
  def resolve(work, catalog) when is_list(catalog) do
    matches = Enum.filter(catalog, &(is_map(&1) and Map.take(&1, @identity) == Map.take(work, @identity)))

    case matches do
      [repository] -> if valid_repository?(repository), do: {:ok, repository}, else: {:error, :invalid_plan_repository}
      [] -> {:error, :unregistered_plan_repository}
      _ -> {:error, :ambiguous_plan_repository}
    end
  end

  def resolve(_, _), do: {:error, :invalid_plan_repositories}

  @doc "Keep configured cross-repository credentials out of executor environments."
  @spec secret_environment_names(map()) :: [String.t()]
  def secret_environment_names(settings) do
    repositories = Map.get(settings, :provider, %{}) |> Map.get("plan_repositories")

    if is_list(repositories) do
      repositories
      |> Enum.flat_map(&credential_name/1)
      |> Enum.uniq()
    else
      []
    end
  end

  defp credential_name(%{"credential" => "$" <> name}), do: if(Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]*\z/, name), do: [name], else: [])
  defp credential_name(_), do: []

  defp valid_repository?(repository) do
    path = repository["path"]
    credential = repository["credential"]

    is_binary(path) and Regex.match?(~r/\A[A-Za-z0-9_.-]+(?:\/[A-Za-z0-9_.-]+)+\z/, path) and
      Enum.all?(String.split(path, "/"), &(&1 not in [".", ".."])) and
      (repository["provider"] == "gitlab" or length(String.split(path, "/")) == 2) and
      is_binary(credential) and Regex.match?(~r/\A\$[A-Za-z_][A-Za-z0-9_]*\z/, credential) and
      valid_endpoint?(repository)
  end

  defp valid_endpoint?(%{"api_url" => api_url} = repository) when is_binary(api_url) do
    uri = URI.parse(api_url)
    authority = authority(uri)
    {expected, paths} = endpoint(repository)

    authority == expected and uri.path in paths and
      uri.userinfo == nil and uri.query == nil and uri.fragment == nil and
      allowed_transport?(uri, repository)
  end

  defp valid_endpoint?(_), do: false

  defp endpoint(%{"provider" => "github", "host" => "github.com"}), do: {"api.github.com", [nil, "", "/"]}
  defp endpoint(%{"provider" => "github", "host" => host}), do: {host, ["/api/v3", "/api/v3/"]}
  defp endpoint(%{"provider" => "gitlab", "host" => host}), do: {host, ["/api/v4", "/api/v4/"]}

  defp allowed_transport?(%URI{scheme: "https"}, _), do: true
  defp allowed_transport?(%URI{scheme: "http"}, repository), do: repository["allow_insecure_http"] == true
  defp allowed_transport?(_, _), do: false

  defp authority(%URI{host: host, port: port} = uri) when is_binary(host) do
    uri = %{uri | scheme: "https", host: String.downcase(host), port: port || 443}

    URI.to_string(%{uri | userinfo: nil, path: nil, query: nil, fragment: nil})
    |> String.replace_prefix("https://", "")
  end

  defp authority(_), do: nil

  defp repository_path(%{"provider" => "github", "path" => path}),
    do: "/repos/" <> Enum.map_join(String.split(path, "/"), "/", &URI.encode_www_form/1)

  defp repository_path(repository), do: "/projects/" <> URI.encode_www_form(repository["path"])
  defp issue_path(repository, number), do: repository_path(repository) <> "/issues/#{number}"
  defp url_field(%{"provider" => "github"}), do: "html_url"
  defp url_field(_), do: "web_url"
  defp description_field(%{"provider" => "github"}), do: "body"
  defp description_field(_), do: "description"

  defp verify_repository(repository, native) when is_map(native) do
    field = if repository["provider"] == "github", do: "full_name", else: "path_with_namespace"

    if is_integer(native["id"]) and to_string(native["id"]) == repository["repository_id"] and
         native[field] == repository["path"] and valid_native_url?(native[url_field(repository)], repository, ""),
       do: :ok,
       else: {:error, :native_repository_mismatch}
  end

  defp verify_repository(_, _), do: {:error, :native_repository_mismatch}

  defp verify_issue(repository, work, raw) when is_map(raw) do
    {number, suffix, ownership} =
      if repository["provider"] == "github",
        do: {raw["number"], "/issues/#{work["number"]}", not Map.has_key?(raw, "pull_request")},
        else: {raw["iid"], "/-/issues/#{work["number"]}", to_string(raw["project_id"]) == work["repository_id"]}

    if number == work["number"] and ownership and is_binary(raw[description_field(repository)]) and
         valid_native_url?(raw[url_field(repository)], repository, suffix),
       do: :ok,
       else: {:error, :native_issue_mismatch}
  end

  defp verify_issue(_, _, _), do: {:error, :native_issue_mismatch}

  defp valid_native_url?(url, repository, suffix) when is_binary(url) do
    uri = URI.parse(url)

    uri.scheme in ["https", "http"] and authority(uri) == repository["host"] and
      uri.userinfo == nil and uri.query == nil and uri.fragment == nil and uri.path == "/" <> repository["path"] <> suffix
  end

  defp valid_native_url?(_, _, _), do: false

  # Ignore unrelated provider response additions, but never ignore a scope,
  # assignment, state or label change while the comments are being read.
  defp issue_version(raw) when is_map(raw), do: TaskWorkflow.digest(Map.take(raw, ~w(id iid number project_id title body description state labels assignees updated_at web_url html_url pull_request)))
  defp issue_version(_), do: nil

  defp comments(_request, _repository, _path, 101, _acc), do: {:error, :native_comments_limit}

  defp comments(request, repository, path, page, acc) do
    suffix = if repository["provider"] == "github", do: "/comments", else: "/notes"
    query = %{"per_page" => 100, "page" => page, "order_by" => "created_at", "sort" => "asc"}

    with {:ok, batch} when is_list(batch) <- get(request, repository, path <> suffix, query),
         true <- Enum.all?(batch, &is_map/1) or {:error, :native_comments_invalid},
         notes = acc ++ Enum.map(batch, &normalize_note(&1, repository)),
         true <- valid_notes?(notes) or {:error, :native_comments_invalid} do
      if length(batch) < 100, do: {:ok, notes}, else: comments(request, repository, path, page + 1, notes)
    else
      {:ok, _} -> {:error, :native_comments_invalid}
      error -> error
    end
  end

  defp normalize_note(note, %{"provider" => "github"}), do: Map.put(note, "author", note["user"])
  defp normalize_note(note, _), do: note

  defp valid_notes?(notes) do
    Enum.all?(notes, &(is_integer(&1["id"]) and &1["id"] > 0 and is_binary(&1["body"]))) and
      length(Enum.uniq_by(notes, & &1["id"])) == length(notes)
  end

  defp get(request, repository, path, query \\ %{}) do
    case request.(repository["provider"], "GET", path, query, settings(repository)) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status}} when is_integer(status) -> {:error, {:native_read_status, status}}
      _ -> {:error, :native_read_failed}
    end
  end

  defp settings(%{"provider" => "github"} = repository),
    do: %{kind: "github", provider: %{"repo" => repository["path"], "api_url" => repository["api_url"], "token" => repository["credential"]}}

  defp settings(repository),
    do: %{
      kind: "gitlab",
      provider: %{"project_path" => repository["path"], "api_url" => repository["api_url"], "api_key" => repository["credential"], "allow_insecure_http" => repository["allow_insecure_http"] == true}
    }

  defp request("github", method, path, query, settings), do: GitHub.request(method, path, query, nil, tracker_settings: settings)
  defp request("gitlab", method, path, query, settings), do: GitLab.request(method, path, query, nil, tracker_settings: settings)
end
