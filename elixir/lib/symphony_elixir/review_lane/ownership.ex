defmodule SymphonyElixir.ReviewLane.Ownership do
  @moduledoc """
  Single-owner resolution for one native review candidate (§11.1).

  A PR/MR whose candidate envelope proves an authorized development task is
  verified by the task lifecycle. The standalone lane must not publish a
  competing technical conclusion for the same candidate, and a candidate with
  more than one task claim is reported as a conflict that needs a human
  decision instead of running both paths.

  Ownership requires the native plan grant, the configured engine actor, a
  journal publication receipt and the current change head. An unreadable
  native source leaves ownership unknown and prevents competing dispatch.
  """

  alias SymphonyElixir.{Config, Execution, ExecutionBinding, NativeWork, RunJournal, TaskControl, TaskPlan}
  alias SymphonyElixir.{TaskPublication, TaskReconciler, TaskWorkflow, WorkRef}
  alias SymphonyElixir.Tracker.Issue

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
    {claims, uncertain} = if MapSet.size(candidates) == 0, do: {%{}, false}, else: claims(members, candidates, opts)
    conflicts = conflicts(claims)

    {Enum.map(members, &resolve_member(&1, conflicts, uncertain)), Enum.map(reviews, &resolve_review(&1, claims, uncertain))}
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
    Enum.reduce(members, {%{}, false}, fn issue, {found, uncertain} ->
      case claimed(issue, candidates, opts) do
        {:ok, claims} -> {Map.merge(found, claims, fn _key, left, right -> left ++ right end), uncertain}
        {:error, _reason} -> {found, true}
      end
    end)
  end

  defp claimed(issue, candidates, opts) do
    with {:ok, claims} <- member_claims(issue, candidates, opts) do
      {:ok, claims |> Enum.filter(&MapSet.member?(candidates, &1["key"])) |> Enum.group_by(& &1["key"])}
    end
  end

  defp member_claims(%Issue{id: id, native_ref: %{"execution_kind" => "plan_member", "work" => work, "parent" => parent}}, candidate_keys, opts) do
    with :ok <- WorkRef.validate(work),
         :ok <- WorkRef.validate(parent),
         {:ok, root} <- NativeWork.read(parent, opts),
         {:ok, plan} <- TaskPlan.parse(root.description),
         true <- plan["parent"] == parent,
         {:ok, grant} <- TaskControl.authority(root, plan),
         {:ok, snapshot} <- NativeWork.read(work, opts),
         %{} = contract <- TaskReconciler.description_contract(snapshot.description),
         {:ok, repository} <- repository(work, opts),
         %{"policy" => %{"engine_actor" => actor} = policy} <- repository["execution"],
         true <- is_binary(actor) and actor != "",
         {:ok, journal} <- journal(work, opts),
         {:ok, %{} = journal} <- present_journal(journal),
         true <- journal["issue_id"] == WorkRef.key(work),
         {:ok, ^journal} <- ExecutionBinding.bind(journal, journal["execution_binding"]),
         {:ok, results} <- TaskPublication.observe(journal, snapshot, actor),
         {:ok, current} <- current_candidate(results, journal, plan, grant, contract, root.notes, policy, work),
         {:ok, found} <- candidates(current, candidate_keys, id, work, opts),
         {:ok, parent_after} <- NativeWork.read(parent, opts),
         true <- NativeWork.snapshot_ref(root) == NativeWork.snapshot_ref(parent_after),
         {:ok, member_after} <- NativeWork.read(work, opts),
         true <- NativeWork.snapshot_ref(snapshot) == NativeWork.snapshot_ref(member_after) do
      {:ok, found}
    else
      {:no_publication, nil} -> {:ok, []}
      {:error, _} = error -> error
      _ -> {:error, :review_ownership_unconfirmed}
    end
  end

  defp member_claims(%Issue{native_ref: %{"execution_kind" => "plan_member"}}, _candidate_keys, _opts), do: {:error, :member_identity_unavailable}
  defp member_claims(_issue, _candidate_keys, _opts), do: {:ok, []}

  defp repository(work, opts) do
    catalog = Keyword.get_lazy(opts, :repositories, fn -> Config.settings!().tracker.provider["plan_repositories"] || [] end)
    NativeWork.resolve(work, catalog)
  end

  defp journal(work, opts) do
    root = Keyword.get_lazy(opts, :journal_root, &Execution.journal_root/0)
    RunJournal.read(RunJournal.directory(root, WorkRef.key(work)))
  end

  defp present_journal(nil), do: {:no_publication, nil}
  defp present_journal(journal), do: {:ok, journal}

  defp current_candidate(results, journal, plan, grant, contract, notes, policy, work) do
    candidates = Enum.filter(results, &(&1.envelope["kind"] == "candidate"))

    case latest_candidate(candidates) do
      {:ok, nil} ->
        {:ok, nil}

      {:ok, selected} ->
        if authenticated?(selected, journal, plan, grant, contract, notes, policy, work),
          do: {:ok, selected},
          else: {:ok, nil}

      error ->
        error
    end
  end

  defp latest_candidate([]), do: {:ok, nil}

  defp latest_candidate(candidates) do
    generation = candidates |> Enum.map(& &1.envelope["generation"]) |> Enum.max()

    case Enum.filter(candidates, &(&1.envelope["generation"] == generation)) do
      [selected] -> {:ok, selected}
      _ -> {:error, :ambiguous_current_candidate}
    end
  end

  defp authenticated?(%{receipt: %{} = receipt, envelope: envelope}, journal, plan, grant, contract, notes, policy, work) do
    binding = envelope["binding"]

    receipt["work"] == work and envelope["actor"] == policy["engine_actor"] and
      valid_binding?(binding, plan, grant, contract, notes, policy, work) and
      execution_matches?(journal, binding, envelope)
  end

  defp authenticated?(_, _, _, _, _, _, _, _), do: false

  defp valid_binding?(binding, plan, grant, contract, notes, policy, work) do
    binding["role"] == "developer" and binding["work"] == work and
      binding["contract_sha"] == contract["contract_sha"] and
      binding["policy_sha"] == TaskWorkflow.digest(policy) and
      TaskPlan.compatible_binding?(plan, grant, binding, work, notes)
  end

  defp execution_matches?(journal, binding, envelope) do
    Enum.any?([journal | journal["execution_history"] || []], fn record ->
      record["execution_binding"] == binding and record["execution_generation"] == envelope["generation"] and
        record["thread_id"] == envelope["thread_id"]
    end)
  end

  defp candidates(nil, _candidate_keys, _id, _work, _opts), do: {:ok, []}

  # TaskPublication.observe accepts candidate entries only with a list of map artifacts.
  defp candidates(%{envelope: %{"payload" => %{"artifacts" => artifacts}}}, candidate_keys, id, work, opts),
    do: Enum.reduce_while(artifacts, {:ok, []}, &add_claim(&1, &2, candidate_keys, id, work, opts))

  defp add_claim(artifact, {:ok, found}, candidate_keys, id, work, opts) do
    if candidate_artifact?(artifact, candidate_keys) do
      target = artifact["target"]

      case NativeWork.read_change(target, opts) do
        {:ok, change} -> {:cont, {:ok, maybe_claim(found, artifact, change, id, work)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    else
      {:cont, {:ok, found}}
    end
  end

  defp candidate_artifact?(artifact, candidate_keys) do
    target = artifact["target"]
    artifact["kind"] in @kinds and WorkRef.validate(target) == :ok and MapSet.member?(candidate_keys, WorkRef.key(target))
  end

  defp maybe_claim(found, artifact, %{facts: %{"head" => head}}, id, work) do
    if head == artifact["version"] do
      target = artifact["target"]
      [%{"key" => WorkRef.key(target), "member" => id, "work" => work, "candidate" => target} | found]
    else
      found
    end
  end

  defp conflicts(claims) do
    claims
    |> Enum.filter(fn {_key, group} -> group |> Enum.map(& &1["member"]) |> Enum.uniq() |> length() > 1 end)
    |> Enum.flat_map(fn {_key, group} -> Enum.map(group, &{&1["member"], conflict(group)}) end)
    |> Map.new()
  end

  defp conflict(group) do
    Map.put(ambiguous(), "tasks", group |> Enum.map(& &1["member"]) |> Enum.uniq() |> Enum.sort())
  end

  defp ambiguous,
    do: %{"owner" => "conflict", "reason" => "candidate_ownership_ambiguous", "resolution" => "requires_human_decision"}

  defp resolve_member(%Issue{} = issue, conflicts, uncertain) do
    cond do
      conflicts[issue.id] ->
        restrict(issue, conflicts[issue.id])

      uncertain and get_in(issue.native_ref, ["execution_kind"]) == "plan_member" ->
        restrict(issue, %{"owner" => "unknown", "reason" => "candidate_ownership_unconfirmed"})

      true ->
        issue
    end
  end

  defp resolve_review(%Issue{native_ref: %{"work" => work}} = issue, claims, uncertain) when is_map(work) do
    cond do
      WorkRef.validate(work) != :ok -> unavailable(issue)
      uncertain -> restrict(issue, %{"owner" => "unknown", "reason" => "candidate_ownership_unconfirmed", "candidate" => work})
      true -> decide(issue, work, Map.get(claims, WorkRef.key(work), []))
    end
  end

  defp resolve_review(issue, _claims, _uncertain), do: unavailable(issue)

  defp decide(issue, work, claims) do
    case Enum.uniq_by(claims, & &1["member"]) do
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
