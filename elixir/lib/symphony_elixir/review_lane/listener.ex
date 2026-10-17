defmodule SymphonyElixir.ReviewLane.Listener do
  @moduledoc """
  Scheduler-owned native discovery and durable MR review execution journal.
  The existing MR is the work item; the journal owns execution identities and receipts.
  Uncertain execution or publication stays fenced across restarts.
  """
  use GenServer
  alias SymphonyElixir.{Config, TaskWorkflow, Tracker.Issue}
  alias SymphonyElixir.ReviewLane.{GitLab, Policy}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]) |> Keyword.put_new(:name, __MODULE__))

  @spec health() :: map()
  def health, do: GenServer.call(__MODULE__, :health)

  @spec issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def issues, do: GenServer.call(__MODULE__, :issues, 120_000)

  @spec begin_run(String.t()) :: {:ok, map(), map()} | {:error, term()}
  def begin_run(id), do: GenServer.call(__MODULE__, {:begin, id}, 60_000)

  @spec checkpoint(String.t(), map()) :: :ok
  def checkpoint(id, changes), do: GenServer.call(__MODULE__, {:checkpoint, id, changes}, 60_000)

  @spec submit(String.t(), map()) :: :ok | {:error, term()}
  def submit(id, arguments), do: GenServer.call(__MODULE__, {:submit, id, arguments}, 120_000)

  @spec request_review(String.t(), pos_integer()) :: :ok | {:error, term()}
  def request_review(project, iid), do: GenServer.call(__MODULE__, {:request_review, project, iid}, 120_000)

  @impl true
  def init(opts) do
    Process.send_after(self(), :configure, 100)

    state = %{
      config: nil,
      health: :disabled,
      records: %{},
      hints: %{},
      last_event_at: nil,
      error: nil,
      initial_config: opts[:config]
    }

    {:ok, state}
  end

  @impl true
  def handle_call(message, from, state) do
    bypass = message == :health or match?({:checkpoint, _, _}, message) or is_nil(state.config)

    if bypass or current_config?(state),
      do: handle_request(message, from, state),
      else: {:reply, {:error, :review_lane_configuration_changed_restart_required}, suspend(state)}
  end

  defp handle_request(:health, _from, state) do
    {:reply,
     Map.take(state, [:health, :last_event_at, :error])
     |> Map.put(:discovery, :native_scan)
     |> Map.put(:pending_hints, map_size(state.hints))
     |> Map.put(
       :fenced_runs,
       Enum.filter(Map.values(state.records), &(&1["phase"] in ["running", "publishing", "failed", "fenced"]))
       |> Enum.map(&Map.take(&1, ["id", "phase", "error", "thread_id", "turn_id"]))
     ), state}
  end

  defp handle_request(:issues, _from, %{config: nil} = state), do: {:reply, {:ok, []}, state}

  defp handle_request(:issues, _from, state) do
    state = state |> discover() |> consume_hints() |> reconcile()
    issues = Enum.map(state.records, fn {_key, record} -> issue(record) end)
    {:reply, {:ok, issues}, state}
  end

  defp handle_request({:request_review, project, iid}, _from, state) do
    if state.config && is_binary(project) && is_integer(iid) && iid > 0 && Map.has_key?(state.config["projects"], project) do
      key = TaskWorkflow.digest([project, iid])
      next = persist(%{state | hints: Map.put(state.hints, key, %{"project" => project, "iid" => iid}), last_event_at: DateTime.utc_now() |> DateTime.to_iso8601()})
      {:reply, :ok, next}
    else
      {:reply, {:error, :invalid_review_scope}, state}
    end
  end

  defp handle_request({:checkpoint, id, changes}, _from, state) do
    record = Map.fetch!(state.records, record_key(id))

    if record["phase"] in ["completed", "ended"] and changes["phase"] == "failed" and stopped?(record) do
      {:reply, :ok, state}
    else
      next = put_record(state, Map.merge(record, changes))
      {:reply, :ok, next}
    end
  end

  defp handle_request({:begin, id}, _from, state) do
    state = reconcile(state)

    case Map.get(state.records, record_key(id)) do
      %{"phase" => "queued", "eligibility" => "current"} = record ->
        record = record |> Map.put("phase", "running") |> Map.put("native_stop_confirmed", false)
        next = put_record(state, record)
        {:reply, {:ok, record, state.config}, next}

      _ ->
        {:reply, {:error, :review_execution_fenced}, state}
    end
  end

  defp handle_request({:submit, id, arguments}, _from, state) do
    case publish(state, id, arguments) do
      {:ok, next} -> {:reply, :ok, next}
      {:error, reason, next} -> {:reply, {:error, reason}, next}
    end
  end

  @impl true
  def handle_info(:configure, state) do
    settings = initial_settings(state.initial_config)

    case settings do
      {:ok, %{tracker: %{provider: %{"review_lane" => %{"enabled" => true} = config}}}} ->
        case load(state, config) do
          {:ok, next} ->
            Process.send_after(self(), :check_config, 1_000)
            Process.send_after(self(), :poll, 0)
            {:noreply, %{recover(next) | health: :listening}}

          {:error, reason} ->
            {:noreply, %{state | health: :failed, error: inspect(reason)}}
        end

      _ ->
        Process.send_after(self(), :configure, 1_000)
        {:noreply, state}
    end
  end

  def handle_info(:poll, %{config: nil} = state), do: {:noreply, state}

  def handle_info(:poll, state) do
    Process.send_after(self(), :poll, state.config["poll_interval_ms"] || 60_000)
    next = if current_config?(state), do: state |> discover() |> consume_hints() |> reconcile(), else: suspend(state)
    {:noreply, next}
  end

  def handle_info(:check_config, state) do
    Process.send_after(self(), :check_config, 1_000)
    {:noreply, if(current_config?(state), do: state, else: suspend(state))}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp initial_settings(nil), do: Config.settings()
  defp initial_settings(config), do: {:ok, %{tracker: %{provider: %{"review_lane" => config}}}}

  defp current_config?(%{initial_config: config}) when is_map(config), do: true

  defp current_config?(state) do
    with :ok <- Config.validate!(),
         {:ok, %{tracker: %{provider: %{"review_lane" => %{"enabled" => true} = config}}}} <- Config.settings() do
      SymphonyElixir.ReviewLane.resolve(config) == state.config
    else
      _ -> false
    end
  end

  defp suspend(state), do: %{state | health: :failed, error: "Configuration changed or invalid; restart required"}

  defp recover(state) do
    Enum.reduce(state.records, state, fn {_id, record}, current ->
      if record["phase"] in ["running", "publishing", "failed"] or (record["phase"] == "completed" and not stopped?(record)) do
        put_record(current, record |> Map.put("previous_phase", record["phase"]) |> Map.put("phase", "fenced"))
      else
        current
      end
    end)
  end

  defp load(state, raw_config) do
    config = SymphonyElixir.ReviewLane.resolve(raw_config)
    path = Path.join(config["state_dir"], "review-lane.json")

    with :ok <- SymphonyElixir.ReviewLane.validate_config(%{provider: %{"review_lane" => config}}),
         true <- not File.exists?(Path.join(config["state_dir"], "mail-review.json")) or {:error, :legacy_review_journal_requires_migration},
         :ok <- File.mkdir_p(config["state_dir"]) do
      case File.read(path) do
        {:ok, content} ->
          restore(state, config, content)

        {:error, :enoent} ->
          {:ok, %{state | config: config}}

        error ->
          error
      end
    end
  end

  defp restore(state, config, content) do
    with {:ok, data} <- Jason.decode(content),
         true <- data["schema_version"] == 2 and scope(data["scope"] || %{}) == scope(config),
         true <- records?(data["records"], config) and hints?(data["hints"], config) do
      {:ok, %{state | config: config, records: data["records"], hints: data["hints"]}}
    else
      _ -> {:error, :invalid_review_journal}
    end
  end

  defp records?(records, config) when is_map(records), do: Enum.all?(records, fn {id, record} -> record?(id, record, config) end)
  defp records?(_, _), do: false

  defp record?(id, %{} = record, config) do
    valid_subject?(record, config) and record_shape?(record) and
      record["work"] == work(config, record["project"], record["iid"]) and
      id == record["id"] and id == round_id(record["work"], record["round"], config)
  end

  defp record?(_, _, _), do: false

  defp record_shape?(record) do
    is_integer(record["round"]) and record["round"] > 0 and
      record["phase"] in ~w(queued running publishing completed failed fenced ended superseded) and
      is_list(record["findings"]) and Enum.all?(record["findings"], &is_map/1) and
      Enum.all?(~w(head base), &valid_sha?(record[&1])) and Enum.all?(~w(policy_sha response_sha), &digest?(record[&1]))
  end

  defp digest?(value), do: is_binary(value) and Regex.match?(~r/^[a-f0-9]{64}$/, value)

  defp hints?(hints, config) when is_map(hints) do
    Enum.all?(hints, fn {key, hint} ->
      valid_subject?(hint, config) and key == TaskWorkflow.digest([hint["project"], hint["iid"]])
    end)
  end

  defp hints?(_, _), do: false

  defp valid_subject?(%{"project" => project, "iid" => iid}, config),
    do: is_binary(project) and Map.has_key?(config["projects"], project) and is_integer(iid) and iid > 0

  defp valid_subject?(_, _), do: false

  defp discover(state) do
    state = %{state | health: :listening, error: nil}

    Enum.reduce(Map.keys(state.config["projects"]) |> Enum.sort(), state, fn project, current ->
      case GitLab.assigned(state.config, project) do
        {:ok, numbers} -> Enum.reduce(numbers, current, &discovered(&2, project, &1))
        {:error, reason} -> %{current | health: :degraded, error: inspect(reason)}
      end
    end)
  end

  defp discovered(state, project, iid) do
    case candidate(state, {:ok, project, iid}) do
      {:ok, next} -> next
      {:error, reason} -> %{state | health: :degraded, error: inspect(reason)}
    end
  end

  defp consume_hints(state) do
    Enum.reduce(state.hints, state, fn {key, hint}, current ->
      case candidate(current, {:ok, hint["project"], hint["iid"]}) do
        {:ok, next} -> persist(%{next | hints: Map.delete(next.hints, key)})
        {:error, reason} -> %{current | error: inspect(reason)}
      end
    end)
  end

  defp candidate(state, {:ok, project, iid}) do
    path = GitLab.mr_path(project, iid)

    with {:ok, mr} <- GitLab.request(state.config, "GET", path),
         true <- valid_mr?(mr, project, iid, state.config),
         true <- Policy.requested_reviewer?(mr, state.config["reviewer_id"]) do
      previous = state.records |> Map.values() |> Enum.filter(&(&1["project"] == project and &1["iid"] == iid))
      if previous == [], do: queue(state, project, iid, mr, 1), else: {:ok, state}
    else
      false -> {:ok, state}
      error -> error
    end
  end

  defp valid_mr?(mr, project, iid, config) when is_map(mr) do
    mr["iid"] == iid and mr["project_id"] == config["projects"][project]["id"] and
      actors?(mr) and mr["state"] in ["opened", "closed", "merged"] and is_map(mr["diff_refs"]) and
      Enum.all?([mr["sha"], get_in(mr, ["diff_refs", "base_sha"])], &valid_sha?/1) and
      valid_mr_url?(mr["web_url"], project, iid, config)
  end

  defp valid_mr?(_, _, _, _), do: false
  defp actors?(%{"author" => %{"id" => id}, "reviewers" => reviewers}), do: is_integer(id) and id > 0 and reviewers?(reviewers)
  defp actors?(_), do: false
  defp reviewers?(reviewers) when is_list(reviewers), do: Enum.all?(reviewers, &(is_map(&1) and is_integer(&1["id"]) and &1["id"] > 0))
  defp reviewers?(_), do: false

  defp valid_sha?(sha), do: is_binary(sha) and Regex.match?(~r/^(?:[a-f0-9]{40}|[a-f0-9]{64})$/, sha)

  defp valid_mr_url?(url, project, iid, config) do
    GitLab.web_url?(url, config, "/#{project}/-/merge_requests/#{iid}")
  end

  defp queue(state, project, iid, mr, round, response_sha \\ TaskWorkflow.digest([])) do
    work = work(state.config, project, iid)
    id = round_id(work, round, state.config)

    record = %{
      "id" => id,
      "project" => project,
      "work" => work,
      "iid" => iid,
      "round" => round,
      "head" => mr["sha"],
      "base" => mr["diff_refs"]["base_sha"],
      "response_sha" => response_sha,
      "policy_sha" => policy_sha(state.config),
      "eligibility" => "current",
      "author_id" => mr["author"]["id"],
      "url" => mr["web_url"],
      "findings" => [],
      "phase" => "queued"
    }

    {:ok, put_record(state, record)}
  end

  defp work(config, project, iid),
    do: %{"provider" => "gitlab", "host" => config["host"], "repository_id" => to_string(config["projects"][project]["id"]), "kind" => "mr", "number" => iid}

  defp round_id(work, round, config), do: TaskWorkflow.digest(%{"work" => work, "round" => round, "reviewer" => config["reviewer_id"]})

  defp reconcile(state) do
    state.records
    |> Map.values()
    |> Enum.group_by(&{&1["project"], &1["iid"]})
    |> Enum.map(fn {_, rounds} -> Enum.max_by(rounds, & &1["round"]) end)
    |> Enum.reduce(state, &reconcile_record(&2, &1))
  end

  defp reconcile_record(state, record) do
    path = GitLab.mr_path(record["project"], record["iid"])

    with {:ok, mr} <- GitLab.request(state.config, "GET", path),
         true <- valid_mr?(mr, record["project"], record["iid"], state.config) or {:error, :invalid_native_review} do
      reconcile_native(state, record, mr, path)
    else
      {:error, reason} -> put_record(state, record |> Map.put("eligibility", "unknown") |> Map.put("error", inspect(reason)))
    end
  end

  defp reconcile_native(state, record, mr, path) do
    if Policy.requested_reviewer?(mr, state.config["reviewer_id"]) do
      reconcile_assigned(state, record, mr, path)
    else
      reason = if mr["state"] in ["closed", "merged"], do: mr["state"], else: "unassigned"
      put_record(state, record |> Map.put("eligibility", reason) |> Map.put("phase", "ended"))
    end
  end

  defp reconcile_assigned(state, record, mr, path) do
    with {:ok, discussions} <- GitLab.discussions(state.config, path),
         {:ok, responses} <- Policy.response_digest(findings_for(state, record), discussions, record["author_id"]) do
      changed = changed_inputs?(state.config, record, mr, responses)

      cond do
        changed and stopped?(record) ->
          previous = record |> Map.put("eligibility", "superseded") |> Map.put("phase", "superseded")
          elem(queue(put_record(state, previous), record["project"], record["iid"], mr, record["round"] + 1, responses), 1)

        changed ->
          put_record(state, Map.put(record, "eligibility", "superseded"))

        true ->
          put_record(state, Map.put(record, "eligibility", "current"))
      end
    else
      {:error, reason} -> put_record(state, record |> Map.put("eligibility", "unknown") |> Map.put("error", inspect(reason)))
    end
  end

  defp findings_for(state, record) do
    state.records |> Map.values() |> Enum.filter(&(&1["project"] == record["project"] and &1["iid"] == record["iid"])) |> Enum.flat_map(& &1["findings"])
  end

  defp changed_inputs?(config, record, mr, responses) do
    mr["sha"] != record["head"] or mr["diff_refs"]["base_sha"] != record["base"] or responses != record["response_sha"] or
      policy_sha(config) != record["policy_sha"] or record["phase"] == "ended"
  end

  defp stopped?(record) do
    record["native_stop_confirmed"] == true or
      (is_nil(record["native_stop_confirmed"]) and record["phase"] not in ["running", "publishing", "failed", "fenced"] and is_nil(record["thread_id"]) and record["thread_allocation_intent"] != true)
  end

  defp policy_sha(config), do: TaskWorkflow.digest(%{"instructions" => File.read!(config["instructions_file"]), "projects" => config["projects"]})

  defp issue(record) do
    active = record["phase"] in ["queued", "running"] or (record["phase"] == "completed" and not stopped?(record))

    %Issue{
      id: "review:" <> record["id"],
      kind: :review,
      identifier: "review-#{String.slice(record["id"], 0, 16)}",
      title: "Review #{record["project"]}!#{record["iid"]}",
      description: Jason.encode!(Map.take(record, ["project", "iid", "head", "base", "round"])),
      state: if(active, do: hd(SymphonyElixir.Config.settings!().tracker.active_states), else: "closed"),
      native_ref: Map.put(record, "execution_kind", "review_lane"),
      labels: SymphonyElixir.Config.settings!().tracker.required_labels,
      dispatchable: active and record["eligibility"] == "current",
      url: record["url"]
    }
  end

  defp publish(state, id, %{"findings" => findings}) when is_list(findings) and length(findings) <= 50 do
    record = state.records[record_key(id)]

    if publishable?(record, findings) do
      record = Map.put_new(record, "submission", findings) |> Map.put("phase", "publishing")
      state = put_record(state, record)
      path = GitLab.mr_path(record["project"], record["iid"])

      with true <- record["submission"] == findings || {:error, :changed_submission},
           {:ok, mr} <- GitLab.request(state.config, "GET", path),
           true <- same_review?(mr, record, state.config) || {:error, :mr_head_changed},
           {:ok, user} <- GitLab.request(state.config, "GET", "user"),
           true <- user["id"] == state.config["publisher_id"] || {:error, :gitlab_identity_mismatch},
           {:ok, discussions} <- GitLab.discussions(state.config, path),
           record = Map.put(record, "response_findings", findings_for(state, record)),
           :ok <- same_responses(record, discussions),
           {:ok, receipts} <- post_findings(state.config, path, record, discussions) do
        {:ok, put_record(state, record |> Map.put("phase", "completed") |> Map.put("receipts", receipts) |> Map.put("findings", if(findings == [], do: [], else: receipts)))}
      else
        {:error, reason} ->
          next = put_record(state, record |> Map.put("phase", "fenced") |> Map.put("error", inspect(reason)))
          {:error, reason, next}
      end
    else
      {:error, :invalid_review_submission, state}
    end
  end

  defp publish(state, _id, _arguments), do: {:error, :invalid_review_submission, state}

  defp publishable?(nil, _findings), do: false

  defp publishable?(record, findings) do
    record["phase"] in ["running", "publishing"] and Enum.all?(findings, &valid_finding?/1)
  end

  defp valid_finding?(finding) do
    is_binary(finding) and byte_size(finding) in 1..16_384 and
      Regex.match?(~r/[\x{4e00}-\x{9fff}]/u, finding) and not String.contains?(finding, "<!-- symphony-review:")
  end

  defp post_findings(config, path, record, discussions) do
    entries = if record["submission"] == [], do: ["本轮评审未发现有充分证据支持的问题。评审范围：`#{record["base"]}` → `#{record["head"]}`。"], else: record["submission"]

    entries
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {body, index}, {:ok, receipts} ->
      marker = Policy.marker(record["id"], index)
      existing = Enum.find(discussions, &owned_note(&1["notes"] || [], marker, config))
      result = if existing, do: {:ok, existing}, else: post_at_head(config, path, record, body <> "\n\n" <> marker)
      collect_receipt(result, marker, config, receipts)
    end)
  end

  defp owned_note(notes, marker, config) do
    Enum.find(
      notes,
      &(String.contains?(&1["body"] || "", marker) and
          get_in(&1, ["author", "id"]) == config["publisher_id"])
    )
  end

  defp collect_receipt({:ok, %{"id" => discussion_id, "notes" => notes}}, marker, config, receipts) do
    case owned_note(notes, marker, config) do
      %{"id" => id} when is_integer(id) ->
        {:cont, {:ok, receipts ++ [%{"discussion_id" => discussion_id, "note_id" => id}]}}

      _ ->
        {:halt, {:error, :invalid_owned_note_receipt}}
    end
  end

  defp collect_receipt({:error, reason}, _marker, _config, _receipts), do: {:halt, {:error, reason}}
  defp collect_receipt(_result, _marker, _config, _receipts), do: {:halt, {:error, :invalid_discussion_receipt}}

  defp same_review?(mr, record, config) do
    valid_mr?(mr, record["project"], record["iid"], config) and
      mr["sha"] == record["head"] and get_in(mr, ["diff_refs", "base_sha"]) == record["base"] and
      policy_sha(config) == record["policy_sha"] and Policy.requested_reviewer?(mr, config["reviewer_id"])
  end

  defp post_at_head(config, path, record, body) do
    with {:ok, mr} <- GitLab.request(config, "GET", path),
         true <- same_review?(mr, record, config) || {:error, :mr_head_or_reviewer_changed},
         {:ok, discussions} <- GitLab.discussions(config, path),
         :ok <- same_responses(record, discussions) do
      GitLab.request(config, "POST", path <> "/discussions", %{"body" => body})
    end
  end

  defp same_responses(record, discussions) do
    expected = record["response_sha"]

    case Policy.response_digest(record["response_findings"], discussions, record["author_id"]) do
      {:ok, ^expected} -> :ok
      _ -> {:error, :review_responses_changed}
    end
  end

  defp record_key("review:" <> key), do: key
  defp record_key(key), do: key

  defp put_record(state, record) do
    if state.records[record["id"]] == record, do: state, else: persist(%{state | records: Map.put(state.records, record["id"], record)})
  end

  defp scope(config), do: Map.take(config, ["provider", "host", "reviewer_id", "publisher_id", "projects", "allow_insecure_http"])

  defp persist(state) do
    path = Path.join(state.config["state_dir"], "review-lane.json")
    File.write!(path <> ".pending", Jason.encode!(%{"schema_version" => 2, "scope" => scope(state.config), "records" => state.records, "hints" => state.hints}), [:sync])
    File.rename!(path <> ".pending", path)
    state
  end
end
