defmodule SymphonyElixir.GitArtifact do
  @moduledoc "Retrieve the complete fixed Git snapshot through an identity-checked native repository."
  alias SymphonyElixir.{TaskWorkflow, WorkRef}

  @doc "Stable retrieval identity; constructing it alone does not prove the artifact is available."
  @spec source_ref(map(), String.t()) :: String.t()
  def source_ref(work, revision) do
    "git:" <> TaskWorkflow.digest(%{"repository" => Map.take(work, ~w(provider host repository_id)), "revision" => revision})
  end

  @doc "Read all trees and blobs at an exact commit; the reader is scoped by NativeWork to a verified repository."
  @spec read(map(), String.t(), function(), keyword()) :: {:ok, map()} | {:error, term()}
  def read(work, revision, get, opts) do
    limit = Keyword.get(opts, :artifact_max_bytes, 104_857_600)
    timeout = Keyword.get(opts, :artifact_timeout_ms, 30_000)

    with :ok <- WorkRef.validate(work),
         true <- oid?(revision) and is_integer(limit) and limit > 0 and is_integer(timeout) and timeout > 0,
         deadline = System.monotonic_time(:millisecond) + timeout,
         get = bounded_reader(get, deadline),
         {:ok, entries} <- entries(work["provider"], revision, get),
         true <- valid_entries?(entries),
         {:ok, files} <- blobs(entries, work["provider"], get, limit),
         :ok <- before_deadline(deadline) do
      receipt = %{
        "source" => source_ref(work, revision),
        "version" => revision,
        "repository" => Map.take(work, ~w(provider host repository_id)),
        "files" => Enum.map(files, &Map.drop(&1, ["content"])),
        "bytes" => Enum.sum(Enum.map(files, & &1["size"]))
      }

      {:ok, %{receipt: Map.put(receipt, "digest", TaskWorkflow.digest(receipt)), files: files}}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_git_artifact}
    end
  end

  defp bounded_reader(get, deadline) do
    fn path, query ->
      with :ok <- before_deadline(deadline), do: get.(path, query)
    end
  end

  defp before_deadline(deadline),
    do: if(System.monotonic_time(:millisecond) < deadline, do: :ok, else: {:error, :git_artifact_timeout})

  defp entries("github", revision, get) do
    with {:ok, %{"sha" => ^revision, "tree" => %{"sha" => tree}}} <- get.("/git/commits/" <> revision, %{}),
         true <- oid?(tree),
         {:ok, entries} <- github_tree(tree, "", get, [], 0) do
      {:ok, entries}
    else
      {:error, _} = error -> error
      _ -> {:error, :git_commit_mismatch}
    end
  end

  defp entries("gitlab", revision, get) do
    case get.("/repository/commits/" <> revision, %{}) do
      {:ok, %{"id" => ^revision}} -> gitlab_tree(revision, get, 1, [])
      {:error, _} = error -> error
      _ -> {:error, :git_commit_mismatch}
    end
  end

  defp github_tree(_tree, _prefix, _get, _acc, depth) when depth > 100, do: {:error, :git_tree_limit}

  defp github_tree(tree, prefix, get, acc, depth) do
    with {:ok, %{"sha" => ^tree, "truncated" => false, "tree" => entries}} <- get.("/git/trees/" <> tree, %{}),
         true <- is_list(entries) and length(entries) + length(acc) <= 10_000 do
      github_children(entries, prefix, get, acc, depth)
    else
      {:error, _} = error -> error
      _ -> {:error, :incomplete_git_tree}
    end
  end

  defp github_children(entries, prefix, get, acc, depth) do
    Enum.reduce_while(entries, {:ok, acc}, fn entry, {:ok, current} ->
      case github_entry(entry, prefix, get, current, depth) do
        {:ok, updated} -> {:cont, {:ok, updated}}
        error -> {:halt, error}
      end
    end)
  end

  defp github_entry(%{"path" => path, "sha" => oid, "mode" => mode, "type" => type}, prefix, get, acc, depth) do
    if path?(path) and not String.contains?(path, "/") and oid?(oid) do
      full = prefix <> path
      entry = %{"path" => full, "oid" => oid, "mode" => mode, "type" => type}

      if type == "tree" and mode == "040000",
        do: github_tree(oid, full <> "/", get, [entry | acc], depth + 1),
        else: {:ok, [entry | acc]}
    else
      {:error, :invalid_git_tree_entry}
    end
  end

  defp github_entry(_, _, _, _, _), do: {:error, :invalid_git_tree_entry}

  defp gitlab_tree(_revision, _get, 101, _acc), do: {:error, :git_tree_limit}

  defp gitlab_tree(revision, get, page, acc) do
    query = %{"ref" => revision, "recursive" => true, "per_page" => 100, "page" => page}

    with {:ok, entries} when is_list(entries) <- get.("/repository/tree", query),
         true <- Enum.all?(entries, &is_map/1) and length(entries) <= 100 do
      current = Enum.map(entries, &%{"path" => &1["path"], "oid" => &1["id"], "mode" => &1["mode"], "type" => &1["type"]}) ++ acc
      if length(entries) < 100, do: {:ok, current}, else: gitlab_tree(revision, get, page + 1, current)
    else
      {:error, _} = error -> error
      _ -> {:error, :incomplete_git_tree}
    end
  end

  defp valid_entries?(entries) do
    length(entries) <= 10_000 and length(Enum.uniq_by(entries, & &1["path"])) == length(entries) and
      Enum.all?(entries, fn entry ->
        path?(entry["path"]) and oid?(entry["oid"]) and
          ((entry["type"] == "blob" and entry["mode"] in ~w(100644 100755 120000)) or
             (entry["type"] == "tree" and entry["mode"] == "040000"))
      end)
  end

  defp blobs(entries, provider, get, limit) do
    entries
    |> Enum.filter(&(&1["type"] == "blob"))
    |> Enum.sort_by(& &1["path"])
    |> Enum.reduce_while({:ok, [], 0}, fn entry, {:ok, files, size} ->
      with {:ok, blob} <- get.(blob_path(provider, entry["oid"]), %{}),
           {:ok, content} <- decode_blob(blob, entry["oid"], limit - size) do
        file = Map.merge(Map.drop(entry, ["type"]), %{"content" => content, "size" => byte_size(content), "sha256" => hash(:sha256, content)})
        {:cont, {:ok, [file | files], size + byte_size(content)}}
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, files, _} -> {:ok, Enum.reverse(files)}
      error -> error
    end
  end

  defp decode_blob(%{"encoding" => "base64", "content" => encoded, "size" => size} = blob, oid, remaining) do
    with true <- blob["sha"] == oid and is_integer(size) and size >= 0 and size <= remaining and is_binary(encoded),
         true <- byte_size(encoded) <= div(size + 2, 3) * 4 + div(size, 40) + 8,
         {:ok, content} <- Base.decode64(encoded, ignore: :whitespace),
         true <- byte_size(content) == size do
      decode_blob(content, oid, remaining)
    else
      _ -> {:error, :git_blob_unverified}
    end
  end

  defp decode_blob(content, oid, remaining) when is_binary(content) do
    algorithm = if byte_size(oid) == 40, do: :sha, else: :sha256
    size = byte_size(content)

    if size <= remaining and hash(algorithm, "blob #{size}\0" <> content) == oid and
         not String.starts_with?(content, "version https://git-lfs.github.com/spec/v1\n"),
       do: {:ok, content},
       else: {:error, :git_blob_unverified}
  end

  defp decode_blob(_, _, _), do: {:error, :git_blob_unverified}
  defp blob_path("github", oid), do: "/git/blobs/" <> oid
  defp blob_path("gitlab", oid), do: "/repository/blobs/" <> oid <> "/raw"
  defp hash(algorithm, content), do: Base.encode16(:crypto.hash(algorithm, content), case: :lower)
  defp oid?(value), do: is_binary(value) and Regex.match?(~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/, value)

  defp path?(value) do
    is_binary(value) and value != "" and not String.contains?(value, ["\0", "\\"]) and
      Enum.all?(String.split(value, "/"), &(&1 not in ["", ".", "..", ".git"]))
  end
end
