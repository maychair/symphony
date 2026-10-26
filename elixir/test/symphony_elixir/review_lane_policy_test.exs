defmodule SymphonyElixir.ReviewLanePolicyTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.ReviewLane
  alias SymphonyElixir.ReviewLane.Policy

  test "configuration validates each required boundary and resolves nested environment references" do
    root = Path.dirname(Workflow.workflow_file_path())
    instructions = Path.join(root, "instructions")
    File.write!(instructions, "## Common\nRead evidence.\n## Standards\nRead standards.\n## Spec\nVerify scope.\n")

    config = %{
      "enabled" => true,
      "host" => "review.invalid",
      "provider" => "gitlab",
      "reviewer_id" => 20,
      "publisher_id" => 20,
      "projects" => %{"team/repo" => %{"id" => 10, "checkout" => root}},
      "state_dir" => root,
      "instruction_files" => [instructions],
      "result_command" => SymphonyElixir.TestSupport.workflow_result_command()
    }

    assert :ok = ReviewLane.validate_config(%{provider: %{"review_lane" => config}})

    for {key, value} <- [{"axes", ["standards"]}, {"pass_on_error", true}, {"lgtm_body", "custom pass"}, {"publisher_approve", true}] do
      assert {:error, :unknown_review_configuration} = ReviewLane.validate_config(%{provider: %{"review_lane" => Map.put(config, key, value)}})
    end

    assert {:error, :unknown_review_configuration} = ReviewLane.validate_config(%{provider: %{"review_lane" => Map.put(config, "policy_file", instructions)}})

    assert :ok = ReviewLane.validate_config(%{provider: %{"review_lane" => %{config | "provider" => "github"}}})
    assert {:error, :mail_review_retired_migration_required} = ReviewLane.validate_config(%{provider: %{"mail_review" => config}})

    File.write!(instructions, "")
    assert {:error, :workflow_instructions_unavailable} = ReviewLane.validate_config(%{provider: %{"review_lane" => config}})
    File.write!(instructions, "## Common\nRead evidence.\n## Standards\nRead standards.\n## Spec\nVerify scope.\n")

    for {key, value, reason} <- [
          {"host", "invalid/host", :review_lane_host_required},
          {"provider", "unknown", :review_lane_provider_unsupported},
          {"reviewer_id", 0, :review_lane_reviewer_id_required},
          {"publisher_id", nil, :review_lane_publisher_id_required},
          {"projects", %{}, :review_lane_projects_required},
          {"projects", nil, :review_lane_projects_required},
          {"projects", %{"repo" => %{}}, :review_lane_invalid_projects},
          {"projects", %{"repo" => %{"id" => 10, "checkout" => root}}, :review_lane_invalid_projects},
          {"projects", %{"team/repo" => %{"checkout" => "relative"}}, :review_lane_invalid_projects},
          {"state_dir", "relative", :review_lane_absolute_state_required},
          {"poll_interval_ms", -1, :review_lane_poll_interval_required},
          {"result_command", nil, :workflow_result_command_required},
          {"result_command", ["python3", 1], :workflow_result_command_required},
          {"model_settings", "invalid", :invalid_workflow_model_settings},
          {"model_settings", %{"sandbox_mode" => "danger-full-access"}, :invalid_workflow_model_settings},
          {"instruction_files", [root], :workflow_instructions_unavailable}
        ] do
      assert {:error, ^reason} = ReviewLane.validate_config(%{provider: %{"review_lane" => Map.put(config, key, value)}})
    end

    System.put_env("SYMPHONY_TEST_REVIEW_VALUE", "fixture")
    on_exit(fn -> System.delete_env("SYMPHONY_TEST_REVIEW_VALUE") end)
    assert %{"key" => ["fixture", 2]} == ReviewLane.resolve(%{"key" => ["$SYMPHONY_TEST_REVIEW_VALUE", 2]})
    assert ReviewLane.job?(%Issue{id: "review:id", native_ref: %{"execution_kind" => "review_lane"}})
    refute ReviewLane.job?(%Issue{id: "normal"})
  end

  test "response versions distinguish new replies, edits and resolution from repeated or irrelevant observations" do
    finding = [%{"discussion_id" => "d", "note_id" => 1}]
    own = %{"id" => 1, "created_at" => "2026-01-01T00:00:00Z", "resolved" => false}
    discussion = %{"id" => "d", "notes" => [own]}
    assert {:ok, empty} = Policy.response_digest([], [], 30)
    assert {:ok, ^empty} = Policy.response_digest(finding, [discussion], 30)
    assert {:error, :review_receipt_source_missing} = Policy.response_digest(finding, [], 30)
    assert {:error, :review_receipt_source_missing} = Policy.response_digest(finding, [%{discussion | "notes" => []}], 30)
    reply = %{"id" => 2, "body" => "修复了边界条件", "author" => %{"id" => 30}, "created_at" => "2026-01-02T00:00:00Z"}
    replied = %{discussion | "notes" => [own, reply]}
    assert {:ok, digest} = Policy.response_digest(finding, [replied], 30)
    refute digest == empty
    assert {:ok, ^digest} = Policy.response_digest(finding ++ finding, [replied], 30)
    edited = update_in(replied["notes"], fn [first, note] -> [first, Map.put(note, "body", "补充复现步骤")] end)
    assert {:ok, different} = Policy.response_digest(finding, [edited], 30)
    refute different == digest
    assert {:ok, resolved} = Policy.response_digest(finding, [%{discussion | "notes" => [%{own | "resolved" => true}]}], 30)
    refute resolved == empty

    for changes <- [%{"system" => true}, %{"body" => " "}, %{"body" => "<!-- symphony-review:owned:0 -->"}, %{"author" => %{"id" => 99}}] do
      assert {:ok, ^empty} = Policy.response_digest(finding, [%{discussion | "notes" => [own, Map.merge(reply, changes)]}], 30)
    end

    assert Policy.requested_reviewer?(%{"state" => "opened", "reviewers" => [%{"id" => 20}]}, 20)
    refute Policy.requested_reviewer?(%{"state" => "opened", "reviewers" => [%{"id" => 99, "username" => "reviewer"}]}, 20)
  end

  test "prior_review? recognizes approvals and human or automated comments while ignoring unreviewed state" do
    config = %{"reviewer_id" => 20, "publisher_id" => 50}
    mr = %{"author" => %{"id" => 30}}

    refute Policy.prior_review?([], mr, config)
    refute Policy.prior_review?([nil, %{}, %{"notes" => [nil]}], mr, config)

    # Approved MR checks
    assert Policy.prior_review?([], Map.put(mr, "approved", true), config)
    assert Policy.prior_review?([], Map.put(mr, "detailed_merge_status", "approved"), config)
    assert Policy.prior_review?([], Map.put(mr, "approved_by", [%{"id" => 20}]), config)
    assert Policy.prior_review?([], Map.put(mr, "reviews", [%{"state" => "APPROVED"}]), config)

    # Discussions with automated review notes
    auto_pub = %{"notes" => [%{"id" => 1, "body" => "LGTM!", "author" => %{"id" => 50}}]}
    assert Policy.prior_review?([auto_pub], mr, config)
    auto_comment = %{"notes" => [%{"id" => 1, "body" => "<!-- symphony-review: 123 -->\\nLGTM!", "author" => %{"id" => 99}}]}
    assert Policy.prior_review?([auto_comment], mr, config)

    # Discussions with human reviews
    human_comment = %{"notes" => [%{"id" => 1, "body" => "Looks good to me, please fix typo.", "author" => %{"id" => 40}}]}
    assert Policy.prior_review?([human_comment], mr, config)
    reviewer_comment = %{"notes" => [%{"id" => 1, "body" => "Please add tests.", "author" => %{"id" => 20}}]}
    assert Policy.prior_review?([reviewer_comment], mr, config)
    github_approval_empty_body = %{"notes" => [%{"id" => 1, "body" => "", "state" => "APPROVED", "author" => %{"id" => 20}}]}
    assert Policy.prior_review?([github_approval_empty_body], mr, config)

    # System notes: approval vs non-approval
    system_approved = %{"notes" => [%{"id" => 1, "system" => true, "body" => "approved this merge request", "author" => %{"id" => 20}}]}
    assert Policy.prior_review?([system_approved], mr, config)
    system_other = %{"notes" => [%{"id" => 1, "system" => true, "body" => "changed target branch", "author" => %{"id" => 30}}]}
    refute Policy.prior_review?([system_other], mr, config)

    # Author's own comments do not count as reviews
    author_note = %{"notes" => [%{"id" => 1, "body" => "Here is my PR explanation", "author" => %{"id" => 30}}]}
    refute Policy.prior_review?([author_note], mr, config)
  end
end
