defmodule SymphonyElixir.ReviewLane.Policy do
  @moduledoc "Native reviewer and author-response policy. Remote text never supplies execution authority."

  @spec requested_reviewer?(map(), pos_integer()) :: boolean()
  def requested_reviewer?(mr, reviewer_id) do
    mr["state"] == "opened" and
      Enum.any?(mr["reviewers"] || [], &(&1["id"] == reviewer_id))
  end

  @doc "Detect whether a merge request was already reviewed automatically or by a human."
  @spec prior_review?([map()], map(), map()) :: boolean()
  def prior_review?(discussions, mr, config) when is_list(discussions) and is_map(mr) and is_map(config) do
    approved?(mr) or Enum.any?(discussions, &discussion_reviewed?(&1, mr, config))
  end

  defp approved?(mr) do
    mr["approved"] == true or
      mr["detailed_merge_status"] == "approved" or
      (is_list(mr["approved_by"]) and mr["approved_by"] != []) or
      (is_list(mr["reviews"]) and Enum.any?(mr["reviews"], &(&1["state"] == "APPROVED")))
  end

  defp discussion_reviewed?(%{"notes" => notes}, mr, config) when is_list(notes) do
    Enum.any?(notes, &note_reviewed?(&1, mr, config))
  end

  defp discussion_reviewed?(_discussion, _mr, _config), do: false

  defp note_reviewed?(note, mr, config) when is_map(note) do
    automatic_review_note?(note, config) or human_review_note?(note, mr, config) or approval_note?(note)
  end

  defp note_reviewed?(_note, _mr, _config), do: false

  defp automatic_review_note?(note, config) do
    author_id = get_in(note, ["author", "id"])
    body = to_string(note["body"] || "")
    publisher_id = config["publisher_id"]

    (is_integer(publisher_id) and author_id == publisher_id) or
      String.contains?(body, "<!-- symphony-review:")
  end

  defp human_review_note?(note, mr, config) do
    author_id = get_in(note, ["author", "id"])
    body = to_string(note["body"] || "")
    publisher_id = config["publisher_id"]
    mr_author_id = get_in(mr, ["author", "id"])
    has_review_state = note["state"] in ["APPROVED", "CHANGES_REQUESTED", "COMMENTED"]

    note["system"] != true and
      is_integer(author_id) and author_id > 0 and
      author_id != mr_author_id and
      author_id != publisher_id and
      (String.trim(body) != "" or has_review_state)
  end

  defp approval_note?(note) do
    (note["system"] == true and String.match?(to_string(note["body"] || ""), ~r/\bapproved\b/i)) or
      note["state"] == "APPROVED"
  end

  defp author_reply?(%{"author" => %{"id" => author}} = note, own, author) do
    at = SymphonyElixir.TaskDecision.timestamp(note["created_at"])
    before = SymphonyElixir.TaskDecision.timestamp(own["created_at"])

    note["system"] != true and
      is_integer(at) and is_integer(before) and at > before
  end

  defp author_reply?(_, _, _), do: false

  @spec marker(String.t(), non_neg_integer()) :: String.t()
  def marker(id, index), do: "<!-- symphony-review:#{id}:#{index} -->"

  @doc "Version relevant author replies and resolution changes; a repeated poll is not another response."
  @spec response_digest([map()], [map()], pos_integer()) :: {:ok, String.t()} | {:error, atom()}
  def response_digest(findings, discussions, author) do
    findings
    |> Enum.uniq_by(&{&1["discussion_id"], &1["note_id"]})
    |> Enum.reduce_while({:ok, []}, fn finding, {:ok, acc} ->
      case response(finding, discussions, author) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, SymphonyElixir.TaskWorkflow.digest(Enum.sort_by(values, &{&1["discussion"], &1["note"]}))}
      error -> error
    end
  end

  defp response(finding, discussions, author) do
    with %{} = discussion <- Enum.find(discussions, &(&1["id"] == finding["discussion_id"])),
         notes when is_list(notes) <- discussion["notes"],
         true <- Enum.all?(notes, &is_map/1),
         %{} = own <- Enum.find(notes, &(&1["id"] == finding["note_id"])),
         true <- is_boolean(own["resolved"]) do
      replies =
        notes
        |> Enum.filter(
          &(author_reply?(&1, own, author) and is_binary(&1["body"]) and String.trim(&1["body"]) != "" and
              not String.contains?(&1["body"], "<!-- symphony-review:"))
        )
        |> Enum.map(&Map.take(&1, ~w(id body created_at updated_at)))
        |> Enum.sort_by(& &1["id"])

      if own["resolved"] or replies != [],
        do: {:ok, %{"discussion" => finding["discussion_id"], "note" => own["id"], "resolved" => own["resolved"], "replies" => replies}},
        else: {:ok, nil}
    else
      _ -> {:error, :review_finding_source_missing}
    end
  end
end
