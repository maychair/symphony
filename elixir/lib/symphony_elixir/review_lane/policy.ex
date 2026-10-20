defmodule SymphonyElixir.ReviewLane.Policy do
  @moduledoc "Native reviewer and author-response policy. Remote text never supplies execution authority."

  @spec requested_reviewer?(map(), pos_integer()) :: boolean()
  def requested_reviewer?(mr, reviewer_id) do
    mr["state"] == "opened" and
      Enum.any?(mr["reviewers"] || [], &(&1["id"] == reviewer_id))
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
