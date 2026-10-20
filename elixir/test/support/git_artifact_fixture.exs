defmodule SymphonyElixir.GitArtifactFixture do
  @moduledoc false

  def git(path, args) do
    {output, 0} = System.cmd("git", ["-C", path | args], stderr_to_stdout: true)
    output
  end

  def create(path, provider, files \\ %{"result" => "expected\n"}) do
    File.mkdir_p!(path)
    git(path, ["init", "-q"])

    Enum.each(files, fn {name, content} ->
      file = Path.join(path, name)
      File.mkdir_p!(Path.dirname(file))
      File.write!(file, content)
    end)

    git(path, ["add", "."])
    git(path, ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.test", "commit", "-qm", "Fixed artifact"])
    revision = git(path, ["rev-parse", "HEAD"]) |> String.trim()
    tree = git(path, ["rev-parse", "HEAD^{tree}"]) |> String.trim()
    entries = tree_entries(path, revision, ["-r", "-t"])
    objects = objects(path, provider, revision, tree, entries)
    %{revision: revision, tree: tree, entries: entries, objects: objects, path: path}
  end

  defp tree_entries(path, ref, args) do
    git(path, ["ls-tree", "-z" | args] ++ [ref])
    |> String.split("\0", trim: true)
    |> Enum.map(fn row ->
      [header, name] = String.split(row, "\t", parts: 2)
      [mode, type, oid] = String.split(header, " ")
      %{"path" => name, "sha" => oid, "mode" => mode, "type" => type}
    end)
  end

  defp objects(path, "github", revision, tree, entries) do
    trees = [tree | entries |> Enum.filter(&(&1["type"] == "tree")) |> Enum.map(& &1["sha"])]
    objects = Map.new(trees, &{"/git/trees/" <> &1, %{"sha" => &1, "truncated" => false, "tree" => tree_entries(path, &1, [])}})
    objects = Map.put(objects, "/git/commits/" <> revision, %{"sha" => revision, "tree" => %{"sha" => tree}})

    Enum.reduce(entries, objects, fn entry, current ->
      if entry["type"] == "blob" do
        content = git(path, ["cat-file", "blob", entry["sha"]])
        Map.put(current, "/git/blobs/" <> entry["sha"], %{"sha" => entry["sha"], "encoding" => "base64", "size" => byte_size(content), "content" => Base.encode64(content)})
      else
        current
      end
    end)
  end

  defp objects(path, "gitlab", revision, _tree, entries) do
    listing = Enum.map(entries, &(&1 |> Map.put("id", &1["sha"]) |> Map.delete("sha")))
    objects = %{("/repository/commits/" <> revision) => %{"id" => revision}, "/repository/tree" => listing}

    Enum.reduce(entries, objects, fn entry, current ->
      if entry["type"] == "blob",
        do: Map.put(current, "/repository/blobs/" <> entry["sha"] <> "/raw", git(path, ["cat-file", "blob", entry["sha"]])),
        else: current
    end)
  end
end
