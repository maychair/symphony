defmodule SymphonyElixir.ReviewLaneGitHubTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.ReviewLane
  alias SymphonyElixir.ReviewLane.GitHub

  test "the review adapter cannot invoke native actions or foreign writes" do
    config = %{"host" => "github.invalid", "projects" => %{"team/repo" => %{"id" => 10}}, "gh_bin" => "must-not-be-called"}
    path = GitHub.mr_path("team/repo", 1) <> "/reviews"
    assert GitHub.comment_body?("请核对边界条件，以及 `source.cpp:10`。")
    refute GitHub.comment_body?(nil)

    for {method, target, fields} <- [
          {"POST", "repos/team/repo/pulls/1/merge", %{}},
          {"DELETE", path <> "/123", %{}},
          {"POST", "repos/other/repo/pulls/1/reviews", %{"body" => "foreign", "event" => "COMMENT", "commit_id" => String.duplicate("a", 40)}},
          {"POST", path <> "?redirect=other", %{"body" => "changed endpoint", "event" => "COMMENT", "commit_id" => String.duplicate("a", 40)}},
          {"POST", path, %{"body" => "text", "event" => "APPROVE", "commit_id" => String.duplicate("a", 40)}},
          {"POST", path, %{"body" => "text", "event" => "REQUEST_CHANGES", "commit_id" => String.duplicate("a", 40)}}
        ] do
      assert {:error, :review_write_not_permitted} = GitHub.request(config, method, target, fields)
    end
  end

  test "private HTTP scope is explicit and cannot redirect metadata to another native path" do
    config = %{"host" => "github.invalid", "projects" => %{"team/repo" => %{"id" => 10}}}
    repository = %{"id" => 10, "full_name" => "team/repo", "html_url" => "http://github.invalid/team/repo"}
    refute GitHub.repository?(repository, config, "team/repo")
    permitted = Map.put(config, "allow_insecure_http", true)
    assert GitHub.repository?(repository, permitted, "team/repo")
    refute GitHub.repository?(Map.put(repository, "id", 11), permitted, "team/repo")
    refute GitHub.web_url?("http://github.invalid/team/repo?redirect=other", permitted, "/team/repo")
    refute GitHub.web_url?("https://foreign.invalid/team/repo", permitted, "/team/repo")
  end

  test "command failures and malformed or excessive discussion pages are rejected" do
    root = Path.dirname(Workflow.workflow_file_path())
    cli = Path.join(root, "gh")

    File.write!(cli, """
    #!/usr/bin/env python3
    import sys,json,pathlib
    mode=(pathlib.Path(__file__).parent/'mode').read_text()
    if mode=='error':sys.exit(3)
    if mode=='invalid':print('{}')
    elif mode=='limit':
      page=int(sys.argv[-1].split('page=')[-1]);print(json.dumps([{'id':page*100+i} for i in range(100)]))
    elif mode=='pages':print(json.dumps([{'id':i} for i in range(100)] if sys.argv[-1].endswith('&page=1') else []))
    """)

    File.chmod!(cli, 0o755)
    config = %{"host" => "github.invalid", "gh_bin" => cli, "projects" => %{"team/repo" => %{"id" => 10}}}
    File.write!(Path.join(root, "mode"), "error")
    assert {:error, {:command_failed, ^cli, 3}} = GitHub.request(config, "GET", "user")
    assert {:error, :review_write_not_permitted} = GitHub.request(config, "GET", "invalid/path")
    assert {:error, :review_write_not_permitted} = GitHub.request(Map.delete(config, "projects"), "GET", "repos/team/repo")
    assert {:error, _} = GitHub.discussions(config, "repos/team/repo/pulls/1")
    File.write!(Path.join(root, "mode"), "invalid")
    assert {:error, :invalid_discussions_response} = GitHub.discussions(config, "repos/team/repo/pulls/1")
    File.write!(Path.join(root, "mode"), "limit")
    assert {:error, :discussion_page_limit} = GitHub.discussions(config, "repos/team/repo/pulls/1")
    File.write!(Path.join(root, "mode"), "pages")
    assert {:ok, entries} = GitHub.discussions(config, "repos/team/repo/pulls/1")
    assert length(entries) == 300
  end

  test "ReviewLane.validate_config accepts github provider" do
    root = Path.dirname(Workflow.workflow_file_path())
    instructions = Path.join(root, "instructions")
    File.write!(instructions, "## Common\nRead evidence.\n## Standards\nRead standards.\n## Spec\nVerify scope.\n")

    config = %{
      "enabled" => true,
      "host" => "github.com",
      "provider" => "github",
      "reviewer_id" => 20,
      "publisher_id" => 20,
      "projects" => %{"team/repo" => %{"id" => 10, "checkout" => root}},
      "state_dir" => root,
      "instruction_files" => [instructions],
      "result_command" => SymphonyElixir.TestSupport.workflow_result_command()
    }

    assert :ok = ReviewLane.validate_config(%{provider: %{"review_lane" => config}})
    assert "GITLAB_PAT" in ReviewLane.secret_environment_names(%{})
    assert "GITLAB_ACCESS_TOKEN" in ReviewLane.secret_environment_names(%{})
    assert "GITHUB_TOKEN" in ReviewLane.secret_environment_names(%{"provider" => "github"})
    assert "GH_TOKEN" in ReviewLane.secret_environment_names(%{"provider" => "github"})
    assert "GH_ENTERPRISE_TOKEN" in ReviewLane.secret_environment_names(%{})
    assert "GITHUB_ENTERPRISE_TOKEN" in ReviewLane.secret_environment_names(%{})
  end

  test "permitted? and helper paths for reviews and issue comments" do
    config = %{"host" => "github.invalid", "gh_bin" => "nonexistent_bin_12345", "projects" => %{"team/repo" => %{"id" => 10}}}
    assert GitHub.mr_path("team/repo", 2) == "repos/team/repo/pulls/2"
    assert GitHub.issues_path("team/repo", 2) == "repos/team/repo/issues/2"

    # valid review POST with command_unavailable
    valid_review_path = "repos/team/repo/pulls/1/reviews"
    sha = String.duplicate("a", 40)

    assert {:error, {:command_failed, "nonexistent_bin_12345", 127}} =
             GitHub.request(config, "POST", valid_review_path, %{"body" => "请核对", "event" => "COMMENT", "commit_id" => sha})

    # valid issue comment POST
    valid_comment_path = "repos/team/repo/issues/1/comments"

    assert {:error, {:command_failed, "nonexistent_bin_12345", 127}} =
             GitHub.request(config, "POST", valid_comment_path, %{"body" => "请核对"})

    # invalid issue comment path project
    assert {:error, :review_write_not_permitted} =
             GitHub.request(config, "POST", "repos/other/repo/issues/1/comments", %{"body" => "请核对"})

    assert {:error, :review_write_not_permitted} =
             GitHub.request(config, "POST", "repos/team/repo/issues/0/comments", %{"body" => "请核对"})

    assert {:error, :review_write_not_permitted} =
             GitHub.request(config, "POST", "repos/team/repo/pulls/0/reviews", %{"body" => "请核对", "event" => "COMMENT", "commit_id" => sha})

    # invalid discussions path
    assert {:error, :invalid_github_path} = GitHub.discussions(config, "invalid/path")
    assert {:error, {:command_unavailable, _}} = SymphonyElixir.Command.run(nil, [])
    refute GitHub.repository?(nil, config, "team/repo")
  end

  test "assigned/2 discovers and filters pull requests by reviewer_id" do
    root = Path.dirname(Workflow.workflow_file_path())
    cli = Path.join(root, "gh-assigned")

    File.write!(cli, """
    #!/usr/bin/env python3
    import sys, json
    path = sys.argv[-1]
    if 'repos/team/repo/pulls' in path:
        print(json.dumps([
            {'id': 101, 'number': 1, 'requested_reviewers': [{'id': 20}]},
            {'id': 102, 'number': 2, 'requested_reviewers': [{'id': 99}]},
            {'id': 103, 'number': 3, 'requested_reviewers': []}
        ]))
    elif path == 'repos/team/repo':
        print(json.dumps({'id': 10, 'full_name': 'team/repo', 'html_url': 'https://github.invalid/team/repo'}))
    else:
        print('{}')
    """)

    File.chmod!(cli, 0o755)

    config = %{
      "host" => "github.invalid",
      "gh_bin" => cli,
      "reviewer_id" => 20,
      "projects" => %{"team/repo" => %{"id" => 10}}
    }

    assert {:ok, [1]} = GitHub.assigned(config, "team/repo")
  end

  test "inline review replies stay in their native discussion" do
    root = Path.dirname(Workflow.workflow_file_path())
    cli = Path.join(root, "gh-inline")

    File.write!(cli, """
    #!/usr/bin/env python3
    import json,sys
    path=sys.argv[-1]
    if path.startswith('repos/team/repo/pulls/1/comments?'):
      print(json.dumps([
        {'id': 12, 'in_reply_to_id': 11, 'body': '已修复', 'created_at': '2026-01-02T00:00:00Z', 'user': {'id': 30}},
        {'id': 11, 'body': '请修复', 'created_at': '2026-01-01T00:00:00Z', 'user': {'id': 20}}
      ]))
    else: print('[]')
    """)

    File.chmod!(cli, 0o755)
    config = %{"host" => "github.invalid", "gh_bin" => cli, "projects" => %{"team/repo" => %{"id" => 10}}}

    assert {:ok, [%{"id" => "pull_comment_11", "notes" => [%{"id" => 11}, %{"id" => 12}]}]} =
             GitHub.discussions(config, "repos/team/repo/pulls/1")
  end

  test "PR reads bind native target repository and current head" do
    root = Path.dirname(Workflow.workflow_file_path())
    cli = Path.join(root, "gh-pull")

    File.write!(cli, """
    #!/usr/bin/env python3
    import json,pathlib,sys
    pull=json.loads((pathlib.Path(__file__).parent/'pull.json').read_text())
    print(json.dumps(pull))
    """)

    File.chmod!(cli, 0o755)
    config = %{"host" => "github.invalid", "gh_bin" => cli, "projects" => %{"team/repo" => %{"id" => 10}}}

    pull = %{
      "number" => 1,
      "base" => %{"repo" => %{"id" => 10}, "sha" => String.duplicate("b", 40), "ref" => "main"},
      "head" => %{"sha" => String.duplicate("a", 40)},
      "user" => %{"id" => 30},
      "requested_reviewers" => [%{"id" => 20}],
      "state" => "open",
      "merged" => false,
      "html_url" => "https://github.invalid/team/repo/pull/1"
    }

    File.write!(Path.join(root, "pull.json"), Jason.encode!(pull))

    assert {:ok, %{"state" => "opened", "sha" => head, "target_branch" => "main", "reviewers" => [%{"id" => 20}]}} =
             GitHub.read_pull(config, "team/repo", 1)

    assert head == String.duplicate("a", 40)
    File.write!(Path.join(root, "pull.json"), Jason.encode!(put_in(pull, ["base", "repo", "id"], 11)))
    assert {:error, :invalid_native_review} = GitHub.read_pull(config, "team/repo", 1)
    File.write!(Path.join(root, "pull.json"), Jason.encode!(%{pull | "merged" => true, "state" => "closed"}))
    assert {:ok, %{"state" => "merged"}} = GitHub.read_pull(config, "team/repo", 1)
    File.write!(Path.join(root, "pull.json"), Jason.encode!(%{pull | "state" => "closed"}))
    assert {:ok, %{"state" => "closed"}} = GitHub.read_pull(config, "team/repo", 1)
    File.write!(Path.join(root, "pull.json"), Jason.encode!(%{pull | "state" => "draft"}))
    assert {:ok, %{"state" => "unknown"}} = GitHub.read_pull(config, "team/repo", 1)
    File.write!(Path.join(root, "pull.json"), Jason.encode!(%{pull | "head" => nil}))
    assert {:error, :invalid_native_review} = GitHub.read_pull(config, "team/repo", 1)
  end

  test "review request timeline distinguishes post-review absence from explicit withdrawal" do
    root = Path.dirname(Workflow.workflow_file_path())
    cli = Path.join(root, "gh-timeline")

    File.write!(cli, """
    #!/usr/bin/env python3
    import json,pathlib
    print((pathlib.Path(__file__).parent/'timeline.json').read_text())
    """)

    File.chmod!(cli, 0o755)
    config = %{"host" => "github.invalid", "gh_bin" => cli, "projects" => %{"team/repo" => %{"id" => 10}}}
    requested = %{"id" => 1, "event" => "review_requested", "requested_reviewer" => %{"id" => 20}, "created_at" => "2026-01-01T00:00:00Z"}
    removed = %{"id" => 2, "event" => "review_request_removed", "requested_reviewer" => %{"id" => 20}, "created_at" => "2026-01-02T00:00:00Z"}
    path = Path.join(root, "timeline.json")

    File.write!(path, Jason.encode!([requested]))
    assert {:ok, true} = GitHub.review_assignment(config, "team/repo", 1, 20)
    File.write!(path, Jason.encode!([removed, requested]))
    assert {:ok, false} = GitHub.review_assignment(config, "team/repo", 1, 20)
    File.write!(path, "[]")
    assert {:error, :review_assignment_unconfirmed} = GitHub.review_assignment(config, "team/repo", 1, 20)
  end
end
