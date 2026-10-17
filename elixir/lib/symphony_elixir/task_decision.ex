defmodule SymphonyElixir.TaskDecision do
  @moduledoc "Bind native label decisions to published, unchanged candidate notes."

  alias SymphonyElixir.TaskWorkflow

  @actions %{"symphony:ready" => "authorize", "symphony:accept" => "accept", "symphony:rework" => "rework"}

  @doc "Render a candidate; publishing this material is not a human decision."
  @spec candidate_block(map()) :: String.t()
  def candidate_block(payload), do: "<!-- symphony-candidate\n" <> TaskWorkflow.canonical_json(payload) <> "\n-->"

  @doc "Resolve labels from native history, never from the current description or journal manifest."
  @spec label_events([map()], [map()]) :: [map()]
  def label_events(labels, notes) do
    candidates = notes |> Enum.reject(&(&1["system"] == true)) |> Enum.flat_map(&candidate/1)
    Enum.flat_map(labels, &label_event(&1, candidates))
  end

  @doc "A source version includes identity, author, creation time and mutable content."
  @spec source_ref(map()) :: String.t()
  def source_ref(note), do: "note:#{note["id"]}@#{version(note)}"

  @doc "Fingerprint a native label observation without granting it decision authority."
  @spec label_observation(map()) :: String.t()
  def label_observation(event) do
    TaskWorkflow.digest(%{
      "id" => event["id"],
      "action" => event["action"],
      "label" => get_in(event, ["label", "name"]),
      "actor" => get_in(event, ["user", "id"]),
      "created_at" => event["created_at"]
    })
  end

  @spec version(map()) :: String.t()
  def version(note), do: TaskWorkflow.digest(Map.put(Map.take(note, ["body", "created_at", "updated_at"]), "actor", get_in(note, ["author", "id"])))

  @spec timestamp(term()) :: integer() | nil
  def timestamp(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, date, _} -> DateTime.to_unix(date, :microsecond)
      _ -> nil
    end
  end

  def timestamp(_), do: nil

  defp candidate(note) do
    body = note["body"] || ""

    if String.contains?(body, ["<!-- symphony-candidate", "<!-- symphony-workflow"]) do
      parse_candidate(note, body)
    else
      []
    end
  end

  defp parse_candidate(note, body) do
    case Regex.scan(~r/(?:^|\n)<!-- symphony-(candidate|workflow)\s+(\{.*?\})\s*-->/s, body) do
      [[block, marker, json]] ->
        if String.ends_with?(String.trim_trailing(body), String.trim_leading(block)),
          do: decode_candidate(note, marker, json),
          else: [%{note: note, payload: %{"action" => "unknown"}}]

      _ ->
        [%{note: note, payload: %{"action" => "unknown"}}]
    end
  end

  defp decode_candidate(note, marker, json) do
    case Jason.decode(json) do
      {:ok, %{"action" => action, "data" => data} = payload} when is_binary(action) and is_map(data) ->
        published_candidate(note, marker, payload)

      _ ->
        [%{note: note, payload: %{"action" => "unknown"}}]
    end
  end

  defp published_candidate(note, "workflow", %{"action" => "manifest"} = payload),
    do: [%{note: note, payload: %{"action" => "accept", "contract" => payload["contract"], "data" => %{"manifest" => source_ref(note)}}}]

  defp published_candidate(_note, "workflow", _payload), do: []

  defp published_candidate(note, "candidate", %{"action" => action} = payload) when action in ["authorize", "rework"],
    do: [%{note: note, payload: payload}]

  defp published_candidate(note, _, _), do: [%{note: note, payload: %{"action" => "unknown"}}]

  defp label_event(%{"action" => "add", "id" => id, "user" => %{"id" => actor}, "label" => %{"name" => name}} = label, candidates)
       when is_integer(id) and id > 0 and is_integer(actor) and actor > 0 do
    with action when is_binary(action) <- @actions[name],
         at when is_integer(at) <- timestamp(label["created_at"]),
         {:ok, candidate} <- resolve(candidates, action, at) do
      payload = candidate.payload

      [
        %{
          "id" => "label:#{String.pad_leading(to_string(id), 12, "0")}",
          "ref" => "label:#{id}@#{actor}@#{label["created_at"]}",
          "version" => nil,
          "at" => at,
          "actor" => to_string(actor),
          "action" => action,
          "contract" => payload["contract"],
          "data" => payload["data"],
          "binding" => source_ref(candidate.note)
        }
      ]
    else
      _ -> []
    end
  end

  defp label_event(_, _), do: []

  defp resolve(candidates, action, at) do
    relevant = Enum.filter(candidates, &(&1.payload["action"] in [action, "unknown"]))

    # Timestamp ties across different native event streams have no reliable
    # order. Edits also erase the old candidate content; do not reconstruct it
    # from the latest version, even if that edit happened before the label.
    ambiguous = Enum.any?(relevant, &(ambiguous?(&1.note, at) or (&1.payload["action"] == "unknown" and timestamp(&1.note["created_at"]) <= at)))
    preceding = Enum.filter(relevant, &(is_integer(timestamp(&1.note["created_at"])) and timestamp(&1.note["created_at"]) < at))
    latest = Enum.max_by(preceding, &timestamp(&1.note["created_at"]), fn -> nil end)

    case latest do
      nil -> {:error, :missing_candidate}
      candidate -> unique_candidate(preceding, candidate, ambiguous)
    end
  end

  defp ambiguous?(note, at) do
    created = timestamp(note["created_at"])
    updated = timestamp(note["updated_at"])

    not is_integer(created) or not is_integer(updated) or not is_integer(note["id"]) or
      not is_integer(get_in(note, ["author", "id"])) or created == at or (created < at and updated != created)
  end

  defp unique_candidate(preceding, candidate, ambiguous) do
    peers = Enum.count(preceding, &(timestamp(&1.note["created_at"]) == timestamp(candidate.note["created_at"])))
    if ambiguous or peers != 1, do: {:error, :ambiguous_candidate}, else: {:ok, candidate}
  end
end
