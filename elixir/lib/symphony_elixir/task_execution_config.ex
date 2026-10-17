defmodule SymphonyElixir.TaskExecutionConfig do
  @moduledoc "Resolve host execution policies and source locations for every member of a native approved plan."
  alias SymphonyElixir.{ArtifactFiles, Config, Execution, NativeWork, RunJournal}
  alias SymphonyElixir.{TaskLifecycle, TaskPlanPreflight, WorkRef}

  @doc "Read the complete approved plan and derive its ephemeral execution registry without allocating workers or journals."
  @spec prepare(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def prepare(parent, opts \\ []) do
    catalog = Keyword.get_lazy(opts, :repositories, fn -> Config.settings!().tracker.provider["plan_repositories"] || [] end)
    root = Keyword.get_lazy(opts, :journal_root, &Execution.journal_root/0) |> path()
    opts = Keyword.put(opts, :repositories, catalog)

    with true <- ArtifactFiles.safe_root?(root) or {:error, :invalid_plan_journal_root},
         {:ok, plan} <- TaskPlanPreflight.inspect_plan(parent, opts),
         {:ok, executions} <- entries(plan, catalog, root, opts) do
      {:ok, %{plan: plan, executions: executions, opts: opts}}
    end
  catch
    kind, reason -> {:error, {:execution_configuration_failed, kind, inspect(reason)}}
  end

  defp entries(plan, catalog, root, opts) do
    Enum.reduce_while(plan.members, {:ok, %{}}, fn {key, member}, {:ok, found} ->
      case entry(member, catalog, root, opts) do
        {:ok, execution} -> {:cont, {:ok, Map.put(found, key, execution)}}
        {:error, reason} -> {:halt, {:error, {:member_execution_configuration, member.work, reason}}}
      end
    end)
  end

  defp entry(member, catalog, root, opts) do
    with {:ok, repository} <- NativeWork.resolve(member.work, catalog),
         %{"policy" => policy} = config <- repository["execution"],
         :ok <- TaskLifecycle.validate_policy(policy, member.contract),
         {:ok, source} <- source(member, config, opts) do
      {:ok, Map.merge(source, %{directory: RunJournal.directory(root, WorkRef.key(member.work)), policy: policy})}
    else
      {:error, _} = error -> error
      _ -> {:error, :missing_repository_execution_policy}
    end
  end

  defp source(member, config, opts) do
    outputs = Enum.filter(member.contract["deliverables"], &(&1["kind"] in ~w(pr mr)))
    selected = config["workspace_artifact"]
    selected_outputs = if is_nil(selected), do: outputs, else: Enum.filter(outputs, &(&1["id"] == selected))
    branches = Enum.map(selected_outputs, & &1["target_branch"]) |> Enum.uniq()

    cond do
      outputs == [] and is_nil(selected) ->
        {:ok, %{}}

      length(branches) == 1 and selected_outputs != [] ->
        repository = path(config["repository"])

        with true <- (ArtifactFiles.safe_root?(repository) and File.dir?(repository)) or {:error, :workspace_repository_unavailable},
             {:ok, base} <- NativeWork.read_branch(member.work, hd(branches), opts) do
          {:ok, %{repository: repository, base_revision: base["revision"], base_source: base, workspace_artifact: selected}}
        end

      true ->
        {:error, :workspace_source_ambiguous}
    end
  end

  defp path("$" <> name), do: System.get_env(name)
  defp path(value), do: value
end
