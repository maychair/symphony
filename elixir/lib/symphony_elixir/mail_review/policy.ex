defmodule SymphonyElixir.MailReview.Policy do
  @moduledoc "Pure mail-signal and author-answer policy. Remote text never supplies execution authority."

  @spec candidate(map(), map()) :: {:ok, String.t(), pos_integer()} | :ignore
  def candidate(mail, config) do
    sender = get_in(mail, ["head_from", "mail_address"])
    text = mail["body_plain_text"] || ""
    notification = text |> String.split("\n") |> List.first() |> String.trim()

    if sender in (config["mail_senders"] || []) and requested?(notification, text, config) do
      match_request(mail, config)
    else
      :ignore
    end
  end

  defp requested?(notification, text, config) do
    Enum.any?(config["reviewer_names"] || [], fn name ->
      String.starts_with?(notification, name <> " was added as a reviewer.") or
        (String.contains?(notification, "created a merge request") and String.contains?(text, "Reviewer: " <> name))
    end)
  end

  defp match_request(mail, config) do
    links = Regex.scan(~r{https?://[^\s<>"']+/-/merge_requests/[0-9]+}, mail["body_html"] || "")
    links = links ++ Regex.scan(~r{https?://[^\s<>"']+/-/merge_requests/[0-9]+}, mail["body_plain_text"] || "")
    matches = links |> Enum.map(fn [url] -> allowed_url(url, config) end) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    match_subject(matches, Regex.run(~r/\(!([1-9][0-9]*)\)/, mail["subject"] || ""))
  end

  defp match_subject([{:ok, project, iid}], [_, number]) do
    if Integer.to_string(iid) == number, do: {:ok, project, iid}, else: :ignore
  end

  defp match_subject(_matches, _subject), do: :ignore

  defp allowed_url(url, config) do
    uri = URI.parse(url)

    with true <-
           uri.scheme in ["http", "https"] and uri.host == config["host"] and
             is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment) and uri.port in [80, 443],
         [_, project, iid] <- Regex.run(~r{^/(.+)/-/merge_requests/([1-9][0-9]*)$}, uri.path || ""),
         true <- Map.has_key?(config["projects"] || %{}, project),
         {number, ""} <- Integer.parse(iid) do
      {:ok, project, number}
    else
      _ -> nil
    end
  end

  @spec requested_reviewer?(map(), String.t()) :: boolean()
  def requested_reviewer?(mr, username) do
    mr["state"] == "opened" and
      Enum.any?(mr["reviewers"] || [], &(&1["username"] == username))
  end

  @spec answered?([map()], [map()], integer()) :: boolean()
  def answered?([], _discussions, _author), do: false

  def answered?(findings, discussions, author) do
    Enum.all?(findings, &finding_answered?(&1, discussions, author))
  end

  defp finding_answered?(finding, discussions, author) do
    case Enum.find(discussions, &(&1["id"] == finding["discussion_id"])) do
      nil -> false
      discussion -> note_answered?(finding, discussion["notes"] || [], author)
    end
  end

  defp note_answered?(finding, notes, author) do
    case Enum.find(notes, &(&1["id"] == finding["note_id"])) do
      nil -> false
      own -> own["resolved"] == true or Enum.any?(notes, &author_reply?(&1, own, author))
    end
  end

  defp author_reply?(note, own, author) do
    get_in(note, ["author", "id"]) == author and note["system"] != true and
      is_binary(note["created_at"]) and note["created_at"] > own["created_at"]
  end

  @spec marker(String.t(), non_neg_integer()) :: String.t()
  def marker(id, index), do: "<!-- symphony-review:#{id}:#{index} -->"
end
