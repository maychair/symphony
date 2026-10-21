defmodule SymphonyElixir.ReviewRequest do
  @moduledoc """
  Prepares fixed review source context for the admitted native target.

  Preparation owns source acquisition and provider reads only. Instruction loading and native execution belong to the caller.
  """

  alias SymphonyElixir.ReviewLane.{GitHub, GitLab}

  @review_ref_prefix %{"gitlab" => "refs/merge-requests/", "github" => "refs/pull/"}
  @commit ~r/^[a-f0-9]{40}(?:[a-f0-9]{24})?$/

  @type context :: %{
          required(:record) => map(),
          required(:repository) => Path.t(),
          required(:config) => map(),
          required(:mr) => map(),
          required(:discussions) => list()
        }

  @spec prepare(map(), map()) :: {:ok, context()} | {:error, term()}
  def prepare(request, config) when is_map(request) and is_map(config) do
    request = stringify_keys(request)

    case request["kind"] do
      "mr" -> prepare_mr(request, config)
      "local" -> prepare_local(request, config)
      _ -> {:error, :invalid_review_request}
    end
  end

  def prepare(_request, _config), do: {:error, :invalid_review_request}

  @doc "Remove a manual snapshot created by prepare/2. Automatic workspaces are left to their owner."
  @spec cleanup(context()) :: :ok
  def cleanup(%{record: %{"_temporary_review_workspace" => true}, repository: repository}) do
    workspace = Path.dirname(repository)
    _ = File.rm_rf(workspace)
    :ok
  end

  def cleanup(_context), do: :ok

  defp prepare_mr(request, config) do
    with {:ok, project} <- required_string(request, "project"),
         {:ok, number} <- positive_integer(request["number"]),
         {:ok, record} <- required_map(request, "record", %{}),
         true <- is_nil(record["resume_thread_id"]) || {:error, :legacy_review_resume_not_supported},
         true <- Map.has_key?(config["projects"] || %{}, project) || {:error, :review_project_not_allowed},
         true <- request_provider?(request, config) || {:error, :review_provider_mismatch},
         {:ok, native} <- provider(config),
         :ok <- native_identity(native, config),
         {:ok, mr} <- read_merge_request(native, config, project, number),
         {:ok, view} <- merge_request_view(mr, config, project, number),
         :ok <- matching_or_unset(record, "project", project),
         :ok <- matching_or_unset(record, "iid", number),
         :ok <- fixed_record(record, view),
         record = record_defaults(record, %{"project" => project, "iid" => number, "head" => view.head, "base" => view.base, "target_branch" => view.target_branch}),
         {:ok, discussions} <- native.discussions(config, native.mr_path(project, number)),
         {:ok, workspace} <- request_workspace(request),
         {:ok, repository} <- snapshot_mr(workspace, record, config) do
      {:ok, evidence} = linked_issue_evidence(mr, record, request, config, project)
      mr = Map.put(mr, "symphony_issue_evidence", evidence)
      record = record_defaults(record, %{"base" => view.base, "head" => view.head, "target_branch" => view.target_branch})
      record = record |> Map.put("issue_evidence", evidence) |> Map.put("_temporary_review_workspace", request["workspace"] == nil)
      {:ok, %{record: record, repository: repository, config: config, mr: mr, discussions: discussions}}
    end
  end

  defp prepare_local(request, config) do
    with {:ok, source} <- required_absolute_path(request, "repository"),
         {:ok, base_ref} <- required_string(request, "base"),
         {:ok, head_ref} <- required_string(request, "head"),
         {:ok, target_branch} <- required_string(request, "target_branch"),
         {:ok, reference} <- resolve_commit(source, base_ref),
         {:ok, head} <- resolve_commit(source, head_ref),
         {:ok, merge_base} <- git(source, ["merge-base", reference, head]),
         base = String.trim(merge_base),
         {:ok, record} <- required_map(request, "record", %{}),
         :ok <- matching_or_unset(record, "base", base),
         :ok <- matching_or_unset(record, "head", head),
         :ok <- matching_or_unset(record, "target_branch", target_branch),
         {:ok, mr} <- optional_map(request, "mr"),
         {:ok, discussions} <- optional_list(request, "discussions"),
         {:ok, workspace} <- request_workspace(request),
         {:ok, repository} <- snapshot_local(workspace, source, base, head) do
      {:ok, evidence} = explicit_or_unavailable_evidence(request)
      mr = mr |> Map.put("symphony_issue_evidence", evidence)
      record = record_defaults(record, %{"base" => base, "head" => head, "target_branch" => target_branch})
      record = record |> Map.put("issue_evidence", evidence) |> Map.put("_temporary_review_workspace", request["workspace"] == nil)
      {:ok, %{record: record, repository: repository, config: config, mr: mr, discussions: discussions}}
    end
  end

  defp request_provider?(request, config),
    do: request["host"] in [nil, config["host"]] and request["provider"] in [nil, config["provider"]]

  defp read_merge_request(GitHub = native, config, project, number), do: native.read_pull(config, project, number)
  defp read_merge_request(native, config, project, number), do: native.request(config, "GET", native.mr_path(project, number))

  defp merge_request_view(mr, config, project, number) when is_map(mr) do
    with %{"sha" => head} <- mr,
         %{"diff_refs" => %{"base_sha" => base}} <- mr,
         %{"target_branch" => target_branch} <- mr,
         true <- get_in(mr, ["project_id"]) == get_in(config, ["projects", project, "id"]),
         true <- mr["iid"] in [nil, number] && mr["number"] in [nil, number],
         true <- commit?(head) and commit?(base) and is_binary(target_branch) and target_branch != "" do
      {:ok, %{base: base, head: head, target_branch: target_branch}}
    else
      _ -> {:error, :invalid_native_review}
    end
  end

  defp merge_request_view(_mr, _config, _project, _number), do: {:error, :invalid_native_review}

  defp fixed_record(record, view) do
    Enum.reduce_while(["base", "head", "target_branch"], :ok, fn field, :ok ->
      expected = Map.fetch!(view, String.to_existing_atom(field))

      case record[field] do
        nil -> {:cont, :ok}
        ^expected -> {:cont, :ok}
        _ -> {:halt, {:error, String.to_atom("review_#{field}_mismatch")}}
      end
    end)
  end

  defp native_identity(native, config) do
    with publisher when is_integer(publisher) <- config["publisher_id"],
         {:ok, %{"id" => ^publisher}} <- native.request(config, "GET", "user") do
      :ok
    else
      {:ok, _} -> {:error, :review_identity_mismatch}
      {:error, _} = error -> error
      _ -> {:error, :review_identity_mismatch}
    end
  end

  defp snapshot_mr(workspace, record, config) do
    repository = Path.join(workspace, "source")
    checkout = get_in(config, ["projects", record["project"], "checkout"])
    native = provider!(config)

    # Clone only the configured checkout. The remote is reset to the verified
    # provider URL before the fixed review ref is fetched.
    with true <- (is_binary(checkout) and File.dir?(checkout)) || {:error, :review_checkout_unavailable},
         {:ok, project} <- native.request(config, "GET", repository_path(config, record["project"])),
         remote = clone_url(project, config),
         true <- safe_project?(project, remote, config, record) || {:error, :unsafe_project_remote},
         true <- not File.exists?(repository) || {:error, :review_snapshot_already_exists},
         {:ok, _} <- git_command(["clone", "--no-local", "--no-checkout", "--no-hardlinks", "--", checkout, repository]),
         {:ok, _} <- git(repository, ["remote", "set-url", "origin", remote]),
         {:ok, _} <- git(repository, ["fetch", "origin", review_ref(config, record["iid"])]),
         {:ok, _} <- git(repository, ["cat-file", "-e", record["base"] <> "^{commit}"]),
         {:ok, _} <- git(repository, ["checkout", "--detach", record["head"]]) do
      {:ok, repository}
    end
  end

  defp snapshot_local(workspace, source, base, head) do
    repository = Path.join(workspace, "source")

    with true <- not File.exists?(repository) || {:error, :review_snapshot_already_exists},
         {:ok, _} <- git_command(["clone", "--no-local", "--no-hardlinks", "--no-checkout", "--", source, repository]),
         {:ok, _} <- git(repository, ["cat-file", "-e", base <> "^{commit}"]),
         {:ok, _} <- git(repository, ["checkout", "--detach", head]) do
      {:ok, repository}
    end
  end

  defp request_workspace(%{"workspace" => workspace}) when is_binary(workspace) do
    with true <- Path.type(workspace) == :absolute || {:error, :review_workspace_must_be_absolute},
         :ok <- SymphonyElixir.Workspace.validate_review_workspace(workspace),
         :ok <- File.mkdir_p(workspace) do
      {:ok, Path.expand(workspace)}
    end
  end

  defp request_workspace(request) when is_map_key(request, "workspace"), do: {:error, :invalid_review_workspace}

  defp request_workspace(_request) do
    nonce = Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
    SymphonyElixir.Workspace.create_for_review(%{identifier: "review-manual-" <> nonce})
  end

  defp commit?(value), do: is_binary(value) and Regex.match?(@commit, value)

  defp resolve_commit(source, ref) do
    with true <- File.dir?(source) || {:error, :review_repository_unavailable},
         {:ok, output} <- git(source, ["rev-parse", "--verify", "--end-of-options", ref <> "^{commit}"]),
         sha = String.trim(output),
         true <- Regex.match?(@commit, sha) || {:error, :invalid_review_revision} do
      {:ok, sha}
    end
  end

  defp linked_issue_evidence(mr, record, request, config, project) do
    explicit = explicit_evidence(request)
    {refs, unresolved} = linked_issue_refs(mr, record, request, config, project)

    result =
      case {explicit, refs} do
        {evidence, []} when evidence != nil ->
          {:ok, evidence}

        {evidence, refs} when evidence != nil ->
          {:ok, Map.put(evidence, "additional_links", refs)}

        {nil, []} ->
          {:ok, unavailable_evidence(:no_linked_issue_reference)}

        {nil, refs} ->
          {:ok, evidence} = fetch_issues(config, project, Enum.take(refs, 4))
          if length(refs) > 4, do: {:ok, Map.merge(evidence, %{"status" => "incomplete", "truncated" => true})}, else: {:ok, evidence}
      end

    case result do
      {:ok, evidence} when unresolved != [] -> {:ok, Map.merge(evidence, %{"status" => "incomplete", "unresolved_links" => unresolved})}
      other -> other
    end
  end

  defp explicit_or_unavailable_evidence(request) do
    case explicit_evidence(request) do
      nil -> {:ok, unavailable_evidence(:no_linked_issue_reference)}
      evidence -> {:ok, evidence}
    end
  end

  defp explicit_evidence(request) do
    cond do
      is_list(request["issue_evidence"]) and request["issue_evidence"] != [] ->
        explicit_items(request["issue_evidence"])

      is_map(request["issue"]) ->
        explicit_items([request["issue"]])

      true ->
        nil
    end
  end

  defp explicit_items(items) do
    evidence = Enum.map(Enum.take(items, 4), &bounded_issue/1)
    status = if length(items) <= 4 and Enum.all?(evidence, &(&1["status"] == "available")), do: "available", else: "incomplete"
    %{"status" => status, "items" => evidence}
  end

  defp linked_issue_refs(mr, record, request, config, project) do
    direct = [request["issue_iid"], request["issue_number"], record["issue_iid"], record["issue_number"]]
    description = if is_binary(mr["description"]), do: mr["description"], else: ""
    parsed = Regex.scan(~r/(?i)\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\s+(\#[1-9][0-9]*\b|https?:\/\/[^\s<>\])]+)/, description, capture: :all_but_first)

    {linked, unresolved} =
      Enum.reduce(List.flatten(parsed), {[], []}, fn token, {ids, missing} ->
        case linked_issue_number(token, config, project) do
          {:ok, number} -> {[number | ids], missing}
          :error -> {ids, [token | missing]}
        end
      end)

    refs =
      (direct ++ linked)
      |> Enum.reduce([], fn value, acc ->
        case positive_integer(value) do
          {:ok, number} -> [number | acc]
          _ -> acc
        end
      end)
      |> Enum.uniq()
      |> Enum.sort()

    {refs, Enum.uniq(unresolved)}
  end

  defp linked_issue_number("#" <> number, _config, _project), do: positive_integer(number)

  defp linked_issue_number(url, config, project) do
    prefix = if config["provider"] == "github", do: "/#{project}/issues/", else: "/#{project}/-/issues/"
    path = URI.parse(url).path || ""

    with true <- String.starts_with?(path, prefix),
         {:ok, number} <- positive_integer(String.replace_prefix(path, prefix, "")),
         true <- GitLab.web_url?(url, config, prefix <> Integer.to_string(number)) do
      {:ok, number}
    else
      _ -> :error
    end
  end

  defp fetch_issues(config, project, refs) do
    native = provider!(config)

    items =
      Enum.map(refs, fn iid ->
        path =
          case config["provider"] do
            "github" -> "repos/#{project}/issues/#{iid}"
            _ -> "projects/#{URI.encode_www_form(project)}/issues/#{iid}"
          end

        case native.request(config, "GET", path) do
          {:ok, issue} when is_map(issue) -> bounded_issue(issue)
          {:error, reason} -> %{"status" => "unavailable", "iid" => iid, "reason" => inspect(reason)}
          _ -> %{"status" => "unavailable", "iid" => iid, "reason" => "invalid_issue_response"}
        end
      end)

    status = if Enum.all?(items, &(&1["status"] == "available")), do: "available", else: "incomplete"
    {:ok, %{"status" => status, "items" => items}}
  end

  defp bounded_issue(issue) when is_map(issue) do
    description = issue["description"] || issue["body"]
    available = is_binary(description) and String.trim(description) != "" and String.length(description) <= 65_536

    %{
      "status" => if(available, do: "available", else: "incomplete"),
      "iid" => issue["iid"] || issue["number"],
      "title" => bounded_text(issue["title"], 512),
      "description" => bounded_text(issue["description"] || issue["body"], 65_536),
      "state" => bounded_text(issue["state"], 64),
      "web_url" => bounded_text(issue["web_url"] || issue["html_url"], 2048)
    }
  end

  defp bounded_issue(_issue), do: %{"status" => "unavailable", "reason" => "invalid_issue_response"}

  defp bounded_text(value, limit) when is_binary(value), do: String.slice(value, 0, limit)
  defp bounded_text(_value, _limit), do: nil

  defp unavailable_evidence(reason), do: %{"status" => "unavailable", "reason" => Atom.to_string(reason), "items" => []}

  defp record_defaults(record, values) do
    record
    |> Map.merge(values)
    |> Map.put_new("policy_sha", nil)
    |> Map.put_new("round", 1)
    |> Map.put_new("finding_register", %{})
  end

  defp matching_or_unset(record, field, value) do
    case record[field] do
      nil -> :ok
      ^value -> :ok
      _ -> {:error, String.to_atom("review_#{field}_mismatch")}
    end
  end

  defp provider(%{"provider" => "github"}), do: {:ok, GitHub}
  defp provider(%{"provider" => "gitlab"}), do: {:ok, GitLab}
  defp provider(_config), do: {:error, :review_lane_provider_unsupported}
  defp provider!(%{"provider" => "github"}), do: GitHub
  defp provider!(_config), do: GitLab

  defp repository_path(%{"provider" => "github"}, project), do: "repos/" <> project
  defp repository_path(_, project), do: "projects/" <> URI.encode_www_form(project)
  defp clone_url(project, %{"provider" => "github"}), do: project["ssh_url"] || project["clone_url"]
  defp clone_url(project, _config), do: project["ssh_url_to_repo"] || project["http_url_to_repo"]
  defp review_ref(%{"provider" => "github"}, number), do: @review_ref_prefix["github"] <> "#{number}/head"
  defp review_ref(_config, number), do: @review_ref_prefix["gitlab"] <> "#{number}/head"

  defp safe_project?(project, remote, config, record) do
    native = provider!(config)
    native.repository?(project, config, record["project"]) and valid_remote?(remote, config, record)
  end

  defp valid_remote?(remote, config, record) when is_binary(remote) do
    if String.starts_with?(remote, "git@") do
      remote == "git@" <> config["host"] <> ":" <> record["project"] <> ".git"
    else
      uri = URI.parse(remote)

      (uri.scheme == "https" or (uri.scheme == "http" and config["allow_insecure_http"] == true)) and
        uri.host == config["host"] and uri.path == "/" <> record["project"] <> ".git" and
        is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment)
    end
  end

  defp valid_remote?(_remote, _config, _record), do: false

  defp git_command(args), do: GitLab.command("git", args)

  defp git(repository, args), do: git_command(["-C", repository | args])

  defp required_string(map, key) do
    value = map[key]
    if is_binary(value) and String.trim(value) != "", do: {:ok, String.trim(value)}, else: {:error, {:missing_review_field, key}}
  end

  defp required_absolute_path(map, key) do
    with {:ok, value} <- required_string(map, key),
         true <- Path.type(value) == :absolute || {:error, {:review_path_must_be_absolute, key}},
         true <- File.dir?(value) || {:error, {:review_path_unavailable, key}} do
      {:ok, Path.expand(value)}
    end
  end

  defp required_map(map, key, default) do
    case map[key] || default do
      value when is_map(value) -> {:ok, stringify_keys(value)}
      _ -> {:error, {:missing_review_field, key}}
    end
  end

  defp optional_map(map, key) do
    case Map.get(map, key, %{}) do
      value when is_map(value) -> {:ok, stringify_keys(value)}
      _ -> {:error, {:invalid_review_field, key}}
    end
  end

  defp optional_list(map, key) do
    case Map.get(map, key, []) do
      value when is_list(value) -> {:ok, value}
      _ -> {:error, {:invalid_review_field, key}}
    end
  end

  defp positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number > 0 -> {:ok, number}
      _ -> {:error, :invalid_review_number}
    end
  end

  defp positive_integer(_value), do: {:error, :invalid_review_number}
  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {if(is_atom(key), do: Atom.to_string(key), else: key), value} end)
end
