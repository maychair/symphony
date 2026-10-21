defmodule SymphonyElixir.ReviewLane.Publication do
  @moduledoc "Durable, version-bound review comments. Only native readback confirms delivery; uncertain sends are never repeated."
  alias SymphonyElixir.ReviewLane.{GitHub, GitLab}
  alias SymphonyElixir.{TaskDecision, TaskWorkflow}

  @spec prepare(map(), map(), pos_integer()) :: {:ok, map()} | {:error, atom()}
  def prepare(record, submission, actor) do
    with :ok <- unified_result(record, submission) do
      prepare_validated(record, submission, actor)
    end
  end

  defp unified_result(%{"review_protocol" => 3} = record, submission) do
    with true <- is_map(record["review_result"]) and is_binary(record["review_result"]["body"]) and record["review_result"]["protocol"] == 3,
         true <- submission == Map.take(record["review_result"], ~w(findings responses)) do
      :ok
    else
      _ -> {:error, :invalid_review_result}
    end
  end

  defp unified_result(_record, _submission), do: {:error, :unsupported_review_result}

  defp prepare_validated(record, submission, actor) do
    case record["submission"] do
      nil ->
        record = Map.put(record, "submission", submission)
        prepared = entries(record)

        if Enum.all?(prepared, &provider(record).comment_body?(&1["body"])),
          do: {:ok, Map.put(record, "publication", %{"version" => 3, "actor" => actor, "context" => context(record), "entries" => prepared})},
          else: {:error, :invalid_review_publication_body}

      ^submission ->
        if valid?(record, actor), do: {:ok, record}, else: {:error, :invalid_review_publication}

      _ ->
        {:error, :changed_submission}
    end
  end

  @spec valid?(map(), pos_integer()) :: boolean()
  def valid?(%{"publication" => %{"version" => version, "actor" => actor, "entries" => saved}} = record, actor) when is_list(saved) and version == 3 do
    unified_result(record, record["submission"]) == :ok and
      version == 3 and valid_submission?(record["submission"]) and
      record["publication"]["context"] == context(record) and
      length(saved) == length(entries(record)) and
      Enum.zip(saved, entries(record)) |> Enum.all?(fn {entry, expected} -> valid_entry?(entry, expected, record, actor) end)
  end

  def valid?(record, _actor), do: is_nil(record["publication"]) and is_nil(record["submission"])

  defp valid_submission?(%{"findings" => findings, "responses" => responses}) when is_list(findings) and is_list(responses),
    do: length(findings) <= 50 and Enum.all?(findings, &is_map/1) and Enum.all?(responses, &is_map/1)

  defp valid_submission?(_), do: false

  @doc "Read every recorded intent, retaining confirmed partial receipts even when another intent is uncertain."
  @spec recover(map(), map(), (map() -> any())) :: {:ok, map()} | {:error, term(), map()}
  def recover(record, config, checkpoint) do
    with true <- (is_map(record["publication"]) and valid?(record, config["publisher_id"])) or {:error, :invalid_review_publication},
         {:ok, repository} <- native(config).request(config, "GET", repository_path(config, record["project"])),
         true <- native(config).repository?(repository, config, record["project"]) or {:error, :review_repository_mismatch},
         {:ok, discussions} <- native(config).discussions(config, native(config).mr_path(record["project"], record["iid"])),
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
        # A return value, including a successful POST, is not a native receipt.
        result = post(config, record, entry["body"])
        sending = remember_native_id(sending, entry, result, checkpoint)
        publish(sending, config, checkpoint, guard)
    end
  end

  defp remember_native_id(%{"work" => %{"provider" => "github"}, "publication" => %{"version" => 3}} = record, entry, {:ok, %{"id" => note}}, checkpoint) when is_integer(note) and note > 0 do
    put_entry(record, Map.merge(entry, %{"status" => "sending", "native_candidate" => %{"discussion_id" => "pull_review_#{note}", "note_id" => note}}), checkpoint)
  end

  defp remember_native_id(%{"publication" => %{"version" => 3}} = record, entry, {:ok, %{"id" => discussion, "notes" => [%{"id" => note} | _]}}, checkpoint)
       when is_binary(discussion) and is_integer(note) and note > 0 do
    put_entry(record, Map.merge(entry, %{"status" => "sending", "native_candidate" => %{"discussion_id" => discussion, "note_id" => note}}), checkpoint)
  end

  defp remember_native_id(record, _entry, _result, _checkpoint), do: record

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
    matches = matching_notes(entry, record, discussions)

    case {entry["status"], matches} do
      {"prepared", []} -> {:ok, entry}
      {"sending", []} -> {:error, :review_publication_uncertain}
      {"published", []} -> {:error, :review_publication_missing}
      {_, [{discussion, note}]} -> confirm(entry, record, discussion, note)
    end
  end

  defp matching_notes(entry, %{"publication" => %{"version" => 3}}, discussions) do
    identity = entry["receipt"] || entry["native_candidate"]

    for discussion <- discussions,
        note <- discussion["notes"],
        is_map(identity),
        discussion["id"] == identity["discussion_id"] and note["id"] == identity["note_id"],
        do: {discussion["id"], note}
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

  defp actor?(note, actor), do: get_in(note, ["author", "id"]) == actor

  defp discussions?(discussions) do
    Enum.all?(discussions, fn discussion ->
      text?(discussion["id"]) and is_list(discussion["notes"]) and
        Enum.all?(discussion["notes"], &(is_map(&1) and is_binary(&1["body"])))
    end)
  end

  defp valid_entry?(%{} = entry, expected, record, actor) do
    Map.take(entry, ~w(index kind body)) == Map.take(expected, ~w(index kind body)) and provider(record).comment_body?(entry["body"]) and
      case entry["status"] do
        "published" -> receipt?(entry["receipt"], entry, record, actor)
        "prepared" -> is_nil(entry["receipt"]) and is_nil(entry["native_candidate"])
        "sending" -> is_nil(entry["receipt"])
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

  defp native(%{"provider" => "github"}), do: GitHub
  defp native(_config), do: GitLab
  defp provider(%{"work" => %{"provider" => "github"}}), do: GitHub
  defp provider(_record), do: GitLab
  defp repository_path(%{"provider" => "github"}, project), do: "repos/" <> project
  defp repository_path(_config, project), do: "projects/" <> URI.encode_www_form(project)

  defp post(config, record, body) do
    module = native(config)
    path = module.mr_path(record["project"], record["iid"])

    case config["provider"] do
      "github" ->
        module.request(config, "POST", path <> "/reviews", %{"body" => body, "event" => "COMMENT", "commit_id" => record["head"]})

      _ ->
        module.request(config, "POST", path <> "/discussions", %{"body" => body})
    end
  end

  defp entries(%{"review_protocol" => 3, "review_result" => result}),
    do: [%{"index" => 0, "kind" => "unified", "body" => result["body"], "status" => "prepared"}]

  defp finding_entry?(%{"kind" => "unified"}, record), do: record["review_result"]["findings"] != []

  defp put_entry(record, entry, checkpoint) do
    updated = put_in(record["publication"]["entries"], List.replace_at(record["publication"]["entries"], entry["index"], entry))
    receipts = Enum.filter(updated["publication"]["entries"], &(&1["status"] == "published"))
    updated = updated |> Map.put("receipts", Enum.map(receipts, & &1["receipt"])) |> Map.put("findings", receipts |> Enum.filter(&finding_entry?(&1, record)) |> Enum.map(& &1["receipt"]))
    if updated != record, do: checkpoint.(updated)
    updated
  end
end
