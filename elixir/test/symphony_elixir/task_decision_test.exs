defmodule SymphonyElixir.TaskDecisionTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.TaskDecision

  defp at(second), do: DateTime.to_iso8601(DateTime.add(~U[2026-10-16 00:00:00Z], second))

  defp note(id, second, action \\ "authorize", data \\ %{"contract_sha" => "sealed"}) do
    %{
      "id" => id,
      "author" => %{"id" => 1},
      "created_at" => at(second),
      "updated_at" => at(second),
      "body" => TaskDecision.candidate_block(%{"action" => action, "contract" => "auth", "data" => data})
    }
  end

  defp label(second, name \\ "symphony:ready") do
    %{"id" => 7, "user" => %{"id" => 1}, "created_at" => at(second), "action" => "add", "label" => %{"name" => name}}
  end

  test "a replay binds the same preceding candidate without a cached flow" do
    first = note(1, 1)
    later = note(2, 5, "authorize", %{"contract_sha" => "new"})
    [event] = TaskDecision.label_events([label(3)], [first, later])
    assert event["data"] == %{"contract_sha" => "sealed"}
    assert event["binding"] == TaskDecision.source_ref(first)
    assert TaskDecision.label_events([label(3)], [later, first]) == [event]
    assert TaskDecision.label_events([label(3)], [later]) == []
    [replacement] = TaskDecision.label_events([label(6)], [first, later])
    assert replacement["data"]["contract_sha"] == "new"
  end

  test "missing actor, invalid identity, removals and unknown labels grant nothing" do
    for invalid <- [
          Map.delete(label(3), "user"),
          put_in(label(3), ["user", "id"], nil),
          put_in(label(3), ["user", "id"], 0),
          Map.put(label(3), "id", "7"),
          Map.put(label(3), "action", "remove"),
          Map.put(label(3), "created_at", "bad"),
          label(3, "type:development"),
          %{}
        ] do
      assert TaskDecision.label_events([invalid], [note(1, 1)]) == []
    end
  end

  test "edits, same-time events, duplicate candidates and missing timestamps require an explicit reference" do
    candidate = note(1, 1)

    for notes <- [
          [Map.put(candidate, "updated_at", at(2))],
          [Map.put(candidate, "updated_at", at(9))],
          [Map.delete(candidate, "created_at")],
          [Map.delete(candidate, "updated_at")],
          [Map.delete(candidate, "author")],
          [Map.delete(candidate, "id")],
          [note(1, 3)],
          [candidate, note(2, 1)],
          [candidate, %{note(2, 1) | "created_at" => "2026-10-16T08:00:01+08:00", "updated_at" => "2026-10-16T08:00:01+08:00"}]
        ] do
      assert TaskDecision.label_events([label(3)], notes) == []
    end
  end

  test "malformed candidate publications cannot silently fall back to an older version" do
    good = note(1, 1)

    for body <- [
          "<!-- symphony-candidate broken -->",
          "<!-- symphony-candidate {} -->",
          "<!-- symphony-candidate {bad} -->",
          TaskDecision.candidate_block(%{"action" => "unknown", "data" => %{}}),
          good["body"] <> "\nDo not approve this quoted proposal.",
          TaskDecision.candidate_block(%{"action" => "authorize", "data" => []}),
          good["body"] <> "\n" <> good["body"]
        ] do
      assert TaskDecision.label_events([label(4)], [good, %{note(2, 2) | "body" => body}]) == []
    end
  end

  test "accept labels bind the published manifest and rework binds explicit criteria" do
    manifest = %{
      "action" => "manifest",
      "contract" => "auth",
      "data" => %{"contract" => "auth", "items" => []}
    }

    publication = %{note(9, 2) | "body" => "<!-- symphony-workflow\n" <> Jason.encode!(manifest) <> "\n-->"}
    [accept] = TaskDecision.label_events([label(3, "symphony:accept")], [publication])
    assert accept["data"] == %{"manifest" => TaskDecision.source_ref(publication)}
    assert accept["contract"] == "auth"
    assert TaskDecision.label_events([label(1, "symphony:accept")], [publication]) == []

    repair = %{"criteria" => ["a"], "changes" => [], "manifest" => TaskDecision.source_ref(publication)}
    [rework] = TaskDecision.label_events([label(5, "symphony:rework")], [note(10, 4, "rework", repair)])
    assert rework["data"] == repair
  end

  test "ordinary comments and system notes are not candidates; profile changes do not version decisions" do
    candidate = note(1, 1)
    comments = [%{note(2, 2) | "body" => "Looks good"}, Map.put(note(3, 2), "system", true), %{note(4, 2) | "body" => "<!-- symphony-workflow {\"action\":\"pause\",\"data\":{}} -->"}]
    assert [_] = TaskDecision.label_events([label(3)], [candidate | comments])
    assert TaskDecision.label_events([label(3)], comments) == []
    assert TaskDecision.source_ref(candidate) == TaskDecision.source_ref(put_in(candidate, ["author", "name"], "New display name"))
    refute TaskDecision.source_ref(candidate) == TaskDecision.source_ref(put_in(candidate, ["author", "id"], 99))
  end
end
