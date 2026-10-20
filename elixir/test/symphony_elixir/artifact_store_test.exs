defmodule SymphonyElixir.ArtifactStoreTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.{ArtifactStore, GitArtifact, GitArtifactFixture, TaskWorkflow}

  defp fixture(provider \\ "github", files \\ %{"report" => "verified\n", "data/binary" => <<0, 255, 10>>}) do
    root = Path.join(System.tmp_dir!(), "artifact-store-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    git = GitArtifactFixture.create(Path.join(root, "source"), provider, files)
    work = %{"provider" => provider, "host" => provider <> ".test", "repository_id" => "10", "kind" => "issue", "number" => 2}
    prefix = if provider == "github", do: "/repos/team/repo", else: "/projects/team%2Frepo"
    url = "https://" <> work["host"] <> "/team/repo"
    native = if provider == "github", do: %{"id" => 10, "full_name" => "team/repo", "html_url" => url}, else: %{"id" => 10, "path_with_namespace" => "team/repo", "web_url" => url}

    repository =
      Map.take(work, ~w(provider host repository_id))
      |> Map.merge(%{"path" => "team/repo", "api_url" => "https://" <> work["host"] <> if(provider == "github", do: "/api/v3", else: "/api/v4"), "credential" => "$UNUSED_ARTIFACT_STORE"})

    objects = Map.new(git.objects, fn {path, value} -> {prefix <> path, value} end) |> Map.put(prefix, native)
    state = start_supervised!({Agent, fn -> %{objects: objects, reads: 0, available: true} end}, id: make_ref())

    request = fn ^provider, "GET", path, _query, _settings ->
      Agent.get_and_update(state, &native_response(&1, path))
    end

    %{
      root: root,
      store: Path.join(root, "retained"),
      work: work,
      git: git,
      state: state,
      owner: %{"kind" => "candidate", "work" => work, "revision" => TaskWorkflow.digest("candidate")},
      opts: [repositories: [repository], request: request]
    }
  end

  defp native_response(current, path) do
    result = if current.available, do: {:ok, %{status: 200, body: Map.fetch!(current.objects, path)}}, else: {:error, :offline}
    {result, %{current | reads: current.reads + 1}}
  end

  defp retain(context, owner \\ nil, opts \\ []),
    do: ArtifactStore.retain(context.store, context.work, context.git.revision, owner || context.owner, Keyword.merge(context.opts, opts))

  defp read(context, opts \\ []), do: ArtifactStore.read(context.store, context.work, context.git.revision, Keyword.merge(context.opts, opts))
  defp references(context), do: ArtifactStore.references(context.store, context.work, context.git.revision, context.opts)
  defp reads(context), do: Agent.get(context.state, & &1.reads)
  defp snapshot_path(context), do: Path.join(context.store, String.replace_prefix(GitArtifact.source_ref(context.work, context.git.revision), "git:", "") <> ".json")
  defp mutate(context, function), do: File.write!(snapshot_path(context), Jason.encode!(function.(Jason.decode!(File.read!(snapshot_path(context))))))

  test "both providers retain exact binary bytes after source worktrees are removed and Git becomes unavailable" do
    for provider <- ["github", "gitlab"] do
      context = fixture(provider)
      assert {:ok, artifact} = retain(context)
      requests = reads(context)
      assert requests > 0
      assert {:ok, [owner]} = references(context)
      assert owner == context.owner
      assert File.stat!(context.store).mode |> Bitwise.band(0o777) == 0o700
      File.rm_rf!(context.git.path)
      Agent.update(context.state, &%{&1 | available: false})
      assert {:ok, ^artifact} = retain(context)
      assert {:ok, ^artifact} = read(context)
      assert reads(context) == requests
      assert hd(artifact.files)["content"] == <<0, 255, 10>>
      assert Enum.filter(File.ls!(context.store), &String.ends_with?(&1, ".pending")) == []
    end
  end

  test "candidate, cross-repository dependency and manifest references preserve the same immutable artifact" do
    context = fixture()
    {:ok, original} = retain(context)
    consumer = %{context.work | "repository_id" => "11", "number" => 3}
    dependency = %{"kind" => "dependency", "work" => consumer, "revision" => TaskWorkflow.digest("pinned input")}
    manifest = %{"kind" => "manifest", "work" => %{context.work | "number" => 1}, "revision" => TaskWorkflow.digest("manifest")}
    assert {:ok, ^original} = retain(context, dependency)
    assert {:ok, ^original} = retain(context, manifest)
    assert {:ok, ^original} = retain(context, dependency)
    assert {:ok, refs} = references(context)
    assert MapSet.new(refs) == MapSet.new([context.owner, dependency, manifest])
    assert {:error, :invalid_artifact_reference} = retain(context, %{dependency | "kind" => "candidate"})
    assert {:error, :invalid_artifact_reference} = retain(context, %{})
  end

  test "concurrent writers publish one immutable file without replacing other references" do
    context = fixture()
    assert {:ok, original} = retain(context)
    File.rm!(snapshot_path(context))

    tasks =
      Enum.map(1..6, fn number ->
        owner = %{context.owner | "revision" => TaskWorkflow.digest(number)}
        Task.async(fn -> retain(context, owner) end)
      end)

    Enum.each(tasks, fn task -> assert {:ok, ^original} = Task.await(task) end)
    assert {:ok, refs} = references(context)
    assert length(refs) == 7
    assert Enum.count(File.ls!(context.store), &String.ends_with?(&1, ".json")) == 1
  end

  test "interrupted temporary files are neither exposed as artifacts nor overwritten on recovery" do
    context = fixture()
    {:ok, original} = retain(context)
    path = snapshot_path(context)
    File.rename!(path, path <> ".interrupted.pending")
    assert {:error, :invalid_artifact_file} = read(context)
    assert {:ok, ^original} = retain(context)
    assert File.exists?(path <> ".interrupted.pending")
    assert {:ok, [owner]} = references(context)
    assert owner == context.owner
  end

  test "corruption is reported without overwriting data or silently redownloading it" do
    context = fixture()
    {:ok, _} = retain(context)
    original = File.read!(snapshot_path(context))

    for damage <- [
          fn data -> put_in(data["files"], [nil]) end,
          fn data -> put_in(data["files"], [%{"content" => "not base64"}]) end,
          fn data -> update_in(data["files"], fn [file | rest] -> [Map.put(file, "content", Base.encode64("changed")) | rest] end) end,
          fn data -> put_in(data["receipt"]["version"], String.duplicate("0", 40)) end,
          fn _ -> %{"schema_version" => 99} end
        ] do
      File.write!(snapshot_path(context), original)
      mutate(context, damage)
      bytes = File.read!(snapshot_path(context))
      requests = reads(context)
      assert {:error, _} = retain(context)
      assert File.read!(snapshot_path(context)) == bytes
      assert reads(context) == requests
    end

    File.write!(snapshot_path(context), "interrupted")
    assert {:error, :invalid_artifact_file} = read(context)
  end

  test "store ownership, path redirects and unknown existing directories cannot be adopted" do
    context = fixture()
    File.mkdir_p!(context.store)
    File.write!(Path.join(context.store, "private"), "preserve")
    assert {:error, :unowned_artifact_store} = retain(context)
    assert File.read!(Path.join(context.store, "private")) == "preserve"
    other = Path.join(context.root, "other")
    File.ln_s!(context.store, other)
    assert {:error, :invalid_artifact_store_context} = retain(%{context | store: other})
    loop = Path.join(context.root, "loop")
    File.ln_s!(loop, loop)
    assert {:error, :invalid_artifact_store_context} = retain(%{context | store: loop})
    assert {:error, :invalid_artifact_store_context} = retain(%{context | store: "relative"})
    assert {:error, :invalid_artifact_store_context} = retain(%{context | store: nil})
  end

  test "symlinked stored snapshots and reference files cannot redirect reads or publication" do
    context = fixture()
    {:ok, _} = retain(context)
    path = snapshot_path(context)
    File.rename!(path, path <> ".saved")
    File.ln_s!(path <> ".saved", path)
    assert {:error, :invalid_artifact_file} = retain(context)
    File.rm!(path)
    File.rename!(path <> ".saved", path)
    [ref] = Path.wildcard(Path.join(context.store, "*.ref"))
    File.rename!(ref, ref <> ".saved")
    File.ln_s!(ref <> ".saved", ref)
    assert {:error, :artifact_publication_conflict} = retain(context)
    assert {:error, :unconfirmed_artifact_reference} = references(context)
  end

  test "registration and content limits still apply to an already retained artifact" do
    context = fixture()
    {:ok, artifact} = retain(context)
    assert {:error, :unregistered_plan_repository} = read(context, repositories: [])
    assert {:error, :invalid_stored_git_artifact} = read(context, artifact_max_bytes: 1)
    assert {:error, :invalid_artifact_store_context} = read(context, artifact_max_bytes: 0)
    assert {:error, :invalid_stored_git_artifact} = GitArtifact.validate(context.work, context.git.revision, nil, [])
    invalid = put_in(artifact.files, [%{"path" => "partial"}])
    assert {:error, :invalid_stored_git_artifact} = GitArtifact.validate(context.work, context.git.revision, invalid, [])
  end

  test "copying a stored snapshot under another repository identity never grants a matching artifact" do
    context = fixture()
    {:ok, _} = retain(context)
    other = %{context.work | "repository_id" => "11"}
    [repository] = context.opts[:repositories]
    opts = Keyword.put(context.opts, :repositories, [%{repository | "repository_id" => "11"}])
    path = Path.join(context.store, String.replace_prefix(GitArtifact.source_ref(other, context.git.revision), "git:", "") <> ".json")
    File.cp!(snapshot_path(context), path)
    assert {:error, :invalid_stored_git_artifact} = ArtifactStore.read(context.store, other, context.git.revision, opts)
  end

  test "changed reference contents cannot be mistaken for no remaining consumers or repaired by overwriting" do
    context = fixture()
    {:ok, _} = retain(context)
    [path] = Path.wildcard(Path.join(context.store, "*.ref"))
    data = Jason.decode!(File.read!(path)) |> put_in(["owner", "revision"], TaskWorkflow.digest("other manifest"))
    File.write!(path, Jason.encode!(data))
    assert {:error, :unconfirmed_artifact_reference} = references(context)
    assert {:error, :artifact_publication_conflict} = retain(context)
    assert Jason.decode!(File.read!(path)) == data
  end

  test "native failures never create a successful artifact or a retention reference" do
    context = fixture()
    Agent.update(context.state, &%{&1 | available: false})
    assert {:error, :native_read_failed} = retain(context)
    assert File.ls!(context.store) == [".owner"]
  end
end
