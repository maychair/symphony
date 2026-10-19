defmodule SymphonyElixir.TaskControl do
  @moduledoc """
  Resolve native plan/member controls independently of the sealed execution grant.

  Only unchanged decisions by the corresponding sealed authorizer are interpreted.
  Observed source receipts survive restart; absence never means implicit resume.

  Short versions use published `symphony-candidate` notes containing `label`,
  `revision`, `authorizer` and the complete candidate `data`. Manifest data lists
  `acceptance_items` for rework. Publishers must keep labels unique within the
  Issue. Consumers persist `parent_decisions/3` receipts and call `read_binding/2`
  with a fresh native snapshot before acting. This module performs no remote writes.
  """
  alias SymphonyElixir.{TaskDecision, TaskWorkflow, WorkRef}

  @markers %{parent: "symphony-plan-decision", member: "symphony-task-decision", acceptance: "symphony-task-acceptance"}

  @doc "Bind an unchanged native reply to one published short version; retained receipts make replay a no-op."
  @spec bind_reply(map(), map(), String.t(), map()) :: {:ok, map() | nil} | {:clarify, map()}
  def bind_reply(snapshot, note, actor, receipts \\ %{}) do
    with :ok <- WorkRef.validate(snapshot.work),
         true <- receipts?(receipts),
         true <- reply_actor?(note, actor) or {:error, :actor_mismatch},
         true <- unchanged?(note) or {:error, :unconfirmed_reply},
         {:ok, action} <- human_action(note["body"]),
         {:ok, candidate} <- reply_candidate(snapshot.notes, note, action, actor),
         {:ok, event} <- bound_reply(snapshot.work, note, candidate, action),
         true <- not Map.has_key?(receipts, event["id"]) or receipts[event["id"]] == event["source"] do
      {:ok, if(Map.has_key?(receipts, event["id"]), do: nil, else: event)}
    else
      {:error, reason} -> {:clarify, clarification(snapshot, note, reason)}
      _ -> {:clarify, clarification(snapshot, note, :source_changed)}
    end
  end

  @doc "Return new parent decisions with stable native receipts, including answers and manifest decisions."
  @spec parent_decisions(map(), String.t(), map()) :: {:ok, map()} | {:error, atom()}
  def parent_decisions(snapshot, actor, previous \\ %{}) do
    with {:ok, events} <- decisions(snapshot, actor, :parent),
         true <- receipts?(previous) or {:error, :invalid_control_receipts},
         receipts = Map.new(events, &{&1["id"], &1["source"]}),
         true <-
           Enum.all?(previous, fn {id, source} -> receipts[id] == source end) or
             {:error, :control_source_unconfirmed} do
      {:ok, %{decisions: Enum.reject(events, &Map.has_key?(previous, &1["id"])), receipts: receipts}}
    end
  end

  @doc "Verify a binding against a newly read native snapshot before consuming its decision."
  @spec read_binding(map(), map()) :: {:ok, map()} | {:clarify, map()}
  def read_binding(snapshot, binding) do
    note = Enum.find(snapshot.notes, &(WorkRef.key(snapshot.work) <> ":note:" <> to_string(&1["id"]) == binding["id"]))

    with %{} <- note,
         {:ok, events} <- decisions(snapshot, binding["actor"], :parent),
         true <- binding in events do
      {:ok, binding}
    else
      _ -> {:clarify, clarification(snapshot, note || %{}, :source_changed)}
    end
  end

  defp reply_actor?(note, actor) do
    native = get_in(note, ["author", "id"])
    is_integer(native) and native > 0 and to_string(native) == actor
  end

  defp clarification(snapshot, note, reason) do
    candidates = Enum.flat_map(snapshot.notes, &short_candidate/1)

    %{
      "target" => snapshot.work,
      "evidence" => TaskDecision.source_ref(note),
      "candidates" => Enum.map(candidates, &candidate_evidence/1),
      "reason" => clarification_reason(reason),
      "decision" => "请由授权人明确引用一个 P/M/Q 短版本；返工请列出未满足的验收项。",
      "next" => "核实原生回复和候选材料后，仅推进该版本对应的动作。"
    }
  end

  defp candidate_evidence(candidate) do
    candidate
    |> Map.take(~w(label revision authorizer))
    |> Map.put("source", TaskDecision.source_ref(candidate["note"]))
    |> Map.put("digest", TaskWorkflow.digest(Map.delete(candidate, "note")))
  end

  defp clarification_reason(:ambiguous_candidate), do: "候选版本不唯一或回复未指明待回答的问题。"
  defp clarification_reason(:actor_mismatch), do: "原生回复的主体与授权人不匹配。"
  defp clarification_reason(:missing_acceptance_items), do: "返工必须明确列出候选材料中的未满足验收项。"
  defp clarification_reason(_), do: "无法核实原生来源、明确意图或候选与决定的事件顺序。"

  defp unchanged?(note) do
    is_integer(note["id"]) and note["id"] > 0 and is_binary(note["body"]) and
      is_integer(TaskDecision.timestamp(note["created_at"])) and note["created_at"] == note["updated_at"] and
      note["system"] != true
  end

  defp human_action(body) when is_binary(body) do
    actions = [
      {"authorize", ~r/^(?:按\s*P\d+\s*执行|批准(?:执行)?(?:\s*P\d+)?|approve(?:\s+P\d+)?)[。.!]?$/iu},
      {"pause", ~r/^(?:P\d+\s*)?(?:暂停(?:这个计划|计划|执行)?|pause)(?:\s*P\d+)?[。.!]?$/iu},
      {"resume", ~r/^(?:P\d+\s*)?(?:恢复(?:执行)?|resume)(?:\s*P\d+)?[。.!]?$/iu},
      {"cancel", ~r/^(?:P\d+\s*)?(?:取消(?:这个计划|计划|执行)?|cancel)(?:\s*P\d+)?[。.!]?$/iu},
      {"accept", ~r/^(?:M\d+\s*(?:验收)?通过|accept\s+M\d+)[。.!]?$/iu},
      {"rework", ~r/^(?:M\d+\s*)?(?:验收项\s*)?(?:C\d+(?:[、,，\s]+C\d+)*\s*未满足[，,；;：:\s]*)?(?:请)?(?:修复|返工|rework)[。.!]?$/iu}
    ]

    case Enum.find(actions, fn {_, pattern} -> Regex.match?(pattern, body) end) do
      {action, _} -> explicit_intent(action, body)
      nil -> explicit_intent("answer", body)
    end
  end

  defp explicit_intent(action, body) do
    answer = body |> String.replace(~r/\bQ[1-9][0-9]*\b/u, "") |> String.trim("：") |> String.trim()
    negative = action != "answer" and Regex.match?(~r/不|否|未通过|勿|别|\bnot\b|don't/iu, body)
    question = Regex.match?(~r/是否|吗|[?？]/u, body)

    if negative or question or (action == "answer" and answer == ""),
      do: {:error, :unclear_intent},
      else: {:ok, action}
  end

  defp reply_candidate(notes, reply, action, actor) do
    prefix = if action in ~w(accept rework), do: "M", else: if(action == "answer", do: "Q", else: "P")
    labels = Regex.scan(~r/\b[PMQ][1-9][0-9]*\b/u, reply["body"]) |> List.flatten() |> Enum.uniq()
    candidates = notes |> Enum.flat_map(&short_candidate/1) |> Enum.filter(&String.starts_with?(&1["label"], prefix))
    selected = if labels == [], do: candidates, else: Enum.filter(candidates, &(&1["label"] in labels))

    case selected do
      [candidate] -> confirm_candidate(candidate, reply, actor, labels)
      _ -> {:error, :ambiguous_candidate}
    end
  end

  defp short_candidate(note) do
    case Regex.run(~r/<!-- symphony-candidate\s+(\{.*?\})\s*-->\s*$/s, note["body"] || "") do
      [_, json] -> decode_short_candidate(note, Jason.decode(json))
      _ -> []
    end
  end

  defp decode_short_candidate(note, {:ok, %{"label" => label} = payload}) do
    revision = payload["revision"]
    actor = payload["authorizer"]

    if is_binary(label) and Regex.match?(~r/^[PMQ][1-9][0-9]*$/, label) and
         text?(revision) and text?(actor) and is_map(payload["data"]),
       do: [Map.put(payload, "note", note)],
       else: []
  end

  defp decode_short_candidate(_, _), do: []

  defp confirm_candidate(candidate, reply, actor, labels) do
    if unchanged?(candidate["note"]) and candidate["authorizer"] == actor and length(labels) <= 1 and
         TaskDecision.timestamp(candidate["note"]["created_at"]) < TaskDecision.timestamp(reply["created_at"]),
       do: {:ok, candidate},
       else: {:error, :unconfirmed_candidate}
  end

  defp bound_reply(work, note, candidate, action) do
    items = Regex.scan(~r/\bC[1-9][0-9]*\b/u, note["body"]) |> List.flatten() |> Enum.uniq()
    allowed = get_in(candidate, ["data", "acceptance_items"]) || []

    if action == "rework" and (items == [] or not is_list(allowed) or not Enum.all?(items, &(&1 in allowed))) do
      {:error, :missing_acceptance_items}
    else
      binding = %{
        "candidate_source" => TaskDecision.source_ref(candidate["note"]),
        "candidate_digest" => TaskWorkflow.digest(Map.delete(candidate, "note")),
        "revision" => candidate["revision"],
        "label" => candidate["label"],
        "actor" => candidate["authorizer"],
        "action" => action,
        "items" => items
      }

      reply_event(work, note, binding)
    end
  end

  defp reply_event(work, note, binding) do
    note_source = TaskDecision.source_ref(note)
    source = "control:" <> TaskWorkflow.digest(%{"work" => work, "source" => note_source, "binding" => binding})

    {:ok,
     Map.merge(binding, %{
       "id" => WorkRef.key(work) <> ":note:" <> to_string(note["id"]),
       "source" => source,
       "note_source" => note_source,
       "at" => TaskDecision.timestamp(note["created_at"]),
       "work" => work
     })}
  end

  @doc "Resolve the latest explicit parent approval without treating a pause or resume as a new grant."
  @spec authority(map(), map()) :: {:ok, map()} | {:error, atom()}
  def authority(root, plan) do
    with true <- root.raw["state"] in ["open", "opened"] or {:error, :parent_not_open},
         {:ok, events} <- decisions(root, plan["authorizer"], :parent),
         {:ok, event} <- latest_authorization(events),
         true <- event["revision"] == plan["revision"] or {:error, :plan_decision_revision_mismatch} do
      proof = Map.take(event, ~w(candidate_source candidate_digest label))

      grant = %{
        "work" => root.work,
        "source" => event["note_source"],
        "actor" => plan["authorizer"],
        "revision" => plan["revision"]
      }

      {:ok, Map.merge(proof, grant)}
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
      {:ok, Enum.filter(root, &(&1["action"] in ~w(pause cancel resume))) ++ member}
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
    questions = Enum.any?(Enum.flat_map(snapshot.notes, &short_candidate/1), &String.starts_with?(&1["label"], "Q"))

    snapshot.notes
    |> Enum.filter(&control_note?(&1, scope, marker, questions))
    |> Enum.reduce_while({:ok, []}, fn note, {:ok, acc} ->
      case native_decision(snapshot, note, actor, scope, marker) do
        {:ok, event} -> {:cont, {:ok, [event | acc]}}
        :foreign -> {:cont, {:ok, acc}}
        error -> {:halt, error}
      end
    end)
    |> unique()
    |> bind_resumes()
  end

  defp control_note?(note, scope, marker, questions) do
    body = note["body"] || ""

    note["system"] != true and
      (String.contains?(body, "<!-- " <> marker) or
         (scope == :parent and not String.contains?(body, "<!--") and
            (questions or Regex.match?(~r/\b[PMQ][1-9][0-9]*\b/u, body) or human_action(body) != {:ok, "answer"})))
  end

  defp native_decision(snapshot, note, actor, scope, marker) do
    cond do
      String.contains?(note["body"] || "", "<!-- " <> marker) -> decision(note, snapshot.work, actor, scope, marker)
      to_string(get_in(note, ["author", "id"])) != actor -> :foreign
      true -> native_reply(snapshot, note, actor)
    end
  end

  defp native_reply(snapshot, note, actor) do
    case bind_reply(snapshot, note, actor) do
      {:ok, event} -> {:ok, event}
      {:clarify, _} -> {:error, :needs_clarification}
    end
  end

  defp bind_resumes({:ok, events}) do
    {:ok, Enum.map(events, &resume_binding(&1, events))}
  end

  defp bind_resumes(error), do: error

  defp resume_binding(%{"action" => "resume"} = event, events) do
    pauses = Enum.filter(events, &resume_target?(&1, event))

    case {event["restriction"], pauses} do
      {nil, [pause]} -> Map.put(event, "restriction", pause["source"])
      _ -> event
    end
  end

  defp resume_binding(event, _), do: event

  defp resume_target?(prior, event) do
    prior["action"] == "pause" and prior["revision"] == event["revision"] and
      prior["work"] == event["work"] and prior["at"] < event["at"]
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
    {human, exact} = Enum.split_with(events, &is_binary(&1["candidate_source"]))
    events = Enum.uniq(human) ++ exact

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
