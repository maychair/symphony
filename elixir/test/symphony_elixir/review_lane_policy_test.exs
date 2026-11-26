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
    assert :ok = ReviewLane.validate_config(%{provider: %{"review_lane" => config |> Map.delete("result_command") |> Map.put("projects", %{"team/repo" => %{"id" => 10}})}})
    assert :ok = ReviewLane.validate_config(%{provider: %{"review_lane" => Map.put(config, "publish_results", false)}})

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
          {"event_driven", "true", :review_lane_event_mode_requires_gitlab},
          {"publish_results", "false", :review_lane_publish_results_boolean_required},
          {"result_command", ["python3", 1], :invalid_workflow_result_command},
          {"result_command", "not-argv", :invalid_workflow_result_command},
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

  test "prior_review? recognizes approvals and human comments while ignoring unreviewed state" do
    mr = %{"author" => %{"id" => 30}}

    refute Policy.prior_review?([], mr)
    refute Policy.prior_review?([nil, %{}, %{"notes" => [nil]}], mr)

    # Approved MR checks
    assert Policy.prior_review?([], Map.put(mr, "approved", true))
    assert Policy.prior_review?([], Map.put(mr, "detailed_merge_status", "approved"))
    assert Policy.prior_review?([], Map.put(mr, "approved_by", [%{"id" => 20}]))
    assert Policy.prior_review?([], Map.put(mr, "reviews", [%{"state" => "APPROVED"}]))

    # Discussions with human reviews
    human_comment = %{"notes" => [%{"id" => 1, "body" => "Looks good to me, please fix typo.", "author" => %{"id" => 40}}]}
    assert Policy.prior_review?([human_comment], mr)
    reviewer_comment = %{"notes" => [%{"id" => 1, "body" => "Please add tests.", "author" => %{"id" => 20}}]}
    assert Policy.prior_review?([reviewer_comment], mr)
    github_approval_empty_body = %{"notes" => [%{"id" => 1, "body" => "", "state" => "APPROVED", "author" => %{"id" => 20}}]}
    assert Policy.prior_review?([github_approval_empty_body], mr)

    # System notes: approval vs non-approval
    system_approved = %{"notes" => [%{"id" => 1, "system" => true, "body" => "approved this merge request", "author" => %{"id" => 20}}]}
    assert Policy.prior_review?([system_approved], mr)
    system_other = %{"notes" => [%{"id" => 1, "system" => true, "body" => "changed target branch", "author" => %{"id" => 30}}]}
    refute Policy.prior_review?([system_other], mr)

    # Publisher-authored assignment notifications are not review results.
    for body <- ["assigned to @reviewer", "requested review from @reviewer", "changed target branch"] do
      note = %{"notes" => [%{"system" => true, "body" => body, "author" => %{"id" => 50}}]}
      refute Policy.prior_review?([note], mr)
    end

    publisher_approval = %{"notes" => [%{"system" => true, "body" => "approved this merge request", "author" => %{"id" => 50}}]}
    assert Policy.prior_review?([publisher_approval], mr)

    # Author's own comments do not count as reviews
    author_note = %{"notes" => [%{"id" => 1, "body" => "Here is my PR explanation", "author" => %{"id" => 30}}]}
    refute Policy.prior_review?([author_note], mr)
  end

  test "a marked native comment and matching provider report link prove delivery regardless of author" do
    config = %{"provider" => "github", "publisher_id" => 50}
    url = "https://github.invalid/team/repo/pull/1"
    marker = Policy.review_marker(%{"number" => 1})
    body = "LGTM!\n\n" <> marker
    note = %{"id" => 1, "body" => body, "author" => %{"id" => 99}}
    review = %{"id" => "pull_review_1", "notes" => [note]}
    result = %{"body" => body, "artifacts" => [%{"label" => "Malformed"}, %{"url" => url <> "#pullrequestreview-1"}]}

    assert Policy.delivered_comment?([review], config, url, marker, result)
    refute Policy.delivered_comment?([review], config, url, marker, %{})
    refute Policy.delivered_comment?([Map.put(review, "id", "inline_1")], config, url, marker, result)
    refute Policy.automatic_review?([%{review | "notes" => [Map.put(note, "system", true)]}], config, marker)
    refute Policy.automatic_review?([%{review | "notes" => [%{"body" => marker}]}], config, marker)
  end
end
