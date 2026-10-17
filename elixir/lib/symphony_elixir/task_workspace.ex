defmodule SymphonyElixir.TaskWorkspace do
  @moduledoc "Generation-owned role workspaces and retained, fixed input files. No native session is started here."
  alias SymphonyElixir.{ArtifactFiles, ArtifactStore, Config, ReportArtifact, RunJournal}
  alias SymphonyElixir.{TaskExecution, TaskWorkflow, WorkRef}

  @doc "Prepare the admitted generation without reusing another role's mutable checkout or changing pinned input versions."
  @spec prepare(map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def prepare(record, executions, opts) do
    with :ok <- validate(record),
         {:ok, observation} <- ready(record, executions, opts),
         {:ok, spec, packages, source} <- specification(observation, executions, opts),
         :ok <- own(spec),
         :ok <- populate(observation.record, spec, packages, source),
         {:ok, current} <- ready(observation.record, executions, opts),
         receipt = receipt(spec),
         {:ok, saved} <- RunJournal.checkpoint(current.record, %{"workspace" => receipt["workspace"], "task_workspace" => receipt}),
         :ok <- validate(saved) do
      {:ok, saved}
    end
  end

  defp ready(record, executions, opts) do
    with {:ok, current} <- TaskExecution.refresh(record, executions, Keyword.put(opts, :active, false)),
         true <- current.flow["dispatchable"] and current.flow["next_binding"] == current.record["execution_binding"] do
      {:ok, current}
    else
      {:error, _} = error -> error
      _ -> {:error, :workspace_execution_not_ready}
    end
  end

  defp specification(observation, executions, opts) do
    record = observation.record
    binding = record["execution_binding"]
    root = Keyword.get_lazy(opts, :workspace_root, fn -> Config.settings!().workspace.root end)
    owner = %{"kind" => "execution", "work" => binding["work"], "revision" => TaskWorkflow.digest(%{"binding" => binding, "generation" => record["execution_generation"]})}
    directory = if is_binary(root), do: Path.join(root, "task-" <> owner["revision"])
    entry = executions[WorkRef.key(binding["work"])]

    with true <- ArtifactFiles.safe_root?(directory) or {:error, :invalid_role_workspace_root},
         {:ok, packages} <- packages(observation, executions, owner, opts),
         {:ok, source} <- source(observation, entry, owner, opts) do
      manifest = %{"binding" => binding, "generation" => record["execution_generation"], "packages" => Enum.map(packages, &package_manifest/1), "source" => source_manifest(source)}
      spec = %{"schema_version" => 1, "directory" => directory, "manifest" => manifest, "manifest_sha" => TaskWorkflow.digest(manifest)}
      {:ok, spec, packages, source}
    end
  end

  defp packages(observation, executions, owner, opts) do
    inputs =
      Enum.map(
        observation.evidence["dependencies"],
        &%{"category" => "inputs", "work" => &1["work"], "id" => &1["artifact"], "version" => &1["version"], "source" => &1["retrieval"], "verification" => &1["verification"]}
      )

    candidate = observation.evidence["candidate"]
    artifacts = if candidate, do: candidate["artifacts"], else: []
    candidates = Enum.map(artifacts, &Map.merge(Map.take(&1, ~w(id version source)), %{"category" => "candidate", "work" => owner["work"]}))

    Enum.reduce_while(inputs ++ candidates, {:ok, []}, fn reference, {:ok, found} ->
      entry = executions[WorkRef.key(reference["work"])]

      case retain(reference, store_root(entry, opts), owner, opts) do
        {:ok, artifact} ->
          package = %{reference: reference, artifact: artifact, path: reference["category"] <> "/" <> TaskWorkflow.digest(reference)}
          {:cont, {:ok, found ++ [package]}}

        error ->
          {:halt, error}
      end
    end)
  end

  defp retain(%{"source" => "report:" <> _} = reference, root, owner, opts) do
    with {:ok, stored} <- ArtifactStore.read_report(root, reference["work"], reference, opts),
         {:ok, report} <- ReportArtifact.build(reference["work"], reference["id"], hd(stored.files)["content"]) do
      ArtifactStore.retain_report(root, reference["work"], report, owner, opts)
    end
  end

  defp retain(reference, root, owner, opts) do
    with {:ok, artifact} <- ArtifactStore.retain(root, reference["work"], reference["version"], owner, opts),
         true <- artifact.receipt["source"] == reference["source"] or {:error, :workspace_artifact_changed} do
      {:ok, artifact}
    end
  end

  defp source(observation, entry, owner, opts) do
    candidate = observation.evidence["candidate"]
    artifacts = if candidate, do: Enum.filter(candidate["artifacts"], &String.starts_with?(&1["source"], "git:")), else: []
    artifacts = if entry[:workspace_artifact], do: Enum.filter(artifacts, &(&1["id"] == entry[:workspace_artifact])), else: artifacts
    revisions = Enum.map(artifacts, & &1["version"]) |> Enum.uniq()
    revisions = if is_nil(candidate) and entry[:base_revision], do: [entry[:base_revision]], else: revisions
    code_output = Enum.any?(observation.plan.members[WorkRef.key(owner["work"])].contract["deliverables"], &(&1["kind"] in ~w(pr mr)))

    case revisions do
      [] when not code_output -> {:ok, nil}
      [revision] -> git_source(entry, owner, revision, opts)
      _ -> {:error, :workspace_revision_unavailable}
    end
  end

  defp git_source(entry, owner, revision, opts) do
    with true <- ArtifactFiles.safe_root?(entry[:repository]) or {:error, :workspace_repository_unavailable},
         {:ok, artifact} <- ArtifactStore.retain(store_root(entry, opts), owner["work"], revision, owner, opts),
         {:ok, _} <- git(entry.repository, ["cat-file", "-e", revision <> "^{commit}"]),
         {:ok, common} <- git(entry.repository, ["rev-parse", "--path-format=absolute", "--git-common-dir"]) do
      {:ok, %{repository: entry.repository, common: common, revision: revision, artifact: artifact}}
    end
  end

  defp store_root(entry, opts), do: Keyword.get(opts, :artifact_store_root, Path.join(Path.dirname(entry.directory), ".artifacts"))
  defp package_manifest(package), do: %{"path" => package.path, "reference" => package.reference, "receipt" => package.artifact.receipt["digest"], "files" => metadata(package.artifact.files)}
  defp source_manifest(nil), do: nil
  defp source_manifest(source), do: %{"revision" => source.revision, "repository" => source.repository, "common" => source.common, "files" => metadata(source.artifact.files)}

  defp metadata(files) do
    Enum.map(files, fn file ->
      data = Map.take(file, ~w(path mode size sha256))
      if file["mode"] == "120000", do: Map.put(data, "target", file["content"]), else: data
    end)
  end

  defp own(spec) do
    root = spec["directory"]

    with true <- ArtifactFiles.safe_root?(root) or {:error, :invalid_role_workspace_root},
         :ok <- File.mkdir_p(Path.dirname(root)) do
      case File.mkdir(root) do
        :ok -> write_once(Path.join(root, ".owner"), owner_body(spec))
        {:error, :eexist} -> same_file(Path.join(root, ".owner"), owner_body(spec))
        error -> error
      end
    end
  end

  defp owner_body(spec), do: TaskWorkflow.canonical_json(Map.drop(spec, ["manifest"]))

  defp populate(%{"task_workspace" => %{} = saved} = record, spec, _, _) do
    if saved == receipt(spec), do: validate(record), else: {:error, :workspace_specification_changed}
  end

  defp populate(_record, spec, packages, source) do
    root = spec["directory"]

    with :ok <- File.mkdir_p(Path.join(root, "inputs")),
         :ok <- File.mkdir_p(Path.join(root, "candidate")),
         :ok <- materialize_packages(root, packages),
         :ok <- checkout(Path.join(root, "source"), source) do
      write_once(Path.join(root, "manifest.json"), TaskWorkflow.canonical_json(spec["manifest"]))
    end
  end

  defp materialize_packages(root, packages) do
    Enum.reduce_while(packages, :ok, fn package, :ok ->
      case ArtifactFiles.materialize(Path.join(root, package.path), package.artifact.files) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp checkout(path, nil), do: File.mkdir(path) |> existing_directory(path)

  defp checkout(path, source) do
    with :ok <- create_worktree(path, source),
         :ok <- git_identity(path, source_manifest(source), true),
         {:ok, _} <- git(path, ["read-tree", source.revision]) do
      ArtifactFiles.materialize(path, source.artifact.files, writable: true, ignore: [".git"])
    end
  end

  defp create_worktree(path, source) do
    case File.lstat(path) do
      {:error, :enoent} ->
        with {:ok, _} <- git(source.repository, ["worktree", "add", "--detach", "--no-checkout", path, source.revision]), do: :ok

      {:ok, %{type: :directory}} ->
        :ok

      _ ->
        {:error, :workspace_path_occupied}
    end
  end

  defp existing_directory({:error, :eexist}, path) do
    if ArtifactFiles.safe_root?(path), do: :ok, else: {:error, :workspace_path_occupied}
  end

  defp existing_directory(result, _), do: result

  defp receipt(spec) do
    %{
      "schema_version" => 1,
      "directory" => spec["directory"],
      "workspace" => Path.join(spec["directory"], "source"),
      "generation" => spec["manifest"]["generation"],
      "binding_sha" => TaskWorkflow.digest(spec["manifest"]["binding"]),
      "manifest_sha" => spec["manifest_sha"],
      "owner_sha" => hash(owner_body(spec))
    }
  end

  @doc "Recheck materialized inputs before role tools. Developer edits survive resume; verifier source bytes remain fixed."
  @spec validate(map()) :: :ok | {:error, term()}
  def validate(%{"task_workspace" => receipt} = record) when is_map(receipt) do
    with true <- receipt?(receipt),
         true <- receipt["generation"] == record["execution_generation"] and receipt["binding_sha"] == record["execution_binding_sha"],
         true <- record["workspace"] == receipt["workspace"] and receipt["workspace"] == Path.join(receipt["directory"], "source"),
         true <- ArtifactFiles.safe_root?(receipt["directory"]) and ArtifactFiles.safe_root?(receipt["workspace"]),
         true <- Enum.all?(~w(source inputs candidate), &File.dir?(Path.join(receipt["directory"], &1))),
         {:ok, owner} <- read_file(Path.join(receipt["directory"], ".owner")),
         true <- hash(owner) == receipt["owner_sha"],
         {:ok, body} <- read_file(Path.join(receipt["directory"], "manifest.json")),
         true <- hash(body) == receipt["manifest_sha"],
         {:ok, %{} = manifest} <- Jason.decode(body),
         true <- is_list(manifest["packages"]),
         true <- manifest["binding"] == record["execution_binding"] and manifest["generation"] == record["execution_generation"],
         files = Enum.flat_map(manifest["packages"], &package_files/1),
         :ok <- ArtifactFiles.validate(receipt["directory"], files, ignore: [".owner", "manifest.json", "source"]),
         :ok <- validate_source(record, manifest["source"]) do
      :ok
    else
      _ -> {:error, :role_workspace_changed}
    end
  end

  def validate(record), do: if(Map.has_key?(record, "task_workspace"), do: {:error, :role_workspace_changed}, else: :ok)

  defp package_files(package) do
    Enum.map(package["files"], &Map.update!(&1, "path", fn path -> Path.join(package["path"], path) end))
  end

  defp receipt?(receipt) do
    receipt["schema_version"] == 1 and is_binary(receipt["directory"]) and is_binary(receipt["workspace"]) and
      Enum.all?(~w(binding_sha manifest_sha owner_sha), &(is_binary(receipt[&1]) and Regex.match?(~r/\A[0-9a-f]{64}\z/, receipt[&1])))
  end

  @doc "Expose generation-owned input paths to the role session and host checks."
  @spec environment(map()) :: map()
  def environment(%{"task_workspace" => %{"directory" => root}}) do
    %{"SYMPHONY_TASK_INPUTS" => Path.join(root, "inputs"), "SYMPHONY_TASK_CANDIDATES" => Path.join(root, "candidate"), "SYMPHONY_TASK_MANIFEST" => Path.join(root, "manifest.json")}
  end

  def environment(_), do: %{}

  defp validate_source(record, source) do
    fixed = record["execution_binding"]["role"] == "verifier"

    with :ok <- git_identity(record["workspace"], source, fixed) do
      validate_source_files(record["workspace"], source, fixed)
    end
  end

  defp validate_source_files(path, source, true) do
    ArtifactFiles.validate(path, if(source, do: source["files"], else: []), writable: true, ignore: [".git"])
  end

  defp validate_source_files(_, _, false), do: :ok

  defp git_identity(path, nil, _) do
    if File.lstat(Path.join(path, ".git")) == {:error, :enoent}, do: :ok, else: {:error, :unexpected_git_workspace}
  end

  defp git_identity(path, source, fixed) do
    with {:ok, %{type: :regular}} <- File.lstat(Path.join(path, ".git")),
         {:ok, common} <- git(path, ["rev-parse", "--path-format=absolute", "--git-common-dir"]),
         true <- common == source["common"],
         {:ok, admin} <- git(path, ["rev-parse", "--path-format=absolute", "--git-dir"]),
         true <- String.starts_with?(admin, common <> "/worktrees/"),
         {:ok, back_link} <- read_file(Path.join(admin, "gitdir")),
         true <- String.trim(back_link) == Path.join(path, ".git"),
         {:ok, head} <- git(path, ["rev-parse", "HEAD"]),
         true <- not fixed or head == source["revision"] do
      :ok
    else
      _ -> {:error, :git_workspace_changed}
    end
  end

  defp git(path, args) do
    command = [
      "-i",
      "PATH=" <> System.get_env("PATH", "/usr/bin:/bin"),
      "GIT_CONFIG_NOSYSTEM=1",
      "GIT_CONFIG_GLOBAL=/dev/null",
      "GIT_NO_REPLACE_OBJECTS=1",
      "git",
      "-c",
      "core.hooksPath=/dev/null",
      "-c",
      "core.fsmonitor=false",
      "-C",
      path | args
    ]

    case System.cmd("env", command, stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      _ -> {:error, :git_workspace_unavailable}
    end
  end

  defp write_once(path, body) do
    case File.write(path, body, [:exclusive, :sync]) do
      :ok -> :ok
      {:error, :eexist} -> same_file(path, body)
      error -> error
    end
  end

  defp same_file(path, body), do: if(read_file(path) == {:ok, body}, do: :ok, else: {:error, :workspace_path_occupied})

  defp read_file(path) do
    with {:ok, %{type: :regular, links: 1, size: size}} when size <= 16_777_216 <- File.lstat(path), do: File.read(path)
  end

  defp hash(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
