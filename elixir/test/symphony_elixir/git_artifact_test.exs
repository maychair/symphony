defmodule SymphonyElixir.GitArtifactTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.{GitArtifact, GitArtifactFixture, NativeWork}

  defp fixture(provider, files \\ %{"result" => "expected\n", "dir/binary" => <<0, 255, 16>>, "dir/data.json" => "{\"value\":1}"}) do
    root = Path.join(System.tmp_dir!(), "git-artifact-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    git = GitArtifactFixture.create(root, provider, files)
    work = %{"provider" => provider, "host" => provider <> ".test", "repository_id" => "10", "kind" => "issue", "number" => 1}
    prefix = if provider == "github", do: "/repos/team/repo", else: "/projects/team%2Frepo"

    repository =
      Map.take(work, ~w(provider host repository_id))
      |> Map.merge(%{"path" => "team/repo", "api_url" => "https://" <> work["host"] <> if(provider == "github", do: "/api/v3", else: "/api/v4"), "credential" => "$UNUSED_GIT_ARTIFACT"})

    url = "https://" <> work["host"] <> "/team/repo"
    metadata = if provider == "github", do: %{"id" => 10, "full_name" => "team/repo", "html_url" => url}, else: %{"id" => 10, "path_with_namespace" => "team/repo", "web_url" => url}
    objects = Map.new(git.objects, fn {path, body} -> {prefix <> path, body} end) |> Map.put(prefix, metadata)
    state = start_supervised!({Agent, fn -> %{objects: objects, reads: []} end}, id: make_ref())

    request = fn ^provider, "GET", path, query, _ ->
      Agent.get_and_update(state, &native_response(&1, path, query))
    end

    %{git: git, work: work, prefix: prefix, state: state, opts: [repositories: [repository], request: request]}
  end

  defp native_response(current, path, query) do
    value = Map.get(current.objects, path, :missing)
    value = if is_function(value, 1), do: value.(query), else: value
    response = if value == :missing, do: %{status: 404, body: %{}}, else: %{status: 200, body: value}
    {{:ok, response}, %{current | reads: current.reads ++ [{path, query}]}}
  end

  defp update(context, path, function), do: Agent.update(context.state, &update_in(&1.objects[context.prefix <> path], function))
  defp read(context, opts \\ []), do: NativeWork.read_git(context.work, context.git.revision, Keyword.merge(context.opts, opts))

  test "both native providers retrieve exact binary files and directory contents from real Git objects" do
    for provider <- ["github", "gitlab"] do
      context = fixture(provider)
      assert {:ok, artifact} = read(context)
      assert artifact.receipt["source"] == GitArtifact.source_ref(context.work, context.git.revision)
      assert Enum.map(artifact.files, & &1["path"]) == ["dir/binary", "dir/data.json", "result"]
      assert hd(artifact.files)["content"] == <<0, 255, 16>>
      assert Enum.all?(artifact.receipt["files"], &(not Map.has_key?(&1, "content")))
      assert artifact.receipt["bytes"] == 23
    end
  end

  test "GitLab pagination is pinned to the commit and an incomplete later page cannot prove retrieval" do
    context = fixture("gitlab", Map.new(1..101, &{"file-#{&1}", "same"}))
    entries = context.git.objects["/repository/tree"]

    update(context, "/repository/tree", fn _ ->
      fn query ->
        assert query["ref"] == context.git.revision
        assert query["recursive"] == true
        Enum.slice(entries, (query["page"] - 1) * 100, 100)
      end
    end)

    assert {:ok, %{files: files}} = read(context)
    assert length(files) == 101
    update(context, "/repository/tree", fn _ -> fn query -> if query["page"] == 1, do: Enum.take(entries, 100), else: :missing end end)
    assert {:error, {:native_read_status, 404}} = read(context)
  end

  test "unregistered or mismatched repositories and floating commit references are rejected" do
    context = fixture("github")
    assert {:error, :unregistered_plan_repository} = read(context, repositories: [])
    assert {:error, :invalid_git_artifact} = NativeWork.read_git(context.work, "main", context.opts)
    update(context, "", &Map.put(&1, "id", 11))
    assert {:error, :native_repository_mismatch} = read(context)
  end

  test "missing commit identities, truncated trees and malformed entries do not create retrieval receipts" do
    context = fixture("github")

    for response <- [%{}, %{"sha" => context.git.revision, "tree" => %{"sha" => "wrong"}}] do
      update(context, "/git/commits/" <> context.git.revision, fn _ -> response end)
      assert {:error, :git_commit_mismatch} = read(context)
    end

    context = fixture("github")
    path = "/git/trees/" <> context.git.tree

    for tree <- [%{"sha" => context.git.tree, "truncated" => true, "tree" => []}, %{"sha" => context.git.tree, "truncated" => false, "tree" => [nil]}] do
      update(context, path, fn _ -> tree end)
      assert {:error, _} = read(context)
    end

    update(context, path, fn _ -> :missing end)
    assert {:error, {:native_read_status, 404}} = read(context)

    context = fixture("gitlab")
    update(context, "/repository/commits/" <> context.git.revision, fn _ -> %{"id" => "other"} end)
    assert {:error, :git_commit_mismatch} = read(context)
    update(context, "/repository/commits/" <> context.git.revision, fn _ -> :missing end)
    assert {:error, {:native_read_status, 404}} = read(context)
  end

  test "duplicate paths, traversal, gitlinks and unreadable blobs keep the artifact unresolved" do
    context = fixture("gitlab")
    entry = Enum.find(context.git.objects["/repository/tree"], &(&1["type"] == "blob"))

    for entries <- [[entry, entry], [%{entry | "path" => "../secret"}], [%{entry | "mode" => "160000", "type" => "commit"}], [nil], %{}] do
      update(context, "/repository/tree", fn _ -> entries end)
      assert {:error, _} = read(context)
    end

    context = fixture("github")
    entry = Enum.find(context.git.entries, &(&1["type"] == "blob"))
    update(context, "/git/blobs/" <> entry["sha"], fn _ -> :missing end)
    assert {:error, {:native_read_status, 404}} = read(context)
  end

  test "blob bytes, encodings and configured total size are verified, including Git LFS indirection" do
    context = fixture("github", %{"result" => "expected\n"})
    entry = hd(context.git.entries)
    path = "/git/blobs/" <> entry["sha"]

    for blob <- [nil, %{"encoding" => "base64", "sha" => entry["sha"], "size" => 9, "content" => Base.encode64("different")}] do
      update(context, path, fn _ -> blob end)
      assert {:error, :git_blob_unverified} = read(context)
    end

    context = fixture("gitlab")
    assert {:error, :git_blob_unverified} = read(context, artifact_max_bytes: 1)
    assert {:error, :invalid_git_artifact} = read(context, artifact_max_bytes: 0)
    context = fixture("gitlab", %{"large" => "version https://git-lfs.github.com/spec/v1\noid sha256:pending\nsize 999\n"})
    assert {:error, :git_blob_unverified} = read(context)
  end

  test "cyclic or excessive native trees stop at the bounded traversal rather than looping" do
    context = fixture("github")
    tree = %{"sha" => context.git.tree, "truncated" => false, "tree" => [%{"path" => "loop", "sha" => context.git.tree, "type" => "tree", "mode" => "040000"}]}
    update(context, "/git/trees/" <> context.git.tree, fn _ -> tree end)
    assert {:error, :git_tree_limit} = read(context)
    context = fixture("gitlab")
    entry = hd(context.git.objects["/repository/tree"])
    update(context, "/repository/tree", fn _ -> List.duplicate(entry, 100) end)
    assert {:error, :git_tree_limit} = read(context)
  end

  test "a spent retrieval deadline stops later native requests and never accepts an over-budget snapshot" do
    context = fixture("gitlab")

    update(context, "/repository/commits/" <> context.git.revision, fn commit ->
      fn _query ->
        Process.sleep(20)
        commit
      end
    end)

    assert {:error, :git_artifact_timeout} = read(context, artifact_timeout_ms: 10)
    reads = Agent.get(context.state, & &1.reads)
    refute Enum.any?(reads, fn {path, _} -> String.ends_with?(path, "/repository/tree") end)
  end
end
