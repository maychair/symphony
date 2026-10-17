defmodule SymphonyElixir.ArtifactStore do
  @moduledoc """
  Retain immutable Git snapshots and native report bytes independently of executor worktrees.

  Stored bytes and retention references are receipts, not task state or execution
  authority. This boundary never deletes artifacts or releases live references.
  """
  alias SymphonyElixir.{Config, GitArtifact, NativeWork, ReportArtifact, TaskWorkflow, WorkRef}

  @owner "symphony-artifact-store:1\n"
  @metadata_limit 16_777_216

  @doc "Reuse validated stored bytes or acquire them natively, then durably pin the exact artifact for an owner."
  @spec retain(Path.t(), map(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def retain(root, work, revision, owner, opts) do
    with :ok <- context(root, work, revision, opts),
         true <- owner?(owner, work) or {:error, :invalid_artifact_reference},
         :ok <- prepare_root(root),
         {:ok, artifact} <- acquire(root, work, revision, opts),
         :ok <- reference(root, artifact.receipt, owner) do
      {:ok, artifact}
    end
  end

  @doc "Persist exact report bytes and a consumer reference; this does not prove native publication or technical verification."
  @spec retain_report(Path.t(), map(), map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def retain_report(root, work, report, owner, opts) do
    with :ok <- context(root, work, report["version"], opts),
         true <- owner?(owner, work) or {:error, :invalid_artifact_reference},
         {:ok, artifact} <- ReportArtifact.snapshot(work, report),
         true <- artifact.receipt["bytes"] <= Keyword.get(opts, :artifact_max_bytes, 104_857_600) or {:error, :artifact_storage_limit},
         :ok <- prepare_root(root),
         :ok <- publish(root, report_path(root, report), encode(artifact)),
         {:ok, saved} <- read_report(root, work, report, opts),
         :ok <- reference(root, saved.receipt, owner) do
      {:ok, saved}
    end
  end

  @doc "Read a fixed retained report without native requests or trusting its filename as proof."
  @spec read_report(Path.t(), map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def read_report(root, work, report, opts) do
    with :ok <- context(root, work, report["version"], opts),
         expected_source = ReportArtifact.source_ref(work, report["id"], report["version"]),
         true <- report["source"] == expected_source or {:error, :invalid_report_artifact},
         :ok <- owned_root(root),
         {:ok, data} <- read_json(report_path(root, report), file_limit(opts)),
         {:ok, artifact} <- decode(data),
         :ok <- ReportArtifact.validate(work, report, artifact),
         true <- artifact.receipt["bytes"] <= Keyword.get(opts, :artifact_max_bytes, 104_857_600) or {:error, :artifact_storage_limit} do
      {:ok, artifact}
    end
  end

  @spec report_references(Path.t(), map(), map(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def report_references(root, work, report, opts) do
    with {:ok, artifact} <- read_report(root, work, report, opts), do: stored_references(root, artifact.receipt, work)
  end

  @doc "Read retained bytes with full integrity checks, without contacting the provider or creating a reference."
  @spec read(Path.t(), map(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def read(root, work, revision, opts) do
    with :ok <- context(root, work, revision, opts),
         :ok <- owned_root(root),
         {:ok, data} <- read_json(snapshot_path(root, work, revision), file_limit(opts)),
         {:ok, artifact} <- decode(data),
         :ok <- GitArtifact.validate(work, revision, artifact, opts) do
      {:ok, artifact}
    end
  end

  @doc "List durable retention owners; damaged references remain a gap, never an empty reference set."
  @spec references(Path.t(), map(), String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def references(root, work, revision, opts) do
    with {:ok, artifact} <- read(root, work, revision, opts), do: stored_references(root, artifact.receipt, work)
  end

  defp stored_references(root, receipt, work) do
    with {:ok, names} <- File.ls(root) do
      prefix = source_key(receipt["source"]) <> "."

      names
      |> Enum.filter(&(String.starts_with?(&1, prefix) and String.ends_with?(&1, ".ref")))
      |> Enum.sort()
      |> read_references(root, receipt, work)
    end
  end

  defp context(root, work, revision, opts) do
    catalog = Keyword.get_lazy(opts, :repositories, fn -> Config.settings!().tracker.provider["plan_repositories"] || [] end)

    with :ok <- WorkRef.validate(work),
         true <- is_binary(revision) and Regex.match?(~r/\A(?:[a-f0-9]{40}|[a-f0-9]{64})\z/, revision),
         {:ok, _} <- NativeWork.resolve(work, catalog),
         true <- safe_root?(root),
         limit = Keyword.get(opts, :artifact_max_bytes, 104_857_600),
         true <- is_integer(limit) and limit > 0 do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_artifact_store_context}
    end
  end

  defp safe_root?(root) when is_binary(root) do
    Path.type(root) == :absolute and root == Path.expand(root) and
      Enum.reduce_while(Path.split(root), "/", fn segment, prefix ->
        path = Path.join(prefix, segment)

        case File.lstat(path) do
          {:ok, %{type: :directory}} -> {:cont, path}
          {:error, :enoent} -> {:cont, path}
          _ -> {:halt, false}
        end
      end) == root
  end

  defp safe_root?(_), do: false

  defp owner?(%{"kind" => kind, "work" => work, "revision" => revision} = owner, producer) do
    map_size(owner) == 3 and kind in ~w(candidate dependency manifest execution) and WorkRef.validate(work) == :ok and
      work["kind"] == "issue" and is_binary(revision) and Regex.match?(~r/\A[0-9a-f]{64}\z/, revision) and
      (kind != "candidate" or work == producer)
  end

  defp owner?(_, _), do: false

  defp prepare_root(root) do
    with {:ok, %{type: :directory}} <- File.lstat(Path.dirname(root)),
         :ok <- create_root(root),
         :ok <- sync_directory(root) do
      sync_directory(Path.dirname(root))
    end
  end

  defp create_root(root) do
    case File.mkdir(root) do
      {:error, :eexist} -> owned_root(root)
      result -> with :ok <- result, do: initialize_root(root)
    end
  end

  defp initialize_root(root) do
    with :ok <- File.chmod(root, 0o700), do: atomic_file(root, Path.join(root, ".owner"), @owner)
  end

  defp owned_root(root) do
    with {:ok, %{type: :directory}} <- File.lstat(root),
         {:ok, %{type: :regular}} <- File.lstat(Path.join(root, ".owner")),
         {:ok, @owner} <- File.read(Path.join(root, ".owner")) do
      :ok
    else
      _ -> {:error, :unowned_artifact_store}
    end
  end

  defp acquire(root, work, revision, opts) do
    case File.lstat(snapshot_path(root, work, revision)) do
      {:error, :enoent} -> capture(root, work, revision, opts)
      result -> with {:ok, _} <- result, do: read(root, work, revision, opts)
    end
  end

  defp capture(root, work, revision, opts) do
    with {:ok, artifact} <- NativeWork.read_git(work, revision, opts),
         :ok <- GitArtifact.validate(work, revision, artifact, opts),
         body = encode(artifact),
         true <- byte_size(body) <= file_limit(opts) or {:error, :artifact_storage_limit},
         :ok <- publish(root, snapshot_path(root, work, revision), body),
         {:ok, saved} <- read(root, work, revision, opts),
         true <- saved.receipt == artifact.receipt or {:error, :artifact_identity_conflict} do
      {:ok, saved}
    end
  end

  defp encode(artifact) do
    files = Enum.map(artifact.files, &Map.update!(&1, "content", fn bytes -> Base.encode64(bytes) end))
    TaskWorkflow.canonical_json(%{"schema_version" => 1, "receipt" => artifact.receipt, "files" => files})
  end

  defp decode(%{"schema_version" => 1, "receipt" => %{} = receipt, "files" => files} = data)
       when is_list(files) and map_size(data) == 3 and length(files) <= 10_000 do
    Enum.reduce_while(files, {:ok, []}, fn file, {:ok, acc} ->
      case decode_file(file) do
        {:ok, decoded} -> {:cont, {:ok, [decoded | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, decoded} -> {:ok, %{receipt: receipt, files: Enum.reverse(decoded)}}
      error -> error
    end
  end

  defp decode(_), do: {:error, :invalid_artifact_file}

  defp decode_file(%{"content" => content} = file) when is_binary(content) do
    case Base.decode64(content) do
      {:ok, bytes} -> {:ok, Map.put(file, "content", bytes)}
      _ -> {:error, :invalid_artifact_content}
    end
  end

  defp decode_file(_), do: {:error, :invalid_artifact_content}

  defp reference(root, receipt, owner) do
    ref = %{"schema_version" => 1, "artifact" => receipt["source"], "digest" => receipt["digest"], "owner" => owner}
    path = Path.join(root, source_key(receipt["source"]) <> "." <> TaskWorkflow.digest(owner) <> ".ref")
    body = TaskWorkflow.canonical_json(ref)

    with :ok <- publish(root, path, body),
         {:ok, saved} <- read_json(path, @metadata_limit),
         true <- saved == ref or {:error, :unconfirmed_artifact_reference} do
      :ok
    end
  end

  defp read_references(names, root, receipt, work) do
    Enum.reduce_while(names, {:ok, []}, fn name, {:ok, acc} ->
      with {:ok, %{"schema_version" => 1, "artifact" => source, "digest" => digest, "owner" => owner} = ref} <- read_json(Path.join(root, name), @metadata_limit),
           true <- map_size(ref) == 4 and source == receipt["source"] and digest == receipt["digest"] and owner?(owner, work),
           true <- name == source_key(source) <> "." <> TaskWorkflow.digest(owner) <> ".ref" do
        {:cont, {:ok, [owner | acc]}}
      else
        _ -> {:halt, {:error, :unconfirmed_artifact_reference}}
      end
    end)
  end

  defp publish(root, path, body) do
    with :ok <- owned_root(root), do: atomic_file(root, path, body)
  end

  defp atomic_file(root, path, body) do
    temporary = path <> "." <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower) <> ".pending"

    with :ok <- write_file(temporary, body) do
      try do
        case File.ln(temporary, path) do
          {:error, :eexist} -> with :ok <- same_file(path, body), do: sync_directory(root)
          result -> with :ok <- result, do: sync_directory(root)
        end
      after
        File.rm(temporary)
      end
    end
  end

  defp same_file(path, body) do
    with {:ok, %{type: :regular, size: size}} <- File.lstat(path),
         true <- size == byte_size(body),
         {:ok, ^body} <- File.read(path) do
      :ok
    else
      _ -> {:error, :artifact_publication_conflict}
    end
  end

  defp read_json(path, limit) do
    with {:ok, %{type: :regular, size: size}} <- File.lstat(path),
         true <- size <= limit,
         {:ok, body} <- File.read(path),
         {:ok, %{} = data} <- Jason.decode(body) do
      {:ok, data}
    else
      _ -> {:error, :invalid_artifact_file}
    end
  end

  defp write_file(path, body) do
    with {:ok, fd} <- :file.open(String.to_charlist(path), [:write, :binary, :raw, :exclusive]) do
      try do
        with :ok <- File.chmod(path, 0o600), :ok <- :file.write(fd, body), do: :file.sync(fd)
      after
        :file.close(fd)
      end
    end
  end

  defp sync_directory(path) do
    with {:ok, fd} <- :file.open(String.to_charlist(path), [:read, :raw, :directory]) do
      try do
        :file.sync(fd)
      after
        :file.close(fd)
      end
    end
  end

  defp key(work, revision), do: String.replace_prefix(GitArtifact.source_ref(work, revision), "git:", "")
  defp source_key(source), do: source |> String.replace_prefix("git:", "") |> String.replace_prefix("report:", "report-")
  defp report_path(root, report), do: Path.join(root, source_key(report["source"]) <> ".json")
  defp snapshot_path(root, work, revision), do: Path.join(root, key(work, revision) <> ".json")
  defp file_limit(opts), do: div(Keyword.get(opts, :artifact_max_bytes, 104_857_600) + 2, 3) * 4 + @metadata_limit
end
