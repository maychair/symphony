defmodule SymphonyElixir.ReviewLane.Policy do
  alias SymphonyElixir.ReviewLane.WaitNotice

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

  @doc "Check native evidence of an existing comment by the configured publisher."
  @spec publisher_comment?([map()], map()) :: boolean()
  def publisher_comment?(discussions, config) do
    Enum.any?(discussion_notes(discussions), fn {_discussion, note} -> publisher_note?(note, config) end)
  end

  @doc "Verify the submitted body and report URL against a native publisher comment."
  @spec delivered_comment?([map()], map(), String.t(), map()) :: boolean()
  def delivered_comment?(discussions, config, url, %{"body" => body, "artifacts" => artifacts})
      when is_binary(body) and is_list(artifacts) do
    Enum.any?(discussion_notes(discussions), fn {discussion, note} ->
      publisher_note?(note, config) and String.trim_trailing(note["body"]) == String.trim_trailing(body) and
        Enum.any?(artifacts, &report_url?(&1, config, url, discussion, note))
    end)
  end

  def delivered_comment?(_, _, _, _), do: false

  defp discussion_notes(discussions) do
    for %{"notes" => notes} = discussion <- discussions, is_list(notes), %{} = note <- notes, do: {discussion, note}
  end

  defp publisher_note?(%{"id" => id, "body" => body, "author" => %{"id" => author}} = note, %{"publisher_id" => publisher})
       when is_integer(id) and id > 0 and is_integer(author) and is_binary(body),
       do: note["system"] != true and author == publisher and String.trim(body) != "" and not WaitNotice.status_note?(note)

  defp publisher_note?(_, _), do: false

  defp report_url?(%{"url" => report}, config, url, discussion, note) do
    case comment_anchor(config, discussion, note["id"]) do
      nil -> false
      anchor -> report == url <> anchor
    end
  end

  defp report_url?(_, _, _, _, _), do: false

  defp comment_anchor(%{"provider" => "gitlab"}, _, id), do: "#note_#{id}"
  defp comment_anchor(%{"provider" => "github"}, %{"id" => "issue_comment_" <> _}, id), do: "#issuecomment-#{id}"
  defp comment_anchor(%{"provider" => "github"}, %{"id" => "pull_review_" <> _}, id), do: "#pullrequestreview-#{id}"
  defp comment_anchor(_, _, _), do: nil

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
    not WaitNotice.status_note?(note) and
      (automatic_review_note?(note, config) or human_review_note?(note, mr, config) or approval_note?(note))
  end

  defp note_reviewed?(_note, _mr, _config), do: false

  defp automatic_review_note?(note, config) do
    author_id = get_in(note, ["author", "id"])
    body = to_string(note["body"] || "")
    publisher_id = config["publisher_id"]

    note["system"] != true and
      ((is_integer(publisher_id) and author_id == publisher_id) or
         String.contains?(body, "<!-- symphony-review:"))
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
