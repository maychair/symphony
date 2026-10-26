defmodule SymphonyElixir.GitLabNativeClientTest do
  use ExUnit.Case, async: false
  alias SymphonyElixir.GitLab.Client
  alias SymphonyElixir.RuntimeContext

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-glab-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    cli = Path.join(root, "glab")

    File.write!(cli, """
    #!/usr/bin/env python3
    import json,os,pathlib,sys
    root=pathlib.Path(__file__).parent
    args=sys.argv[1:]
    body=pathlib.Path(args[args.index('--input')+1]) if '--input' in args else None
    (root/'request.json').write_text(json.dumps(dict(args=args,body=json.loads(body.read_text()) if body else None,store=os.environ.get('GLAB_CONFIG_DIR'))))
    mode=(root/'mode').read_text() if (root/'mode').exists() else 'ok'
    if mode=='exit': sys.exit(9)
    status={'missing':404,'denied':403,'empty':204}.get(mode,200)
    print('HTTP/2 '+str(status)+' status\\r\\nContent-Type: application/json\\r\\n\\r\\n',end='')
    if mode=='raw': print('{"value": 1}\\n',end='')
    elif mode=='large': print('x'*(9*1024*1024),end='')
    elif mode!='empty': print(json.dumps({'message':mode}))
    sys.exit(1 if status>=400 else 0)
    """)

    File.chmod!(cli, 0o755)
    settings = %{provider: %{"project_path" => "team/repo", "api_url" => "https://gitlab.test/api/v4", "glab_bin" => cli}}
    {:ok, root: root, settings: settings, cli: cli}
  end

  test "native credentials, query values and structured bodies reach the configured CLI", c do
    body = %{"labels" => ["review", "ready"], "state_event" => "close", "description" => "line one\nline two"}

    RuntimeContext.with_context(%{environment: %{"GLAB_CONFIG_DIR" => "selected-bot"}}, fn ->
      assert {:ok, %{status: 200, body: %{"message" => "ok"}}} =
               Client.request("PUT", "/projects/team%2Frepo/issues/1", %{"search" => "a & b"}, body, tracker_settings: c.settings)
    end)

    request = Jason.decode!(File.read!(Path.join(c.root, "request.json")))
    assert request["store"] == "selected-bot"
    assert request["body"] == body
    assert "https://gitlab.test/api/v4/projects/team%2Frepo/issues/1?search=a+%26+b" in request["args"]
    assert "Content-Type: application/json" in request["args"]
    input = request["args"] |> Enum.drop_while(&(&1 != "--input")) |> Enum.at(1)
    refute File.exists?(input)
  end

  test "HTTP failures remain HTTP responses and missing Issues remain absent", c do
    File.write!(Path.join(c.root, "mode"), "missing")
    assert {:ok, %{status: 404, body: %{"message" => "missing"}}} = Client.request("GET", "/missing", %{}, nil, tracker_settings: c.settings)
    assert {:ok, []} = Client.fetch_issues_by_ids(["1"], c.settings)
    File.write!(Path.join(c.root, "mode"), "denied")
    assert {:error, {:gitlab_api_status, 403}} = Client.fetch_issues_by_states(["opened"], c.settings)
    File.write!(Path.join(c.root, "mode"), "exit")
    assert {:error, {:command_failed, _, 9}} = Client.request("GET", "/user", %{}, nil, tracker_settings: c.settings)
  end

  test "GitLab responses and command output preserve content larger than 8 MiB", c do
    File.write!(Path.join(c.root, "mode"), "large")
    expected = String.duplicate("x", 9 * 1024 * 1024)

    assert {:ok, %{status: 200, body: ^expected}} =
             Client.request("GET", "/repository/files/file/raw", %{}, nil, tracker_settings: c.settings)

    assert {:ok, output} = SymphonyElixir.Command.run(c.cli, [])
    assert [_, ^expected] = String.split(output, "\r\n\r\n", parts: 2)
  end

  test "raw files and empty responses preserve their body semantics", c do
    File.write!(Path.join(c.root, "mode"), "raw")
    assert {:ok, %{status: 200, body: "{\"value\": 1}\n"}} = Client.request("GET", "/repository/files/file/raw", %{}, nil, tracker_settings: c.settings)
    File.write!(Path.join(c.root, "mode"), "empty")
    assert {:ok, %{status: 204, body: nil}} = Client.request("DELETE", "/resource", %{}, nil, tracker_settings: c.settings)
    assert {:error, :invalid_gitlab_method} = Client.request("INVALID", "/resource", %{}, nil, tracker_settings: c.settings)
  end
end
