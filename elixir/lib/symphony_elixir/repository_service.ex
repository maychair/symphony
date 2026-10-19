defmodule SymphonyElixir.RepositoryService do
  @moduledoc "A single service and endpoint hosting repository-isolated execution subtrees."
  use Supervisor
  alias SymphonyElixir.{Config, Execution, RepositorySupervisor, RuntimeContext, Tracker, Workflow}
  alias SymphonyElixir.Config.Schema

  @registry SymphonyElixir.RepositoryRegistry
  @environment ~w(SYMPHONY_EXECUTION_BACKEND SYMPHONY_RUN_JOURNAL_DIR SYMPHONY_WORKTREE_ROOT SYMPHONY_TARGET_REPO SYMPHONY_REVIEW_REPOSITORY SYMPHONY_BASE_REF SYMPHONY_BASE_MODE SYMPHONY_TARGET_REMOTE SYMPHONY_WORKSPACE_ROOT SYMPHONY_PROJECT SYMPHONY_TASKBOARD_URL SYMPHONY_CODEX_COMMAND SYMPHONY_BACKEND_CONFIG_FILES)

  @spec start_link([map()]) :: Supervisor.on_start()
  def start_link(repositories), do: Supervisor.start_link(__MODULE__, repositories, name: __MODULE__)

  @impl true
  def init(repositories) do
    secrets = Enum.flat_map(repositories, & &1.secrets) |> Enum.uniq()
    registry = {Registry, keys: :unique, name: @registry, meta: [repositories: repositories, secrets: secrets]}
    children = Enum.map(repositories, &Supervisor.child_spec({RepositorySupervisor, &1}, id: &1.id))
    start = {Supervisor, :start_link, [children, [strategy: :one_for_one]]}
    group = %{id: :repositories, start: start, type: :supervisor}
    Supervisor.init([registry, group], strategy: :one_for_all)
  end

  @spec repositories() :: [map()]
  def repositories do
    if Process.whereis(@registry), do: elem(Registry.meta(@registry, :repositories), 1), else: []
  end

  @spec aggregate?() :: boolean()
  def aggregate?, do: is_nil(RuntimeContext.current()) and repositories() != []

  @spec snapshot(timeout()) :: map() | :unavailable
  def snapshot(timeout) do
    snapshots =
      Enum.map(repositories(), fn context ->
        {context.id, RuntimeContext.with_context(context, fn -> SymphonyElixir.Orchestrator.snapshot(RuntimeContext.server(SymphonyElixir.Orchestrator), timeout) end)}
      end)

    if Enum.all?(snapshots, fn {_, snapshot} -> is_map(snapshot) end) do
      entries = fn key -> Enum.flat_map(snapshots, &snapshot_entries(&1, key)) end

      totals = Enum.reduce(snapshots, %{}, &add_totals/2)

      %{
        running: entries.(:running),
        retrying: entries.(:retrying),
        blocked: entries.(:blocked),
        codex_totals: totals,
        rate_limits: Map.new(snapshots, fn {id, snapshot} -> {id, snapshot.rate_limits} end),
        polling: %{checking?: Enum.any?(snapshots, fn {_, s} -> s.polling.checking? end), next_poll_in_ms: nil, poll_interval_ms: 1_000}
      }
    else
      :unavailable
    end
  end

  @spec refresh() :: map() | :unavailable
  def refresh do
    results = Enum.map(repositories(), fn context -> RuntimeContext.with_context(context, fn -> SymphonyElixir.Orchestrator.request_refresh() end) end)
    if Enum.all?(results, &is_map/1), do: %{queued: true, coalesced: Enum.all?(results, & &1.coalesced), requested_at: DateTime.utc_now(), operations: ["poll", "reconcile"]}, else: :unavailable
  end

  @spec taskboard_snapshot(keyword()) :: map()
  def taskboard_snapshot(opts) do
    snapshots =
      Enum.map(repositories(), fn context ->
        snapshot = RuntimeContext.with_context(context, fn -> SymphonyElixir.Taskboard.snapshot(Keyword.delete(opts, :settings)) end)
        {context.id, snapshot}
      end)

    base = elem(hd(snapshots), 1)
    projects = Enum.flat_map(snapshots, fn {id, s} -> Enum.map(s.projects, &Map.update!(&1, :id, fn key -> id <> ":" <> key end)) end)
    cards = Enum.flat_map(snapshots, fn {id, s} -> Enum.map(s.cards, &Map.update!(&1, :project_id, fn key -> id <> ":" <> key end)) end)
    errors = Enum.flat_map(snapshots, fn {id, s} -> Enum.map(s.errors, &Map.put(&1, :repository_id, id)) end)
    counts = Enum.reduce(snapshots, %{}, fn {_, s}, acc -> Map.merge(acc, s.counts, fn _, a, b -> a + b end) end)
    %{base | projects: projects, cards: cards, counts: counts, errors: errors}
  end

  @spec secret_environment_names() :: [String.t()]
  def secret_environment_names do
    configured = if Process.whereis(@registry), do: elem(Registry.meta(@registry, :secrets), 1), else: []
    native = System.get_env() |> Map.keys() |> Enum.filter(&String.starts_with?(&1, "SYMPHONY_CREDENTIAL_"))
    Enum.uniq(configured ++ native)
  end

  @doc false
  @spec validate_manifest(Workflow.loaded_workflow()) :: :ok | {:error, term()}
  def validate_manifest(workflow) do
    configured = workflow.config["repositories"] || []
    running = repositories()

    if is_nil(RuntimeContext.current()) and running != [] and
         configured != Enum.map(running, & &1.manifest) do
      {:error, :repository_membership_changed_restart_required}
    else
      :ok
    end
  end

  @doc false
  @spec validate_settings(Schema.t()) :: :ok | {:error, term()}
  def validate_settings(settings) do
    case RuntimeContext.current() do
      %{roots: roots, owner: owner, workflow: workflow} ->
        if scope(settings, workflow) == {roots, owner} do
          :ok
        else
          {:error, :repository_scope_changed_restart_required}
        end

      _ ->
        :ok
    end
  end

  @spec load(Path.t()) :: {:ok, [map()]} | {:error, term()}
  def load(path) do
    with {:ok, workflow} <- Workflow.load(path) do
      entries = Map.get(workflow.config, "repositories", [])

      load_entries(entries, Path.dirname(path))
    end
  end

  defp load_entries(entries, root) when is_list(entries) do
    Enum.reduce_while(entries, {:ok, []}, &load_entry(&1, &2, root)) |> validate_ownership()
  end

  defp load_entries(_, _), do: {:error, :invalid_repositories}

  defp load_entry(entry, {:ok, acc}, root) do
    case repository(entry, root) do
      {:ok, context} -> {:cont, {:ok, acc ++ [context]}}
      error -> {:halt, error}
    end
  end

  defp repository(%{"id" => id, "workflow" => path} = entry, root) when is_binary(id) and is_binary(path) do
    environment = entry["environment"] || %{}

    if Regex.match?(~r/^[a-z0-9][a-z0-9_-]*$/, id) and is_map(environment) and
         Enum.all?(environment, fn {key, value} -> key in @environment and is_binary(value) end) do
      context = %{id: id, workflow: Path.expand(path, root), environment: environment}

      RuntimeContext.with_context(context, fn -> load_repository(context, entry) end)
    else
      {:error, :invalid_repository_context}
    end
  end

  defp repository(_, _), do: {:error, :invalid_repository_context}

  defp load_repository(context, entry) do
    with {:ok, workflow} <- Workflow.load(context.workflow),
         true <- not Map.has_key?(workflow.config, "repositories") or {:error, :nested_repository_service},
         {:ok, settings} <- Schema.parse(workflow.config),
         :ok <- Config.validate_settings(settings) do
      {:ok, adapter} = Tracker.adapter_for_kind(settings.tracker.kind)
      secrets = adapter.secret_environment_names(settings.tracker)
      secrets = secrets ++ SymphonyElixir.NativeWork.secret_environment_names(settings.tracker)
      {roots, owner} = scope(settings, context.workflow)
      {:ok, Map.merge(context, %{roots: roots, owner: owner, secrets: Enum.uniq(secrets), manifest: entry})}
    end
  end

  defp add_totals({_, snapshot}, acc), do: Map.merge(acc, snapshot.codex_totals, fn _, a, b -> a + b end)

  defp snapshot_entries({id, snapshot}, key) do
    Enum.map(snapshot[key], fn entry ->
      Map.merge(entry, %{repository_id: id, identifier: id <> ":" <> entry.identifier, issue_id: id <> ":" <> entry.issue_id})
    end)
  end

  defp scope(settings, workflow) do
    roots = [Config.local_workspace_root_for(settings, workflow), Execution.journal_root_for(settings)]
    review = settings.tracker.provider["review_lane"]
    roots = if is_map(review) and review["enabled"], do: [review["state_dir"] | roots], else: roots

    owner = native_owner(settings.tracker)

    {roots, owner}
  end

  defp native_owner(tracker) do
    defaults = %{"github" => "https://api.github.com", "gitlab" => "https://gitlab.com/api/v4"}
    endpoint = tracker.provider["api_url"] || tracker.endpoint || defaults[tracker.kind] || ""
    endpoint = endpoint |> String.downcase() |> String.trim_trailing("/")
    repository = tracker.provider["project_path"] || tracker.provider["repo"] || tracker.project_slug
    repository = resolve_repository(repository, tracker.kind)
    repository = if tracker.kind == "github" and is_binary(repository), do: String.downcase(repository), else: repository
    {tracker.kind, endpoint, repository}
  end

  defp resolve_repository("$" <> name, _kind), do: RuntimeContext.get_env(name)
  defp resolve_repository(nil, "gitlab"), do: RuntimeContext.get_env("GITLAB_PROJECT_PATH")
  defp resolve_repository(nil, "github"), do: RuntimeContext.get_env("GITHUB_REPO")
  defp resolve_repository(repository, _kind), do: repository

  defp validate_ownership({:error, _} = error), do: error

  defp validate_ownership({:ok, entries}) do
    keys = Enum.map(entries, & &1.id)
    owners = Enum.map(entries, & &1.owner)
    roots = Enum.flat_map(entries, & &1.roots)

    if length(Enum.uniq(keys)) == length(keys) and length(Enum.uniq(owners)) == length(owners) and
         Enum.all?(roots, &SymphonyElixir.ArtifactFiles.safe_root?/1) and not overlapping_entries?(entries) do
      {:ok, entries}
    else
      {:error, :repository_ownership_overlap}
    end
  end

  defp overlapping_entries?(entries) do
    Enum.with_index(entries)
    |> Enum.any?(fn {entry, index} -> Enum.any?(Enum.drop(entries, index + 1), &overlap?(entry.roots, &1.roots)) end)
  end

  defp overlap?(left, right), do: Enum.any?(left, fn root -> Enum.any?(right, &overlap_paths?(root, &1)) end)

  defp overlap_paths?(left, right), do: left == right or String.starts_with?(left, right <> "/") or String.starts_with?(right, left <> "/")
end
