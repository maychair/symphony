defmodule SymphonyElixir.ReviewLane.Publication do
  @moduledoc "Durable, version-bound review comments. Only native readback confirms delivery; uncertain sends are never repeated."
  alias SymphonyElixir.ReviewLane.{GitLab, Policy}
  alias SymphonyElixir.{TaskDecision, TaskWorkflow}

  @spec prepare(map(), [String.t()], pos_integer()) :: {:ok, map()} | {:error, atom()}
  def prepare(record, findings, actor) do
    case record["submission"] do
      nil ->
        record = Map.put(record, "submission", findings)
        {:ok, Map.put(record, "publication", %{"version" => 1, "actor" => actor, "context" => context(record), "entries" => entries(record)})}

      ^findings ->
        if valid?(record, actor), do: {:ok, record}, else: {:error, :invalid_review_publication}

      _ ->
        {:error, :changed_submission}
    end
  end

  @spec valid?(map(), pos_integer()) :: boolean()
  def valid?(%{"publication" => %{"version" => 1, "actor" => actor, "entries" => saved}} = record, actor) when is_list(saved) do
    record["publication"]["context"] == context(record) and
      is_list(record["submission"]) and length(record["submission"]) <= 50 and Enum.all?(record["submission"], &is_binary/1) and
      length(saved) == length(entries(record)) and
      Enum.zip(saved, entries(record)) |> Enum.all?(fn {entry, expected} -> valid_entry?(entry, expected, record, actor) end)
  end

  def valid?(record, _actor), do: is_nil(record["publication"]) and is_nil(record["submission"])

  @doc "Read every recorded intent, retaining confirmed partial receipts even when another intent is uncertain."
  @spec recover(map(), map(), (map() -> any())) :: {:ok, map()} | {:error, term(), map()}
  def recover(record, config, checkpoint) do
    with true <- (is_map(record["publication"]) and valid?(record, config["publisher_id"])) or {:error, :invalid_review_publication},
         {:ok, repository} <- GitLab.request(config, "GET", "projects/" <> URI.encode_www_form(record["project"])),
         true <- GitLab.repository?(repository, config, record["project"]) or {:error, :review_repository_mismatch},
         {:ok, discussions} <- GitLab.discussions(config, GitLab.mr_path(record["project"], record["iid"])),
         true <- discussions?(discussions) or {:error, :invalid_review_discussions} do
      recover_entries(record, discussions, checkpoint)
    else
      {:error, reason} -> {:error, reason, record}
    end
  end

  @doc "Continue only unsent entries, fencing each new send with the caller's current native review scope."
  @spec publish(map(), map(), (map() -> any()), (map() -> :ok | {:error, term()})) ::
          {:ok, map()} | {:error, term(), map()}
  def publish(record, config, checkpoint, guard) do
    with {:ok, record} <- recover(record, config, checkpoint) do
      case guard.(record) do
        :ok -> send_next(record, config, checkpoint, guard)
        {:error, reason} -> {:error, reason, record}
      end
    end
  end

  defp send_next(record, config, checkpoint, guard) do
    case Enum.find(record["publication"]["entries"], &(&1["status"] == "prepared")) do
      nil ->
        {:ok, record}

      entry ->
        sending = put_entry(record, Map.put(entry, "status", "sending"), checkpoint)
        path = GitLab.mr_path(record["project"], record["iid"]) <> "/discussions"
        # A return value, including a successful POST, is not a native receipt.
        GitLab.request(config, "POST", path, %{"body" => entry["body"]})
        publish(sending, config, checkpoint, guard)
    end
  end

  defp recover_entries(record, discussions, checkpoint) do
    {current, error} =
      Enum.reduce(record["publication"]["entries"], {record, nil}, fn entry, {current, error} ->
        case observe(entry, record, discussions) do
          {:ok, observed} -> {put_entry(current, observed, checkpoint), error}
          {:error, reason} -> {current, error || reason}
        end
      end)

    if error, do: {:error, error, current}, else: {:ok, current}
  end

  defp observe(entry, record, discussions) do
    marker = Policy.marker(record["id"], entry["index"])

    matches =
      for discussion <- discussions,
          note <- discussion["notes"],
          String.contains?(note["body"], marker),
          do: {discussion["id"], note}

    case {entry["status"], matches} do
      {"prepared", []} -> {:ok, entry}
      {"sending", []} -> {:error, :review_publication_uncertain}
      {"published", []} -> {:error, :review_publication_missing}
      {"prepared", [_]} -> {:error, :unexpected_review_publication}
      {_, [{discussion, note}]} -> confirm(entry, record, discussion, note)
      _ -> {:error, :review_publication_conflict}
    end
  end

  defp confirm(entry, record, discussion, note) do
    receipt = %{
      "work" => record["work"],
      "discussion_id" => discussion,
      "note_id" => note["id"],
      "actor" => record["publication"]["actor"],
      "body_sha" => TaskWorkflow.digest(entry["body"]),
      "created_at" => note["created_at"]
    }

    valid =
      note["body"] == entry["body"] and actor?(note, receipt["actor"]) and note["system"] != true and
        receipt?(receipt, entry, record, receipt["actor"])

    if valid and (is_nil(entry["receipt"]) or entry["receipt"] == receipt),
      do: {:ok, entry |> Map.put("status", "published") |> Map.put("receipt", receipt)},
      else: {:error, :review_publication_conflict}
  end

  defp actor?(%{"author" => %{"id" => actor}}, actor), do: true
  defp actor?(_, _), do: false

  defp discussions?(discussions) do
    Enum.all?(discussions, fn discussion ->
      text?(discussion["id"]) and is_list(discussion["notes"]) and
        Enum.all?(discussion["notes"], &(is_map(&1) and is_binary(&1["body"])))
    end)
  end

  defp valid_entry?(%{} = entry, expected, record, actor) do
    Map.take(entry, ~w(index kind body)) == Map.take(expected, ~w(index kind body)) and GitLab.comment_body?(entry["body"]) and
      case entry["status"] do
        "published" -> receipt?(entry["receipt"], entry, record, actor)
        status when status in ["prepared", "sending"] -> is_nil(entry["receipt"])
        _ -> false
      end
  end

  defp valid_entry?(_, _, _, _), do: false

  defp receipt?(%{} = receipt, entry, record, actor) do
    receipt["work"] == record["work"] and receipt["actor"] == actor and receipt["body_sha"] == TaskWorkflow.digest(entry["body"]) and
      text?(receipt["discussion_id"]) and is_integer(receipt["note_id"]) and receipt["note_id"] > 0 and
      is_integer(TaskDecision.timestamp(receipt["created_at"]))
  end

  defp receipt?(_, _, _, _), do: false
  defp text?(value), do: is_binary(value) and value != ""
  defp context(record), do: Map.take(record, ~w(work round head base response_sha policy_sha))

  defp entries(record) do
    findings = Enum.map(record["submission"], &{"finding", &1})
    summary = if findings == [], do: "本轮评审未发现有充分证据支持的问题。", else: "本轮评审完成，发现 #{length(findings)} 个有证据支持的问题，详见本轮评论。"

    (findings ++ [{"conclusion", summary}])
    |> Enum.with_index()
    |> Enum.map(fn {{kind, text}, index} ->
      version = "评审轮次：#{record["round"]}；范围：`#{record["base"]}` → `#{record["head"]}`。"
      body = text <> "\n\n" <> version <> "\n\n" <> Policy.marker(record["id"], index) <> "\n<!-- symphony-review-context:#{TaskWorkflow.digest(context(record))} -->"
      %{"index" => index, "kind" => kind, "body" => body, "status" => "prepared"}
    end)
  end

  defp put_entry(record, entry, checkpoint) do
    updated = put_in(record["publication"]["entries"], List.replace_at(record["publication"]["entries"], entry["index"], entry))
    receipts = Enum.filter(updated["publication"]["entries"], &(&1["status"] == "published"))
    updated = updated |> Map.put("receipts", Enum.map(receipts, & &1["receipt"])) |> Map.put("findings", receipts |> Enum.filter(&(&1["kind"] == "finding")) |> Enum.map(& &1["receipt"]))
    if updated != record, do: checkpoint.(updated)
    updated
  end
end
