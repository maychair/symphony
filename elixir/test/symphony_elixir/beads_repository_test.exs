defmodule SymphonyElixir.BeadsRepositoryTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Beads.{Acceptance, Repository, RunJournal, SourceIssue}

  test "self-managed origin and nested repository scope are explicit" do
    settings = %{provider: %{"review_repository" => "git.example.test/group/sub/repo", "gitlab_web_url" => "http://git.example.test"}}
    url = "http://git.example.test/group/sub/repo/-/merge_requests/7"
    assert :ok = Acceptance.validate_review_scope(settings, url)

    for bad <- [
          "http://git.example.test/other/repo/-/merge_requests/7",
          "https://git.example.test/group/sub/repo/-/merge_requests/7",
          "http://gitlab.com/group/sub/repo/-/merge_requests/7",
          "http://user@git.example.test/group/sub/repo/-/merge_requests/7",
          url <> "?redirect=elsewhere",
          "http://git.example.test:9000/group/sub/repo/-/merge_requests/7"
        ] do
      assert {:error, _} = Acceptance.validate_review_scope(settings, bad)
    end

    assert {:error, :source_issue_outside_configured_repository} =
             SourceIssue.read(settings, "http://git.example.test/other/repo/-/issues/7")

    refute Repository.gitlab_url?(%{provider: %{}}, url)
    assert :ok = Acceptance.validate_review_scope(%{provider: %{"review_repository" => "github.com/owner/repo"}}, "https://github.com/owner/repo/pull/7")
  end

  test "missing turn remains fenced without explicit pre-turn native recovery evidence" do
    root = Path.join(System.tmp_dir!(), "beads-preturn-" <> Integer.to_string(System.unique_integer([:positive])))
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, record} = RunJournal.admit(root, "task")
    {:ok, record} = RunJournal.checkpoint(record, %{"phase" => "thread_ready", "thread_id" => "allocated-no-rollout"})
    :ok = RunJournal.complete(record, "thread_ready")
    assert {:error, _} = RunJournal.admit(root, "task")
    File.rmdir!(Path.join(record["directory"], "executor.lock"))

    {:ok, _} =
      RunJournal.checkpoint(record, %{
        "phase" => "completed",
        "thread_id" => nil,
        "turn_id" => nil,
        "turn_count" => 0,
        "pre_turn_recovered" => true,
        "abandoned_pre_turn_thread_id" => "allocated-no-rollout"
      })

    assert {:ok, %{"attempt_count" => 2, "thread_id" => nil}} = RunJournal.admit(root, "task")
  end
end
