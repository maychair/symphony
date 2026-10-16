defmodule SymphonyElixir.MailReviewGitLabTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.MailReview.GitLab

  test "command failures and malformed or excessive discussion pages are rejected" do
    root = Path.dirname(Workflow.workflow_file_path())
    cli = Path.join(root, "glab")

    File.write!(cli, """
    #!/usr/bin/env python3
    import sys,json,pathlib
    mode=(pathlib.Path(__file__).parent/'mode').read_text()
    if mode=='error':sys.exit(3)
    if mode=='invalid':print('{}')
    elif mode=='limit':print(json.dumps([{}]*100))
    elif mode=='pages':print(json.dumps([{}]*100 if sys.argv[-1].endswith('&page=1') else []))
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
