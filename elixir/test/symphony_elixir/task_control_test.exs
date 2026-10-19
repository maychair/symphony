defmodule SymphonyElixir.TaskControlTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.{TaskControl, TaskWorkflow, WorkRef}

  defp fixture do
    parent = %{"provider" => "github", "host" => "github.test", "repository_id" => "10", "kind" => "issue", "number" => 1}
    child = %{"provider" => "gitlab", "host" => "gitlab.test", "repository_id" => "20", "kind" => "issue", "number" => 1}
    revision = TaskWorkflow.digest("plan")
    contract = %{"contract_sha" => TaskWorkflow.digest("child scope"), "authorizer" => "2"}

    %{
      plan: %{"parent" => parent, "revision" => revision, "authorizer" => "1"},
      parent: %{work: parent, raw: %{"state" => "open"}, notes: []},
      members: %{WorkRef.key(child) => %{work: child, contract: contract, notes: []}}
    }
  end

  defp child(fixture), do: hd(Map.values(fixture.members)).work

  defp note(fixture, scope, action, id, extra \\ %{}) do
    member = hd(Map.values(fixture.members))
    marker = if scope == :parent, do: "plan", else: "task"
    actor = if scope == :parent, do: 1, else: 2
    payload = %{"action" => action, "revision" => fixture.plan["revision"]}
    payload = if scope == :member, do: Map.put(payload, "contract_sha", member.contract["contract_sha"]), else: payload
    timestamp = DateTime.from_unix!(1_792_200_000 + id) |> DateTime.to_iso8601()

    %{
      "id" => id,
      "author" => %{"id" => actor},
      "created_at" => timestamp,
      "updated_at" => timestamp,
      "body" => "Human-readable decision\n<!-- symphony-#{marker}-decision " <> Jason.encode!(Map.merge(payload, extra)) <> " -->"
    }
  end

  defp parent_notes(fixture, notes), do: put_in(fixture.parent.notes, notes)
  defp child_notes(fixture, notes), do: put_in(fixture.members[WorkRef.key(child(fixture))].notes, notes)
  defp observe(fixture, previous \\ %{}), do: TaskControl.observe(fixture, child(fixture), previous)

  test "approval remains the same grant across a pause and an explicitly bound resume" do
    f = fixture()
    approval = note(f, :parent, "authorize", 1)
    pause = note(f, :parent, "pause", 2)
    f = parent_notes(f, [approval, pause])
    assert {:ok, authority} = TaskControl.authority(f.parent, f.plan)
    assert {:ok, paused} = observe(f)
    assert [%{"kind" => "pause", "source" => source}] = paused.restrictions
    resume = note(f, :parent, "resume", 3, %{"restriction" => source})
    f = parent_notes(f, [resume, approval, pause])
    assert {:ok, ^authority} = TaskControl.authority(f.parent, f.plan)
    assert {:ok, resumed} = observe(f, paused.receipts)
    assert resumed.restrictions == []
    assert [%{"restriction_source" => ^source}] = resumed.releases
    assert map_size(resumed.receipts) == 2
  end

  test "a released historical control cannot keep blocking a later approved plan revision" do
    f = fixture()
    authorize = note(f, :parent, "authorize", 1)
    pause = note(f, :parent, "pause", 2)
    f = parent_notes(f, [authorize, pause])
    assert {:ok, paused} = observe(f)
    resume = note(f, :parent, "resume", 3, %{"restriction" => hd(paused.sources)})
    f = parent_notes(f, [authorize, pause, resume])
    assert {:ok, %{restrictions: []}} = observe(f)

    second = TaskWorkflow.digest("plan v2")
    f = put_in(f.plan["revision"], second)
    f = parent_notes(f, [note(f, :parent, "authorize", 4), pause, resume])
    assert {:ok, authority} = TaskControl.authority(f.parent, f.plan)
    assert authority["revision"] == second
    assert {:ok, controls} = observe(f)
    assert controls.restrictions == []
    assert [%{"restriction_source" => source}] = controls.releases
    assert source == hd(paused.sources)
  end

  test "an unreleased control bound to a superseded revision still blocks" do
    f = fixture()
    pause = note(f, :parent, "pause", 2)
    f = put_in(f.plan["revision"], TaskWorkflow.digest("plan v2"))
    f = parent_notes(f, [note(f, :parent, "authorize", 3), pause])
    assert {:ok, _authority} = TaskControl.authority(f.parent, f.plan)
    assert {:error, :control_revision_mismatch} = observe(f)
  end

  test "parent and member note numbers cannot collide and child resume cannot clear a parent pause" do
    f = fixture()
    f = f |> parent_notes([note(f, :parent, "pause", 1)]) |> child_notes([note(f, :member, "pause", 1)])
    assert {:ok, controls} = observe(f)
    assert length(Enum.uniq(controls.sources)) == 2
    assert map_size(controls.receipts) == 2
    assert {:ok, parent_controls} = TaskControl.observe(f, f.plan["parent"])
    assert length(parent_controls.restrictions) == 1
    source = hd(parent_controls.sources)
    f = child_notes(f, [note(f, :member, "resume", 2, %{"restriction" => source})])
    assert {:error, :unresolved_control_release} = observe(f)
  end

  test "resuming one of several pauses does not release the others or independent sibling work" do
    f = fixture()
    pauses = [note(f, :member, "pause", 1), note(f, :member, "pause", 2)]
    f = child_notes(f, pauses)
    assert {:ok, paused} = observe(f)
    source = hd(paused.restrictions)["source"]
    f = child_notes(f, pauses ++ [note(f, :member, "resume", 3, %{"restriction" => source})])
    assert {:ok, resumed} = observe(f)
    assert length(resumed.restrictions) == 1
    refute hd(resumed.restrictions)["source"] == source

    sibling = %{child(f) | "number" => 2}
    member = %{hd(Map.values(f.members)) | work: sibling, notes: []}
    f = put_in(f.members[WorkRef.key(sibling)], member)
    assert {:ok, %{restrictions: []}} = TaskControl.observe(f, sibling)
  end

  test "known pause and resume receipts must both survive source readback" do
    f = fixture()
    pause = note(f, :parent, "pause", 1)
    f = parent_notes(f, [pause])
    assert {:ok, paused} = observe(f)
    resume = note(f, :parent, "resume", 2, %{"restriction" => hd(paused.sources)})
    f = parent_notes(f, [pause, resume])
    assert {:ok, resumed} = observe(f, paused.receipts)

    for notes <- [[pause], [resume], [], [%{pause | "body" => "Deleted decision"}, resume]] do
      assert {:error, _} = observe(parent_notes(f, notes), resumed.receipts)
    end

    assert {:error, :invalid_control_receipts} = observe(f, [])
    assert {:error, :invalid_control_receipts} = observe(f, %{"id" => nil})
    assert {:error, :control_source_unconfirmed} = observe(f, %{"missing" => "source"})
  end

  test "cancel, unknown sources, future pauses and timestamp ties cannot be resumed" do
    for action <- ["pause", "cancel"], resume_id <- [1, 2, 3] do
      f = fixture()
      pause = note(f, :parent, action, 2)
      f = parent_notes(f, [pause])
      assert {:ok, controls} = observe(f)
      resume = note(f, :parent, "resume", resume_id, %{"restriction" => hd(controls.sources)})
      f = parent_notes(f, [pause, Map.put(resume, "id", 10)])

      if action == "pause" and resume_id == 3 do
        assert {:ok, %{restrictions: []}} = observe(f)
      else
        assert {:error, :unresolved_control_release} = observe(f)
      end
    end

    f = fixture()
    assert {:error, :unresolved_control_release} = observe(parent_notes(f, [note(f, :parent, "resume", 1, %{"restriction" => "unknown"})]))
  end

  test "foreign actors, ordinary replies and system notices never control execution" do
    f = fixture()

    notes = [
      Map.put(note(f, :parent, "pause", 1), "author", %{"id" => 99}),
      Map.put(note(f, :parent, "pause", 2), "system", true),
      Map.put(note(f, :parent, "pause", 3), "body", "Looks good, please continue")
    ]

    assert {:ok, %{restrictions: [], receipts: receipts}} = observe(parent_notes(f, notes))
    assert receipts == %{}
    # A parent authorizer has no implicit identity on another provider.
    foreign = Map.put(note(f, :member, "pause", 1), "author", %{"id" => 1})
    assert {:ok, %{restrictions: []}} = observe(child_notes(f, [foreign]))
  end

  test "unknown actors, edited or malformed decision sources fail closed" do
    f = fixture()
    pause = note(f, :parent, "pause", 1)

    for changes <- [
          %{"author" => %{}},
          %{"id" => 0},
          %{"created_at" => "unknown"},
          %{"updated_at" => "2026-10-18T00:00:00Z"},
          %{"body" => "<!-- symphony-plan-decision broken -->"},
          %{"body" => "<!-- symphony-plan-decision {} -->"},
          %{"body" => "<!-- symphony-plan-decision {invalid} -->"},
          %{"body" => pause["body"] <> "\ntrailing content"},
          %{"body" => pause["body"] <> "\n" <> pause["body"]}
        ] do
      assert {:error, _} = observe(parent_notes(f, [Map.merge(pause, changes)]))
    end

    assert {:error, :duplicate_control_source} = observe(parent_notes(f, [pause, pause]))
  end

  test "unrecognized actions, extra keys and changed plan or member revisions are not silently discarded" do
    f = fixture()

    for {scope, action, extra, error} <- [
          {:parent, "approve", %{}, :unconfirmed_native_control},
          {:parent, "pause", %{"extra" => "field"}, :unconfirmed_native_control},
          {:parent, "pause", %{"revision" => "different"}, :control_revision_mismatch},
          {:parent, "pause", %{"revision" => nil}, :unconfirmed_native_control},
          {:member, "authorize", %{}, :unconfirmed_native_control},
          {:member, "pause", %{"contract_sha" => "different"}, :control_revision_mismatch},
          {:member, "resume", %{}, :unconfirmed_native_control}
        ] do
      value = note(f, scope, action, 1, extra)
      changed = if scope == :parent, do: parent_notes(f, [value]), else: child_notes(f, [value])
      assert {:error, ^error} = observe(changed)
    end
  end

  test "authority uses the latest unambiguous unchanged approval, never a later control as authorization" do
    f = fixture()
    assert {:error, :missing_plan_authorization} = TaskControl.authority(f.parent, f.plan)
    pause = note(f, :parent, "pause", 3)
    assert {:error, :missing_plan_authorization} = TaskControl.authority(parent_notes(f, [pause]).parent, f.plan)
    approval = note(f, :parent, "authorize", 1)
    newer = note(f, :parent, "authorize", 2)
    root = parent_notes(f, [newer, pause, approval]).parent
    assert {:ok, authority} = TaskControl.authority(root, f.plan)
    assert String.starts_with?(authority["source"], "note:2@")
    assert {:error, :parent_not_open} = TaskControl.authority(put_in(root.raw["state"], "closed"), f.plan)
    assert {:error, :plan_decision_revision_mismatch} = TaskControl.authority(root, Map.put(f.plan, "revision", "changed"))
    tied = %{newer | "id" => 20}
    assert {:error, :ambiguous_plan_authorization} = TaskControl.authority(%{root | notes: [newer, tied]}, f.plan)
    edited = %{newer | "updated_at" => pause["updated_at"]}
    assert {:error, :unconfirmed_native_control} = TaskControl.authority(%{root | notes: [approval, edited]}, f.plan)
  end

  test "work outside the approved membership cannot inherit controls" do
    f = fixture()
    assert {:error, :missing_plan_member} = TaskControl.observe(f, %{child(f) | "number" => 999})
    assert {:error, :invalid_work_ref} = TaskControl.observe(f, %{})
  end

  test "publisher observations and prior projections cannot hide conflicting source versions" do
    assert TaskControl.recorded(%{}) == %{}

    assert TaskControl.recorded(%{"control_receipts" => %{"p" => "pause"}, "workflow" => %{"control_receipts" => %{"p" => "pause", "r" => "resume"}}}) ==
             %{"p" => "pause", "r" => "resume"}

    for runtime <- [
          %{"control_receipts" => []},
          %{"workflow" => []},
          %{"workflow" => %{"control_receipts" => nil}},
          %{"workflow" => %{"control_receipts" => []}},
          %{"control_receipts" => %{"p" => "old"}, "workflow" => %{"control_receipts" => %{"p" => "new"}}}
        ] do
      assert is_nil(TaskControl.recorded(runtime))
    end
  end

  test "a gated member is accepted only by the designated acceptor against the current contract" do
    f = fixture()
    work = child(f)
    sha = TaskWorkflow.digest("child scope")
    candidate = TaskWorkflow.digest("candidate")
    contract = %{"contract_sha" => sha, "acceptance_mode" => "separate", "acceptor" => "7"}
    snapshot = fn notes -> %{work: work, notes: notes} end

    assert {:ok, nil} = TaskControl.acceptance(snapshot.([note(f, :member, "pause", 1)]), Map.merge(contract, %{"acceptance_mode" => "technical", "acceptor" => nil}))
    assert {:ok, nil} = TaskControl.acceptance(snapshot.([]), contract)
    assert {:ok, nil} = TaskControl.acceptance(snapshot.([acceptance_note(8, 1, sha, candidate)]), contract)
    assert {:ok, nil} = TaskControl.acceptance(snapshot.([acceptance_note(7, 1, TaskWorkflow.digest("old scope"), candidate)]), contract)

    accepted = acceptance_note(7, 1, sha, candidate)
    assert {:ok, %{"actor" => "7", "candidate" => ^candidate, "source" => source}} = TaskControl.acceptance(snapshot.([accepted]), contract)
    assert String.starts_with?(source, "control:")

    tied = %{acceptance_note(7, 2, sha, candidate) | "created_at" => accepted["created_at"], "updated_at" => accepted["updated_at"]}
    assert {:error, :ambiguous_task_acceptance} = TaskControl.acceptance(snapshot.([accepted, tied]), contract)

    extra = Jason.encode!(%{"action" => "accept", "candidate" => "x", "contract_sha" => "y", "extra" => "z"})
    malformed = %{accepted | "body" => "Acceptance\n<!-- symphony-task-acceptance " <> extra <> " -->"}
    assert {:error, :unconfirmed_native_control} = TaskControl.acceptance(snapshot.([malformed]), contract)

    unknown = put_in(accepted, ["author", "id"], 0)
    assert {:error, :unknown_control_actor} = TaskControl.acceptance(snapshot.([unknown]), contract)
  end

  defp acceptance_note(actor, id, contract_sha, candidate) do
    timestamp = DateTime.from_unix!(1_792_200_000 + id) |> DateTime.to_iso8601()
    payload = %{"action" => "accept", "candidate" => candidate, "contract_sha" => contract_sha}

    %{
      "id" => id,
      "author" => %{"id" => actor},
      "created_at" => timestamp,
      "updated_at" => timestamp,
      "body" => "Acceptance\n<!-- symphony-task-acceptance " <> Jason.encode!(payload) <> " -->"
    }
  end

  defp short_note(fixture, label, id) do
    payload = %{
      "label" => label,
      "revision" => fixture.plan["revision"],
      "authorizer" => "1",
      "data" => %{"acceptance_items" => ["C2"]}
    }

    body = "候选 #{label}\n" <> SymphonyElixir.TaskDecision.candidate_block(payload)
    %{note(fixture, :parent, "authorize", id) | "body" => body}
  end

  defp reply(fixture, body, id), do: %{note(fixture, :parent, "authorize", id) | "body" => body}

  test "readable approval binds native candidate evidence and survives receipt replay" do
    f = fixture()
    candidate = short_note(f, "P1", 1)
    human = reply(f, "按 P1 执行", 2)
    root = %{f.parent | notes: [candidate, human]}
    assert {:ok, event} = TaskControl.bind_reply(root, human, "1")
    assert event["revision"] == f.plan["revision"]
    assert event["work"] == root.work
    assert event["candidate_source"] == SymphonyElixir.TaskDecision.source_ref(candidate)
    assert is_binary(event["candidate_digest"])
    assert {:ok, nil} = TaskControl.bind_reply(root, human, "1", %{event["id"] => event["source"]})
    assert {:clarify, _} = TaskControl.bind_reply(root, human, "1", %{event["id"] => "changed"})
    assert {:ok, authority} = TaskControl.authority(root, f.plan)
    assert authority["candidate_source"] == event["candidate_source"]
    assert {:ok, %{restrictions: []}} = observe(%{f | parent: root})
    assert {:ok, ^event} = TaskControl.read_binding(root, event)
    assert {:clarify, _} = TaskControl.read_binding(%{root | notes: [candidate]}, event)
    edited = %{human | "body" => "批准 P1"}
    assert {:clarify, _} = TaskControl.read_binding(%{root | notes: [candidate, edited]}, event)
    duplicate = %{root | notes: [candidate, human, human]}
    assert {:ok, %{decisions: [^event], receipts: receipts}} = TaskControl.parent_decisions(duplicate, "1")
    assert {:ok, %{decisions: []}} = TaskControl.parent_decisions(duplicate, "1", receipts)
    assert {:error, :invalid_control_receipts} = TaskControl.parent_decisions(root, "1", [])
    assert {:error, :control_source_unconfirmed} = TaskControl.parent_decisions(root, "1", %{event["id"] => "old"})
  end

  test "replacement material never inherits an earlier reply and ambiguity asks a concrete decision" do
    f = fixture()
    human = reply(f, "按 P1 执行", 2)
    first = short_note(f, "P1", 1)
    second = short_note(f, "P1", 3)

    tied = %{first | "created_at" => human["created_at"], "updated_at" => human["created_at"]}

    for notes <- [[second], [first, second], [%{first | "updated_at" => second["created_at"]}], [tied]] do
      root = %{f.parent | notes: notes ++ [human]}
      assert {:clarify, block} = TaskControl.bind_reply(root, human, "1")
      assert block["target"] == root.work
      assert Enum.all?(~w(evidence reason decision next), &is_binary(block[&1]))
      assert {:error, :needs_clarification} = TaskControl.authority(root, f.plan)
    end
  end

  test "answers require one question and never grant execution" do
    f = fixture()
    first = short_note(f, "Q1", 1)
    second = short_note(f, "Q2", 2)
    root = %{f.parent | notes: [first, second]}
    human = reply(f, "采用方案 B", 3)
    assert {:clarify, _} = TaskControl.bind_reply(root, human, "1")
    assert {:error, :needs_clarification} = TaskControl.parent_decisions(%{root | notes: root.notes ++ [human]}, "1")
    explicit = reply(f, "Q2：采用方案 B", 3)
    assert {:ok, %{"action" => "answer", "label" => "Q2"}} = TaskControl.bind_reply(root, explicit, "1")
    assert {:ok, %{"action" => "answer"}} = TaskControl.bind_reply(%{root | notes: [second]}, human, "1")
    answered = %{root | notes: [first, second, explicit]}
    assert {:error, :missing_plan_authorization} = TaskControl.authority(answered, f.plan)
    assert {:clarify, _} = TaskControl.bind_reply(root, reply(f, "Q1 Q2 采用方案 B", 3), "1")
    assert {:clarify, _} = TaskControl.bind_reply(root, reply(f, "Q2", 3), "1")
    assert {:clarify, _} = TaskControl.bind_reply(root, reply(f, "Q2 是否采用方案 B？", 3), "1")
    missing = %{human | "body" => nil}
    assert {:error, :needs_clarification} = TaskControl.parent_decisions(%{root | notes: root.notes ++ [missing]}, "1")
  end

  test "a new manifest cannot receive an old acceptance even after a restart" do
    f = fixture()
    first = short_note(f, "M1", 1)
    human = reply(f, "M1 验收通过", 2)
    root = %{f.parent | notes: [first, human]}
    assert {:ok, %{decisions: [event], receipts: receipts}} = TaskControl.parent_decisions(root, "1")
    second = short_note(f, "M2", 3)
    changed = %{root | notes: [second, human]}
    assert {:clarify, _} = TaskControl.read_binding(changed, event)
    assert {:error, :needs_clarification} = TaskControl.parent_decisions(changed, "1", receipts)
    assert {:ok, %{decisions: []}} = TaskControl.parent_decisions(root, "1", receipts)
  end

  test "acceptance and rework carry manifest and enumerated unmet criteria without becoming controls" do
    f = fixture()
    root = %{f.parent | notes: [short_note(f, "M2", 1)]}
    accepted = reply(f, "M2 验收通过", 2)
    assert {:ok, %{"action" => "accept", "label" => "M2"}} = TaskControl.bind_reply(root, accepted, "1")
    repair = reply(f, "M2 验收项 C2 未满足，请修复", 3)
    assert {:ok, %{"action" => "rework", "items" => ["C2"]}} = TaskControl.bind_reply(root, repair, "1")
    assert {:ok, %{restrictions: []}} = observe(%{f | parent: %{root | notes: root.notes ++ [accepted, repair]}})
    assert {:clarify, _} = TaskControl.bind_reply(root, reply(f, "M2 请修复", 3), "1")
    unknown = reply(f, "M2 验收项 C3 未满足，请修复", 3)
    assert {:clarify, _} = TaskControl.bind_reply(root, unknown, "1")
    mixed = reply(f, "M2 验收项 C2 未满足，请修复并验收通过", 3)
    assert {:clarify, _} = TaskControl.bind_reply(root, mixed, "1")
  end

  test "readable controls preserve separate pause identities and require a unique resume target" do
    f = fixture()
    candidate = short_note(f, "P1", 1)
    pause = reply(f, "暂停这个计划", 2)
    resume = reply(f, "恢复执行", 3)
    f = parent_notes(f, [candidate, pause, resume])
    assert {:ok, %{restrictions: [], releases: [_]}} = observe(f)
    assert {:error, :unresolved_control_release} = observe(parent_notes(f, [candidate, resume]))

    assert {:error, :unresolved_control_release} =
             observe(parent_notes(f, [candidate, pause, reply(f, "暂停", 3), reply(f, "恢复执行", 4)]))

    cancelled = parent_notes(f, [candidate, reply(f, "取消", 4)])
    assert {:ok, %{restrictions: [%{"kind" => "cancel"}]}} = observe(cancelled)
  end

  test "invalid actor, edited reply, missing or malformed material and mixed intents fail closed" do
    f = fixture()
    candidate = short_note(f, "P1", 1)
    human = reply(f, "按 P1 执行", 2)
    root = %{f.parent | notes: [candidate]}

    for invalid <- [
          put_in(human, ["author", "id"], 9),
          %{human | "id" => 0},
          %{human | "updated_at" => candidate["created_at"]},
          Map.put(human, "system", true),
          %{human | "body" => nil},
          %{human | "body" => "P1 批准并取消"}
        ] do
      assert {:clarify, _} = TaskControl.bind_reply(root, invalid, "1")
    end

    assert {:clarify, _} = TaskControl.bind_reply(%{root | work: %{}}, human, "1")
    assert {:clarify, _} = TaskControl.bind_reply(root, human, "1", [])
    assert {:clarify, _} = TaskControl.bind_reply(root, human, "9")
    assert {:clarify, _} = TaskControl.bind_reply(root, reply(f, "不要按 P1 执行", 2), "1")

    malformed = "<!-- symphony-candidate {\"label\":false,\"revision\":\"x\",\"authorizer\":\"1\"} -->"

    for body <- ["<!-- symphony-candidate {bad} -->", "<!-- symphony-candidate {} -->", malformed] do
      assert {:clarify, _} = TaskControl.bind_reply(%{root | notes: [%{candidate | "body" => body}]}, human, "1")
    end
  end
end
