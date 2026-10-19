defmodule SymphonyElixir.ReviewLane.Ownership do
  @moduledoc """
  Single-owner resolution for one native review candidate (§11.1).

  A PR/MR whose candidate envelope proves an authorized development task is
  verified by the task lifecycle. The standalone lane must not publish a
  competing technical conclusion for the same candidate, and a candidate with
  more than one task claim is reported as a conflict that needs a human
  decision instead of running both paths.

  Ownership comes from native facts only: the engine's own candidate envelope,
  read from the member Issue, names the plan authority the work was executed
  under. Unreadable or absent facts are not evidence of ownership, so they never
  restrict an unrelated review. Only candidates a standalone review actually
  references are resolved, so an ordinary poll does not re-read every member's
  native evidence.
  """

  alias SymphonyElixir.{NativeWork, WorkRef}
  alias SymphonyElixir.Tracker.Issue

  @evidence ~r/\n\n<!-- symphony-evidence (\{[^\n]*\}) -->\n<!-- symphony-engine-notice -->\z/
  @kinds ~w(mr pr)

  @doc """
  Resolve candidate ownership across the discovered standalone reviews and plan members.

  Returns the member and review Issues with a readable `ownership` fact; the
  losing path is not dispatchable and every conflict is exposed as a state that
  needs a human decision.
  """
  @spec converge([Issue.t()], [Issue.t()], keyword()) :: {[Issue.t()], [Issue.t()]}
  def converge([], members, _opts), do: {members, []}

  def converge(reviews, members, opts) do
    candidates = candidate_keys(reviews)
    claims = if MapSet.size(candidates) == 0, do: %{}, else: claims(members, candidates, opts)
    conflicts = conflicts(claims)

    {Enum.map(members, &resolve_member(&1, conflicts)), Enum.map(reviews, &resolve_review(&1, claims))}
  end

  defp candidate_keys(reviews) do
    reviews
    |> Enum.flat_map(fn
      %Issue{native_ref: %{"work" => work}} when is_map(work) -> [work]
      _issue -> []
    end)
    |> Enum.filter(&(WorkRef.validate(&1) == :ok))
    |> Enum.map(&WorkRef.key/1)
    |> MapSet.new()
  end

  defp claims(members, candidates, opts) do
    Enum.reduce(members, %{}, fn issue, found ->
      Map.merge(found, claimed(issue, candidates, opts), fn _key, left, right -> left ++ right end)
    end)
  end

  defp claimed(issue, candidates, opts) do
    issue
    |> member_claims(opts)
    |> Enum.filter(&MapSet.member?(candidates, &1["key"]))
    |> Enum.group_by(& &1["key"])
  end

  defp member_claims(%Issue{id: id, native_ref: %{"execution_kind" => "plan_member", "work" => work}}, opts) do
    with :ok <- WorkRef.validate(work), {:ok, snapshot} <- NativeWork.read(work, opts) do
      snapshot.notes
      |> Enum.flat_map(fn note -> envelope(note["body"]) end)
      |> Enum.filter(&authorized?(&1, work))
      |> Enum.flat_map(&candidates(&1, id, work))
    else
      _error -> []
    end
  end

  defp member_claims(_issue, _opts), do: []

  defp envelope(body) do
    with true <- is_binary(body), [json] <- Regex.run(@evidence, body, capture: :all_but_first) do
      decode(json)
    else
      _missing -> []
    end
  end

  defp decode(json) do
    case Jason.decode(json) do
      {:ok, %{"kind" => "candidate"} = value} -> [value]
      _other -> []
    end
  end

  # A comment carrying the marker is not ownership evidence unless the engine
  # published it for this member under some plan authority.
  defp authorized?(%{"binding" => %{"work" => work, "authority" => %{"work" => authority}}}, work),
    do: WorkRef.validate(authority) == :ok

  defp authorized?(_envelope, _work), do: false

  defp candidates(envelope, id, work) do
    case get_in(envelope, ["payload", "artifacts"]) do
      artifacts when is_list(artifacts) ->
        artifacts
        |> Enum.filter(&(is_map(&1) and &1["kind"] in @kinds and WorkRef.validate(&1["target"]) == :ok))
        |> Enum.map(&claim(&1, envelope, id, work))

      _missing ->
        []
    end
  end

  defp claim(artifact, envelope, id, work) do
    %{
      "key" => WorkRef.key(artifact["target"]),
      "member" => id,
      "work" => work,
      "candidate" => artifact["target"],
      "authority" => envelope["binding"]["authority"],
      "contract_sha" => envelope["binding"]["contract_sha"]
    }
  end

  defp conflicts(claims) do
    claims
    |> Enum.filter(fn {_key, group} -> length(group) > 1 end)
    |> Enum.flat_map(fn {_key, group} -> Enum.map(group, &{&1["member"], conflict(group)}) end)
    |> Map.new()
  end

  defp conflict(group) do
    Map.put(ambiguous(), "tasks", group |> Enum.map(& &1["member"]) |> Enum.uniq() |> Enum.sort())
  end

  defp ambiguous,
    do: %{"owner" => "conflict", "reason" => "candidate_ownership_ambiguous", "resolution" => "requires_human_decision"}

  defp resolve_member(%Issue{} = issue, conflicts) do
    case conflicts[issue.id] do
      nil -> issue
      conflict -> restrict(issue, conflict)
    end
  end

  defp resolve_review(%Issue{native_ref: %{"work" => work}} = issue, claims) when is_map(work) do
    if WorkRef.validate(work) == :ok, do: decide(issue, work, Map.get(claims, WorkRef.key(work), [])), else: unavailable(issue)
  end

  defp resolve_review(issue, _claims), do: unavailable(issue)

  defp decide(issue, work, claims) do
    case claims do
      [] ->
        own(issue, %{"owner" => "review", "reason" => "standalone_review_unclaimed", "candidate" => work})

      [claim] ->
        owned = %{"owner" => "task", "reason" => "candidate_owned_by_task_verification", "candidate" => work, "task" => claim["member"]}
        restrict(issue, owned)

      group ->
        restrict(issue, Map.put(conflict(group), "candidate", work))
    end
  end

  defp unavailable(issue), do: own(issue, %{"owner" => "review", "reason" => "candidate_identity_unavailable"})

  defp own(issue, ownership), do: %{issue | native_ref: Map.put(issue.native_ref || %{}, "ownership", ownership)}

  defp restrict(issue, ownership),
    do: %{issue | dispatchable: false, native_ref: Map.put(issue.native_ref || %{}, "ownership", ownership)}
end
