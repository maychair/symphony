defmodule SymphonyElixir.ReviewReaderTest do
  use ExUnit.Case, async: true

  setup do
    root = Path.join(System.tmp_dir!(), "review-reader-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    script = :symphony_elixir |> :code.priv_dir() |> List.to_string() |> Path.join("review_read.py")
    {:ok, root: root, script: script}
  end

  defp page(c, request) do
    {output, 0} = System.cmd("python3", [c.script, Jason.encode!(request)], cd: c.root)
    Jason.decode!(output)
  end

  defp all(c, args, offset \\ 0) do
    p = page(c, Map.put(args, "offset", offset))
    assert byte_size(p["content"]) <= 16_384
    assert String.valid?(p["content"])
    if p["next_offset"], do: p["content"] <> all(c, args, p["next_offset"]), else: p["content"]
  end

  test "large ordinary text stays exact across RPC-sized pages", c do
    body = String.duplicate("normal source 中\n", 270_000)
    assert byte_size(body) > 4_194_304
    File.write!(Path.join(c.root, "large.txt"), body)
    p = page(c, %{"kind" => "file", "path" => "large.txt"})
    assert p["raw_bytes"] == byte_size(body)
    assert p["raw_sha256"] == Base.encode16(:crypto.hash(:sha256, body), case: :lower)
    assert p["total_bytes"] == byte_size(body)
    # The tail remains reachable, beyond the former whole-file rejection.
    offset = byte_size(body) - byte_size("normal source 中\n")
    assert page(c, %{"kind" => "file", "path" => "large.txt", "offset" => offset})["content"] == "normal source 中\n"
  end

  test "multi-megabyte hex diff preserves surrounding code and exposes original bytes", c do
    git = fn args ->
      {output, 0} = System.cmd("git", args, cd: c.root)
      String.trim(output)
    end

    git.(["init", "-q"])
    git.(["-c", "user.name=Test", "-c", "user.email=test@example.test", "commit", "--allow-empty", "-qm", "base"])
    base = git.(["rev-parse", "HEAD"])
    data = :binary.copy(<<17, 254>>, 1_100_000)
    hex = Base.encode16(data)
    prefix = "before();\nweight = \"0x"
    suffix = "\"; changed_call();\nafter();\n"
    File.write!(Path.join(c.root, "weights.mlir"), prefix <> hex <> suffix)
    git.(["add", "."])
    git.(["-c", "user.name=Test", "-c", "user.email=test@example.test", "commit", "-qm", "weights"])
    head = git.(["rev-parse", "HEAD"])
    args = %{"kind" => "diff", "base" => base, "head" => head}
    p = page(c, args)
    assert p["raw_bytes"] > 4_194_304
    assert p["content"] =~ "+before();"
    assert p["content"] =~ "bytes=#{byte_size(data)} sha256=#{Base.encode16(:crypto.hash(:sha256, data), case: :lower)}"
    assert p["content"] =~ "\"; changed_call();\n+after();"
    assert p["next_offset"] == nil
    raw = page(c, %{"kind" => "file", "path" => "weights.mlir", "representation" => "raw", "offset" => byte_size(prefix) + byte_size(hex) - 8})
    assert raw["content"] == String.slice(hex, -8, 8) <> suffix
    assert raw["total_bytes"] > 4_194_304
  end

  test "short, escaped, malformed and non-hex strings remain exact", c do
    body =
      ("escaped: " <> Jason.encode!(~s(prefix "0x#{String.duplicate("ab", 3000)}")) <> "\n") <>
        ~s("0x1234"\n"0x#{String.duplicate("a", 4097)}"\n"0x#{String.duplicate("ab", 3000)}Z"\n)

    File.write!(Path.join(c.root, "strings.txt"), body)
    assert all(c, %{"kind" => "file", "path" => "strings.txt"}) == body
    File.write!(Path.join(c.root, "binary"), <<255>>)
    assert {_output, 1} = System.cmd("python3", [c.script, Jason.encode!(%{"kind" => "file", "path" => "binary"})], cd: c.root, stderr_to_stdout: true)
  end
end
