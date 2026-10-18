defmodule SymphonyElixir.TaskControl do
  @moduledoc """
  Resolve native plan/member controls independently of the sealed execution grant.

  Only unchanged decisions by the corresponding sealed authorizer are interpreted.
  Observed source receipts survive restart; absence never means implicit resume.
  """
  alias SymphonyElixir.{TaskDecision, TaskWorkflow, WorkRef}

  @markers %{parent: "symphony-plan-decision", member: "symphony-task-decision", acceptance: "symphony-task-acceptance"}

  @doc "Resolve the latest explicit parent approval without treating a pause or resume as a new grant."
  @spec authority(map(), map()) :: {:ok, map()} | {:error, atom()}
  def authority(root, plan) do
    with true <- root.raw["state"] in ["open", "opened"] or {:error, :parent_not_open},
         {:ok, events} <- decisions(root, plan["authorizer"], :parent),
         {:ok, event} <- latest_authorization(events),
         true <- event["revision"] == plan["revision"] or {:error, :plan_decision_revision_mismatch} do
      {:ok, %{"work" => root.work, "source" => event["note_source"], "actor" => plan["authorizer"], "revision" => plan["revision"]}}
    end
  end

  @doc "Read parent and own-member controls, preserving exact source receipts and separate pause identities."
  @spec observe(map(), map(), map()) :: {:ok, map()} | {:error, atom()}
  def observe(preflight, work, previous \\ %{}) do
    with :ok <- WorkRef.validate(work),
         {:ok, events} <- applicable(preflight, work),
         {:ok, released} <- releases(events),
         true <- Enum.all?(events, &(historical?(&1, released) or current?(&1, preflight, work))) or {:error, :control_revision_mismatch},
         receipts = Map.new(events, &{&1["id"], &1["source"]}),
         true <- receipts?(previous) or {:error, :invalid_control_receipts},
         true <- Enum.all?(previous, fn {id, source} -> receipts[id] == source end) or {:error, :control_source_unconfirmed} do
      restrictions =
        events
        |> Enum.filter(&(&1["action"] in ["pause", "cancel"] and &1["source"] not in released))
        |> Enum.map(&%{"id" => &1["id"], "kind" => &1["action"], "source" => &1["source"], "scope" => "task"})

      releases =
        events
        |> Enum.filter(&(&1["action"] == "resume"))
        |> Enum.map(fn event ->
          prior = Enum.find(events, &(&1["source"] == event["restriction"]))
          %{"id" => prior["id"], "restriction_source" => prior["source"], "source" => event["source"]}
        end)

      {:ok, %{restrictions: restrictions, releases: releases, sources: Map.values(receipts), receipts: receipts}}
    end
  end

  @doc "Combine persisted observation receipts with the prior projection without hiding conflicting versions."
  @spec recorded(map()) :: map() | nil
  def recorded(runtime) do
    observed = Map.get(runtime, "control_receipts", %{})

    projected =
      case runtime["workflow"] do
        nil -> %{}
        %{} = flow -> Map.get(flow, "control_receipts", %{})
        _ -> nil
      end

    if receipts?(observed) and receipts?(projected) and Enum.all?(observed, fn {id, source} -> not Map.has_key?(projected, id) or projected[id] == source end),
      do: Map.merge(observed, projected)
  end

  @doc """
  Read the designated acceptor's candidate-bound acceptance for a gated member.

  Only a decision bound to the member's current sealed contract counts; absence is
  waiting, never implicit acceptance. Technical members have no separate acceptor.
  """
  @spec acceptance(map(), map()) :: {:ok, map() | nil} | {:error, atom()}
  def acceptance(snapshot, contract) do
    with true <- contract["acceptance_mode"] == "separate",
         {:ok, events} <- decisions(snapshot, contract["acceptor"], :acceptance) do
      acceptance_from(events, contract)
    else
      false -> {:ok, nil}
      {:error, _} = error -> error
    end
  end

  defp acceptance_from(events, contract) do
    case events |> Enum.filter(&(&1["contract_sha"] == contract["contract_sha"])) |> Enum.sort_by(& &1["at"], :desc) do
      [] -> {:ok, nil}
      [%{"at" => at}, %{"at" => at} | _] -> {:error, :ambiguous_task_acceptance}
      [event | _] -> {:ok, %{"actor" => contract["acceptor"], "source" => event["source"], "candidate" => event["candidate"]}}
    end
  end

  defp applicable(preflight, work) do
    with {:ok, root} <- decisions(preflight.parent, preflight.plan["authorizer"], :parent),
         {:ok, member} <- member_decisions(preflight, work) do
      {:ok, Enum.reject(root, &(&1["action"] == "authorize")) ++ member}
    end
  end

  defp member_decisions(%{plan: %{"parent" => work}}, work), do: {:ok, []}

  defp member_decisions(preflight, work) do
    case preflight.members[WorkRef.key(work)] do
      %{work: ^work, contract: contract} = member -> decisions(member, contract["authorizer"], :member)
      _ -> {:error, :missing_plan_member}
    end
  end

  defp current?(event, preflight, work) do
    event["revision"] == preflight.plan["revision"] and
      (event["work"] == preflight.plan["parent"] or event["contract_sha"] == preflight.members[WorkRef.key(work)].contract["contract_sha"])
  end

  # A released restriction and the resume that released it are history, not live
  # controls: an older plan revision cannot keep blocking a later authorized one
  # through a pair the corresponding authorizer already closed.
  defp historical?(event, released), do: event["source"] in released or event["action"] == "resume"

  defp decisions(snapshot, actor, scope) do
    marker = Map.fetch!(@markers, scope)

    snapshot.notes
    |> Enum.filter(&(&1["system"] != true and String.contains?(&1["body"], "<!-- " <> marker)))
    |> Enum.reduce_while({:ok, []}, fn note, {:ok, acc} ->
      case decision(note, snapshot.work, actor, scope, marker) do
        {:ok, event} -> {:cont, {:ok, [event | acc]}}
        :foreign -> {:cont, {:ok, acc}}
        error -> {:halt, error}
      end
    end)
    |> unique()
  end

  defp decision(note, work, actor, scope, marker) do
    native_actor = get_in(note, ["author", "id"])

    cond do
      not is_integer(native_actor) or native_actor <= 0 -> {:error, :unknown_control_actor}
      to_string(native_actor) != actor -> :foreign
      true -> parse(note, work, scope, marker)
    end
  end

  defp parse(note, work, scope, marker) do
    expression = Regex.compile!("(?:^|\\n)<!-- " <> marker <> "\\s+(\\{.*?\\})\\s*-->\\s*$", "s")

    with true <- is_integer(note["id"]) and note["id"] > 0,
         at when is_integer(at) <- TaskDecision.timestamp(note["created_at"]),
         true <- at == TaskDecision.timestamp(note["updated_at"]),
         [[_, json]] <- Regex.scan(expression, note["body"]),
         {:ok, payload} <- Jason.decode(json),
         true <- payload?(payload, scope) do
      note_source = TaskDecision.source_ref(note)
      id = WorkRef.key(work) <> ":note:" <> to_string(note["id"])
      source = "control:" <> TaskWorkflow.digest(%{"work" => work, "source" => note_source})
      {:ok, Map.merge(payload, %{"id" => id, "source" => source, "note_source" => note_source, "at" => at, "work" => work})}
    else
      _ -> {:error, :unconfirmed_native_control}
    end
  end

  defp payload?(%{"action" => "accept"} = payload, :acceptance) do
    Enum.sort(Map.keys(payload)) == ["action", "candidate", "contract_sha"] and Enum.all?(Map.values(payload), &text?/1)
  end

  defp payload?(%{"action" => action, "revision" => revision} = payload, scope) do
    fields = ~w(action revision) ++ if(scope == :member, do: ["contract_sha"], else: [])
    fields = fields ++ if(action == "resume", do: ["restriction"], else: [])
    actions = if scope == :parent, do: ~w(authorize pause cancel resume), else: ~w(pause cancel resume)
    action in actions and text?(revision) and Enum.sort(Map.keys(payload)) == Enum.sort(fields) and Enum.all?(Map.values(payload), &text?/1)
  end

  defp payload?(_, _), do: false

  defp unique({:ok, events}) do
    if length(Enum.uniq_by(events, & &1["id"])) == length(events),
      do: {:ok, events},
      else: {:error, :duplicate_control_source}
  end

  defp unique(error), do: error

  defp latest_authorization(events) do
    case Enum.filter(events, &(&1["action"] == "authorize")) |> Enum.sort_by(& &1["at"], :desc) do
      [] -> {:error, :missing_plan_authorization}
      [%{"at" => at}, %{"at" => at} | _] -> {:error, :ambiguous_plan_authorization}
      [event | _] -> {:ok, event}
    end
  end

  defp releases(events) do
    Enum.reduce_while(events, {:ok, []}, fn
      %{"action" => "resume"} = event, {:ok, acc} ->
        prior = Enum.find(events, &(&1["source"] == event["restriction"]))

        if is_map(prior) and prior["action"] == "pause" and prior["work"] == event["work"] and prior["at"] < event["at"],
          do: {:cont, {:ok, [prior["source"] | acc]}},
          else: {:halt, {:error, :unresolved_control_release}}

      _, result ->
        {:cont, result}
    end)
  end

  defp receipts?(receipts) when is_map(receipts), do: Enum.all?(receipts, fn {id, source} -> text?(id) and text?(source) end)
  defp receipts?(_), do: false
  defp text?(value), do: is_binary(value) and String.trim(value) != ""
end
