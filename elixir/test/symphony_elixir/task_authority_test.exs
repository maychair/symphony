defmodule SymphonyElixir.TaskAuthorityTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.{TaskAuthority, TaskReconciler, TaskWorkflow}

  setup do
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)
    at = "2026-10-20T02:00:00Z"
    decision = %{"action" => "pause", "contract" => "note:1@" <> String.duplicate("a", 64), "data" => %{}}

    evidence = %{
      "kind" => "codex-user-request",
      "session" => "01a152a2-673a-7223-87fb-a27840146ed4",
      "at" => at,
      "request" => "暂停 #24",
      "request_sha256" => Base.encode16(:crypto.hash(:sha256, "暂停 #24"), case: :lower)
    }

    grant = %{
      "schema" => 1,
      "principal" => "20",
      "publisher" => "194",
      "repository" => "gitlab.test/team/project",
      "issue" => 24,
      "issued_at" => 1_792_461_600,
      "evidence" => evidence,
      "decision" => decision
    }

    signature = :crypto.sign(:eddsa, :none, TaskWorkflow.canonical_json(grant), [private, :ed25519]) |> Base.encode64()
    payload = Map.put(decision, "authority", %{"grant" => grant, "signature" => signature})
    note = %{"id" => 2, "author" => %{"id" => 194}, "created_at" => at, "updated_at" => at, "body" => "Agent relay\n\n<!-- symphony-workflow\n" <> Jason.encode!(payload) <> "\n-->"}
    scope = %{policy: %{"principal" => "20", "publisher" => 194, "public_key" => Base.encode64(public)}, repository: "gitlab.test/team/project", issue: 24, owner: "20"}
    %{note: note, payload: payload, scope: scope, signature: signature}
  end

  test "verified relay preserves publisher and human principal through native replay", c do
    assert TaskAuthority.actor(c.note, c.payload, c.scope) == "20"
    [event] = TaskReconciler.events([c.note], %{}, "20", c.scope)
    assert event["actor"] == "20"
    assert event["publisher"] == "194"
    assert event["action"] == "pause"
    assert TaskReconciler.events([c.note], %{}, "20", c.scope) == [event]
  end

  test "claims and copied, edited, delayed or foreign grants cannot confer authority", c do
    assert TaskAuthority.actor(c.note, Map.delete(c.payload, "authority"), c.scope) == "194"

    for {note, payload, scope} <- [
          {c.note, put_in(c.payload, ["data", "kind"], "cancel"), c.scope},
          {put_in(c.note, ["author", "id"], 20), c.payload, c.scope},
          {Map.put(c.note, "updated_at", "2026-10-20T02:00:01Z"), c.payload, c.scope},
          {Map.merge(c.note, %{"created_at" => "2026-10-20T02:06:00Z", "updated_at" => "2026-10-20T02:06:00Z"}), c.payload, c.scope},
          {c.note, c.payload, %{c.scope | issue: 25}},
          {c.note, c.payload, %{c.scope | repository: "gitlab.test/other/project"}},
          {c.note, c.payload, %{c.scope | owner: "21"}},
          {c.note, put_in(c.payload, ["authority", "signature"], "forged"), c.scope},
          {c.note, c.payload, nil}
        ] do
      assert TaskAuthority.actor(note, payload, scope) == nil
    end

    assert [original] = TaskReconciler.events([Map.put(c.note, "id", 3), c.note], %{}, "20", c.scope)
    assert original["id"] == c.note["id"]
    pinned = %{"relay_sources" => %{original["relay_id"] => original["ref"]}}
    assert TaskReconciler.events([Map.put(c.note, "id", 3)], pinned, "20", c.scope) == []
    assert [_] = TaskReconciler.events([c.note, c.note |> Map.put("id", 3) |> put_in(["author", "id"], 99)], %{}, "20", c.scope)
    malformed = Map.put(c.note, "body", "<!-- symphony-workflow\n{\"action\":\"pause\",\"authority\":42}\n-->")
    assert TaskReconciler.events([malformed], %{}, "20", c.scope) == []
  end

  test "authority policy and malformed remote envelopes fail closed", c do
    assert TaskAuthority.validate(%{provider: %{}, assignee: "20"}) == :ok
    assert TaskAuthority.validate(%{provider: %{"delegated_authority" => c.scope.policy}, assignee: "20"}) == :ok

    for policy <- [
          nil,
          "bad",
          %{},
          Map.put(c.scope.policy, "extra", true),
          Map.put(c.scope.policy, "principal", "21"),
          Map.put(c.scope.policy, "public_key", "bad"),
          Map.put(c.scope.policy, "publisher", 0)
        ] do
      if policy != nil do
        assert TaskAuthority.validate(%{provider: %{"delegated_authority" => policy}, assignee: "20"}) ==
                 {:error, :invalid_delegated_authority}
      end
    end

    for authority <- [nil, false, %{}, %{"grant" => 1, "signature" => 42}, %{"grant" => %{}, "signature" => "bad"}] do
      assert TaskAuthority.actor(c.note, Map.put(c.payload, "authority", authority), c.scope) == nil
    end

    assert TaskAuthority.actor(c.note, put_in(c.payload, ["authority", "grant", "evidence"], %{}), c.scope) == nil

    for {field, value} <- [{"at", "invalid"}, {"session", "forged-session"}, {"request", "forged consent"}] do
      assert TaskAuthority.actor(c.note, put_in(c.payload, ["authority", "grant", "evidence", field], value), c.scope) == nil
    end

    assert TaskAuthority.actor(c.note, c.payload, %{c.scope | policy: Map.put(c.scope.policy, "public_key", Base.encode64(<<0>>))}) == nil
    assert TaskAuthority.actor(c.note, c.payload, %{c.scope | policy: Map.put(c.scope.policy, "public_key", Base.encode64(<<0::256>>))}) == nil
  end

  test "bounded publication skew tolerates native clocks without permitting old replay", c do
    for offset <- [-60, -1, 0, 300] do
      at = DateTime.add(~U[2026-10-20 02:00:00Z], offset) |> DateTime.to_iso8601()
      assert TaskAuthority.actor(Map.merge(c.note, %{"created_at" => at, "updated_at" => at}), c.payload, c.scope) == "20"
    end

    for offset <- [-61, 301] do
      at = DateTime.add(~U[2026-10-20 02:00:00Z], offset) |> DateTime.to_iso8601()
      assert TaskAuthority.actor(Map.merge(c.note, %{"created_at" => at, "updated_at" => at}), c.payload, c.scope) == nil
    end
  end

  test "existing human audit remains verifiable without borrowing identity", c do
    payload = Map.delete(c.payload, "authority")
    assert TaskAuthority.actor(put_in(c.note, ["author", "id"], 20), payload, nil) == "20"
    assert TaskAuthority.actor(put_in(c.note, ["author", "id"], nil), payload, nil) == nil
    assert TaskAuthority.actor(c.note, put_in(c.payload, ["authority", "grant", "evidence", "request"], "伪造"), c.scope) == nil
  end
end
