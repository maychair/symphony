defmodule SymphonyElixir.ReviewLane.Policy do
  @moduledoc "Native reviewer request and review-once admission. Remote text never supplies execution authority."

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
end
