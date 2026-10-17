defmodule SymphonyElixir.TaskPublication do
  @moduledoc """
  Publish engine evidence to its owning Issue with durable intent and readback.

  This boundary authenticates publication, not the truth of an agent assertion.
  Evidence producers must supply actual candidate/check receipts. No native
  approval, merge, Issue creation or closure operation is exposed here.
  """
  alias SymphonyElixir.{ExecutionBinding, NativeWork, RunJournal, TaskDecision, TaskWorkflow, WorkRef}
  alias SymphonyElixir.{ReportArtifact, TaskControl, TaskPlanPreflight}

  @marker "<!-- symphony-evidence "

  @doc "Read recorded result envelopes and their current native confirmation without granting result validity."
  @spec observe(map(), map(), String.t()) :: {:ok, [map()]} | {:error, atom()}
  def observe(record, snapshot, actor) do
    entries = Map.get(record, "publications", %{})

    if is_map(entries) and Enum.all?(entries, fn {id, entry} -> valid_entry?(id, entry) and entry["work"] == snapshot.work end) do
      results = Enum.map(entries, fn {_id, entry} -> observation(entry, snapshot) end)
      known = [actor | Enum.map(entries, fn {_id, entry} -> entry["actor"] end)]
      bodies = Enum.map(entries, fn {_id, entry} -> entry["body"] end)
      unknown = Enum.any?(snapshot.notes, &(String.contains?(&1["body"], @marker) and to_string(get_in(&1, ["author", "id"])) in known and &1["body"] not in bodies))
      if unknown, do: {:error, :unrecorded_native_result}, else: {:ok, results}
    else
      {:error, :invalid_publication_journal}
    end
  end

  defp observation(entry, snapshot) do
    [json] = Regex.run(~r/\n\n<!-- symphony-evidence (\{[^\n]*\}) -->\n<!-- symphony-engine-notice -->\z/, entry["body"], capture: :all_but_first)
    envelope = Jason.decode!(json)

    receipt =
      case matches(snapshot, entry) do
        [note] ->
          expected = %{"work" => entry["work"], "note_id" => note["id"], "source" => TaskDecision.source_ref(note), "id" => entry["id"]}
          if entry["status"] == "published" and unchanged?(note, entry) and entry["receipt"] == expected, do: expected

        _ ->
          nil
      end

    %{envelope: envelope, receipt: receipt}
  end

  @doc "Publish a role-bound engine result; uncertain sends recover by reading, never by blind reposting."
  @spec publish(map(), String.t(), map(), String.t(), keyword()) :: {:ok, map(), map()} | {:error, term()}
  def publish(record, kind, payload, summary, opts \\ []) do
    with {:ok, entry} <- prepare(record, kind, payload, summary, opts[:policy]),
         {:ok, current} <- RunJournal.checkpoint(record, %{}),
         {:ok, current} <- recover(current, opts),
         {:ok, current, entry} <- intent(current, entry),
         {:ok, current, entry} <- complete(current, entry, opts) do
      {:ok, current, entry["receipt"]}
    end
  end

  @doc "Recover known send intents, including old roles, without writing to the provider."
  @spec recover(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def recover(record, opts \\ []) do
    recover_entries(record, record["publications"] || %{}, opts)
  end

  defp recover_entries(record, entries, opts) when is_map(entries) do
    Enum.reduce_while(entries, {:ok, record}, fn {id, entry}, {:ok, current} ->
      result =
        if valid_entry?(id, entry),
          do: recover_pending(current, entry, opts),
          else: {:error, :invalid_publication_journal}

      case result do
        {:ok, updated} -> {:cont, {:ok, updated}}
        error -> {:halt, error}
      end
    end)
  end

  defp recover_entries(_, _, _), do: {:error, :invalid_publication_journal}

  defp prepare(record, kind, payload, summary, policy) do
    binding = record["execution_binding"]

    with {:ok, ^binding} <- ExecutionBinding.normalize(binding),
         {:ok, ^record} <- ExecutionBinding.bind(record, binding),
         true <- is_binary(record["thread_id"]) and record["thread_id"] != "",
         true <- is_map(policy) and TaskWorkflow.digest(policy) == binding["policy_sha"],
         true <- text?(policy["engine_actor"]) and summary?(summary) and is_map(payload),
         true <- NativeWork.comment_body?(binding["work"]["provider"], summary),
         true <- role_payload?(kind, payload, binding),
         :ok <- attest(kind, record, payload, policy) do
      envelope = %{
        "schema_version" => 1,
        "kind" => kind,
        "binding" => binding,
        "generation" => record["execution_generation"],
        "thread_id" => record["thread_id"],
        "actor" => policy["engine_actor"],
        "payload" => payload,
        "summary" => summary
      }

      id = TaskWorkflow.digest(Map.delete(envelope, "summary"))
      envelope = Map.put(envelope, "id", id)
      body = render(envelope)

      if byte_size(body) <= 64_000 do
        {:ok, %{"id" => id, "work" => binding["work"], "actor" => policy["engine_actor"], "body" => body, "status" => "prepared", "binding" => binding}}
      else
        {:error, :publication_body_too_large}
      end
    else
      _ -> {:error, :invalid_publication_context}
    end
  end

  defp attest("verification", record, payload, policy), do: SymphonyElixir.CommandCheck.attest(record, payload, policy)
  defp attest(_, _, _, _), do: :ok

  defp render(envelope) do
    report = report_text(envelope)
    json = TaskWorkflow.canonical_json(envelope)
    json = if report == "", do: json, else: json |> String.replace("<", "\\u003c") |> String.replace(">", "\\u003e")
    envelope["summary"] <> report <> "\n\n" <> @marker <> json <> " -->\n<!-- symphony-engine-notice -->"
  end

  defp report_text(%{"kind" => "candidate", "payload" => %{"artifacts" => artifacts}}) do
    Enum.map_join(artifacts, "", fn
      %{"kind" => "report", "body" => body, "id" => id} -> "\n\n### Report " <> Jason.encode!(id) <> "\n\n" <> body
      _ -> ""
    end)
  end

  defp report_text(_), do: ""
  defp summary?(summary), do: text?(summary) and not String.contains?(summary, "<!-- symphony-")

  defp valid_entry?(id, %{"id" => id, "body" => body, "binding" => binding, "status" => status} = entry) when is_binary(body) do
    with true <- status in ["prepared", "sending", "published"] and receipt_shape?(entry) and byte_size(body) <= 64_000,
         {:ok, ^binding} <- ExecutionBinding.normalize(binding),
         [json] <- Regex.run(~r/\n\n<!-- symphony-evidence (\{[^\n]*\}) -->\n<!-- symphony-engine-notice -->\z/, body, capture: :all_but_first),
         {:ok, %{"id" => ^id, "binding" => ^binding, "actor" => actor} = envelope} <- Jason.decode(json) do
      envelope_shape?(envelope) and
        summary?(envelope["summary"]) and render(envelope) == body and entry["work"] == binding["work"] and
        text?(actor) and entry["actor"] == actor and id == TaskWorkflow.digest(Map.drop(envelope, ~w(id summary)))
    else
      _ -> false
    end
  end

  defp valid_entry?(_, _), do: false

  defp envelope_shape?(envelope) do
    envelope["schema_version"] == 1 and is_integer(envelope["generation"]) and envelope["generation"] > 0 and
      text?(envelope["thread_id"]) and is_map(envelope["payload"]) and
      role_payload?(envelope["kind"], envelope["payload"], envelope["binding"])
  end

  defp receipt_shape?(%{"status" => "published", "receipt" => %{"work" => work, "note_id" => note, "source" => source, "id" => id}} = entry) do
    work == entry["work"] and id == entry["id"] and is_integer(note) and note > 0 and text?(source)
  end

  defp receipt_shape?(%{"status" => status} = entry) when status in ["prepared", "sending"], do: is_nil(entry["receipt"])
  defp receipt_shape?(_), do: false

  defp role_payload?("candidate", payload, %{"role" => "developer"} = binding) do
    expected = Map.take(binding, ~w(work contract_sha inputs))

    Enum.all?(expected, fn {key, value} -> payload[key] == value end) and is_list(payload["artifacts"]) and payload["artifacts"] != [] and
      Enum.all?(payload["artifacts"], &valid_report?(&1, binding["work"]))
  end

  defp role_payload?("verification", payload, %{"role" => "verifier"} = binding) do
    Enum.all?(~w(candidate inputs policy_sha), &(payload[&1] == binding[&1])) and is_list(payload["checks"]) and is_list(payload["findings"])
  end

  defp role_payload?(_, _, _), do: false

  defp valid_report?(artifact, work) when is_map(artifact),
    do: not Map.has_key?(artifact, "body") or match?({:ok, _}, ReportArtifact.snapshot(work, artifact))

  defp valid_report?(_, _), do: false

  defp intent(record, %{"body" => body} = entry) do
    case (record["publications"] || %{})[entry["id"]] do
      nil ->
        with {:ok, current} <- save(record, entry), do: {:ok, current, entry}

      %{"body" => ^body} = existing ->
        {:ok, record, existing}

      _ ->
        {:error, :publication_intent_changed}
    end
  end

  defp complete(record, %{"status" => "published"} = entry, opts) do
    with {:ok, current} <- recover_entry(record, entry, opts), do: {:ok, current, entry}
  end

  defp complete(record, %{"status" => "prepared"} = entry, opts) do
    with {:ok, snapshot, controls} <- publication_scope(record, entry, opts),
         {:ok, record} <- RunJournal.checkpoint(record, %{"control_receipts" => controls.receipts}),
         true <- controls.restrictions == [] or {:error, :publication_controlled},
         :ok <- absent(snapshot, entry),
         {:ok, sending} <- save(record, Map.put(entry, "status", "sending")) do
      finish_send(NativeWork.comment(snapshot, entry["body"], entry["actor"], opts), sending, entry, opts)
    end
  end

  defp finish_send({:not_sent, reason}, record, entry, _) do
    with {:ok, _} <- save(record, entry), do: {:error, {:publication_not_sent, reason}}
  end

  defp finish_send(_, record, entry, opts) do
    with {:ok, recovered} <- recover_entry(record, Map.put(entry, "status", "sending"), opts),
         do: {:ok, recovered, recovered["publications"][entry["id"]]}
  end

  defp publication_scope(record, entry, opts) do
    binding = entry["binding"]

    with {:ok, plan} <- TaskPlanPreflight.inspect_plan(binding["authority"]["work"], opts),
         true <- plan.authority == binding["authority"] and plan.plan["revision"] == binding["plan_revision"],
         %{} = member <- plan.members[WorkRef.key(entry["work"])],
         true <- member.contract["contract_sha"] == binding["contract_sha"],
         true <- member.raw["state"] in ["open", "opened"],
         {:ok, controls} <- TaskControl.observe(plan, entry["work"], TaskControl.recorded(record)) do
      {:ok, member, controls}
    else
      {:error, _} = error -> error
      _ -> {:error, :publication_scope_changed}
    end
  end

  defp absent(snapshot, entry) do
    if matches(snapshot, entry) == [], do: :ok, else: {:error, :unexpected_native_publication}
  end

  defp recover_pending(record, %{"status" => "published"}, _), do: {:ok, record}
  defp recover_pending(record, entry, opts), do: recover_entry(record, entry, opts)

  defp recover_entry(record, %{"status" => "prepared"}, _), do: {:ok, record}

  defp recover_entry(record, %{"status" => status} = entry, opts) when status in ["sending", "published"] do
    with {:ok, snapshot} <- NativeWork.read(entry["work"], opts),
         [note] <- matches(snapshot, entry),
         true <- unchanged?(note, entry),
         receipt = %{"work" => entry["work"], "note_id" => note["id"], "source" => TaskDecision.source_ref(note), "id" => entry["id"]},
         true <- is_nil(entry["receipt"]) or entry["receipt"] == receipt do
      if status == "published" do
        {:ok, record}
      else
        save(record, Map.merge(entry, %{"status" => "published", "receipt" => receipt}))
      end
    else
      _ -> {:error, :publication_readback_unconfirmed}
    end
  end

  defp matches(snapshot, entry) do
    # Include altered/foreign copies of our ID so ambiguity cannot be hidden by
    # filtering the attacker-controlled body or author before counting matches.
    needle = "\"id\":\"" <> entry["id"] <> "\""
    Enum.filter(snapshot.notes, &(String.contains?(&1["body"], @marker) and String.contains?(&1["body"], needle)))
  end

  defp unchanged?(note, entry) do
    at = TaskDecision.timestamp(note["created_at"])

    note["body"] == entry["body"] and note["system"] != true and is_integer(at) and
      at == TaskDecision.timestamp(note["updated_at"]) and to_string(get_in(note, ["author", "id"])) == entry["actor"]
  end

  defp save(record, entry) do
    entries = Map.put(record["publications"] || %{}, entry["id"], entry)
    RunJournal.checkpoint(record, %{"publications" => entries})
  end

  defp text?(value), do: is_binary(value) and String.trim(value) != ""
end
