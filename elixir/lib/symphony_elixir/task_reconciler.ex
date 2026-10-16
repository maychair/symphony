defmodule SymphonyElixir.TaskReconciler do
  @moduledoc "Reconcile Issue decisions on the existing execution and scheduler loops."
  require Logger
  alias SymphonyElixir.{Config, Execution, RunJournal, TaskWorkflow}
  alias SymphonyElixir.GitLab.Client

  @spec enabled?() :: boolean()
  def enabled? do
    tracker = Config.settings!().tracker
    Execution.enabled?() and tracker.kind == "gitlab" and tracker.provider["task_workflow"] == true
  end

  @spec poll(MapSet.t()) :: :ok
  def poll(active_ids) do
    if enabled?() do
      Execution.journal_root()
      |> Path.join("*/run.json")
      |> Path.wildcard()
      |> Enum.each(&poll_record(&1, active_ids))
    end

    :ok
  end

  defp poll_record(path, active_ids) do
    with {:ok, record} when is_map(record) <- RunJournal.read(Path.dirname(path)),
         false <- MapSet.member?(active_ids, record["issue_id"]) do
      locked_refresh(record)
    end
  end

  defp locked_refresh(record) do
    lock = Path.join(record["directory"], "executor.lock")

    case File.mkdir(lock) do
      :ok ->
        try do
          File.write!(Path.join(lock, "reconcile-owner"), System.pid())

          with {:ok, current} <- RunJournal.read(record["directory"]) do
            refresh(current, false)
          end
        after
          File.rm(Path.join(lock, "reconcile-owner"))
          File.rmdir(lock)
        end

      {:error, :eexist} ->
        :ok

      error ->
        Logger.warning("Task reconciliation lock failed issue_id=#{record["issue_id"]} error=#{inspect(error)}")
    end
  end

  @spec admit(SymphonyElixir.Tracker.Issue.t(), map()) :: {:ok, map()} | {:error, term()}
  def admit(issue, record) do
    if enabled?() do
      with {:ok, current} <- refresh(Map.put(record, "issue_url", issue.url), false),
           true <- current["workflow"]["state"] == "ready" and current["workflow"]["allowed_criteria"] != [] do
        now = System.system_time(:millisecond)
        flow = TaskWorkflow.start(current["workflow"], now)
        remaining = flow["budget_ms"] - flow["used_ms"]
        RunJournal.checkpoint(current, %{"workflow" => flow, "remaining_budget_ms" => remaining})
      else
        false -> {:error, :task_workflow_waiting}
        error -> error
      end
    else
      {:ok, record}
    end
  end

  @spec refresh(map(), boolean(), keyword()) :: {:ok, map()} | {:error, term()}
  def refresh(record, active, opts \\ []) do
    with {:ok, observation} <- observe(record, opts), do: apply_observation(record, observation, active, opts)
  end

  @spec observe(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def observe(record, opts \\ []) do
    settings = Keyword.get(opts, :settings, Config.settings!().tracker)
    default_client = Application.get_env(:symphony_elixir, :task_workflow_client, &Client.request/5)
    client = Keyword.get(opts, :client, default_client)
    prefix = "/projects/#{URI.encode_www_form(settings.provider["project_path"])}"
    path = prefix <> "/issues/" <> record["issue_id"]

    with {:ok, raw} <- get(client, path, settings),
         true <- raw["web_url"] == record["issue_url"],
         {:ok, notes} <- pages(client, path <> "/notes", settings, 1, []),
         {:ok, facts, events} <- facts(raw, notes, record, prefix, client, settings) do
      observation = %{facts: facts, events: events, raw: raw, path: path, settings: settings, client: client}
      {:ok, Map.put(observation, :attempt_id, record["attempt_id"])}
    else
      error -> {:error, {:task_facts_unavailable, error}}
    end
  end

  @spec apply_observation(map(), map(), boolean(), keyword()) :: {:ok, map()} | {:error, term()}
  def apply_observation(record, observation, active, opts \\ []) do
    %{facts: facts, events: events, raw: raw, path: path, settings: settings, client: client} = observation
    now = Keyword.get(opts, :now, System.system_time(:millisecond))

    if observation.attempt_id != record["attempt_id"] do
      {:error, :stale_execution_observation}
    else
      flow = record["workflow"] || TaskWorkflow.new(Execution.run_budget_ms(record["issue_id"]), now)
      facts = Map.merge(facts, %{"active" => active, "now" => now, "stopped" => record["native_stop_confirmed"] == true or record["thread_allocation_intent"] != true})
      flow = flow |> check_routing(facts, active) |> TaskWorkflow.reconcile(facts, events, now)

      with {:ok, saved} <- RunJournal.checkpoint(record, %{"workflow" => flow}) do
        routing(saved, raw, path, settings, client, active)
      end
    end
  end

  defp facts(raw, notes, record, prefix, client, settings) do
    owner =
      case raw["assignees"] do
        [%{"id" => id}] -> to_string(id)
        _ -> nil
      end

    type = raw["labels"] |> Enum.filter(&(&1 in ["type:research", "type:development", "type:mixed"]))
    type = if length(type) == 1, do: String.replace(hd(type), "type:", ""), else: nil
    now = System.system_time(:millisecond)
    flow = record["workflow"] || TaskWorkflow.new(Execution.run_budget_ms(record["issue_id"]), now)
    events = events(notes, flow, owner)

    basic = %{
      "owner" => owner,
      "type" => type,
      "issue_version" => TaskWorkflow.digest(raw["description"] || ""),
      "closed" => raw["state"] == "closed",
      "labels" => raw["labels"],
      "versions" => %{},
      "now" => now,
      "source_refs" => Enum.map(events, & &1["ref"]),
      "owner_valid" => owner == settings.assignee
    }

    candidate = TaskWorkflow.reconcile(flow, basic, events, now)
    items = Enum.flat_map(List.wrap(candidate["manifest"]), & &1["items"]) ++ List.wrap(flow["intermediate"])
    items = Enum.uniq_by(items, & &1["url"])

    with {:ok, versions, merged, merged_urls} <- versions(items, prefix, raw["web_url"], notes, client, settings),
         {:ok, satisfied} <- dependencies(candidate, prefix, client, settings) do
      {:ok, Map.merge(basic, %{"versions" => versions, "merge_verified" => merged, "merged_urls" => merged_urls, "satisfied" => satisfied}), events}
    end
  end

  @spec events([map()], map(), String.t() | nil) :: [map()]
  def events(notes, flow, owner) do
    parsed = notes |> Enum.reject(&(&1["system"] == true)) |> Enum.map(&parse_note/1) |> Enum.reject(&is_nil/1)
    contracts = Enum.filter(parsed, &(&1["action"] == "authorize" and &1["actor"] == (get_in(flow, ["contract", "authorizer"]) || owner)))

    Enum.map(parsed, &bind_natural(&1, contracts, parsed, flow))
  end

  defp bind_natural(%{"natural" => true} = event, contracts, parsed, flow) do
    contract = contracts |> Enum.filter(&(&1["at"] <= event["at"])) |> Enum.max_by(& &1["at"], fn -> flow["contract"] end)
    ids = (flow["restrictions"] || %{}) |> Enum.filter(fn {_, value} -> value["kind"] == "pause" end) |> Enum.map(&elem(&1, 0))
    ids = ids ++ (parsed |> Enum.filter(&(&1["action"] == "pause" and &1["at"] <= event["at"])) |> Enum.map(& &1["ref"]))
    event |> Map.put("contract", contract && contract["ref"]) |> Map.update!("data", &Map.put(&1, "restrictions", Enum.uniq(ids)))
  end

  defp bind_natural(event, _, _, _), do: event

  defp parse_note(note) do
    body = note["body"] || ""

    payload = note_payload(body)

    if is_map(payload) and is_map(payload["data"] || %{}) do
      version = TaskWorkflow.digest(%{"body" => body, "updated_at" => note["updated_at"]})

      %{
        "id" => note["id"],
        "version" => version,
        "ref" => "note:#{note["id"]}@#{version}",
        "at" => time(note["updated_at"] || note["created_at"]),
        "actor" => to_string(get_in(note, ["author", "id"])),
        "action" => payload["action"],
        "contract" => payload["contract"],
        "data" => payload["data"] || %{},
        "natural" => payload["natural"] == true
      }
    end
  end

  defp note_payload(body) do
    case Regex.run(~r/<!-- symphony-workflow\s+(\{.*?\})\s*-->/s, body) do
      [_, json] -> decode_payload(json)
      _ -> natural(String.trim(body))
    end
  end

  defp decode_payload(json) do
    case Jason.decode(json) do
      {:ok, %{"action" => action} = data} when is_binary(action) -> data
      _ -> nil
    end
  end

  defp natural(text) when text in ["暂停", "暂停任务", "停止执行", "Pause task", "Stop execution"], do: %{"action" => "pause", "natural" => true}
  defp natural(text) when text in ["恢复执行", "继续执行", "Resume execution"], do: %{"action" => "resume", "natural" => true}
  defp natural(_), do: nil

  defp time(text) do
    case DateTime.from_iso8601(text || "") do
      {:ok, date, _} -> DateTime.to_unix(date, :microsecond)
      _ -> 0
    end
  end

  defp versions(items, prefix, issue_url, notes, client, settings) do
    Enum.reduce_while(items, {:ok, %{}, true, []}, fn item, {:ok, versions, merged, urls} ->
      case artifact(item, prefix, issue_url, notes, client, settings) do
        {:ok, version, complete, native_merged} -> {:cont, {:ok, Map.put(versions, item["url"], version), merged and complete, if(native_merged, do: [item["url"] | urls], else: urls)}}
        error -> {:halt, error}
      end
    end)
  end

  defp artifact(item, prefix, issue_url, notes, client, settings) do
    mr_prefix = String.replace(issue_url, ~r{/issues/\d+$}, "/merge_requests/")
    url = item["url"] || ""

    cond do
      String.starts_with?(url, mr_prefix) -> mr_artifact(item, prefix, mr_prefix, client, settings)
      String.starts_with?(url, issue_url <> "#note_") -> report_artifact(url, notes)
      true -> {:error, :unsupported_artifact_reference}
    end
  end

  defp mr_artifact(item, prefix, mr_prefix, client, settings) do
    id = String.replace_prefix(item["url"], mr_prefix, "")

    with true <- Regex.match?(~r/^[1-9][0-9]*$/, id),
         {:ok, mr} <- get(client, prefix <> "/merge_requests/" <> id, settings),
         true <- mr["web_url"] == item["url"] and mr["source_project_id"] == mr["target_project_id"] do
      merged = mr["state"] == "merged" and is_binary(mr["merged_at"])
      verified = merged and item["checks"] == true and item["review"] == true
      {:ok, get_in(mr, ["diff_refs", "head_sha"]) || mr["sha"], verified, merged}
    else
      error -> {:error, {:artifact_not_verified, error}}
    end
  end

  defp report_artifact(url, notes) do
    case Regex.run(~r/#note_([1-9][0-9]*)$/, url) do
      [_, id] ->
        note = Enum.find(notes, &(&1["id"] == String.to_integer(id)))
        {:ok, if(note, do: TaskWorkflow.digest(note["body"] || ""), else: nil), false, false}

      _ ->
        {:error, :unsupported_artifact_reference}
    end
  end

  defp dependencies(flow, prefix, client, settings) do
    Enum.reduce_while(flow["restrictions"], {:ok, []}, fn {id, restriction}, {:ok, satisfied} ->
      case dependency(restriction, prefix, client, settings) do
        {:ok, true} -> {:cont, {:ok, [id | satisfied]}}
        {:ok, false} -> {:cont, {:ok, satisfied}}
        error -> {:halt, error}
      end
    end)
  end

  defp dependency(%{"kind" => "dependency", "condition" => %{"kind" => kind, "number" => number}}, prefix, client, settings)
       when kind in ["issue", "mr"] and is_integer(number) and number > 0 do
    {segment, expected} = if kind == "issue", do: {"/issues/", "closed"}, else: {"/merge_requests/", "merged"}

    case get(client, prefix <> segment <> to_string(number), settings) do
      {:ok, native} -> {:ok, native["state"] == expected}
      error -> error
    end
  end

  defp dependency(_, _, _, _), do: {:ok, false}

  defp check_routing(flow, facts, active) do
    routed = "symphony:ready" in facts["labels"]

    cond do
      not facts["owner_valid"] ->
        put_in(flow, ["restrictions", "owner"], %{"kind" => "decision", "scope" => "task"})

      not routed and not flow["routing_removed"] and (active or flow["started"]) ->
        put_in(flow, ["restrictions", "external_routing"], %{"kind" => "decision", "scope" => "task"})

      true ->
        Map.update!(flow, "restrictions", &Map.delete(&1, "owner"))
    end
  end

  defp routing(record, raw, path, settings, client, active) do
    flow = record["workflow"]
    remove = flow["state"] in ["waiting", "review", "ended"]
    add = restore_routing?(record, active)
    labels = settings.required_labels ++ ["symphony:retry"]
    routed = Enum.any?(labels, &(&1 in raw["labels"]))

    cond do
      remove and routed ->
        with {:ok, intent} <- RunJournal.checkpoint(record, %{"workflow" => Map.put(flow, "routing_removed", true)}),
             {:ok, _} <- request(client, "PUT", path, %{"remove_labels" => Enum.join(labels, ",")}, settings),
             {:ok, current} <- get(client, path, settings),
             true <- Enum.all?(labels, &(&1 not in current["labels"])) do
          {:ok, intent}
        else
          error -> {:error, {:routing_release_unconfirmed, error}}
        end

      add and not routed ->
        with {:ok, _} <- request(client, "PUT", path, %{"add_labels" => Enum.join(settings.required_labels, ",")}, settings),
             {:ok, current} <- get(client, path, settings),
             true <- Enum.all?(settings.required_labels, &(&1 in current["labels"])) do
          # The next admission reads all decisions again, including a racing pause.
          RunJournal.checkpoint(record, %{"workflow" => Map.put(flow, "routing_removed", false)})
        else
          error -> {:error, {:routing_restore_unconfirmed, error}}
        end

      true ->
        {:ok, record}
    end
  end

  defp restore_routing?(record, active) do
    flow = record["workflow"]

    not active and flow["state"] == "ready" and flow["routing_removed"] and
      flow["resume_requested"] and stopped?(record)
  end

  defp stopped?(record), do: record["native_stop_confirmed"] == true or record["thread_allocation_intent"] != true

  defp get(client, path, settings), do: request(client, "GET", path, nil, settings)

  defp request(client, method, path, body, settings) do
    case client.(method, path, %{}, body, tracker_settings: settings) do
      {:ok, %{status: status, body: result}} when status in 200..299 -> {:ok, result}
      error -> {:error, error}
    end
  end

  defp pages(client, path, settings, page, acc) do
    result = client.("GET", path, %{"per_page" => 100, "page" => page}, nil, tracker_settings: settings)

    case result do
      {:ok, %{status: 200, body: notes}} when is_list(notes) ->
        if length(notes) < 100, do: {:ok, acc ++ notes}, else: pages(client, path, settings, page + 1, acc ++ notes)

      error ->
        {:error, error}
    end
  end
end
