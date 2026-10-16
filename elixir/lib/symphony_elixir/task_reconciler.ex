defmodule SymphonyElixir.TaskReconciler do
  @moduledoc "Reconcile Issue decisions on the existing execution and scheduler loops."
  require Logger
  alias SymphonyElixir.{Config, Execution, RunJournal, TaskWorkflow}
  alias SymphonyElixir.GitLab.Client

  # Human labels. The engine never writes them: authorization, rework and
  # acceptance are always human actions, and removing `symphony:ready` revokes
  # scheduling.
  @human_labels ["symphony:ready", "symphony:rework", "symphony:accept"]
  # Engine labels. The engine owns them; people never write them.
  @engine_labels ["symphony:running", "symphony:review", "symphony:blocked", "symphony:failed"]
  # Engine notices carry a hidden marker. The engine currently writes through the
  # same credentials as the human, so the marker is what tells its own question
  # apart from the owner's answer.
  @engine_notice_marker "<!-- symphony-engine-notice -->"

  @spec human_labels() :: [String.t()]
  def human_labels, do: @human_labels

  @spec engine_labels() :: [String.t()]
  def engine_labels, do: @engine_labels

  @spec engine_notice_marker() :: String.t()
  def engine_notice_marker, do: @engine_notice_marker

  @spec engine_notice?(map()) :: boolean()
  def engine_notice?(note) do
    body = String.trim_trailing(note["body"] || "")
    body == @engine_notice_marker or String.ends_with?(body, "\n" <> @engine_notice_marker)
  end

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

          with {:ok, current} <- RunJournal.read(record["directory"]),
               {:ok, current} <- Execution.reconcile_native_stop(current) do
            with {:ok, _} <- refresh(current, false) do
              reconcile_pending_delivery(current)
            end
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

  defp reconcile_pending_delivery(record) do
    issue = %SymphonyElixir.Tracker.Issue{id: record["issue_id"], url: record["issue_url"], identifier: record["issue_identifier"]}
    client = Application.get_env(:symphony_elixir, :task_workflow_client, &Client.request/5)
    Execution.reconcile_delivery(issue, tracker_settings: Config.settings!().tracker, gitlab_client: client)
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
         {:ok, label_events} <- pages(client, path <> "/resource_label_events", settings, 1, []),
         {:ok, facts, events} <- facts(raw, notes, label_events, record, prefix, client, settings) do
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

      with {:ok, saved} <- RunJournal.checkpoint(record, %{"workflow" => flow}),
           {:ok, saved} <- notify_restrictions(saved, path, settings, client),
           {:ok, saved} <- maybe_close(saved, raw, path, settings, client) do
        routing(saved, raw, path, settings, client, active)
      end
    end
  end

  defp notify_restrictions(record, path, settings, client) do
    if stopped?(record) do
      Enum.reduce_while(record["workflow"]["restrictions"], {:ok, record}, fn {id, restriction}, {:ok, current} ->
        next_notice(current, id, restriction, path, settings, client)
      end)
    else
      {:ok, record}
    end
  end

  defp next_notice(record, id, restriction, path, settings, client) do
    case notify_restriction(record, id, restriction, path, settings, client) do
      {:ok, saved} -> {:cont, {:ok, saved}}
      error -> {:halt, error}
    end
  end

  defp notify_restriction(record, id, %{"kind" => kind} = restriction, path, settings, client)
       when kind in ["decision", "scope", "budget"] do
    key = TaskWorkflow.digest(restriction)
    previous = record["waiting_notices"] || %{}

    if previous[id] == key do
      {:ok, record}
    else
      body = restriction_notice(record, id, kind, restriction)

      with {:ok, notes} <- pages(client, path <> "/notes", settings, 1, []),
           :ok <- post_wait_notice(notes, body, path, settings, client) do
        RunJournal.checkpoint(record, %{"waiting_notices" => Map.put(previous, id, key)})
      end
    end
  end

  defp notify_restriction(record, _, _, _, _, _), do: {:ok, record}

  defp restriction_notice(record, id, kind, restriction) do
    message =
      case {id, kind} do
        {"budget", _} -> "累计执行预算已用完。请授权人追加预算、调整约定或决定如何处理现有成果。"
        {"baseline", _} -> "当前任务约定版本无法核验。请授权人确认范围、权限和验收条件。"
        {"external_routing", _} -> "调度标签被外部移除，原因尚未核验。请授权人明确是否恢复执行。"
        {_, "scope"} -> "这条请求无法对应原有验收项，或改变了任务约定。请授权人确认受影响部分；独立且已授权的工作可继续。"
        _ -> "存在未解除的执行限制或含义不清的指令。请授权人确认具体决定；调度标签不会代替授权。"
      end

    source =
      case Regex.run(~r/^note:([1-9][0-9]*)@/, restriction["source"] || "") do
        [_, number] -> "\n\n[需要确认的指令](#{record["issue_url"]}#note_#{number})"
        _ -> ""
      end

    "**Symphony 需要确认**\n\n" <> message <> source <> "\n\n" <> @engine_notice_marker
  end

  defp post_wait_notice(notes, body, path, settings, client) do
    if Enum.any?(notes, &(&1["body"] == body)) do
      :ok
    else
      with {:ok, note} <- request(client, "POST", path <> "/notes", %{"body" => body}, settings),
           true <- is_map(note) and note["body"] == body do
        :ok
      else
        error -> {:error, {:waiting_notice_unconfirmed, error}}
      end
    end
  end

  defp maybe_close(record, raw, path, settings, client) do
    flow = record["workflow"]

    if close_authorized?(record, raw) do
      conclusion = flow["acceptance"] || %{"ref" => flow["cancellation"]}

      with {:ok, intent} <- RunJournal.checkpoint(record, %{"closure_intent" => conclusion}),
           {:ok, _} <- request(client, "PUT", path, %{"state_event" => "close"}, settings),
           {:ok, current} <- get(client, path, settings),
           true <- current["state"] == "closed" do
        RunJournal.checkpoint(intent, %{"closure_confirmed" => conclusion})
      else
        error -> {:error, {:issue_closure_unconfirmed, error}}
      end
    else
      {:ok, record}
    end
  end

  defp close_authorized?(record, raw) do
    flow = record["workflow"]

    get_in(flow, ["contract", "close_on_conclusion"]) == true and raw["state"] != "closed" and
      TaskWorkflow.valid_conclusion?(flow) and stopped?(record)
  end

  defp facts(raw, notes, label_events, record, prefix, client, settings) do
    owner =
      case raw["assignees"] do
        [%{"id" => id}] -> to_string(id)
        _ -> nil
      end

    type = raw["labels"] |> Enum.filter(&(&1 in ["type:research", "type:development", "type:mixed"]))
    type = if length(type) == 1, do: String.replace(hd(type), "type:", ""), else: nil
    now = System.system_time(:millisecond)
    flow = record["workflow"] || TaskWorkflow.new(Execution.run_budget_ms(record["issue_id"]), now)
    contract = description_contract(raw["description"])
    issue_version = TaskWorkflow.digest(raw["description"] || "")
    events = events(notes, flow, owner) ++ label_events(label_events, flow, contract, issue_version, owner)

    basic = %{
      "owner" => owner,
      "type" => type,
      "issue_version" => issue_version,
      "contract" => contract,
      "closed" => raw["state"] == "closed",
      "labels" => raw["labels"],
      "versions" => %{},
      "now" => now,
      "source_refs" => Enum.map(events, & &1["ref"]),
      "observed_refs" => notes |> Enum.reject(&(&1["system"] == true)) |> Enum.map(&source_ref/1),
      "owner_valid" => owner == settings.assignee
    }

    candidate = TaskWorkflow.reconcile(flow, basic, events, now)
    items = Enum.flat_map(List.wrap(candidate["manifest"]), & &1["items"]) ++ List.wrap(flow["intermediate"])

    with {:ok, versions, merged, merged_urls} <- versions(items, prefix, raw["web_url"], notes, client, settings),
         {:ok, satisfied} <- dependencies(candidate, prefix, client, settings) do
      evidence = %{"versions" => versions, "merge_verified" => merged, "deliveries_ready" => merged, "merged_urls" => merged_urls, "satisfied" => satisfied}
      {:ok, Map.merge(basic, evidence), events}
    end
  end

  @spec description_contract(String.t() | nil) :: map() | nil
  def description_contract(description) do
    with [_, json] <- Regex.run(~r/<!--\s*symphony-contract\s+(\{.*?\})\s*-->/s, description || ""),
         {:ok, %{"contract_sha" => sha} = block} when is_binary(sha) <- Jason.decode(json),
         data = Map.delete(block, "contract_sha"),
         true <- sha == TaskWorkflow.digest(data) do
      Map.put(data, "contract_sha", sha)
    else
      _ -> nil
    end
  end

  @spec label_events([map()], map(), map() | nil, String.t(), String.t() | nil) :: [map()]
  def label_events(raw_events, flow, contract, issue_version, owner) do
    raw_events
    |> Enum.filter(&(&1["action"] == "add"))
    |> Enum.flat_map(&label_event(&1, flow, contract, issue_version, owner))
  end

  defp label_event(%{"label" => %{"name" => name}, "id" => id} = raw, flow, contract, issue_version, owner) do
    actor = to_string(get_in(raw, ["user", "id"]) || owner)
    ref = "label:#{id}@#{actor}@#{raw["created_at"]}"

    # Zero-padding keeps `{at, id, version}` in numeric order for label events
    # instead of lexicographic order, while every label id still sorts above the
    # integer note ids, matching `event_priority/1`.
    base = %{"id" => "label:#{String.pad_leading(to_string(id), 12, "0")}", "ref" => ref, "at" => time(raw["created_at"]), "actor" => actor}

    case name do
      "symphony:ready" ->
        [base |> Map.put("action", "authorize") |> Map.put("contract", nil) |> Map.put("data", authorize_data(contract, issue_version))]

      "symphony:rework" ->
        [base |> Map.put("action", "rework") |> Map.put("contract", contract_ref(flow)) |> Map.put("data", rework_data(flow))]

      "symphony:accept" ->
        [base |> Map.put("action", "accept") |> Map.put("contract", contract_ref(flow)) |> Map.put("data", %{})]

      _ ->
        []
    end
  end

  defp label_event(_, _, _, _, _), do: []

  defp contract_ref(flow), do: get_in(flow, ["contract", "ref"])

  defp authorize_data(nil, issue_version), do: %{"issue_version" => issue_version}
  defp authorize_data(contract, issue_version), do: Map.put(contract, "issue_version", issue_version)

  defp rework_data(flow), do: %{"criteria" => get_in(flow, ["contract", "criteria"]) || [], "changes" => []}

  @spec events([map()], map(), String.t() | nil) :: [map()]
  def events(notes, flow, owner) do
    question = question(notes)

    parsed =
      notes
      |> Enum.reject(&(&1["system"] == true))
      |> Enum.map(&parse_note(&1, flow, owner, question))
      |> Enum.reject(&is_nil/1)

    contracts = Enum.filter(parsed, &(&1["action"] == "authorize" and &1["actor"] == (get_in(flow, ["contract", "authorizer"]) || owner)))

    Enum.map(parsed, &bind_natural(&1, contracts, parsed, flow))
  end

  defp bind_natural(%{"natural" => true} = event, contracts, parsed, flow) do
    contract = contracts |> Enum.filter(&(&1["at"] <= event["at"])) |> Enum.max_by(& &1["at"], fn -> flow["contract"] end)
    ids = natural_restrictions(event, parsed, flow)
    event |> Map.put("contract", contract && contract["ref"]) |> Map.update!("data", &Map.put(&1, "restrictions", Enum.uniq(ids)))
  end

  defp bind_natural(event, _, _, _), do: event

  # The restrictions a natural note releases: an answer resumes the task, so it
  # releases the decision that asked for it and the pauses that precede it. Only
  # a note that follows the question is an answer, so an older resume cannot
  # release a decision raised after it.
  defp natural_restrictions(%{"answer" => true} = event, parsed, flow),
    do: pause_releases(event, parsed, flow) ++ decision_handoff(flow)

  defp natural_restrictions(event, parsed, flow), do: pause_releases(event, parsed, flow)

  defp pause_releases(event, parsed, flow) do
    ids = (flow["restrictions"] || %{}) |> Enum.filter(fn {_, value} -> value["kind"] == "pause" end) |> Enum.map(&elem(&1, 0))
    ids ++ (parsed |> Enum.filter(&(&1["action"] == "pause" and &1["at"] <= event["at"])) |> Enum.map(& &1["ref"]))
  end

  defp decision_handoff(flow) do
    if get_in(flow, ["restrictions", "handoff", "kind"]) == "decision", do: ["handoff"], else: []
  end

  defp parse_note(note, flow, owner, question) do
    body = note["body"] || ""
    answers? = answer?(note, flow, owner, question)
    payload = note_payload(body) || (answers? and %{"action" => "resume", "natural" => true})

    if is_map(payload) and is_map(payload["data"] || %{}) do
      version = note_version(note)

      %{
        "id" => note["id"],
        "version" => version,
        "ref" => "note:#{note["id"]}@#{version}",
        "at" => note_at(note),
        "actor" => to_string(get_in(note, ["author", "id"])),
        "action" => payload["action"],
        "contract" => payload["contract"],
        "data" => payload["data"] || %{},
        "natural" => payload["natural"] == true,
        "answer" => answer_event?(answers?, payload)
      }
    end
  end

  # A note answers the question only when it both follows the question and
  # resumes, so a clarification or pause request is not an answer.
  defp answer_event?(true, %{"action" => "resume", "natural" => true}), do: true
  defp answer_event?(_answers?, _payload), do: false

  # A blocking question is answered in the Issue itself: while the agent's
  # handoff holds a task-scope decision restriction, the owner's first comment
  # after the question reached the Issue is the answer. Anchoring on an engine
  # notice keeps an earlier comment from answering a question it predates, and
  # the notice marker keeps the engine from answering its own question.
  defp answer?(note, flow, owner, question) do
    handoff = get_in(flow, ["restrictions", "handoff"])

    is_map(handoff) and handoff["kind"] == "decision" and is_binary(owner) and
      to_string(get_in(note, ["author", "id"])) == owner and
      not engine_notice?(note) and after_question?(note, question)
  end

  # The newest engine notice is when the pending question reached the Issue.
  defp question(notes),
    do: notes |> Enum.filter(&engine_notice?/1) |> Enum.max_by(&{note_at(&1), &1["id"] || 0}, fn -> nil end)

  defp after_question?(_note, nil), do: false

  # Notes carry second precision, so a note in the question's own second counts
  # only when its note id follows the notice.
  defp after_question?(note, question) do
    at = note_at(note)
    asked_at = note_at(question)

    at > asked_at or
      (at == asked_at and is_integer(note["id"]) and is_integer(question["id"]) and note["id"] > question["id"])
  end

  defp note_at(note), do: time(note["updated_at"] || note["created_at"])

  defp note_payload(body) do
    case Regex.run(~r/(?:^|\n)<!-- symphony-workflow\s+(\{.*?\})\s*-->\s*$/s, body) do
      [_, json] -> decode_payload(json)
      _ -> intent(String.trim(body))
    end
  end

  defp decode_payload(json) do
    case Jason.decode(json) do
      {:ok, %{"action" => action} = data} when is_binary(action) -> data
      _ -> nil
    end
  end

  @spec source_ref(map()) :: String.t()
  def source_ref(note), do: "note:#{note["id"]}@#{note_version(note)}"
  defp note_version(note), do: TaskWorkflow.digest(%{"body" => note["body"] || "", "updated_at" => note["updated_at"]})

  @spec intent(String.t()) :: map() | nil
  def intent(text) do
    cond do
      pause_intent?(text) -> natural("pause")
      resume_intent?(text) -> natural("resume")
      Regex.match?(~r/^(?:(?:please|could you|can you|would you)\s+)?(?:pause|stop|resume|continue)\b|^(?:请|先|暂时|请先)?(?:暂停|停止|恢复|继续)/i, text) -> natural("clarify")
      true -> nil
    end
  end

  defp pause_intent?(text) do
    english = ~r/^(?:please\s+)?(?:pause|stop)(?:\s+(?:this|the))?(?:\s+(?:task|execution))?(?:\s+(?:now|please))?[.!。！]?$/iu
    chinese = ~r/^(?:请|先|暂时|请先)?(?:暂停|停止)(?:一下)?(?:这个|该|此)?(?:任务|执行)?[。！!]?$/u
    Regex.match?(english, text) or Regex.match?(chinese, text)
  end

  defp resume_intent?(text) do
    english = ~r/^(?:please\s+)?(?:resume|continue)(?:\s+(?:this|the))?(?:\s+(?:task|execution))?[.!。！]?$/iu
    chinese = ~r/^(?:请|继续|请先)?(?:恢复|继续)(?:这个|该|此)?(?:任务|执行)?[。！!]?$/u
    Regex.match?(english, text) or Regex.match?(chinese, text)
  end

  defp natural(action), do: %{"action" => action, "natural" => true}

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
      item["kind"] == "mr" and String.starts_with?(url, mr_prefix) -> mr_artifact(item, prefix, mr_prefix, client, settings)
      item["kind"] == "report" and String.starts_with?(url, issue_url <> "#note_") -> report_artifact(url, notes)
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
        version = if note, do: TaskWorkflow.digest(note["body"] || "")
        ready = is_map(note) and is_binary(note["body"]) and String.trim(note["body"]) != ""
        {:ok, version, ready, false}

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

      not routed and (active or flow["started"]) ->
        put_in(flow, ["restrictions", "external_routing"], %{"kind" => "decision", "scope" => "task"})

      true ->
        flow = if flow["restrictions"]["owner"], do: Map.put(flow, "resume_requested", true), else: flow
        Map.update!(flow, "restrictions", &Map.delete(&1, "owner"))
    end
  end

  defp routing(record, raw, path, settings, client, active) do
    desired = state_labels(record, active)
    current = raw["labels"] |> List.wrap() |> Enum.filter(&(&1 in @engine_labels))
    add = desired -- current
    remove = current -- desired

    if add == [] and remove == [] do
      {:ok, record}
    else
      with :ok <- write_state_labels(client, path, settings, add, remove),
           :ok <- verify_state_labels(client, path, settings, desired, add, remove) do
        {:ok, record}
      end
    end
  end

  defp write_state_labels(client, path, settings, add, remove) do
    case request(client, "PUT", path, label_change(add, remove), settings) do
      {:ok, _} -> :ok
      error -> {:error, {:state_label_unconfirmed, error}}
    end
  end

  defp verify_state_labels(client, path, settings, desired, add, remove) do
    case get(client, path, settings) do
      {:ok, %{} = current_issue} ->
        if observed_engine_labels(current_issue) == Enum.sort(desired) do
          :ok
        else
          {:error, {:state_label_unconfirmed, {current_issue["labels"], desired, add, remove}}}
        end

      error ->
        {:error, {:state_label_unconfirmed, error}}
    end
  end

  defp label_change(add, remove) do
    %{}
    |> then(&if(add == [], do: &1, else: Map.put(&1, "add_labels", Enum.join(add, ","))))
    |> then(&if(remove == [], do: &1, else: Map.put(&1, "remove_labels", Enum.join(remove, ","))))
  end

  defp observed_engine_labels(issue) do
    issue["labels"] |> List.wrap() |> Enum.filter(&(&1 in @engine_labels)) |> Enum.sort()
  end

  # The engine's own labels always describe the current logical state, so a poll
  # repairs a stale or missing state label without touching human labels.
  defp state_labels(%{"phase" => "incident"} = record, _active) do
    if stopped?(record), do: ["symphony:failed"], else: []
  end

  defp state_labels(record, active) do
    flow = record["workflow"] || %{}

    cond do
      flow["state"] in [nil, "ended"] -> []
      review_label?(flow) -> ["symphony:review"]
      flow["state"] == "waiting" -> ["symphony:blocked"]
      flow["state"] == "running" -> ["symphony:running"]
      flow["state"] == "ready" and active -> ["symphony:running"]
      true -> []
    end
  end

  defp review_label?(flow), do: flow["state"] == "review" or review_handoff?(flow)

  # A review handoff also waits for the human, but `symphony:review` says so
  # without reading as a question the human still has to answer.
  defp review_handoff?(flow), do: get_in(flow, ["restrictions", "handoff", "kind"]) == "review"

  defp stopped?(record), do: record["native_stop_confirmed"] == true or record["thread_allocation_intent"] != true

  defp get(client, path, settings), do: request(client, "GET", path, nil, settings)

  @spec read_notes(function(), String.t(), map()) :: {:ok, [map()]} | {:error, term()}
  def read_notes(client, path, settings), do: pages(client, path, settings, 1, [])

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
