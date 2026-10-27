defmodule SymphonyElixir.TaskboardReviewsTest do
  use SymphonyElixir.TestSupport, runtime: false
  alias SymphonyElixir.Taskboard
  alias SymphonyElixir.Taskboard.Reviews
  alias SymphonyElixir.TaskWorkflow

  defp config(provider \\ "gitlab"), do: %{"enabled" => true, "provider" => provider, "host" => "review.invalid", "publisher_id" => 21, "projects" => %{"team/repo" => %{"id" => 10}}}

  defp record(round \\ 1, provider \\ "gitlab") do
    kind = if provider == "github", do: "pr", else: "mr"
    path = if kind == "pr", do: "/pull/", else: "/-/merge_requests/"

    %{
      "id" => "round-#{round}",
      "project" => "team/repo",
      "iid" => 1,
      "round" => round,
      "work" => %{"provider" => provider, "host" => "review.invalid", "repository_id" => "10", "kind" => kind, "number" => 1},
      "head" => String.duplicate("a", 40),
      "base" => String.duplicate("b", 40),
      "policy_sha" => TaskWorkflow.digest("policy"),
      "target_branch" => "main",
      "phase" => "queued",
      "eligibility" => "current",
      "findings" => [],
      "title" => "实现边界检查",
      "url" => "https://review.invalid/team/repo" <> path <> "1"
    }
  end

  defp completed(record, findings \\ [], responses \\ []) do
    axes =
      Map.new(["standards", "spec"], fn name ->
        {name,
         %{
           "status" => "complete",
           "report" => "审查完成",
           "findings" => if(name == "spec", do: findings, else: []),
           "responses" => if(name == "spec", do: responses, else: []),
           "thread_id" => name,
           "turn_id" => name <> "-turn",
           "reads_verified" => true,
           "native_stop_confirmed" => true
         }}
      end)

    {:ok, result} = SymphonyElixir.TestSupport.fixture_review_result(record, axes)
    url = record["url"] <> if(record["work"]["provider"] == "github", do: "#pullrequestreview-11", else: "#note_11")
    result = Map.put(result, "artifacts", [%{"url" => url, "label" => "Review report"}])
    Map.merge(record, %{"workflow_result" => result, "native_stop_confirmed" => true, "phase" => "completed"})
  end

  defp cards(records, cfg \\ config()) do
    {projects, []} = Reviews.merge([], {:ok, %{config: cfg, records: records}})
    Enum.flat_map(projects, & &1.cards)
  end

  test "one MR card follows the latest automatic round, without todo or assignee labels" do
    previous = completed(record())
    latest = record(2)
    [card] = cards([previous, latest])
    assert card.item_type == "review"
    assert card.column == "Todo"
    assert card.review.round == 2
    assert Enum.map(card.review.history, & &1.round) == [2, 1]
    assert card.labels == []
    [done] = cards([previous])
    assert done.column == "Done"
    assert done.issue_id == card.issue_id
    assert done.artifacts |> hd() |> Map.fetch!(:url) == previous["url"] <> "#note_11"
    assert [] == cards([previous, Map.put(latest, "eligibility", "unassigned")])
  end

  test "execution, missing result and stale scope never invent Done" do
    done = completed(record())

    for {patch, column} <- [
          {%{"phase" => "running"}, "In Progress"},
          {%{"phase" => "failed"}, "Human Review"},
          {%{"phase" => "fenced"}, "Human Review"},
          {%{"eligibility" => "unknown"}, "Human Review"},
          {%{"eligibility" => "superseded"}, "Human Review"},
          {%{"native_stop_confirmed" => false}, "Human Review"},
          {%{"workflow_result" => nil}, "Human Review"}
        ] do
      assert [card] = cards([Map.merge(done, patch)])
      assert card.column == column
    end
  end

  test "a complete review with findings is delivered, without approving the MR" do
    r = record()

    finding = %{
      "schema_version" => 1,
      "id" => "S1",
      "required" => true,
      "criterion" => "边界约定",
      "version" => %{"head" => r["head"], "base" => r["base"], "target" => "main"},
      "location" => "source.c:1",
      "evidence" => "空输入越界",
      "impact" => "可能崩溃",
      "resolution" => "补充边界检查",
      "regression_of" => nil
    }

    [card] = cards([completed(r, [finding])])
    assert card.column == "Done"
    assert card.review.conclusion == "changes_requested"

    prior = completed(r, [finding])["workflow_result"]["finding_register"]
    recheck = Map.put(record(2), "finding_register", prior)
    response = %{"finding" => "S1", "status" => "still_valid", "evidence" => "当前源码仍可触发原反例", "rationale" => "原问题未修复", "verified_by" => "reviewer"}
    completed_recheck = completed(recheck, [], [response])
    [recheck_card] = cards([completed_recheck])
    assert recheck_card.column == "Done"
    assert recheck_card.review.conclusion == "changes_requested"
    refute completed_recheck["workflow_result"]["body"] == "LGTM!"
  end

  test "native provider identity and allowlist filter records; manual journals are not a data source" do
    r = completed(record(1, "github"))
    assert [%{column: "Done", artifacts: [%{url: url}]}] = cards([r], config("github"))
    assert url == r["url"] <> "#pullrequestreview-11"

    for foreign <- [
          put_in(r, ["work", "host"], "foreign.invalid"),
          put_in(r, ["work", "repository_id"], "999"),
          Map.put(r, "project", "foreign/repo"),
          Map.put(r, "url", "https://foreign.invalid/team/repo/pull/1"),
          Map.delete(r, "work")
        ] do
      assert [] == cards([foreign], config("github"))
    end

    assert {[], []} = Reviews.merge([], {:ok, %{config: nil, records: [r]}})
    assert {[], []} = Reviews.merge([], {:ok, %{config: %{"enabled" => false}, records: [r]}})
    assert {[], [%{error: _}]} = Reviews.merge([], {:error, :busy})
  end

  test "opaque workflow fields do not become board text or crash the projection" do
    result = %{"body" => %{"custom" => true}, "status" => ["custom"], "artifacts" => [%{"url" => "https://review.invalid/report", "label" => %{}}]}
    r = record() |> Map.merge(%{"workflow_result" => result, "phase" => "completed", "native_stop_confirmed" => true})
    assert [card] = cards([r])
    assert card.summary == nil
    assert card.review.conclusion == "incomplete"
    assert [%{label: "Review report"}] = card.artifacts
  end

  test "a repository with no automatic listener has no review cards" do
    assert {:ok, %{records: []}} = SymphonyElixir.RuntimeContext.with_context(%{id: "board-not-started"}, &Reviews.snapshot/0)
  end

  test "board and project APIs retain Issue filters while adding review cards and history" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", project_slug: "team/repo")
    unrelated = %Tracker.Issue{id: "unlabelled", identifier: "MOCK-1", title: "Unrelated", state: "Todo"}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [unrelated])
    cfg = put_in(Config.settings!().tracker.project_slug, "team/repo")
    review = {:ok, %{config: config(), records: [completed(record())]}}
    opts = [settings: cfg, runtime_snapshot_fun: fn -> %{} end, review_snapshot_fun: fn -> review end]
    board = Taskboard.snapshot(opts)
    assert [%{item_type: "review", column: "Done"} = card] = board.cards
    assert board.counts["Done"] == 1
    assert card.project_id == "memory-team-repo"
    assert {:ok, project} = Taskboard.project_snapshot(card.project_id, opts)
    assert project.cards == [card]
    unavailable = Taskboard.snapshot(Keyword.put(opts, :review_snapshot_fun, fn -> {:error, :unavailable} end))
    assert unavailable.cards == []
    assert [%{project_id: "automatic-reviews"}] = unavailable.errors
  end

  test "review-only native repositories expose their project snapshot" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    view = {:ok, %{config: config(), records: [record()]}}
    opts = [review_snapshot_fun: fn -> view end, runtime_snapshot_fun: fn -> %{} end]
    board = Taskboard.snapshot(opts)
    [card] = board.cards
    assert String.starts_with?(card.project_id, "reviews-")
    assert {:ok, %{cards: [^card]}} = Taskboard.project_snapshot(card.project_id, opts)
  end

  test "remote read-only boards retain typed review history without allowing unlabelled Issues" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    remote = %{"id" => "remote", "name" => "Remote", "repo" => "team/repo", "kind" => "gitlab", "url" => "https://board.invalid"}
    cfg = put_in(Config.settings!().taskboard.projects, [remote])
    [card] = cards([completed(record())])
    wire = card |> Jason.encode!() |> Jason.decode!()
    invalid = put_in(wire, ["review", "round"], 0)
    unlabelled = %{"issue_identifier" => "GL-9", "title" => "Unrelated", "labels" => []}

    remote_read = fn _url, _headers -> {:ok, %{status: 200, body: %{"cards" => [wire, invalid, unlabelled]}}} end
    snapshot = Taskboard.snapshot(settings: cfg, runtime_snapshot_fun: fn -> %{} end, remote_request_fun: remote_read)

    assert [%{item_type: "review", project_id: "remote", review: %{"round" => 1}}] = snapshot.cards
  end
end
