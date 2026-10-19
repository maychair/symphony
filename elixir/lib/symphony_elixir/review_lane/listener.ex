defmodule SymphonyElixir.ReviewLane.Listener do
  alias SymphonyElixir.RuntimeContext

  @moduledoc """
  Scheduler-owned native discovery and durable MR review execution journal.
  The existing MR is the work item; the journal owns execution identities and receipts.
  Uncertain execution or publication stays fenced across restarts.
  """
  use GenServer
  alias SymphonyElixir.{Config, TaskWorkflow, Tracker.Issue}
  alias SymphonyElixir.ReviewLane.{Finding, GitHub, GitLab, Journal, Owner, Policy, Publication}

  @worker_fields ~w(thread_allocation_intent turn_allocation_intent native_stop_confirmed workspace worker_host backend thread_id turn_id native_stop_receipt native_stop_recovery phase error)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]) |> Keyword.put_new(:name, __MODULE__))

  @spec health() :: map()
  def health, do: GenServer.call(RuntimeContext.server(__MODULE__), :health)

  @spec issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def issues, do: GenServer.call(RuntimeContext.server(__MODULE__), :issues, 120_000)

  @spec begin_run(String.t()) :: {:ok, map(), map()} | {:error, term()}
  def begin_run(id), do: GenServer.call(RuntimeContext.server(__MODULE__), {:begin, id}, 60_000)

  @spec checkpoint(String.t(), map() | nil, map()) :: :ok | {:error, term()}
  def checkpoint(id, owner, changes), do: GenServer.call(RuntimeContext.server(__MODULE__), {:checkpoint, id, owner, changes}, 60_000)

  @spec submit(String.t(), map() | nil, map()) :: :ok | {:error, term()}
  def submit(id, owner, arguments), do: GenServer.call(RuntimeContext.server(__MODULE__), {:submit, id, owner, arguments}, 120_000)

  @spec request_review(String.t(), pos_integer()) :: :ok | {:error, term()}
  def request_review(project, iid), do: GenServer.call(RuntimeContext.server(__MODULE__), {:request_review, project, iid}, 120_000)

  @impl true
  def init(opts) do
    RuntimeContext.install(opts[:context])
    Process.send_after(self(), :configure, 100)

    state = %{
      config: nil,
      health: :disabled,
      records: %{},
      hints: %{},
      owners: %{},
      journal: nil,
      last_event_at: nil,
      error: nil,
      initial_config: opts[:config]
    }

    {:ok, state}
  end

  @impl true
  def handle_call(message, from, state) do
    if message == :health or is_nil(state.config) do
      handle_current_call(message, from, state)
    else
      case Journal.check(state.journal) do
        :ok -> handle_current_call(message, from, state)
        {:error, reason} -> {:stop, {:review_journal_lost, reason}, {:error, reason}, state}
      end
    end
  end

  defp handle_current_call(message, from, state) do
    bypass = message == :health or match?({:checkpoint, _, _, _}, message) or is_nil(state.config)

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

  defp handle_request({:checkpoint, id, owner, changes}, {caller, _}, state) do
    record = state.records[record_key(id)]

    with true <- owned?(record, owner, caller) or {:error, :review_execution_owner_mismatch},
         true <- worker_changes?(record, changes) or {:error, :invalid_review_checkpoint} do
      checkpoint_owned(state, record, changes)
    else
      error -> {:reply, error, state}
    end
  end

  defp handle_request({:begin, id}, {caller, _}, state) do
    state = reconcile(state)

    case Map.get(state.records, record_key(id)) do
      %{"phase" => "queued", "eligibility" => "current"} = record ->
        if stopped?(record) do
          record =
            Map.merge(record, %{
              "phase" => "running",
              "native_stop_confirmed" => false,
              "native_stop_receipt" => nil,
              "thread_allocation_intent" => false,
              "turn_allocation_intent" => false,
              "execution_owner" => Owner.new(caller)
            })

          next = state |> put_record(record) |> monitor_owner(record, caller)
          {:reply, {:ok, record, state.config}, next}
        else
          {:reply, {:error, :review_execution_fenced}, state}
        end

      _ ->
        {:reply, {:error, :review_execution_fenced}, state}
    end
  end

  defp handle_request({:submit, id, owner, arguments}, {caller, _}, state) do
    if owned?(state.records[record_key(id)], owner, caller) do
      case publish(state, id, arguments) do
        {:ok, next} -> {:reply, :ok, next}
        {:error, reason, next} -> {:reply, {:error, reason}, next}
      end
    else
      {:reply, {:error, :review_execution_owner_mismatch}, state}
    end
  end

  defp owned?(%{"execution_owner" => recorded}, supplied, caller), do: Owner.authorized?(recorded, supplied, caller)
  defp owned?(_, _, _), do: false

  defp worker_changes?(record, changes) when is_map(changes) do
    Enum.all?(Map.keys(changes), &(&1 in @worker_fields)) and
      changes["phase"] in [nil, "failed", "fenced"] and stop_changes?(record, changes) and
      Enum.all?(~w(thread_allocation_intent turn_allocation_intent), &(not Map.has_key?(changes, &1) or changes[&1] == true)) and
      same_thread?(record, changes) and same_runtime?(record, changes)
  end

  defp worker_changes?(_, _), do: false

  defp stop_changes?(record, changes) do
    not (stopped?(record) and (allocation?(changes) or changes["native_stop_confirmed"] == false)) and
      not (changes["native_stop_confirmed"] == true and allocation?(changes)) and
      (not Map.has_key?(changes, "native_stop_confirmed") or is_boolean(changes["native_stop_confirmed"]))
  end

  defp same_runtime?(record, changes) do
    Enum.all?(~w(workspace worker_host backend), &(not Map.has_key?(changes, &1) or not Map.has_key?(record, &1) or record[&1] == changes[&1]))
  end

  defp same_thread?(record, %{"thread_id" => thread}) do
    is_binary(thread) and thread != "" and (is_nil(record["thread_id"]) or record["thread_id"] == thread)
  end

  defp same_thread?(_, _), do: true
  defp allocation?(changes), do: changes["thread_allocation_intent"] == true or changes["turn_allocation_intent"] == true

  defp checkpoint_owned(state, record, changes) do
    if allocation?(changes) do
      next = if current_config?(state), do: reconcile(state), else: suspend(state)
      current = next.records[record["id"]]

      if allocation_allowed?(next, current, changes) do
        {:reply, :ok, put_record(next, Map.merge(current, changes))}
      else
        {:reply, {:error, :review_execution_fenced}, next}
      end
    else
      changes = if stopped?(record) and record["phase"] in ["completed", "ended"], do: Map.delete(changes, "phase"), else: changes
      {:reply, :ok, put_record(state, Map.merge(record, changes))}
    end
  end

  defp allocation_allowed?(state, record, changes) do
    state.health != :failed and record["phase"] == "running" and record["eligibility"] == "current" and
      turn_ready?(record, changes) and
      Enum.all?(~w(thread_allocation_intent turn_allocation_intent), &(changes[&1] != true or record[&1] != true))
  end

  defp turn_ready?(record, changes) do
    changes["turn_allocation_intent"] != true or (is_binary(record["thread_id"]) and record["thread_allocation_intent"] == true)
  end

  defp monitor_owner(state, record, pid) do
    owners =
      Enum.reduce(state.owners, state.owners, fn {ref, {id, _}}, owners ->
        if id == record["id"] do
          Process.demonitor(ref, [:flush])
          Map.delete(owners, ref)
        else
          owners
        end
      end)

    %{state | owners: Map.put(owners, Process.monitor(pid), {record["id"], record["execution_owner"]})}
  end

  defp recover_owners(state) do
    Enum.reduce(state.records, state, fn {_id, record}, current -> recover_owner(current, record) end)
  end

  defp recover_owner(state, record) do
    case Owner.local_pid(record["execution_owner"]) do
      pid when is_pid(pid) ->
        cond do
          stopped?(record) ->
            state

          Process.alive?(pid) ->
            send(pid, :symphony_stop)
            monitor_owner(state, record, pid)

          true ->
            owner_down(state, record["id"], record["execution_owner"], :listener_restart)
        end

      _ ->
        state
    end
  end

  defp owner_down(state, id, owner, reason) do
    record = state.records[id]

    if record && record["execution_owner"] == owner && not stopped?(record) do
      no_allocation = not allocation?(record) and is_nil(record["thread_id"]) and is_nil(record["resume_thread_id"])
      phase = if record["phase"] in ["ended", "superseded"], do: record["phase"], else: "fenced"
      put_record(state, Map.merge(record, %{"phase" => phase, "native_stop_confirmed" => no_allocation, "error" => "Review worker exited: #{inspect(reason)}"}))
    else
      state
    end
  end

  @impl true
  def handle_info(:configure, %{journal: %{} = _journal} = state), do: {:noreply, state}

  def handle_info(:configure, state) do
    settings = initial_settings(state.initial_config)

    case settings do
      {:ok, %{tracker: %{provider: %{"review_lane" => %{"enabled" => true} = config}}}} ->
        case load(state, config) do
          {:ok, next} ->
            Process.send_after(self(), :check_config, 1_000)
            Process.send_after(self(), :poll, 0)
            {:noreply, %{(next |> recover() |> recover_owners()) | health: :listening}}

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

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.owners, ref) do
      {nil, _} -> {:noreply, state}
      {{id, owner}, owners} -> {:noreply, owner_down(%{state | owners: owners}, id, owner, reason)}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{journal: %{port: owned}} = state) when port == owned do
    {:stop, {:review_journal_lost, status}, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state), do: Journal.close(state.journal)

  defp initial_settings(nil), do: Config.settings()
  defp initial_settings(config), do: {:ok, %{tracker: %{provider: %{"review_lane" => config}}}}

  defp current_config?(state) do
    case Journal.check(state.journal) do
      :ok -> config_current?(state)
      {:error, reason} -> exit({:review_journal_lost, reason})
    end
  end

  defp config_current?(%{initial_config: config}) when is_map(config), do: true

  defp config_current?(state) do
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

    with :ok <- SymphonyElixir.ReviewLane.validate_config(%{provider: %{"review_lane" => config}}),
         true <- not File.exists?(Path.join(config["state_dir"], "mail-review.json")) or {:error, :legacy_review_journal_requires_migration},
         {:ok, journal, content} <- Journal.open(config["state_dir"]) do
      owned = %{state | journal: journal}
      result = if is_nil(content), do: {:ok, %{owned | config: config}}, else: restore(owned, config, content)

      case result do
        {:ok, _} ->
          result

        error ->
          Journal.close(journal)
          error
      end
    end
  end

  defp restore(state, config, content) do
    case Jason.decode(content) do
      {:ok, data} -> restore_records(state, config, data)
      _ -> {:error, :invalid_review_journal}
    end
  end

  defp restore_records(state, config, data) do
    cond do
      data["schema_version"] == 2 ->
        {:error, :review_journal_migration_required}

      data["schema_version"] != 3 or scope(data["scope"] || %{}) != scope(config) ->
        {:error, :invalid_review_journal}

      records?(data["records"], config) and hints?(data["hints"], config) ->
        {:ok, %{state | config: config, records: data["records"], hints: data["hints"]}}

      true ->
        {:error, :invalid_review_journal}
    end
  end

  defp records?(records, config) when is_map(records), do: Enum.all?(records, fn {id, record} -> record?(id, record, config) end)
  defp records?(_, _), do: false

  defp record?(id, %{} = record, config) do
    valid_subject?(record, config) and record_shape?(record) and Publication.valid?(record, config["publisher_id"]) and
      target_branch?(record["target_branch"]) and
      (is_nil(record["finding_register"]) or Finding.register?(record["finding_register"])) and
      record["work"] == work(config, record["project"], record["iid"]) and
      id == record["id"] and id == round_id(record["work"], record["round"], config)
  end

  defp record?(_, _, _), do: false

  defp record_shape?(record) do
    is_integer(record["round"]) and record["round"] > 0 and
      record["phase"] in ~w(queued running publishing completed failed fenced ended superseded) and
      is_list(record["findings"]) and Enum.all?(record["findings"], &is_map/1) and
      Enum.all?(~w(head base), &valid_sha?(record[&1])) and Enum.all?(~w(policy_sha response_sha), &digest?(record[&1])) and
      auxiliary_fields?(record)
  end

  defp auxiliary_fields?(record) do
    (is_nil(record["execution_owner"]) or Owner.valid?(record["execution_owner"])) and
      completion?(record) and review_gap?(record)
  end

  defp completion?(%{"review_completion" => completion} = record) when is_map(completion) do
    completion == completion_proof(record) and published_review?(record)
  end

  defp completion?(record), do: is_nil(record["review_completion"])

  defp review_gap?(%{"review_gap" => gap}) when is_map(gap) do
    gap["status"] in ["none", "missing_current_review"] and
      Enum.all?(~w(head base), &valid_sha?(gap[&1])) and target_branch?(gap["target_branch"]) and
      (is_nil(gap["completion"]) or is_map(gap["completion"]))
  end

  defp review_gap?(record), do: is_nil(record["review_gap"])

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
      case native(state.config).assigned(state.config, project) do
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
    with {:ok, mr} <- read_mr(state.config, project, iid),
         true <- valid_mr?(mr, project, iid, state.config) or {:error, :invalid_native_review},
         {:ok, true} <- lane_assignment(state.config, project, iid, mr) do
      previous = state.records |> Map.values() |> Enum.filter(&(&1["project"] == project and &1["iid"] == iid))
      if previous == [], do: queue(state, project, iid, mr, 1), else: {:ok, state}
    else
      {:ok, false} -> {:ok, state}
      error -> error
    end
  end

  # GitLab merges expose `opened/closed/merged` plus a durable reviewer list.
  # GitHub drops a submitted reviewer from `requested_reviewers`, so an absent
  # current request is resolved from the latest native timeline event. Missing
  # timeline evidence fails closed instead of treating automatic removal as an
  # explicit withdrawal.
  defp lane_assignment(%{"provider" => "github"} = config, project, iid, mr) do
    cond do
      mr["state"] != "opened" -> {:ok, false}
      Policy.requested_reviewer?(mr, config["reviewer_id"]) -> {:ok, true}
      true -> GitHub.review_assignment(config, project, iid, config["reviewer_id"])
    end
  end

  defp lane_assignment(config, _project, _iid, mr), do: {:ok, Policy.requested_reviewer?(mr, config["reviewer_id"])}

  defp valid_mr?(mr, project, iid, config) when is_map(mr) do
    mr["iid"] == iid and mr["project_id"] == config["projects"][project]["id"] and
      actors?(mr) and mr["state"] in ["opened", "closed", "merged"] and is_map(mr["diff_refs"]) and
      target_branch?(mr["target_branch"]) and
      Enum.all?([mr["sha"], get_in(mr, ["diff_refs", "base_sha"])], &valid_sha?/1) and
      valid_mr_url?(mr["web_url"], project, iid, config)
  end

  defp valid_mr?(_, _, _, _), do: false
  defp target_branch?(branch), do: is_binary(branch) and String.trim(branch) != "" and not String.contains?(branch, <<0>>)

  defp actors?(%{"author" => %{"id" => id}, "reviewers" => reviewers}), do: is_integer(id) and id > 0 and reviewers?(reviewers)
  defp actors?(_), do: false
  defp reviewers?(reviewers) when is_list(reviewers), do: Enum.all?(reviewers, &(is_map(&1) and is_integer(&1["id"]) and &1["id"] > 0))
  defp reviewers?(_), do: false

  defp valid_sha?(sha), do: is_binary(sha) and Regex.match?(~r/^(?:[a-f0-9]{40}|[a-f0-9]{64})$/, sha)

  defp valid_mr_url?(url, project, iid, config) do
    native(config).web_url?(url, config, web_url_path(config, project, iid))
  end

  defp queue(state, project, iid, mr, round, response_sha \\ TaskWorkflow.digest([])) do
    work = work(state.config, project, iid)
    id = round_id(work, round, state.config)
    register = carried_register(state, project, iid, round)

    record = %{
      "id" => id,
      "project" => project,
      "work" => work,
      "iid" => iid,
      "round" => round,
      "head" => mr["sha"],
      "base" => mr["diff_refs"]["base_sha"],
      "target_branch" => mr["target_branch"],
      "response_sha" => response_sha,
      "policy_sha" => policy_sha(state.config),
      "eligibility" => "current",
      "finding_register" => register,
      "verdict" => Finding.verdict(register),
      "author_id" => mr["author"]["id"],
      "url" => mr["web_url"],
      "findings" => [],
      "phase" => "queued"
    }

    {:ok, put_record(state, record)}
  end

  # Findings keep their identity across rounds of the same MR; a later round
  # inherits every conclusion an earlier round recorded (§17.1).
  defp carried_register(state, project, iid, round) do
    state.records
    |> Map.values()
    |> Enum.filter(&(&1["project"] == project and &1["iid"] == iid and &1["round"] < round))
    |> Enum.sort_by(& &1["round"])
    |> Enum.reduce(%{}, fn record, acc -> Map.merge(acc, record["finding_register"] || %{}) end)
  end

  defp work(config, project, iid) do
    kind = if config["provider"] == "github", do: "pr", else: "mr"
    %{"provider" => config["provider"], "host" => config["host"], "repository_id" => to_string(config["projects"][project]["id"]), "kind" => kind, "number" => iid}
  end

  defp round_id(work, round, config), do: TaskWorkflow.digest(%{"work" => work, "round" => round, "reviewer" => config["reviewer_id"]})

  defp reconcile(state) do
    state = recover_publications(state)

    state.records
    |> Map.values()
    |> Enum.group_by(&{&1["project"], &1["iid"]})
    |> Enum.map(fn {_, rounds} -> Enum.max_by(rounds, & &1["round"]) end)
    |> Enum.reduce(state, &reconcile_record(&2, &1))
    |> continue_publications()
  end

  defp reconcile_record(state, record) do
    path = native(state.config).mr_path(record["project"], record["iid"])

    with {:ok, mr} <- read_mr(state.config, record["project"], record["iid"]),
         true <- valid_mr?(mr, record["project"], record["iid"], state.config) or {:error, :invalid_native_review} do
      reconcile_native(state, record, mr, path)
    else
      {:error, reason} -> put_record(state, record |> Map.put("eligibility", "unknown") |> Map.put("error", inspect(reason)))
    end
  end

  defp reconcile_native(state, record, mr, path) do
    if mr["state"] == "merged" do
      put_record(state, merged_review(record, mr))
    else
      reconcile_unmerged(state, record, mr, path)
    end
  end

  defp reconcile_unmerged(state, record, mr, path) do
    case lane_assignment(state.config, record["project"], record["iid"], mr) do
      {:ok, true} ->
        reconcile_assigned(state, record, mr, path)

      {:ok, false} ->
        reason = if mr["state"] in ["closed", "merged"], do: mr["state"], else: "unassigned"
        put_record(state, record |> Map.put("eligibility", reason) |> Map.put("phase", "ended"))

      {:error, reason} ->
        put_record(state, record |> Map.put("eligibility", "unknown") |> Map.put("error", inspect(reason)))
    end
  end

  defp merged_review(record, mr) do
    current =
      published_review?(record) and record["review_completion"] == completion_proof(record) and
        is_nil(record["publication_error"]) and mr["sha"] == record["head"] and
        mr["diff_refs"]["base_sha"] == record["base"] and not target_changed?(record, mr)

    gap = %{
      "status" => if(current, do: "none", else: "missing_current_review"),
      "head" => mr["sha"],
      "base" => mr["diff_refs"]["base_sha"],
      "target_branch" => mr["target_branch"],
      "completion" => if(current, do: record["review_completion"])
    }

    record |> Map.put("eligibility", "merged") |> Map.put("phase", "ended") |> Map.put("review_gap", gap)
  end

  defp completion_proof(record) do
    %{
      "head" => record["head"],
      "base" => record["base"],
      "target_branch" => record["target_branch"],
      "publication_sha" => TaskWorkflow.digest(record["publication"])
    }
  end

  defp published_review?(%{"publication" => %{"entries" => entries}}) when is_list(entries),
    do: entries != [] and Enum.all?(entries, &(&1["status"] == "published" and is_map(&1["receipt"])))

  defp published_review?(_), do: false

  defp reconcile_assigned(state, record, mr, path) do
    findings = findings_for(state, record)

    with {:ok, discussions} <- native(state.config).discussions(state.config, path),
         discussions = bind_replies(state.config, findings, discussions, record["author_id"]),
         {:ok, responses} <- Policy.response_digest(findings, discussions, record["author_id"]),
         true <- publications_verified?(state, record) or {:error, :review_publication_unverified} do
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

  defp publications_verified?(state, record) do
    state.records |> Map.values() |> Enum.filter(&(&1["project"] == record["project"] and &1["iid"] == record["iid"])) |> Enum.all?(&is_nil(&1["publication_error"]))
  end

  defp changed_inputs?(config, record, mr, responses) do
    mr["sha"] != record["head"] or target_changed?(record, mr) or mr["diff_refs"]["base_sha"] != record["base"] or
      responses != record["response_sha"] or policy_sha(config) != record["policy_sha"] or record["phase"] == "ended"
  end

  # Retargeting changes the integration context even when head and merge base
  # are unchanged, so the previous round can no longer prove the new target.
  defp target_changed?(record, mr), do: mr["target_branch"] != record["target_branch"]

  defp stopped?(record) do
    record["native_stop_confirmed"] == true or
      (is_nil(record["native_stop_confirmed"]) and record["phase"] not in ["running", "publishing", "failed", "fenced"] and is_nil(record["thread_id"]) and record["thread_allocation_intent"] != true)
  end

  defp policy_sha(config), do: TaskWorkflow.digest(%{"instructions" => File.read!(config["instructions_file"]), "projects" => config["projects"]})

  defp issue(record) do
    active = record["phase"] in ["queued", "running"] or (record["phase"] == "completed" and not stopped?(record))
    separator = if record["work"]["provider"] == "github", do: "#", else: "!"

    %Issue{
      id: "review:" <> record["id"],
      kind: :review,
      identifier: "review-#{String.slice(record["id"], 0, 16)}",
      title: "Review #{record["project"]}#{separator}#{record["iid"]}",
      description: Jason.encode!(Map.take(record, ["project", "iid", "head", "base", "round", "review_gap"])),
      state: if(active, do: hd(SymphonyElixir.Config.settings!().tracker.active_states), else: "closed"),
      native_ref: Map.put(record, "execution_kind", "review_lane"),
      labels: SymphonyElixir.Config.settings!().tracker.required_labels,
      dispatchable: active and record["eligibility"] == "current",
      url: record["url"]
    }
  end

  defp publish(state, id, %{"findings" => _findings} = arguments) do
    record = state.records[record_key(id)]

    with true <- publishable?(record),
         {:ok, submission} <- Finding.validate(arguments, record),
         record = register(record, submission),
         {:ok, record} <- Publication.prepare(record, submission, state.config["publisher_id"]) do
      record = record |> Map.put_new("response_findings", findings_for(state, record)) |> Map.put("phase", "publishing")
      finish_publication(put_record(state, record), record, :worker)
    else
      {:error, reason} -> {:error, reason, state}
      false -> {:error, :invalid_review_submission, state}
    end
  end

  defp publish(state, _id, _arguments), do: {:error, :invalid_review_submission, state}
  defp publishable?(record), do: is_map(record) and record["phase"] in ["running", "publishing", "completed"]

  # Only the independent reviewer channel resolves a finding; the register is
  # advanced before the publication intent is stored.
  defp register(record, submission) do
    register = Finding.advance(record["finding_register"], submission, record["round"])
    record |> Map.put("finding_register", register) |> Map.put("verdict", Finding.verdict(register))
  end

  defp finish_publication(state, record, mode \\ :recovery) do
    guard = fn current ->
      with :ok <- publication_scope(current, state), do: publication_owner(current, mode)
    end

    case Publication.publish(record, state.config, &put_record(state, &1), guard) do
      {:ok, current} ->
        current = current |> Map.put("phase", "completed") |> Map.delete("publication_error") |> Map.put("review_completion", completion_proof(current))
        {:ok, put_record(state, current)}

      {:error, reason, current} ->
        current = current |> Map.put("phase", "fenced") |> Map.put("publication_error", inspect(reason))
        {:error, reason, put_record(state, current)}
    end
  end

  defp publication_owner(_record, :recovery), do: :ok

  defp publication_owner(record, :worker) do
    pid = Owner.local_pid(record["execution_owner"])
    if is_pid(pid) and Process.alive?(pid), do: :ok, else: {:error, :review_execution_owner_exited}
  end

  defp recover_publications(state) do
    Enum.reduce(state.records, state, fn {_id, record}, current ->
      if is_map(record["publication"]), do: recover_publication(current, record), else: current
    end)
  end

  defp recover_publication(state, record) do
    case Publication.recover(record, state.config, &put_record(state, &1)) do
      {:ok, record} ->
        put_record(state, Map.delete(record, "publication_error"))

      {:error, reason, record} ->
        phase = if record["phase"] in ["ended", "superseded"], do: record["phase"], else: "fenced"
        put_record(state, record |> Map.put("phase", phase) |> Map.put("publication_error", inspect(reason)))
    end
  end

  defp continue_publications(state), do: Enum.reduce(state.records, state, fn {_id, record}, current -> continue_publication(current, record) end)

  defp continue_publication(state, record) do
    if record["phase"] in ["publishing", "fenced", "failed"] and record["eligibility"] == "current" and
         record["native_stop_confirmed"] == true and is_map(record["publication"]) and is_nil(record["publication_error"]) do
      case finish_publication(state, record) do
        {:ok, next} -> next
        {:error, _, next} -> next
      end
    else
      state
    end
  end

  defp same_review?(mr, record, config) do
    mr["sha"] == record["head"] and not target_changed?(record, mr) and
      get_in(mr, ["diff_refs", "base_sha"]) == record["base"] and
      policy_sha(config) == record["policy_sha"]
  end

  defp publication_scope(record, state) do
    config = state.config
    module = native(config)
    path = module.mr_path(record["project"], record["iid"])

    with true <- current_config?(state) || {:error, :review_lane_configuration_changed_restart_required},
         {:ok, mr} <- read_mr(config, record["project"], record["iid"]),
         true <- valid_mr?(mr, record["project"], record["iid"], config) || {:error, :mr_head_changed},
         true <- mr["state"] == "opened" || {:error, :review_not_open},
         true <- same_review?(mr, record, config) || {:error, :mr_head_changed},
         :ok <- require_assignment(lane_assignment(config, record["project"], record["iid"], mr)),
         {:ok, user} <- module.request(config, "GET", "user"),
         true <- user["id"] == config["publisher_id"] || {:error, identity_mismatch(config)},
         {:ok, discussions} <- module.discussions(config, path) do
      same_responses(record, discussions, config)
    end
  end

  defp same_responses(record, discussions, config) do
    expected = record["response_sha"]
    findings = record["response_findings"] ++ record["findings"]
    discussions = bind_replies(config, findings, discussions, record["author_id"])

    case Policy.response_digest(findings, discussions, record["author_id"]) do
      {:ok, ^expected} -> :ok
      _ -> {:error, :review_responses_changed}
    end
  end

  defp native(%{"provider" => "github"}), do: GitHub
  defp native(_config), do: GitLab

  defp read_mr(%{"provider" => "github"} = config, project, iid), do: GitHub.read_pull(config, project, iid)

  defp read_mr(config, project, iid),
    do: native(config).request(config, "GET", native(config).mr_path(project, iid))

  defp web_url_path(%{"provider" => "github"}, project, iid), do: "/#{project}/pull/#{iid}"
  defp web_url_path(_config, project, iid), do: "/#{project}/-/merge_requests/#{iid}"

  defp identity_mismatch(%{"provider" => "github"}), do: :github_identity_mismatch
  defp identity_mismatch(_config), do: :gitlab_identity_mismatch
  defp require_assignment({:ok, true}), do: :ok
  defp require_assignment({:ok, false}), do: {:error, :review_assignment_withdrawn}
  defp require_assignment({:error, _reason} = error), do: error

  # GitHub stores review bodies and issue comments as separate native objects
  # without a shared discussion ID. Bind author notes conservatively to every
  # open finding in the reviewed round; Policy still filters by author and time.
  defp bind_replies(%{"provider" => "github"}, findings, discussions, author_id),
    do: merge_replies(findings, discussions, author_id)

  defp bind_replies(_config, _findings, discussions, _author_id), do: discussions

  defp merge_replies([], discussions, _author_id), do: discussions

  defp merge_replies(findings, discussions, author_id) do
    own = findings |> Enum.map(& &1["discussion_id"]) |> MapSet.new()

    replies =
      for discussion <- discussions,
          not MapSet.member?(own, discussion["id"]),
          note <- discussion["notes"] || [],
          get_in(note, ["author", "id"]) == author_id,
          do: note

    Enum.map(discussions, fn discussion ->
      if MapSet.member?(own, discussion["id"]),
        do: Map.update(discussion, "notes", replies, &(&1 ++ replies)),
        else: discussion
    end)
  end

  defp record_key("review:" <> key), do: key
  defp record_key(key), do: key

  defp put_record(state, record) do
    if state.records[record["id"]] == record, do: state, else: persist(%{state | records: Map.put(state.records, record["id"], record)})
  end

  defp scope(config), do: Map.take(config, ["provider", "host", "reviewer_id", "publisher_id", "projects", "allow_insecure_http"])

  defp persist(state) do
    body = Jason.encode!(%{"schema_version" => 3, "scope" => scope(state.config), "records" => state.records, "hints" => state.hints})
    :ok = Journal.write!(state.journal, body)
    state
  end
end
