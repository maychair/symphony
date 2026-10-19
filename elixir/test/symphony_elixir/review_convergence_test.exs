defmodule SymphonyElixir.ReviewConvergenceTest do
  @moduledoc """
  Single-owner resolution between task verification and a standalone review (§11.1, reject #8).

  One candidate may have exactly one current technical conclusion. A candidate an
  authorized plan member published is owned by the task lane; a candidate two
  members claim is a conflict that needs a human decision; everything else stays
  with the standalone review.
  """

  use ExUnit.Case, async: true

  alias SymphonyElixir.ReviewLane.Ownership
  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixir.WorkRef

  @repository %{
    "provider" => "gitlab",
    "host" => "review.invalid",
    "repository_id" => "10",
    "path" => "team/repo",
    "api_url" => "https://review.invalid/api/v4",
    "credential" => "$UNUSED_FIXTURE"
  }

  test "no standalone review leaves every discovered member untouched" do
    member = member(1)
    assert {[^member], []} = Ownership.converge([], [member], [])
  end

  test "an unclaimed candidate keeps the standalone review as the only owner" do
    review = review(candidate(7))
    assert {[], [resolved]} = Ownership.converge([review], [], [])

    assert resolved.dispatchable
    assert resolved.native_ref["ownership"]["owner"] == "review"
    assert resolved.native_ref["ownership"]["reason"] == "standalone_review_unclaimed"
    assert resolved.native_ref["ownership"]["candidate"] == candidate(7)
  end

  test "a single task claim moves technical ownership to the task lane" do
    review = review(candidate(7))
    member = member(1)
    notes = %{1 => [note(marked(envelope(member_work(1), candidate(7))))]}

    assert {[unchanged], [resolved]} = Ownership.converge([review], [member], opts(notes))

    assert unchanged == member
    refute resolved.dispatchable
    assert resolved.native_ref["ownership"]["owner"] == "task"
    assert resolved.native_ref["ownership"]["reason"] == "candidate_owned_by_task_verification"
    assert resolved.native_ref["ownership"]["task"] == member.id
    assert resolved.native_ref["ownership"]["candidate"] == candidate(7)
  end

  test "candidates with an unusable identity never restrict an unrelated review" do
    missing = %Issue{id: "review:no-work", kind: :review, dispatchable: true, native_ref: %{"execution_kind" => "review_lane"}}
    invalid = %Issue{id: "review:invalid", kind: :review, dispatchable: true, native_ref: %{"execution_kind" => "review_lane", "work" => %{"provider" => "gitlab", "kind" => "mr"}}}

    assert {[], [first, second]} = Ownership.converge([missing, invalid], [], [])

    for resolved <- [first, second] do
      assert resolved.dispatchable
      assert resolved.native_ref["ownership"]["owner"] == "review"
      assert resolved.native_ref["ownership"]["reason"] == "candidate_identity_unavailable"
    end
  end

  test "ambiguous claims across tasks surface a human decision and stop both paths" do
    review = review(candidate(7))
    first = member(1)
    second = member(2)

    notes = %{
      1 => [note(marked(envelope(member_work(1), candidate(7))))],
      2 => [note(marked(envelope(member_work(2), candidate(7))))]
    }

    assert {members, [resolved]} = Ownership.converge([review], [first, second], opts(notes))

    assert Enum.map(members, & &1.dispatchable) == [false, false]
    assert Enum.map(members, & &1.native_ref["ownership"]["owner"]) == ["conflict", "conflict"]
    assert hd(members).native_ref["ownership"]["tasks"] == Enum.sort([first.id, second.id])
    assert hd(members).native_ref["ownership"]["resolution"] == "requires_human_decision"

    refute resolved.dispatchable
    assert resolved.native_ref["ownership"]["owner"] == "conflict"
    assert resolved.native_ref["ownership"]["reason"] == "candidate_ownership_ambiguous"
    assert resolved.native_ref["ownership"]["candidate"] == candidate(7)
  end

  test "unreadable, unauthorized and unrelated member evidence never claims a candidate" do
    review = review(candidate(7))

    strangers = [
      %Issue{id: "task-1", dispatchable: true, native_ref: %{"execution_kind" => "task"}},
      with_work("member:bad", %{"provider" => "gitlab"}),
      with_work("member:unregistered", unregistered_work()),
      member(3),
      member(4),
      member(5),
      member(6),
      member(7)
    ]

    notes = %{
      3 => [note("没有机器凭据的普通评论")],
      4 => [note(marked(envelope(member_work(4), candidate(7), kind: "verification")))],
      5 => [note(marked(envelope(member_work(9), candidate(7))))],
      6 => [note(marked(envelope(member_work(6), candidate(7), payload: %{"summary" => "no artifacts"})))],
      7 => [
        note(
          marked(
            envelope(member_work(7), candidate(7),
              payload: %{
                "artifacts" => [
                  %{"kind" => "report", "target" => candidate(7)},
                  %{"kind" => "mr", "target" => %{"provider" => "gitlab"}}
                ]
              }
            )
          )
        )
      ]
    }

    assert {unresolved, [resolved]} = Ownership.converge([review], strangers, opts(notes))

    assert unresolved == strangers
    assert resolved.dispatchable
    assert resolved.native_ref["ownership"]["reason"] == "standalone_review_unclaimed"
  end

  defp candidate(number) do
    %{"provider" => "gitlab", "host" => "review.invalid", "repository_id" => "10", "kind" => "mr", "number" => number}
  end

  defp member_work(number) do
    %{"provider" => "gitlab", "host" => "review.invalid", "repository_id" => "10", "kind" => "issue", "number" => number}
  end

  defp unregistered_work do
    %{"provider" => "gitlab", "host" => "unknown.invalid", "repository_id" => "10", "kind" => "issue", "number" => 8}
  end

  defp authority_work do
    %{"provider" => "gitlab", "host" => "review.invalid", "repository_id" => "10", "kind" => "issue", "number" => 99}
  end

  defp review(work) do
    %Issue{
      id: "review:" <> WorkRef.key(work),
      kind: :review,
      dispatchable: true,
      native_ref: %{"execution_kind" => "review_lane", "work" => work}
    }
  end

  defp member(number), do: with_work("member:" <> WorkRef.key(member_work(number)), member_work(number))

  defp with_work(id, work) do
    %Issue{
      id: id,
      kind: :task,
      state: "Todo",
      dispatchable: true,
      native_ref: %{"execution_kind" => "plan_member", "work" => work, "parent" => authority_work()}
    }
  end

  defp envelope(member_work, candidate_work, opts \\ []) do
    %{
      "kind" => Keyword.get(opts, :kind, "candidate"),
      "binding" => %{
        "work" => member_work,
        "authority" => %{"work" => authority_work()},
        "role" => "developer",
        "contract_sha" => String.duplicate("a", 64)
      },
      "payload" => Keyword.get(opts, :payload, %{"artifacts" => [%{"kind" => "mr", "target" => candidate_work}]})
    }
  end

  defp marked(envelope) do
    "候选成果已发布。\n\n<!-- symphony-evidence " <> Jason.encode!(envelope) <> " -->\n<!-- symphony-engine-notice -->"
  end

  defp note(body), do: %{"id" => System.unique_integer([:positive]), "body" => body, "author" => %{"id" => 30}, "created_at" => "2026-01-01T00:00:00Z"}

  defp opts(notes_by_number) do
    objects =
      Enum.reduce(notes_by_number, %{"/projects/team%2Frepo" => repository_raw()}, fn {number, notes}, acc ->
        issue = "/projects/team%2Frepo/issues/#{number}"
        acc |> Map.put(issue, issue_raw(number)) |> Map.put(issue <> "/notes", notes)
      end)

    [repositories: [@repository], request: request(objects)]
  end

  defp request(objects) do
    fn _provider, "GET", path, _query, _settings ->
      case Map.fetch(objects, path) do
        {:ok, body} -> {:ok, %{status: 200, body: body}}
        :error -> {:error, :native_read_failed}
      end
    end
  end

  defp repository_raw do
    %{"id" => 10, "path_with_namespace" => "team/repo", "web_url" => "https://review.invalid/team/repo"}
  end

  defp issue_raw(number) do
    %{
      "id" => 1000 + number,
      "iid" => number,
      "project_id" => 10,
      "title" => "Member #{number}",
      "description" => "member #{number} scope",
      "state" => "opened",
      "labels" => [],
      "web_url" => "https://review.invalid/team/repo/-/issues/#{number}"
    }
  end
end

defmodule SymphonyElixir.ReviewConvergenceTrackerTest do
  @moduledoc "The read path that schedules work converges reviews and members (reject #8)."

  use SymphonyElixir.TestSupport

  test "both tracker read modes still return the converged issue set" do
    issue = %Issue{id: "issue-1", identifier: "MT-1", state: "open", dispatchable: true}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    assert {:ok, [^issue]} = Tracker.fetch_issues_by_states(["open"])
    assert {:ok, [^issue]} = Tracker.fetch_issues_by_ids(["issue-1"])
  end
end
