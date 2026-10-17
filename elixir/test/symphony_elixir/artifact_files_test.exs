defmodule SymphonyElixir.ArtifactFilesTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.ArtifactFiles

  defp file(path, mode, bytes),
    do: %{"path" => path, "mode" => mode, "size" => byte_size(bytes), "sha256" => Base.encode16(:crypto.hash(:sha256, bytes), case: :lower), "content" => bytes}

  setup do
    root = Path.join(System.tmp_dir!(), "artifact-files-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  test "materialized bytes, executable modes and internal links are checked without following external paths", %{root: root} do
    path = Path.join(root, "package")
    files = [file("bin/tool", "100755", "#!/bin/sh\nexit 0\n"), file("data", "100644", <<0, 255, 10>>), file("link", "120000", "data")]
    assert :ok = ArtifactFiles.materialize(path, files)
    assert :ok = ArtifactFiles.materialize(path, files)
    assert File.read!(Path.join(path, "link")) == <<0, 255, 10>>
    assert :ok = ArtifactFiles.validate(path, files)
    File.write!(Path.join(path, "extra"), "unexpected")
    assert {:error, :artifact_files_changed} = ArtifactFiles.validate(path, files)
    File.rm!(Path.join(path, "extra"))
    File.chmod!(Path.join(path, "data"), 0o644)
    assert {:error, :artifact_files_changed} = ArtifactFiles.validate(path, files)
    assert :ok = ArtifactFiles.validate(path, files, writable: true)
    File.write!(Path.join(path, "data"), "changed")
    assert {:error, :artifact_files_changed} = ArtifactFiles.materialize(path, files)
    File.write!(Path.join(path, "data"), <<0, 255, 10>>)
    File.chmod!(Path.join(path, "data"), 0o444)
    File.rm!(Path.join(path, "link"))
    File.ln_s!("/etc/passwd", Path.join(path, "link"))
    assert {:error, :artifact_files_changed} = ArtifactFiles.validate(path, files)
    File.rm!(Path.join(path, "link"))
    File.write!(Path.join(path, "link"), "data")
    assert {:error, :artifact_files_changed} = ArtifactFiles.validate(path, files)
  end

  test "untrusted paths, missing bytes and hardlinks cannot become materialized inputs", %{root: root} do
    for input <- [file("../outside", "100644", "x"), file(".git/config", "100644", "x"), file("link", "120000", "../outside"), file("link", "120000", "/etc/passwd")] do
      assert {:error, :invalid_artifact_paths} = ArtifactFiles.materialize(Path.join(root, "invalid"), [input])
    end

    assert {:error, :invalid_artifact_paths} = ArtifactFiles.materialize(root, [%{}])
    assert {:error, :invalid_artifact_paths} = ArtifactFiles.materialize(root, nil)
    assert {:error, :invalid_artifact_paths} = ArtifactFiles.materialize(root, [file(nil, "100644", "x")])
    assert {:error, :invalid_artifact_paths} = ArtifactFiles.materialize(root, [Map.delete(file("link", "120000", "x"), "content")])
    assert {:error, :invalid_artifact_paths} = ArtifactFiles.materialize(nil, [])
    assert {:error, :artifact_bytes_missing} = ArtifactFiles.materialize(root, [Map.delete(file("missing", "100644", "x"), "content")])
    path = Path.join(root, "package")
    files = [file("data", "100644", "x")]
    assert :ok = ArtifactFiles.materialize(path, files)
    File.ln!(Path.join(path, "data"), Path.join(root, "external"))
    assert {:error, :artifact_files_changed} = ArtifactFiles.validate(path, files)
    File.ln_s!(path, Path.join(root, "alias"))
    assert {:error, :invalid_artifact_paths} = ArtifactFiles.materialize(Path.join(root, "alias"), files)
    assert {:error, :artifact_files_changed} = ArtifactFiles.validate(Path.join(root, "missing"), [])
    assert {:error, :invalid_artifact_paths} = ArtifactFiles.materialize(Path.join(root, "overlap"), [file("file", "100644", "x"), file("file/child", "100644", "y")])
  end

  test "unreadable input directories fail validation and cannot be populated", %{root: root} do
    path = Path.join(root, "package")
    files = [file("nested/data", "100644", "x")]
    assert :ok = ArtifactFiles.materialize(path, files)
    nested = Path.join(path, "nested")
    File.chmod!(nested, 0)

    try do
      assert {:error, :artifact_files_changed} = ArtifactFiles.validate(path, files)
      assert {:error, :eacces} = ArtifactFiles.materialize(nested, [file("other", "100644", "x")])
    after
      File.chmod!(nested, 0o755)
    end

    File.chmod!(path, 0o444)

    try do
      assert {:error, :artifact_files_changed} = ArtifactFiles.validate(path, files)
    after
      File.chmod!(path, 0o755)
    end
  end
end
