defmodule SymphonyElixir.ReviewConvergenceTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ReviewLane.Ownership
  alias SymphonyElixir.{RunJournal, TaskDecision, TaskPlan, TaskPlanPreflight, TaskWorkflow, WorkRef}
  alias SymphonyElixir.Tracker.Issue

  @repository %{
    "provider" => "gitlab",
    "host" => "review.invalid",
    "repository_id" => "10",
    "path" => "team/repo",
    "api_url" => "https://review.invalid/api/v4",
    "credential" => "$UNUSED_FIXTURE"
  }
  @head String.duplicate("a", 40)

  test "no standalone review leaves every discovered member untouched" do
    member = member()
    assert {[^member], []} = Ownership.converge([], [member], [])
  end

  test "unclaimed candidate stays in standalone lane" do
    assert {[], [resolved]} = Ownership.converge([review()], [], [])
    assert resolved.dispatchable
    assert resolved.native_ref["ownership"]["owner"] == "review"
  end

  test "two successive published candidates from the same task are one claim" do
    f = fixture()
    f = publish(f, f.record, 201)
    {:ok, stopped} = RunJournal.checkpoint(f.record, %{"native_stop_confirmed" => true})
    :ok = RunJournal.complete(stopped, "completed")
    binding = %{stopped["execution_binding"] | "candidate" => String.duplicate("b", 64)}
    {:ok, next} = RunJournal.admit(f.root, WorkRef.key(f.work), execution_binding: binding)
    {:ok, next} = RunJournal.checkpoint(next, %{"thread_id" => "developer-2"})
    f = publish(%{f | record: next}, next, 202)

    assert {[member], [resolved]} = Ownership.converge([review()], [member()], f.opts)
    assert member.dispatchable
    refute resolved.dispatchable
    assert resolved.native_ref["ownership"]["owner"] == "task"
    assert resolved.native_ref["ownership"]["task"] == member().id
  end

  test "forged native author cannot claim an otherwise valid publication" do
    f = fixture() |> then(&publish(&1, &1.record, 201))

    Agent.update(f.state, fn objects ->
      update_in(objects, [f.member_notes], fn [note] -> [%{note | "author" => %{"id" => 30}}] end)
    end)

    assert {[member], [resolved]} = Ownership.converge([review()], [member()], f.opts)
    assert member.dispatchable
    assert resolved.dispatchable
    assert resolved.native_ref["ownership"]["owner"] == "review"
  end

  test "native read failure fails closed instead of dispatching standalone review" do
    f = fixture()
    Agent.update(f.state, &Map.delete(&1, f.member_notes))

    assert {[member], [resolved]} = Ownership.converge([review()], [member()], f.opts)
    refute member.dispatchable
    refute resolved.dispatchable
    assert resolved.native_ref["ownership"]["reason"] == "candidate_ownership_unconfirmed"
  end

  test "a removed native grant cannot authenticate a task claim" do
    f = fixture() |> then(&publish(&1, &1.record, 201))
    Agent.update(f.state, &Map.put(&1, "/projects/team%2Frepo/issues/1/notes", []))

    assert {[member], [resolved]} = Ownership.converge([review()], [member()], f.opts)
    refute member.dispatchable
    refute resolved.dispatchable
    assert resolved.native_ref["ownership"]["owner"] == "unknown"
  end

  test "a member with no journal and no publication leaves the review unclaimed" do
    f = fixture()
    File.rm!(Path.join(f.record["directory"], "run.json"))

    assert {[member], [resolved]} = Ownership.converge([review()], [member()], f.opts)
    assert member.dispatchable
    assert resolved.dispatchable
    assert resolved.native_ref["ownership"]["owner"] == "review"
  end

  test "a published candidate for an old head does not own the current review" do
    f = fixture() |> then(&publish(&1, &1.record, 201))
    path = "/projects/team%2Frepo/merge_requests/7"
    Agent.update(f.state, &update_in(&1, [path, "sha"], fn _ -> String.duplicate("b", 40) end))

    assert {[member], [resolved]} = Ownership.converge([review()], [member()], f.opts)
    assert member.dispatchable
    assert resolved.dispatchable
    assert resolved.native_ref["ownership"]["owner"] == "review"
  end

  test "two independently authorized tasks claiming one current MR block both lanes" do
    first = fixture() |> then(&publish(&1, &1.record, 201))
    second = fixture(10, 11, first.root) |> then(&publish(&1, &1.record, 301))
    first_request = first.opts[:request]
    second_request = second.opts[:request]

    request = fn provider, method, path, query, settings ->
      case first_request.(provider, method, path, query, settings) do
        {:error, :native_read_failed} -> second_request.(provider, method, path, query, settings)
        result -> result
      end
    end

    opts = Keyword.put(first.opts, :request, request)
    assert {[one, two], [resolved]} = Ownership.converge([review()], [member(), member(11, 10)], opts)
    refute one.dispatchable
    refute two.dispatchable
    refute resolved.dispatchable
    assert resolved.native_ref["ownership"]["owner"] == "conflict"
    assert resolved.native_ref["ownership"]["tasks"] == Enum.sort([one.id, two.id])
    assert one.native_ref["ownership"]["tasks"] == resolved.native_ref["ownership"]["tasks"]
  end

  test "unrelated and unusable review identities do not acquire task ownership" do
    unrelated = %Issue{id: "legacy", kind: :task, dispatchable: true, native_ref: %{"execution_kind" => "task"}}
    missing = %Issue{id: "review:missing", kind: :review, dispatchable: true, native_ref: %{"execution_kind" => "review_lane"}}
    invalid = %Issue{id: "review:invalid", kind: :review, dispatchable: true, native_ref: %{"execution_kind" => "review_lane", "work" => %{"provider" => "gitlab"}}}

    assert {[^unrelated], [first, second, normal]} = Ownership.converge([missing, invalid, review()], [unrelated], [])

    for resolved <- [first, second] do
      assert resolved.dispatchable
      assert resolved.native_ref["ownership"]["reason"] == "candidate_identity_unavailable"
    end

    assert normal.dispatchable
    assert normal.native_ref["ownership"]["reason"] == "standalone_review_unclaimed"
  end

  test "malformed member identity cannot establish an absent ownership claim" do
    malformed = %Issue{id: "member:missing-parent", kind: :task, dispatchable: true, native_ref: %{"execution_kind" => "plan_member", "work" => work(2)}}

    assert {[member], [resolved]} = Ownership.converge([review()], [malformed], [])
    refute member.dispatchable
    refute resolved.dispatchable
    assert resolved.native_ref["ownership"]["owner"] == "unknown"
  end

  test "a journal bound to a different Issue cannot authenticate its publication" do
    f = fixture() |> then(&publish(&1, &1.record, 201))
    assert {:ok, _} = RunJournal.checkpoint(f.record, %{"issue_id" => WorkRef.key(work(11))})

    assert {[member], [resolved]} = Ownership.converge([review()], [member()], f.opts)
    refute member.dispatchable
    refute resolved.dispatchable
    assert resolved.native_ref["ownership"]["owner"] == "unknown"
  end

  test "a journal with no candidate leaves the review unclaimed" do
    f = fixture()
    assert {[member], [resolved]} = Ownership.converge([review()], [member()], f.opts)
    assert member.dispatchable
    assert resolved.dispatchable
    assert resolved.native_ref["ownership"]["owner"] == "review"
  end

  test "two different candidates in the same execution generation require resolution" do
    f = fixture() |> then(&publish(&1, &1.record, 201))
    artifact = %{"id" => "output", "kind" => "mr", "target" => change(), "target_branch" => "main", "version" => String.duplicate("b", 40)}
    f = publish(f, f.record, 202, [artifact])

    assert {[member], [resolved]} = Ownership.converge([review()], [member()], f.opts)
    refute member.dispatchable
    refute resolved.dispatchable
    assert resolved.native_ref["ownership"]["owner"] == "unknown"
  end

  test "an artifact with an invalid target cannot claim a current MR" do
    f = fixture()
    artifact = %{"id" => "output", "kind" => "mr", "target" => %{"provider" => "gitlab"}, "target_branch" => "main", "version" => @head}
    f = publish(f, f.record, 201, [artifact])

    assert {[member], [resolved]} = Ownership.converge([review()], [member()], f.opts)
    assert member.dispatchable
    assert resolved.dispatchable
    assert resolved.native_ref["ownership"]["owner"] == "review"
  end

  test "a malformed recorded publication cannot authenticate task ownership" do
    f = fixture()
    f = publish(f, f.record, 201, ["not an artifact"])

    assert {[member], [resolved]} = Ownership.converge([review()], [member()], f.opts)
    refute member.dispatchable
    refute resolved.dispatchable
    assert resolved.native_ref["ownership"]["owner"] == "unknown"
  end

  test "a failed native change read cannot prove the candidate is unclaimed" do
    f = fixture() |> then(&publish(&1, &1.record, 201))
    Agent.update(f.state, &Map.delete(&1, "/projects/team%2Frepo/merge_requests/7"))

    assert {[member], [resolved]} = Ownership.converge([review()], [member()], f.opts)
    refute member.dispatchable
    refute resolved.dispatchable
    assert resolved.native_ref["ownership"]["owner"] == "unknown"
  end

  defp work(number), do: %{"provider" => "gitlab", "host" => "review.invalid", "repository_id" => "10", "kind" => "issue", "number" => number}
  defp change, do: %{work(2) | "kind" => "mr", "number" => 7}

  defp member(number \\ 2, parent \\ 1),
    do: %Issue{id: "member:" <> WorkRef.key(work(number)), kind: :task, dispatchable: true, native_ref: %{"execution_kind" => "plan_member", "work" => work(number), "parent" => work(parent)}}

  defp review, do: %Issue{id: "review:" <> WorkRef.key(change()), kind: :review, dispatchable: true, native_ref: %{"execution_kind" => "review_lane", "work" => change()}}

  defp contract(work, parent) do
    data = %{
      "schema_version" => 2,
      "work" => work,
      "parent" => parent,
      "goal" => "Deliver the approved result",
      "non_goals" => [],
      "criteria" => ["result"],
      "criteria_details" => %{"result" => "Reproducible output"},
      "verification_checks" => %{"result" => ["test"]},
      "authorizer" => "1",
      "acceptance_mode" => if(parent, do: "technical", else: "separate"),
      "acceptor" => if(parent, do: nil, else: "2"),
      "budget_ms" => 100_000,
      "deliverables" => [%{"id" => "output", "kind" => "mr", "criteria" => ["result"], "target_branch" => "main"}]
    }

    Map.put(data, "contract_sha", TaskWorkflow.digest(data))
  end

  defp note(id, actor, body) do
    %{"id" => id, "body" => body, "author" => %{"id" => actor}, "created_at" => "2026-10-17T00:00:00Z", "updated_at" => "2026-10-17T00:00:00Z"}
  end

  defp fixture(parent_number \\ 1, member_number \\ 2, shared_root \\ nil) do
    parent_work = work(parent_number)
    member_work = work(member_number)
    parent_scope = contract(parent_work, nil)
    child_scope = contract(member_work, parent_work)

    {:ok, plan} =
      TaskPlan.seal(%{
        "parent" => parent_work,
        "contract_sha" => parent_scope["contract_sha"],
        "authorizer" => "1",
        "criteria" => ["result"],
        "members" => [%{"work" => member_work, "contract_sha" => child_scope["contract_sha"], "criteria" => ["result"], "budget_ms" => 100_000, "human_gate" => false}],
        "dependencies" => [],
        "integration" => member_work,
        "budget_ms" => 100_000
      })

    approval = note(1, 1, "<!-- symphony-plan-decision " <> Jason.encode!(%{"action" => "authorize", "revision" => plan["revision"]}) <> " -->")
    base = "/projects/team%2Frepo"
    member_notes = base <> "/issues/#{member_number}/notes"

    raw = fn number, description ->
      %{
        "id" => 1000 + number,
        "iid" => number,
        "project_id" => 10,
        "title" => "Issue #{number}",
        "description" => description,
        "state" => "opened",
        "assignees" => [%{"id" => 1}],
        "labels" => [],
        "web_url" => "https://review.invalid/team/repo/-/issues/#{number}"
      }
    end

    objects = %{
      base => %{"id" => 10, "path_with_namespace" => "team/repo", "web_url" => "https://review.invalid/team/repo"},
      (base <> "/issues/#{parent_number}") => raw.(parent_number, "<!-- symphony-contract " <> Jason.encode!(parent_scope) <> " -->\n<!-- symphony-plan " <> Jason.encode!(plan) <> " -->"),
      (base <> "/issues/#{member_number}") => raw.(member_number, "<!-- symphony-contract " <> Jason.encode!(child_scope) <> " -->"),
      (base <> "/issues/#{parent_number}/notes") => [approval],
      member_notes => [],
      (base <> "/merge_requests/7") => %{
        "id" => 107,
        "iid" => 7,
        "project_id" => 10,
        "source_project_id" => 10,
        "target_project_id" => 10,
        "sha" => @head,
        "source_branch" => "feature",
        "target_branch" => "main",
        "state" => "opened",
        "merged_at" => nil,
        "web_url" => "https://review.invalid/team/repo/-/merge_requests/7"
      }
    }

    state = start_supervised!({Agent, fn -> objects end}, id: make_ref())

    request = fn _, "GET", path, _, _ ->
      case Agent.get(state, &Map.fetch(&1, path)) do
        {:ok, body} -> {:ok, %{status: 200, body: body}}
        :error -> {:error, :native_read_failed}
      end
    end

    policy = %{"engine_actor" => "99", "max_repairs" => 2, "max_retries" => 2, "checks" => %{}}
    repository = Map.put(@repository, "execution", %{"policy" => policy})
    root = shared_root || Path.join(System.tmp_dir!(), "ownership-#{System.unique_integer([:positive])}")
    if is_nil(shared_root), do: on_exit(fn -> File.rm_rf!(root) end)
    opts = [repositories: [repository], request: request, journal_root: root]
    {:ok, preflight} = TaskPlanPreflight.inspect_plan(parent_work, opts)

    binding = %{
      "work" => member_work,
      "role" => "developer",
      "plan_revision" => plan["revision"],
      "contract_sha" => child_scope["contract_sha"],
      "authority" => preflight.authority,
      "inputs" => [],
      "candidate" => nil,
      "policy_sha" => TaskWorkflow.digest(policy)
    }

    {:ok, record} = RunJournal.admit(root, WorkRef.key(member_work), execution_binding: binding)
    {:ok, record} = RunJournal.checkpoint(record, %{"thread_id" => "developer-1"})

    %{
      root: root,
      record: record,
      state: state,
      member_notes: member_notes,
      work: member_work,
      opts: opts,
      policy: policy
    }
  end

  defp publish(f, record, note_id, artifacts \\ nil) do
    binding = record["execution_binding"]
    payload = Map.take(binding, ~w(work contract_sha inputs))
    artifacts = artifacts || [%{"id" => "output", "kind" => "mr", "target" => change(), "target_branch" => "main", "version" => @head}]
    payload = Map.put(payload, "artifacts", artifacts)

    envelope = %{
      "schema_version" => 1,
      "kind" => "candidate",
      "binding" => binding,
      "generation" => record["execution_generation"],
      "thread_id" => record["thread_id"],
      "actor" => "99",
      "payload" => payload,
      "summary" => "Candidate ready"
    }

    id = TaskWorkflow.digest(Map.delete(envelope, "summary"))
    envelope = Map.put(envelope, "id", id)
    body = "Candidate ready\n\n<!-- symphony-evidence " <> TaskWorkflow.canonical_json(envelope) <> " -->\n<!-- symphony-engine-notice -->"
    native = note(note_id, 99, body)
    receipt = %{"work" => f.work, "note_id" => note_id, "source" => TaskDecision.source_ref(native), "id" => id}
    entry = %{"id" => id, "work" => f.work, "actor" => "99", "body" => body, "status" => "published", "binding" => binding, "receipt" => receipt}
    {:ok, updated} = RunJournal.checkpoint(record, %{"publications" => Map.put(record["publications"] || %{}, id, entry)})
    Agent.update(f.state, &Map.update!(&1, f.member_notes, fn notes -> notes ++ [native] end))
    %{f | record: updated}
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
