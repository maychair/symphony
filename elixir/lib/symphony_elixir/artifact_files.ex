defmodule SymphonyElixir.ArtifactFiles do
  @moduledoc "Materialize and recheck exact artifact bytes without following links outside their package."
  import Bitwise

  @spec materialize(Path.t(), [map()], keyword()) :: :ok | {:error, term()}
  def materialize(root, files, opts \\ []) do
    with true <- (safe_root?(root) and files?(root, files)) or {:error, :invalid_artifact_paths},
         :ok <- File.mkdir_p(root),
         :ok <- write_files(root, files, opts) do
      validate(root, files, opts)
    end
  end

  @spec validate(Path.t(), [map()], keyword()) :: :ok | {:error, term()}
  def validate(root, files, opts \\ []) do
    with true <- safe_root?(root) and files?(root, files),
         {:ok, actual} <- inventory(root, "", Keyword.get(opts, :ignore, [])),
         true <- Enum.sort(actual) == Enum.sort(Enum.map(files, & &1["path"])),
         true <- Enum.all?(files, &file_matches?(Path.join(root, &1["path"]), &1, opts[:writable] == true)) do
      :ok
    else
      _ -> {:error, :artifact_files_changed}
    end
  end

  @doc "Require an absolute normalized directory path whose existing ancestors are directories, never symlinks."
  @spec safe_root?(term()) :: boolean()
  def safe_root?(root) when is_binary(root) do
    Path.type(root) == :absolute and root == Path.expand(root) and root != "/" and
      Enum.reduce_while(Path.split(root), "/", fn segment, parent ->
        path = Path.join(parent, segment)

        case File.lstat(path) do
          {:ok, %{type: :directory}} -> {:cont, path}
          {:error, :enoent} -> {:cont, path}
          _ -> {:halt, false}
        end
      end) == root
  end

  def safe_root?(_), do: false

  defp files?(root, files) when is_list(files) do
    Enum.all?(files, &file?(root, &1)) and length(Enum.uniq_by(files, & &1["path"])) == length(files)
  end

  defp files?(_, _), do: false

  defp file?(root, %{"path" => path, "mode" => mode, "sha256" => sha, "size" => size} = file) do
    relative_path?(path) and
      mode in ~w(100644 100755 120000) and is_integer(size) and size >= 0 and
      is_binary(sha) and Regex.match?(~r/\A[0-9a-f]{64}\z/, sha) and link?(root, file)
  end

  defp file?(_, _), do: false

  defp relative_path?(path) when is_binary(path) do
    path != "" and Path.type(path) == :relative and Path.join(Path.split(path)) == path and
      not Enum.any?(Path.split(path), &(&1 in [".", "..", ".git"])) and not String.contains?(path, <<0>>)
  end

  defp relative_path?(_), do: false
  defp link?(_root, %{"mode" => mode}) when mode != "120000", do: true

  defp link?(root, %{"path" => path, "target" => target}) when is_binary(target) do
    target != "" and String.valid?(target) and not String.contains?(target, <<0>>) and Path.type(target) == :relative and
      String.starts_with?(Path.expand(target, Path.dirname(Path.join(root, path))), root <> "/")
  end

  defp link?(root, %{"content" => target} = file), do: link?(root, file |> Map.delete("content") |> Map.put("target", target))
  defp link?(_, _), do: false

  defp write_files(root, files, opts) do
    Enum.reduce_while(files, :ok, fn file, :ok ->
      path = Path.join(root, file["path"])

      result =
        with true <- safe_root?(Path.dirname(path)) or {:error, :invalid_artifact_paths},
             :ok <- File.mkdir_p(Path.dirname(path)) do
          write_file(path, file, opts[:writable] == true)
        end

      if result == :ok, do: {:cont, :ok}, else: {:halt, result}
    end)
  end

  defp write_file(path, %{"content" => content} = file, writable) when is_binary(content) do
    case File.lstat(path) do
      {:error, :enoent} -> create_file(path, file, writable)
      {:ok, _} -> if file_matches?(path, file, writable), do: :ok, else: {:error, :artifact_files_changed}
      error -> error
    end
  end

  defp write_file(_, _, _), do: {:error, :artifact_bytes_missing}
  defp create_file(path, %{"mode" => "120000", "content" => target}, _), do: File.ln_s(target, path)

  defp create_file(path, file, writable) do
    with :ok <- File.write(path, file["content"], [:exclusive]) do
      File.chmod(path, permissions(file, writable))
    end
  end

  defp permissions(file, writable) do
    base = if file["mode"] == "100755", do: 0o555, else: 0o444
    if writable, do: base ||| 0o200, else: base
  end

  defp file_matches?(path, %{"mode" => "120000"} = file, _) do
    with {:ok, %{type: :symlink}} <- File.lstat(path),
         {:ok, target} <- File.read_link(path) do
      bytes?(target, file) and target == (file["target"] || file["content"])
    else
      _ -> false
    end
  end

  defp file_matches?(path, file, writable) do
    with {:ok, %{type: :regular, links: 1, mode: mode, size: size}} <- File.lstat(path),
         true <- size == file["size"] and (writable or (mode &&& 0o222) == 0),
         true <- (mode &&& 0o111) != 0 == (file["mode"] == "100755"),
         {:ok, bytes} <- File.read(path) do
      bytes?(bytes, file)
    else
      _ -> false
    end
  end

  defp bytes?(bytes, file), do: byte_size(bytes) == file["size"] and Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == file["sha256"]

  defp inventory(root, prefix, ignored) do
    with {:ok, names} <- File.ls(Path.join(root, prefix)) do
      names
      |> Enum.reject(&(prefix == "" and &1 in ignored))
      |> Enum.reduce_while({:ok, []}, fn name, {:ok, found} ->
        relative = Path.join(prefix, name)

        inventory_entry(root, relative, ignored, found)
      end)
    end
  end

  defp inventory_entry(root, relative, ignored, found) do
    case File.lstat(Path.join(root, relative)) do
      {:ok, %{type: :directory}} -> collect_inventory(root, relative, ignored, found)
      {:ok, _} -> {:cont, {:ok, [relative | found]}}
      error -> {:halt, error}
    end
  end

  defp collect_inventory(root, relative, ignored, found) do
    case inventory(root, relative, ignored) do
      {:ok, entries} -> {:cont, {:ok, entries ++ found}}
      error -> {:halt, error}
    end
  end
end
