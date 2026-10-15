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

  test "runtime recovery retains review repair budget and enforces its own limit" do
    alias SymphonyElixir.Beads.Recovery
    settings = %{provider: %{"max_repair_runs" => 3, "max_runtime_recoveries" => 1}}
    record = %{"repair_count" => 2}
    feedback = %{cause: "runtime", actor: "operator_agent", caused_by_event: "validation-item", fingerprint: "runtime-v1"}
    assert {:ok, changes} = Recovery.recovery_changes(settings, record, feedback)
    assert changes["runtime_recovery_count"] == 1
    refute changes["repair_count"]
    refute changes["repair_fingerprint"]
    assert changes["runtime_recovery_fingerprint"] == "runtime-v1"
    assert changes["trigger_actor"] == "operator_agent"
    assert {:error, :recovery_budget_exhausted} = Recovery.recovery_changes(settings, Map.merge(record, changes), feedback)
    assert {:ok, %{"repair_count" => 3}} = Recovery.recovery_changes(settings, record, %{cause: "review"})
    assert {:error, :recovery_budget_exhausted} = Recovery.recovery_changes(settings, %{"repair_count" => 3}, %{})
    assert {:error, :unknown_recovery_cause} = Recovery.recovery_changes(settings, record, %{cause: "unknown"})
  end
end
