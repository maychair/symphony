defmodule SymphonyElixir.ReviewLaneGitLabTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.ReviewLane.GitLab

  test "the review adapter cannot invoke native actions, foreign writes or quick actions inside comments" do
    config = %{"host" => "review.invalid", "projects" => %{"team/repo" => %{"id" => 10}}, "glab_bin" => "must-not-be-called"}
    path = GitLab.mr_path("team/repo", 1) <> "/discussions"
    assert GitLab.comment_body?("请核对 `/approve` 的字面含义，以及 `source.cpp:10`。")
    refute GitLab.comment_body?(nil)

    for body <- ["/approve\n审查通过", "说明\n /merge", "说明\r\n\t/close", "示例\n```\n/rebase\n```", "说明\r/approve"] do
      refute GitLab.comment_body?(body)
      assert {:error, :review_write_not_permitted} = GitLab.request(config, "POST", path, %{"body" => body})
    end

    for {method, target, fields} <- [
          {"POST", GitLab.mr_path("team/repo", 1) <> "/approve", %{}},
          {"PUT", GitLab.mr_path("team/repo", 1) <> "/merge", %{}},
          {"DELETE", path <> "/existing", %{}},
          {"POST", GitLab.mr_path("other/repo", 1) <> "/discussions", %{"body" => "foreign"}},
          {"POST", path <> "?redirect=other", %{"body" => "changed endpoint"}},
          {"POST", path, %{"body" => "text", "resolved" => "true"}}
        ] do
      assert {:error, :review_write_not_permitted} = GitLab.request(config, method, target, fields)
    end
  end

  test "native review commands inherit only their concurrent repository environment" do
    root = Path.dirname(Workflow.workflow_file_path())
    cli = Path.join(root, "identity-cli")

    File.write!(cli, """
    #!/usr/bin/env python3
    import json,os
    key='GH_CONFIG_DIR' if os.environ.get('REVIEW_PROVIDER')=='github' else 'GLAB_CONFIG_DIR'
    print(json.dumps({'id':{'bot-a':21,'bot-b':22}.get(os.environ.get(key),999),'name':'meichao-agent','bot':True}))
    """)

    File.chmod!(cli, 0o755)
    previous = System.get_env("GLAB_CONFIG_DIR")
    System.put_env("GLAB_CONFIG_DIR", "personal-host")
    on_exit(fn -> restore_env("GLAB_CONFIG_DIR", previous) end)

    tasks =
      for {directory, id} <- [{"bot-a", 21}, {"bot-b", 22}] do
        Task.async(fn ->
          context = %{id: directory, environment: %{"GLAB_CONFIG_DIR" => directory, "GH_CONFIG_DIR" => directory, "GIT_CONFIG_PARAMETERS" => "'user.name=#{directory}'"}}

          SymphonyElixir.RuntimeContext.with_context(context, fn ->
            config = %{"host" => "review.invalid", "glab_bin" => cli, "gh_bin" => cli}
            assert {:ok, %{"id" => ^id}} = GitLab.request(config, "GET", "user")
            github = put_in(context, [:environment, "REVIEW_PROVIDER"], "github")

            SymphonyElixir.RuntimeContext.with_context(github, fn ->
              assert {:ok, %{"id" => ^id}} = SymphonyElixir.ReviewLane.GitHub.request(config, "GET", "user")
            end)

            assert {:ok, name} = GitLab.command("git", ["config", "--get", "user.name"])
            assert String.trim(name) == directory
          end)
        end)
      end

    Enum.each(tasks, &Task.await(&1, 5_000))
    assert System.get_env("GLAB_CONFIG_DIR") == "personal-host"
  end

  test "private HTTP scope is explicit and cannot redirect metadata to another native path" do
    config = %{"host" => "review.invalid", "projects" => %{"team/repo" => %{"id" => 10}}}
    repository = %{"id" => 10, "path_with_namespace" => "team/repo", "web_url" => "http://review.invalid/team/repo"}
    refute GitLab.repository?(repository, config, "team/repo")
    permitted = Map.put(config, "allow_insecure_http", true)
    assert GitLab.repository?(repository, permitted, "team/repo")
    refute GitLab.repository?(Map.put(repository, "id", 11), permitted, "team/repo")
    refute GitLab.web_url?("http://review.invalid/team/repo?redirect=other", permitted, "/team/repo")
    refute GitLab.web_url?("https://foreign.invalid/team/repo", permitted, "/team/repo")
  end

  test "command failures and malformed or excessive discussion pages are rejected" do
    root = Path.dirname(Workflow.workflow_file_path())
    cli = Path.join(root, "glab")

    File.write!(cli, """
    #!/usr/bin/env python3
    import sys,json,pathlib
    mode=(pathlib.Path(__file__).parent/'mode').read_text()
    if mode=='error':sys.exit(3)
    if mode=='invalid':print('{}')
    elif mode=='limit':
      page=int(sys.argv[-1].split('page=')[-1]);print(json.dumps([{'id':str(page*100+i)} for i in range(100)]))
    elif mode=='pages':print(json.dumps([{'id':str(i)} for i in range(100)] if sys.argv[-1].endswith('&page=1') else []))
    """)

    File.chmod!(cli, 0o755)
    config = %{"host" => "review.invalid", "glab_bin" => cli}
    File.write!(Path.join(root, "mode"), "error")
    assert {:error, {:command_failed, ^cli, 3}} = GitLab.request(config, "GET", "user")
    assert {:error, _} = GitLab.discussions(config, "mr")
    File.write!(Path.join(root, "mode"), "invalid")
    assert {:error, :invalid_discussions_response} = GitLab.discussions(config, "mr")
    File.write!(Path.join(root, "mode"), "limit")
    assert {:error, :discussion_page_limit} = GitLab.discussions(config, "mr")
    File.write!(Path.join(root, "mode"), "pages")
    assert {:ok, entries} = GitLab.discussions(config, "mr")
    assert length(entries) == 100
    previous = System.get_env("PATH")
    System.put_env("PATH", root)

    try do
      assert {:error, {:command_unavailable, _}} = GitLab.command("missing", [])
    after
      restore_env("PATH", previous)
    end
  end
end
