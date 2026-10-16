defmodule SymphonyElixir.BuildInfoTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.BuildInfo

  test "embedded source identity matches the Workspace launcher's independent path-component ordering" do
    code = """
    import hashlib,sys
    from pathlib import Path
    checkout=Path(sys.argv[1]);h=hashlib.sha256()
    paths=[checkout/'elixir/mix.exs',checkout/'elixir/mix.lock']
    for name in ['lib','config']:paths.extend((checkout/'elixir'/name).rglob('*'))
    for path in sorted(p for p in paths if p.is_file()):
      h.update(str(path.relative_to(checkout)).encode()+b'\\0');h.update(path.read_bytes())
    print(h.hexdigest())
    """

    {digest, 0} = System.cmd("python3", ["-c", code, Path.expand("../../..", __DIR__)])
    identity = BuildInfo.identity()
    assert identity.source_sha256 == String.trim(digest)
    assert identity.pid == System.pid()
    assert identity == BuildInfo.identity()
    refute BuildInfo.__mix_recompile__?()
  end
end
