defmodule SymphonyElixir.ReviewLane.Policy do
  alias SymphonyElixir.ReviewLane.WaitNotice
  alias SymphonyElixir.TaskWorkflow

  @moduledoc "Native reviewer request and review-once admission. Remote text never supplies execution authority."

  @spec requested_reviewer?(map(), pos_integer()) :: boolean()
  def requested_reviewer?(mr, reviewer_id) do
    mr["state"] == "opened" and
      Enum.any?(mr["reviewers"] || [], &(&1["id"] == reviewer_id))
  end

  @doc "Return the stable automatic-review marker for one native change request."
  @spec review_marker(map()) :: String.t()
  def review_marker(work), do: "<!-- symphony-review: #{TaskWorkflow.digest(work)} -->"

  @doc "Detect a prior human review or approval."
  @spec prior_review?([map()], map()) :: boolean()
  def prior_review?(discussions, mr) do
    approved?(mr) or Enum.any?(discussion_notes(discussions), fn {_, note} -> note_reviewed?(note, mr) end)
  end

  @doc "Detect a marked final Review on the native change request."
  @spec automatic_review?([map()], map(), String.t()) :: boolean()
  def automatic_review?(discussions, config, marker) do
    Enum.any?(discussion_notes(discussions), fn {discussion, note} ->
      automatic_review_note?(note, marker) and is_binary(comment_anchor(config, discussion, note["id"]))
    end)
  end

  @doc "Verify the submitted body and report URL against a marked native comment."
  @spec delivered_comment?([map()], map(), String.t(), String.t(), map()) :: boolean()
  def delivered_comment?(discussions, config, url, marker, %{"body" => body, "artifacts" => artifacts})
      when is_binary(body) and is_list(artifacts) do
    Enum.any?(discussion_notes(discussions), fn {discussion, note} ->
      automatic_review_note?(note, marker) and String.trim_trailing(note["body"]) == String.trim_trailing(body) and
        Enum.any?(artifacts, &report_url?(&1, config, url, discussion, note))
    end)
  end

  def delivered_comment?(_, _, _, _, _), do: false

  defp discussion_notes(discussions) do
    for %{"notes" => notes} = discussion <- discussions, is_list(notes), %{} = note <- notes, do: {discussion, note}
  end

  defp automatic_review_note?(%{"id" => id, "body" => body} = note, marker)
       when is_integer(id) and id > 0 and is_binary(body) do
    note["system"] != true and String.ends_with?(String.trim_trailing(body), "\n\n" <> marker)
  end

  defp automatic_review_note?(_, _), do: false

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

  defp note_reviewed?(note, mr) do
    not WaitNotice.status_note?(note) and
      (human_review_note?(note, mr) or approval_note?(note))
  end

  defp human_review_note?(note, mr) do
    author_id = get_in(note, ["author", "id"])
    body = to_string(note["body"] || "")
    mr_author_id = get_in(mr, ["author", "id"])
    has_review_state = note["state"] in ["APPROVED", "CHANGES_REQUESTED", "COMMENTED"]

    note["system"] != true and
      is_integer(author_id) and author_id > 0 and
      author_id != mr_author_id and
      (String.trim(body) != "" or has_review_state)
  end

  defp approval_note?(note) do
    (note["system"] == true and String.match?(to_string(note["body"] || ""), ~r/\bapproved\b/i)) or
      note["state"] == "APPROVED"
  end
end
