defmodule SymphonyElixir.NativeWork do
  @moduledoc "Read native Issue, change and Git evidence only through explicitly configured repository identities."

  alias SymphonyElixir.{Config, TaskWorkflow, WorkRef}
  alias SymphonyElixir.GitHub.Client, as: GitHub
  alias SymphonyElixir.GitLab.Client, as: GitLab

  @identity ~w(provider host repository_id)

  @doc "Read a PR/MR's actual source and delivery identity twice; pre-merge test SHAs never prove delivery."
  @spec read_change(WorkRef.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def read_change(work, opts) do
    catalog = Keyword.get_lazy(opts, :repositories, fn -> Config.settings!().tracker.provider["plan_repositories"] || [] end)
    request = Keyword.get(opts, :request, &request/5)

    with :ok <- WorkRef.validate(work),
         true <- work["kind"] in ["pr", "mr"] or {:error, :expected_change},
         {:ok, repository} <- resolve(work, catalog),
         {:ok, native} <- get(request, repository, repository_path(repository)),
         :ok <- verify_repository(repository, native),
         path = repository_path(repository) <> if(work["kind"] == "pr", do: "/pulls/", else: "/merge_requests/") <> to_string(work["number"]),
         {:ok, raw} <- get(request, repository, path),
         {:ok, facts} <- change_facts(repository, work, raw),
         {:ok, after_read} <- get(request, repository, path),
         {:ok, current} <- change_facts(repository, work, after_read),
         true <- current == facts or {:error, :native_change_changed} do
      version = TaskWorkflow.digest(%{"work" => work, "facts" => facts})
      {:ok, %{work: work, facts: facts, version: version, source: "change:" <> version}}
    end
  end

  defp change_facts(repository, work, raw) when is_map(raw) do
    facts = normalize_change(repository, raw)
    suffix = if work["kind"] == "pr", do: "/pull/#{work["number"]}", else: "/-/merge_requests/#{work["number"]}"

    if facts["number"] == work["number"] and facts["target_repository"] == Map.take(work, @identity) and
         valid_native_url?(facts["url"], repository, suffix) and valid_change?(facts),
       do: {:ok, facts},
       else: {:error, :native_change_incomplete}
  end

  defp change_facts(_, _, _), do: {:error, :native_change_incomplete}

  defp normalize_change(%{"provider" => "github"} = repository, %{"head" => %{"repo" => %{}}, "base" => %{"repo" => %{}}} = raw) do
    %{
      "id" => raw["id"],
      "number" => raw["number"],
      "url" => raw["html_url"],
      "source_repository" => change_repository(repository, get_in(raw, ["head", "repo", "id"])),
      "target_repository" => change_repository(repository, get_in(raw, ["base", "repo", "id"])),
      "source_branch" => get_in(raw, ["head", "ref"]),
      "target_branch" => get_in(raw, ["base", "ref"]),
      "head" => get_in(raw, ["head", "sha"]),
      "state" => if(raw["state"] in ["open", "closed"], do: raw["state"]),
      "merged" => raw["merged"],
      "merged_at" => raw["merged_at"],
      "revision" => if(raw["merged"] == true, do: raw["merge_commit_sha"])
    }
  end

  defp normalize_change(%{"provider" => "github"}, _), do: %{}

  defp normalize_change(repository, raw) do
    target = if raw["project_id"] == raw["target_project_id"], do: raw["target_project_id"]

    %{
      "id" => raw["id"],
      "number" => raw["iid"],
      "url" => raw["web_url"],
      "source_repository" => change_repository(repository, raw["source_project_id"]),
      "target_repository" => change_repository(repository, target),
      "source_branch" => raw["source_branch"],
      "target_branch" => raw["target_branch"],
      "head" => raw["sha"],
      "state" => raw["state"],
      "merged" => raw["state"] == "merged",
      "merged_at" => raw["merged_at"],
      "revision" => if(raw["state"] == "merged", do: raw["merge_commit_sha"] || raw["squash_commit_sha"])
    }
  end

  defp change_repository(repository, id) when is_integer(id) and id > 0,
    do: repository |> Map.take(~w(provider host)) |> Map.put("repository_id", to_string(id))

  defp change_repository(_, _), do: nil

  defp valid_change?(facts) do
    is_integer(facts["id"]) and facts["id"] > 0 and is_map(facts["source_repository"]) and
      Enum.all?(~w(source_branch target_branch), &(is_binary(facts[&1]) and facts[&1] != "")) and
      git_revision?(facts["head"]) and change_state?(facts)
  end

  defp change_state?(%{"merged" => true, "state" => state, "revision" => revision, "merged_at" => time}) do
    state in ["closed", "merged"] and git_revision?(revision) and
      is_binary(time) and match?({:ok, _, _}, DateTime.from_iso8601(time))
  end

  defp change_state?(%{"merged" => false, "state" => state, "merged_at" => nil}), do: state in ["open", "opened", "closed", "locked"]
  defp change_state?(_), do: false
  defp git_revision?(value), do: is_binary(value) and Regex.match?(~r/\A(?:[a-f0-9]{40}|[a-f0-9]{64})\z/, value)

  @doc "Resolve an exact branch in the configured native repository; two matching reads pin its initial commit."
  @spec read_branch(WorkRef.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def read_branch(work, branch, opts) do
    catalog = Keyword.get_lazy(opts, :repositories, fn -> Config.settings!().tracker.provider["plan_repositories"] || [] end)
    request = Keyword.get(opts, :request, &request/5)

    with :ok <- WorkRef.validate(work),
         true <- branch_name?(branch) or {:error, :invalid_native_branch},
         {:ok, repository} <- resolve(work, catalog),
         prefix = repository_path(repository),
         {:ok, native} <- get(request, repository, prefix),
         :ok <- verify_repository(repository, native),
         suffix = if(repository["provider"] == "github", do: "/branches/", else: "/repository/branches/"),
         path = prefix <> suffix <> URI.encode_www_form(branch),
         {:ok, before} <- get(request, repository, path),
         {:ok, revision} <- branch_revision(before, repository["provider"], branch),
         {:ok, after_read} <- get(request, repository, path),
         {:ok, current} <- branch_revision(after_read, repository["provider"], branch),
         true <- current == revision or {:error, :native_branch_changed},
         {:ok, after_repository} <- get(request, repository, prefix),
         :ok <- verify_repository(repository, after_repository) do
      facts = %{"repository" => Map.take(work, @identity), "branch" => branch, "revision" => revision}
      {:ok, Map.put(facts, "source", "branch:" <> TaskWorkflow.digest(facts))}
    end
  end

  defp branch_name?(branch), do: is_binary(branch) and branch != "" and not String.contains?(branch, <<0>>)

  defp branch_revision(%{"name" => name, "commit" => %{} = commit}, provider, name) do
    revision = commit[if(provider == "github", do: "sha", else: "id")]
    if git_revision?(revision), do: {:ok, revision}, else: {:error, :native_branch_incomplete}
  end

  defp branch_revision(_, _, _), do: {:error, :native_branch_incomplete}

  @doc "Retrieve a complete fixed Git snapshot after checking the configured native repository identity."
  @spec read_git(WorkRef.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def read_git(work, revision, opts) do
    catalog = Keyword.get_lazy(opts, :repositories, fn -> Config.settings!().tracker.provider["plan_repositories"] || [] end)
    request = Keyword.get(opts, :request, &request/5)

    with :ok <- WorkRef.validate(work),
         {:ok, repository} <- resolve(work, catalog),
         prefix = repository_path(repository),
         {:ok, native} <- get(request, repository, prefix),
         :ok <- verify_repository(repository, native) do
      reader = fn suffix, query -> get(request, repository, prefix <> suffix, query) end
      SymphonyElixir.GitArtifact.read(work, revision, reader, opts)
    end
  end

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

  @doc "Fingerprint both Issue content and all comment versions for a later write fence."
  @spec snapshot_ref(map()) :: String.t()
  def snapshot_ref(snapshot) do
    TaskWorkflow.digest(%{
      "work" => snapshot.work,
      "issue" => snapshot.version,
      "notes" => Enum.map(snapshot.notes, &SymphonyElixir.TaskDecision.source_ref/1) |> Enum.sort()
    })
  end

  @doc """
  Append one comment after a fresh scope and credential-actor check.

  The caller must persist its send intent first and reconcile native readback
  even after success. A write response is never a publication receipt.
  """
  @spec comment(map(), String.t(), String.t(), keyword()) :: :sent | {:not_sent, term()} | {:uncertain, term()}
  def comment(snapshot, body, actor, opts \\ []) do
    request = Keyword.get(opts, :request, &request/5)

    with true <- is_binary(body) and String.trim(body) != "" and is_binary(actor),
         true <- comment_body?(snapshot.work["provider"], body) or {:error, :native_comment_action_not_allowed},
         catalog = Keyword.get_lazy(opts, :repositories, fn -> Config.settings!().tracker.provider["plan_repositories"] || [] end),
         {:ok, repository} <- resolve(snapshot.work, catalog),
         {:ok, %{"id" => id}} when is_integer(id) and id > 0 <- get(request, repository, "/user"),
         true <- to_string(id) == actor or {:error, :native_publication_actor_mismatch},
         {:ok, current} <- read(snapshot.work, opts),
         true <- snapshot_ref(current) == snapshot_ref(snapshot) or {:error, :native_snapshot_changed},
         true <- current.raw["state"] in ["open", "opened"] or {:error, :native_issue_not_open} do
      write_comment(repository, current.work, body, opts)
    else
      {:error, reason} -> {:not_sent, reason}
      _ -> {:not_sent, :invalid_native_publication}
    end
  end

  @doc "Keep native comment creation from executing GitLab quick actions, even when credentials have broader permissions."
  @spec comment_body?(String.t(), term()) :: boolean()
  def comment_body?("gitlab", body) when is_binary(body), do: not Regex.match?(~r{(?:\A|[\r\n])[\s]*\/}u, body)
  def comment_body?("github", body) when is_binary(body), do: true
  def comment_body?(_provider, _body), do: false

  defp write_comment(repository, work, body, opts) do
    path = issue_path(repository, work["number"]) <> if(repository["provider"] == "github", do: "/comments", else: "/notes")
    writer = Keyword.get(opts, :write_request, &write_request/6)

    case writer.(repository["provider"], "POST", path, %{}, %{"body" => body}, settings(repository)) do
      {:ok, %{status: 201}} -> :sent
      {:ok, %{status: status}} when is_integer(status) -> {:uncertain, {:native_write_status, status}}
      _ -> {:uncertain, :native_write_failed}
    end
  end

  @doc """
  Request native closure of one Issue after a fresh scope and snapshot check.

  The caller must persist its closure intent first and confirm the read-back
  state before recording a receipt; a write response is never a closure proof.
  """
  @spec close(map(), keyword()) :: :sent | {:not_sent, term()} | {:uncertain, term()}
  def close(snapshot, opts \\ []) do
    with true <- valid_snapshot?(snapshot) or {:error, :invalid_native_closure},
         catalog = Keyword.get_lazy(opts, :repositories, fn -> Config.settings!().tracker.provider["plan_repositories"] || [] end),
         true <- snapshot.work["kind"] == "issue" or {:error, :expected_issue},
         {:ok, repository} <- resolve(snapshot.work, catalog),
         true <- snapshot.raw["state"] in ["open", "opened"] or {:error, :native_issue_not_open},
         {:ok, current} <- read(snapshot.work, opts),
         true <- snapshot_ref(current) == snapshot_ref(snapshot) or {:error, :native_snapshot_changed} do
      write_close(repository, current.work, opts)
    else
      {:error, reason} -> {:not_sent, reason}
    end
  end

  defp valid_snapshot?(snapshot), do: is_map(snapshot) and is_map(snapshot[:work]) and is_map(snapshot[:raw])

  defp write_close(repository, work, opts) do
    {method, body} = closure_body(repository)
    writer = Keyword.get(opts, :write_request, &write_request/6)

    case writer.(repository["provider"], method, issue_path(repository, work["number"]), %{}, body, settings(repository)) do
      {:ok, %{status: status}} when status in [200, 201] -> :sent
      {:ok, %{status: status}} when is_integer(status) -> {:uncertain, {:native_write_status, status}}
      _ -> {:uncertain, :native_write_failed}
    end
  end

  defp closure_body(%{"provider" => "github"}), do: {"PATCH", %{"state" => "closed"}}
  defp closure_body(_), do: {"PUT", %{"state_event" => "close"}}

  @doc """
  Request native reopening of one Issue after a fresh scope and snapshot check.

  Only a closed Issue is reopened, so a repeated request never writes twice. The
  caller must persist its intent first and confirm the read-back state before
  recording a receipt; a write response is never an open proof.
  """
  @spec reopen(map(), keyword()) :: :sent | {:not_sent, term()} | {:uncertain, term()}
  def reopen(snapshot, opts \\ []) do
    with true <- valid_snapshot?(snapshot) or {:error, :invalid_native_reopen},
         catalog = Keyword.get_lazy(opts, :repositories, fn -> Config.settings!().tracker.provider["plan_repositories"] || [] end),
         true <- snapshot.work["kind"] == "issue" or {:error, :expected_issue},
         {:ok, repository} <- resolve(snapshot.work, catalog),
         true <- snapshot.raw["state"] == "closed" or {:error, :native_issue_not_closed},
         {:ok, current} <- read(snapshot.work, opts),
         true <- snapshot_ref(current) == snapshot_ref(snapshot) or {:error, :native_snapshot_changed},
         :ok <- Keyword.get(opts, :before_reopen, fn -> :ok end).() do
      write_reopen(repository, current.work, opts)
    else
      {:error, reason} -> {:not_sent, reason}
    end
  end

  defp reopen_body(%{"provider" => "github"}), do: {"PATCH", %{"state" => "open"}}
  defp reopen_body(_), do: {"PUT", %{"state_event" => "reopen"}}

  defp write_reopen(repository, work, opts) do
    {method, body} = reopen_body(repository)
    writer = Keyword.get(opts, :write_request, &write_request/6)

    case writer.(repository["provider"], method, issue_path(repository, work["number"]), %{}, body, settings(repository)) do
      {:ok, %{status: status}} when status in [200, 201] -> :sent
      {:ok, %{status: status}} when is_integer(status) -> {:uncertain, {:native_write_status, status}}
      _ -> {:uncertain, :native_write_failed}
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

    is_binary(path) and Regex.match?(~r/\A[A-Za-z0-9_.-]+(?:\/[A-Za-z0-9_.-]+)+\z/, path) and
      Enum.all?(String.split(path, "/"), &(&1 not in [".", ".."])) and
      (repository["provider"] == "gitlab" or length(String.split(path, "/")) == 2) and
      valid_credential?(repository) and
      valid_endpoint?(repository)
  end

  defp valid_credential?(%{"provider" => "gitlab"}), do: true

  defp valid_credential?(repository) do
    credential = repository["credential"]
    is_binary(credential) and Regex.match?(~r/\A\$[A-Za-z_][A-Za-z0-9_]*\z/, credential)
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
      provider: %{"project_path" => repository["path"], "api_url" => repository["api_url"], "glab_bin" => repository["glab_bin"], "allow_insecure_http" => repository["allow_insecure_http"] == true}
    }

  defp request("github", method, path, query, settings), do: GitHub.request(method, path, query, nil, tracker_settings: settings)
  defp request("gitlab", method, path, query, settings), do: GitLab.request(method, path, query, nil, tracker_settings: settings)
  defp write_request("github", method, path, query, body, settings), do: GitHub.request(method, path, query, body, tracker_settings: settings)
  defp write_request("gitlab", method, path, query, body, settings), do: GitLab.request(method, path, query, body, tracker_settings: settings)
end
