defmodule SymphonyElixir.MailReviewPolicyTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.MailReview
  alias SymphonyElixir.MailReview.Policy

  test "configuration validates each required boundary and resolves nested environment references" do
    root = Path.dirname(Workflow.workflow_file_path())
    instructions = Path.join(root, "instructions")
    File.write!(instructions, "Review instructions")

    config = %{
      "enabled" => true,
      "host" => "review.invalid",
      "username" => "reviewer",
      "projects" => %{"team/repo" => %{"checkout" => root}},
      "state_dir" => root,
      "reviewer_names" => ["Reviewer"],
      "mail_senders" => ["gitlab@review.invalid"],
      "instructions_file" => instructions
    }

    assert :ok = MailReview.validate_config(%{provider: %{"mail_review" => config}})

    for {key, value, reason} <- [
          {"host", "invalid/host", :mail_review_host_required},
          {"username", "", :mail_review_username_required},
          {"projects", %{}, :mail_review_projects_required},
          {"projects", nil, :mail_review_projects_required},
          {"projects", %{"repo" => %{}}, :mail_review_invalid_projects},
          {"projects", %{"repo" => %{"checkout" => root}}, :mail_review_invalid_projects},
          {"projects", %{"team/repo" => %{"checkout" => "relative"}}, :mail_review_invalid_projects},
          {"state_dir", "relative", :mail_review_absolute_state_required},
          {"reviewer_names", [], :mail_review_names_required},
          {"reviewer_names", [""], :mail_review_names_required},
          {"mail_senders", [], :mail_review_senders_required},
          {"instructions_file", root, :mail_review_instructions_file_required}
        ] do
      assert {:error, ^reason} = MailReview.validate_config(%{provider: %{"mail_review" => Map.put(config, key, value)}})
    end

    System.put_env("SYMPHONY_TEST_REVIEW_VALUE", "fixture")
    on_exit(fn -> System.delete_env("SYMPHONY_TEST_REVIEW_VALUE") end)
    assert %{"key" => ["fixture", 2]} == MailReview.resolve(%{"key" => ["$SYMPHONY_TEST_REVIEW_VALUE", 2]})
    assert MailReview.binding().adapter == MailReview
    assert MailReview.job?(%Issue{id: "mail-review:id", native_ref: %{"execution_kind" => "mail_review"}})
    refute MailReview.job?(%Issue{id: "normal"})
    assert %{"success" => false} = MailReview.execute_agent_tool("unknown", %{}, [])
  end

  test "mail requires trusted sender, unique allowlisted MR and matching subject" do
    config = %{"host" => "review.invalid", "projects" => %{"team/repo" => %{}}, "reviewer_names" => ["Reviewer"], "mail_senders" => ["gitlab@review.invalid"]}

    mail = %{
      "head_from" => %{"mail_address" => "gitlab@review.invalid"},
      "subject" => "Task (!1)",
      "body_plain_text" => "Author created a merge request\nReviewer: Reviewer\nhttps://review.invalid/team/repo/-/merge_requests/1"
    }

    assert {:ok, "team/repo", 1} = Policy.candidate(mail, config)
    assert :ignore = Policy.candidate(%{mail | "subject" => "Task (!2)"}, config)
    assert :ignore = Policy.candidate(%{mail | "subject" => "Task"}, config)

    for url <- ["https://evil.invalid/team/repo/-/merge_requests/1", "https://review.invalid/other/repo/-/merge_requests/1"] do
      assert :ignore = Policy.candidate(Map.put(mail, "body_html", url) |> Map.put("body_plain_text", "Reviewer was added as a reviewer."), config)
    end

    refute Policy.answered?([], [], 30)
    finding = [%{"discussion_id" => "d", "note_id" => 1}]
    own = %{"id" => 1, "created_at" => "2026-01-01", "resolved" => false}
    refute Policy.answered?(finding, [%{"id" => "d", "notes" => []}], 30)
    refute Policy.answered?(finding, [%{"id" => "d", "notes" => [own]}], 30)
    reply = %{"id" => 2, "author" => %{"id" => 30}, "created_at" => "2026-01-02"}
    assert Policy.answered?(finding, [%{"id" => "d", "notes" => [own, reply]}], 30)
    assert Policy.answered?(finding, [%{"id" => "d", "notes" => [%{own | "resolved" => true}]}], 30)
    refute Policy.answered?(finding, [%{"id" => "d", "notes" => [own, Map.put(reply, "system", true)]}], 30)
  end
end
