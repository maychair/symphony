defmodule SymphonyElixir.Execution do
  alias SymphonyElixir.RuntimeContext
  @moduledoc "Durable native execution for repository Issues, independent of task storage."
  alias SymphonyElixir.{Config, ExecutionBackend, RunJournal, TaskReconciler, Tracker}

  # Logical workflow states that wait for a person. A confirmed native stop in
  # any of them means no worker may be dispatched: the poll reconciler observes
  # the Issue and the next human label, answer or decision re-enters the task
  # workflow.
  @human_decision_states ["waiting", "review", "ended"]

  @spec enabled?() :: boolean()
  def enabled?, do: Config.settings!().agent.goal_mode

  @spec journal_root() :: Path.t()
  def journal_root do
    journal_root_for(Config.settings!())
  end

  @doc false
  @spec journal_root_for(Config.Schema.t()) :: Path.t()
  def journal_root_for(settings) do
    configured = settings.agent.run_journal_dir

    value =
      case configured do
        "$" <> name -> RuntimeContext.get_env(name)
        other -> other
      end

    value || RuntimeContext.get_env("SYMPHONY_RUN_JOURNAL_DIR") || Path.join(settings.workspace.root, ".runs")
  end

  @spec run_budget_ms(String.t()) :: pos_integer()
  def run_budget_ms(id) do
    agent = Config.settings!().agent

    case Map.get(agent.run_budget_ms_by_issue, id, agent.run_budget_ms) do
      value when is_integer(value) and value > 0 -> value
      _ -> agent.run_budget_ms
    end
  end

  @spec prepare(Tracker.Issue.t(), keyword()) :: {:ok, Tracker.Issue.t(), keyword()} | {:error, term()}
  def prepare(%Tracker.Issue{kind: :plan}, _opts), do: {:error, :parent_plan_has_no_executor}

  def prepare(issue, opts) do
    if SymphonyElixir.TaskPlan.requires_plan_lifecycle?(issue),
      do: {:error, :plan_execution_unavailable},
      else: prepare_legacy(issue, opts)
  end

  defp prepare_legacy(issue, opts) do
    if enabled?() do
      with :ok <- ExecutionBackend.check_record(journal_root(), issue.id),
           :ok <- recover_stopped(issue),
           {:ok, record} <- RunJournal.admit(journal_root(), issue.id),
           {:ok, record} <-
             RunJournal.checkpoint(record, %{
               "issue_url" => issue.url,
               "issue_identifier" => issue.identifier,
               "backend" => ExecutionBackend.kind(),
               "worker_host" => if(is_binary(record["thread_id"]), do: record["worker_host"], else: opts[:worker_host]),
               "recovery" => if(record["thread_id"], do: "resume existing native thread", else: nil),
               "handoff" => nil,
               "blocker_reason" => nil
             }) do
        admit_workflow(issue, record, opts)
      end
    else
      {:ok, issue, opts}
    end
  end

  defp admit_workflow(issue, record, opts) do
    case TaskReconciler.admit(issue, record) do
      {:ok, admitted} ->
        budget = min(run_budget_ms(issue.id), admitted["remaining_budget_ms"] || run_budget_ms(issue.id))
        options = Keyword.merge(opts, run_record: admitted, worker_host: admitted["worker_host"], deadline: System.monotonic_time(:millisecond) + budget, tracker_settings: Config.settings!().tracker)
        {:ok, issue, options}

      error ->
        {:ok, current} = RunJournal.read(record["directory"])
        RunJournal.complete(current, "completed")
        error
    end
  end

  # A dead scheduler may release its lock, but resuming the recorded thread still
  # goes through AppServer's native idle/turn identity check. An unrecorded thread
  # allocation remains an incident instead of silently creating another executor.
  defp recover_stopped(issue) do
    directory = RunJournal.directory(journal_root(), issue.id)

    with {:ok, record} <- RunJournal.read(directory) do
      cond do
        is_nil(record) -> :ok
        record["issue_url"] != issue.url -> {:error, :execution_issue_identity_changed}
        # Completed runs have already released their executor lock. A lock present
        # now may belong to merge cleanup; admission must never reclaim it.
        record["phase"] == "completed" -> :ok
        resumable?(issue) -> release_for_resume(record)
        record["phase"] == "incident" -> {:error, {:execution_requires_recovery, record["blocker_reason"]}}
        stopped_with_known_allocation?(record) -> release_for_resume(record)
        true -> {:error, {:execution_requires_recovery, record["blocker_reason"] || record["phase"]}}
      end
    end
  end

  defp workflow_recovery?(record) do
    flow = record["workflow"] || %{}

    (record["native_stop_confirmed"] == true or record["thread_allocation_intent"] != true) and
      flow["resume_requested"] == true and
      flow["allowed_criteria"] != [] and flow["state"] == "ready"
  end

  defp stopped_with_known_allocation?(record) do
    RunJournal.executor_state(record) == :stopped and
      (is_binary(record["thread_id"]) or record["thread_allocation_intent"] != true)
  end

  @spec handing_off?(String.t()) :: boolean()
  def handing_off?(id) do
    if enabled?() do
      case RunJournal.read(RunJournal.directory(journal_root(), id)) do
        {:ok, %{} = record} -> record["handoff_pending"] == true or is_map(record["handoff"])
        _ -> false
      end
    else
      false
    end
  end

  @doc """
  Whether the recorded run confirmed its native stop and left the Issue at a
  human decision.

  The continuation check after a normal worker exit, dispatch selection and the
  retry timer all consult this, so a task that waits for `symphony:accept`,
  `symphony:rework`, another human label or an answer keeps the poll reconciler
  as its only owner instead of re-dispatching an executor that admission rejects.
  """
  @spec awaiting_human?(String.t()) :: boolean()
  def awaiting_human?(id) do
    if enabled?() do
      case RunJournal.read(RunJournal.directory(journal_root(), id)) do
        {:ok, %{} = record} -> human_decision_record?(record)
        _ -> false
      end
    else
      false
    end
  end

  defp human_decision_record?(%{
         "native_stop_confirmed" => true,
         "workflow" => %{"state" => state}
       }),
       do: state in @human_decision_states

  defp human_decision_record?(_record), do: false

  defp release_for_resume(record) do
    with false <- File.exists?(Path.join([record["directory"], "executor.lock", "cleanup-owner.json"])),
         false <- File.exists?(Path.join([record["directory"], "executor.lock", "reconcile-owner"])),
         true <- RunJournal.recoverable_lock?(record),
         {:ok, _} <- RunJournal.checkpoint(record, %{"phase" => "completed", "handoff" => nil, "blocker_reason" => nil}) do
      case RunJournal.release_lock(record) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        error -> error
      end
    else
      true -> {:error, :merge_cleanup_in_progress}
      false -> {:error, :execution_lock_owner_unverified}
      error -> error
    end
  end

  @spec finish(Tracker.Issue.t(), keyword(), term()) :: :ok | {:error, term()}
  def finish(_issue, opts, _result) when not is_list(opts), do: :ok

  def finish(issue, opts, result) do
    case opts[:run_record] do
      nil ->
        :ok

      initial ->
        finish_record(issue, initial, result)
    end
  end

  defp finish_record(issue, initial, result) do
    with {:ok, record} <- RunJournal.read(initial["directory"]),
         true <- record["attempt_id"] == initial["attempt_id"],
         :ok <- legacy_finalizer(record) do
      record =
        case refresh_workflow(record, false) do
          {:ok, refreshed} -> refreshed
          _ -> record
        end

      record = count_retry(record, result)
      {phase, error} = final_phase(issue, record, result)
      record = if phase == "incident", do: clear_resume_requested(record), else: record

      with {:ok, updated} <- RunJournal.checkpoint(record, %{"blocker_reason" => error}) do
        RunJournal.complete(updated, phase)
      end
    end
  end

  defp legacy_finalizer(record) do
    if is_map(record["execution_binding"]) or get_in(record, ["workflow", "schema_version"]) == 2,
      do: {:error, :plan_execution_finalizer_required},
      else: :ok
  end

  defp clear_resume_requested(%{"workflow" => flow} = record),
    do: Map.put(record, "workflow", Map.put(flow, "resume_requested", false))

  defp clear_resume_requested(record), do: record

  defp count_retry(record, :ok), do: record
  defp count_retry(record, {:error, :scheduler_stop}), do: record

  defp count_retry(%{"native_stop_confirmed" => true, "workflow" => %{"state" => state}} = record, _)
       when state in @human_decision_states, do: record

  defp count_retry(%{"native_stop_confirmed" => true, "control_restart" => true} = record, _), do: record
  defp count_retry(record, _), do: Map.update(record, "retry_count", 1, &(&1 + 1))

  @spec refresh_workflow(map(), boolean()) :: {:ok, map()} | {:error, term()}
  def refresh_workflow(record, active) do
    if TaskReconciler.enabled?(), do: TaskReconciler.refresh(record, active), else: {:ok, record}
  end

  @spec reconcile_native_stop(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def reconcile_native_stop(record, opts \\ []) do
    cond do
      record["native_stop_confirmed"] == true or record["thread_allocation_intent"] != true ->
        {:ok, record}

      (record["backend"] || "codex") != "codex" ->
        RunJournal.checkpoint(record, %{"native_stop_recovery" => "Recorded backend requires explicit native recovery"})

      true ->
        halt_recorded_thread(record, opts)
    end
  end

  defp halt_recorded_thread(record, opts) do
    case SymphonyElixir.NativeStop.confirm(record, opts) do
      {:ok, evidence} ->
        RunJournal.checkpoint(record, Map.put(evidence, "native_stop_recovery", "recorded Goal halted and native idle verified"))

      {:error, reason} ->
        RunJournal.checkpoint(record, %{"native_stop_recovery" => "Recorded native stop remains unconfirmed: #{inspect(reason)}"})
    end
  end

  @spec activation_options(keyword()) :: {:ok, keyword()} | {:error, term()}
  def activation_options(opts) do
    case opts[:run_record] do
      nil -> {:ok, opts}
      record -> refresh_activation(record, opts)
    end
  end

  defp refresh_activation(record, opts) do
    with {:ok, current} <- RunJournal.read(record["directory"]),
         true <- current["attempt_id"] == record["attempt_id"],
         {:ok, current} <- refresh_workflow(current, false) do
      activation_budget(current, opts)
    else
      false -> {:error, :execution_attempt_changed}
      error -> error
    end
  end

  defp activation_budget(%{"workflow" => flow} = record, opts) do
    now = System.monotonic_time(:millisecond)
    remaining = max(0, flow["budget_ms"] - flow["used_ms"])
    deadline = min(opts[:deadline] || now + remaining, now + remaining)

    cond do
      flow["state"] not in ["ready", "running"] -> {:error, :scheduler_stop}
      deadline <= now -> {:error, :execution_budget_exhausted}
      true -> {:ok, Keyword.merge(opts, run_record: record, deadline: deadline)}
    end
  end

  defp activation_budget(record, opts), do: {:ok, Keyword.put(opts, :run_record, record)}

  @spec controlled_stop?(keyword()) :: boolean()
  def controlled_stop?(opts) do
    with %{} = initial <- opts[:run_record],
         {:ok, current} <- RunJournal.read(initial["directory"]) do
      known = current["attempt_id"] == initial["attempt_id"] and current["native_stop_confirmed"] == true
      control = get_in(current, ["workflow", "state"]) in @human_decision_states or current["control_restart"] == true
      known and control
    else
      _ -> false
    end
  end

  defp final_phase(_issue, %{"native_stop_confirmed" => true, "workflow" => %{"state" => state}}, _result)
       when state in @human_decision_states, do: {"completed", nil}

  defp final_phase(_issue, %{"native_stop_confirmed" => true, "control_restart" => true}, _result), do: {"completed", nil}

  defp final_phase(_issue, record, {:error, :scheduler_stop}) do
    if record["native_stop_confirmed"] == true,
      do: {"completed", nil},
      else: {"incident", "Scheduler requested shutdown, but the native Goal could not be confirmed stopped."}
  end

  defp final_phase(issue, record, :ok) do
    if record["handoff"] do
      {"completed", nil}
    else
      case Tracker.fetch_issues_by_ids([issue.id]) do
        {:ok, [current]} ->
          issue_final_phase(current)

        {:ok, []} ->
          {"completed", nil}

        {:error, reason} ->
          {"incident", "Cannot confirm the Issue after execution: #{inspect(reason)}"}
      end
    end
  end

  defp final_phase(_issue, record, result) do
    # Confirmed-stopped transient failures get exactly one automatic rework
    # before the Incident is surfaced for a human decision.
    if (record["native_stop_confirmed"] == true or record["thread_allocation_intent"] != true) and (record["retry_count"] || 0) <= 1,
      do: {"completed", inspect(result)},
      else: {"incident", inspect(result)}
  end

  defp issue_final_phase(current) do
    settings = Config.settings!().tracker

    if current.state in settings.terminal_states or not Tracker.Issue.routable?(current, settings),
      do: {"completed", nil},
      else: {"incident", "Goal ended while the Issue still requests execution; review the result and reapply symphony:ready."}
  end

  @spec worker_down(String.t(), term()) :: :ok | {:blocked, String.t()}
  def worker_down(id, reason) do
    scheduler_pid = System.pid()

    if enabled?() do
      case RunJournal.read(RunJournal.directory(journal_root(), id)) do
        {:ok, %{"executor_os_pid" => pid}} when pid != scheduler_pid ->
          :ok

        {:ok, %{"phase" => "incident"} = record} ->
          {:blocked, record["blocker_reason"] || inspect(reason)}

        {:ok, %{"phase" => phase} = record} when phase != "completed" ->
          message = "Execution interrupted at #{phase}: #{inspect(reason)}"
          finish_interrupted(record, message)

        _ ->
          :ok
      end
    else
      :ok
    end
  end

  defp finish_interrupted(record, message) do
    record = clear_resume_requested(record)

    with :ok <- legacy_finalizer(record),
         {:ok, updated} <- RunJournal.checkpoint(record, %{"blocker_reason" => message}),
         :ok <- RunJournal.complete(updated, "incident") do
      {:blocked, message}
    else
      error -> {:blocked, "Cannot finalize interrupted execution: #{inspect(error)}"}
    end
  end

  @spec resumable?(Tracker.Issue.t()) :: boolean()
  def resumable?(issue) do
    if enabled?() do
      case RunJournal.read(RunJournal.directory(journal_root(), issue.id)) do
        {:ok, %{"phase" => "incident"} = record} ->
          workflow_recovery?(record)

        _ ->
          false
      end
    else
      false
    end
  end

  @spec tool_specs() :: [map()]
  def tool_specs do
    if enabled?() do
      [
        %{
          "name" => "task_handoff",
          "description" =>
            "Record a concrete review, decision or blocker on this repository Issue and mark it for review. Never writes a human authorization label; does not create a task, merge or close the Issue.",
          "inputSchema" => %{
            "type" => "object",
            "additionalProperties" => false,
            "required" => ["kind", "reason"],
            "properties" => %{
              "kind" => %{"type" => "string", "enum" => ["review", "decision", "blocked"]},
              "reason" => %{"type" => "string", "minLength" => 1},
              "url" => %{"type" => "string"}
            }
          }
        }
      ]
    else
      []
    end
  end

  @spec reconcile_delivery(Tracker.Issue.t(), keyword()) :: :ok | {:error, term()}
  def reconcile_delivery(issue, opts) do
    directory = RunJournal.directory(journal_root(), issue.id)

    with {:ok, record} <- RunJournal.read(directory),
         {:ok, path} <- pending_review_path(record) do
      case accept_delivery(issue, record, path, opts) do
        :ok -> :ok
        error -> record_delivery_error(directory, error)
      end
    else
      :none -> :ok
      error -> error
    end
  end

  defp pending_review_path(nil), do: :none

  defp pending_review_path(record) do
    path = Path.join(record["directory"], "review-request-#{record["attempt_id"]}.json")
    if record["handoff"] || not File.exists?(path), do: :none, else: {:ok, path}
  end

  defp record_delivery_error(directory, error) do
    {:ok, current} = RunJournal.read(directory)
    RunJournal.checkpoint(current, %{"blocker_reason" => "Automatic review handoff failed: #{inspect(error)}"})
    error
  end

  defp accept_delivery(issue, record, path, opts) do
    settings = opts[:tracker_settings] || Config.settings!().tracker
    opts = Keyword.merge(opts, issue: issue, tracker_settings: settings)
    {client, _} = client_path(settings, issue, opts)
    prefix = String.replace_suffix(issue.url, "/issues/#{issue.id}", "/merge_requests/")

    with {:ok, data} <- File.read(path),
         {:ok, %{} = request} <- Jason.decode(data),
         true <- valid_delivery_request?(settings, issue, record, request),
         %{"iid" => iid, "sha" => sha} = publication <- request["publication"],
         true <- is_integer(iid) and iid > 0 and is_binary(sha) and request["url"] == prefix <> to_string(iid),
         {:ok, %{status: 200, body: %{} = mr}} <- client.("GET", "/projects/#{URI.encode_www_form(settings.provider["project_path"])}/merge_requests/#{iid}", %{}, nil, tracker_settings: settings),
         true <- valid_review_options?(mr, request["url"]),
         true <- same_publication?(publication, mr),
         delivery = %{"url" => request["url"], "kind" => "mr", "version" => sha, "mr_verified" => true, "attempt_id" => record["attempt_id"]},
         {:ok, _} <- RunJournal.checkpoint(record, %{"delivery" => delivery}),
         %{"success" => true} <- handoff(Map.take(request, ["kind", "reason", "url", "stage", "continue_after", "manifest"]), opts) do
      :ok
    else
      error -> {:error, {:review_delivery_not_verified, error}}
    end
  end

  defp valid_delivery_request?(settings, issue, record, request) do
    expected = %{"schema_version" => 1, "attempt_id" => record["attempt_id"], "issue_url" => issue.url}
    settings.kind == "gitlab" and Enum.all?(expected, fn {key, value} -> request[key] == value end)
  end

  defp valid_review_options?(mr, url) do
    expected = %{"web_url" => url, "squash" => true}

    Enum.all?(expected, fn {key, value} -> mr[key] == value end) and mr["state"] in ["opened", "merged"] and mr["draft"] != true and
      mr["source_project_id"] == mr["target_project_id"] and
      (mr["force_remove_source_branch"] == true or mr["should_remove_source_branch"] == true)
  end

  defp same_publication?(publication, mr) do
    fields = ["sha", "source_branch", "target_branch", "source_project_id", "target_project_id"]
    Enum.all?(fields, &(not is_nil(publication[&1]) and publication[&1] == mr[&1]))
  end

  @spec handoff(term(), keyword()) :: map()
  def handoff(arguments, opts) do
    result = do_handoff(arguments, opts)
    output = Jason.encode!(%{"result" => inspect(result)})
    %{"success" => match?({:ok, _}, result), "output" => output, "contentItems" => [%{"type" => "inputText", "text" => output}]}
  end

  defp do_handoff(%{"kind" => kind, "reason" => reason} = arguments, opts)
       when kind in ["review", "decision", "blocked"] and is_binary(reason) and byte_size(reason) > 0 do
    issue = Keyword.fetch!(opts, :issue)
    settings = Keyword.fetch!(opts, :tracker_settings)

    with {:ok, %{} = record} <- RunJournal.read(RunJournal.directory(journal_root(), issue.id)),
         true <- record["issue_url"] == issue.url,
         :ok <- valid_handoff_manifest(record, arguments),
         {:ok, pending} <- RunJournal.checkpoint(record, handoff_intent(record, arguments)) do
      case post_handoff(settings, issue, arguments, pending, opts) do
        {:ok, posted} ->
          complete_handoff(posted, arguments)

        error ->
          {:ok, current} = RunJournal.read(record["directory"])
          RunJournal.checkpoint(current, %{"handoff_pending" => false})
          {:error, error}
      end
    else
      error -> {:error, error}
    end
  end

  defp do_handoff(_, _), do: {:error, :invalid_handoff}

  defp valid_handoff_manifest(record, %{"manifest" => manifest}) when is_map(manifest) do
    case SymphonyElixir.TaskWorkflow.submit(record["workflow"], Map.put(manifest, "ref", "pending")) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp valid_handoff_manifest(_, %{"manifest" => _}), do: {:error, :invalid_manifest}
  defp valid_handoff_manifest(_, _), do: :ok

  defp handoff_intent(record, arguments) do
    changes = %{"handoff_pending" => true}

    if record["workflow"] do
      flow = SymphonyElixir.TaskWorkflow.handoff(record["workflow"], arguments)
      Map.put(changes, "workflow", Map.put(flow, "intermediate", if(arguments["continue_after"] == "merged", do: record["delivery"], else: nil)))
    else
      changes
    end
  end

  defp complete_handoff(posted, arguments) do
    with {:ok, updated} <- RunJournal.checkpoint(posted, %{"handoff_pending" => false, "handoff" => arguments}) do
      {:ok, Map.take(updated, ["issue_url", "handoff"])}
    end
  end

  defp post_handoff(%{kind: kind} = settings, issue, args, record, opts) when kind in ["github", "gitlab"] do
    {client, path} = client_path(settings, issue, opts)
    suffix = if kind == "github", do: "/comments", else: "/notes"

    body = handoff_body(args, record)

    with {:ok, posted} <- ensure_handoff_notice(client, path <> suffix, settings, body, record) do
      # The versioned workflow keeps the human authorization label and marks the
      # handoff with the engine-owned review label; the legacy workflow restores
      # the previous routing-label removal so the run actually stops.
      if TaskReconciler.enabled?(),
        do: mark_review(settings, issue, path, client, posted, opts),
        else: release_routing(settings, issue, path, client, posted, opts)
    end
  end

  defp post_handoff(_, _, _, _, _), do: {:error, :repository_tracker_required}

  defp mark_review(settings, issue, path, client, posted, opts) do
    with :ok <- add_labels(settings, issue, ["symphony:review"], opts),
         {:ok, %{status: 200, body: %{} = current}} <- client.("GET", path, %{}, nil, tracker_settings: settings),
         true <- "symphony:review" in label_names(current["labels"]) do
      {:ok, posted}
    end
  end

  defp release_routing(settings, issue, path, client, posted, opts) do
    with :ok <- remove_labels(settings, issue, legacy_routing_labels(settings), opts),
         {:ok, %{status: 200, body: %{} = current}} <- client.("GET", path, %{}, nil, tracker_settings: settings),
         labels when is_list(labels) <- current["labels"],
         true <- routing_released?(labels, settings) do
      {:ok, posted}
    end
  end

  # Only the legacy path keeps the pre-upgrade routing labels, so an Issue that
  # still carries `symphony:retry` stops being routed after the handoff.
  defp legacy_routing_labels(settings),
    do: Enum.reject(settings.required_labels, &(&1 == "symphony:todo")) ++ ["symphony:retry"]

  defp routing_released?(labels, settings) do
    routing = legacy_routing_labels(settings)

    Enum.all?(labels, fn label ->
      name = if is_map(label), do: label["name"], else: label
      is_binary(name) and String.downcase(String.trim(name)) not in routing
    end)
  end

  defp label_names(labels) do
    labels
    |> List.wrap()
    |> Enum.map(fn label -> if is_map(label), do: label["name"], else: label end)
  end

  defp ensure_handoff_notice(_client, _path, _settings, body, %{"handoff_notice" => previous} = record)
       when previous == body, do: {:ok, record}

  defp ensure_handoff_notice(client, path, settings, body, record) do
    with {:ok, notes} <- TaskReconciler.read_notes(client, path, settings),
         :ok <- post_notice_unless_present(client, path, settings, body, notes) do
      RunJournal.checkpoint(record, %{"handoff_notice" => body})
    end
  end

  defp post_notice_unless_present(client, path, settings, body, notes) do
    if Enum.any?(notes, &(&1["body"] == body)) do
      :ok
    else
      response(client.("POST", path, %{}, %{"body" => body}, tracker_settings: settings))
    end
  end

  defp add_labels(%{kind: "gitlab"} = settings, issue, labels, opts) do
    {client, path} = client_path(settings, issue, opts)
    response(client.("PUT", path, %{}, %{"add_labels" => Enum.join(labels, ",")}, tracker_settings: settings))
  end

  defp remove_labels(%{kind: "github"} = settings, issue, labels, opts) do
    {client, path} = client_path(settings, issue, opts)

    Enum.reduce_while(labels, :ok, fn label, :ok ->
      case client.("DELETE", path <> "/labels/" <> URI.encode_www_form(label), %{}, nil, tracker_settings: settings) do
        {:ok, %{status: status}} when status in 200..299 or status == 404 -> {:cont, :ok}
        error -> {:halt, {:error, error}}
      end
    end)
  end

  defp remove_labels(%{kind: "gitlab"} = settings, issue, labels, opts) do
    {client, path} = client_path(settings, issue, opts)
    response(client.("PUT", path, %{}, %{"remove_labels" => Enum.join(labels, ",")}, tracker_settings: settings))
  end

  defp client_path(%{kind: "github"} = settings, issue, opts),
    do: {opts[:github_client] || (&SymphonyElixir.GitHub.Client.request/5), "/repos/#{settings.provider["repo"]}/issues/#{issue.id}"}

  defp client_path(%{kind: "gitlab"} = settings, issue, opts),
    do: {opts[:gitlab_client] || (&SymphonyElixir.GitLab.Client.request/5), "/projects/#{URI.encode_www_form(settings.provider["project_path"])}/issues/#{issue.id}"}

  defp handoff_body(args, record) do
    body =
      ("**#{args["kind"]}**\n\n#{args["reason"]}" <> if(args["url"], do: "\n\n#{args["url"]}", else: ""))
      |> String.replace("<", "&lt;")

    case args["manifest"] do
      nil ->
        # A manifest-less handoff asks the human a question, so the notice carries
        # the engine marker: the owner's first later comment answers it, and this
        # notice must never answer itself.
        body <>
          "\n\n" <>
          handoff_action(args["kind"]) <>
          "\n\n" <> TaskReconciler.engine_notice_marker()

      manifest ->
        decision = %{"action" => "manifest", "contract" => manifest["contract"], "data" => manifest}
        summary = Enum.map_join(manifest["items"], "\n", &"- [#{&1["id"]}](#{&1["url"]})") |> String.replace("<", "&lt;")

        body <>
          "\n\n全部约定成果已提交。请按以下清单和人工动作完成审查与验收：\n\n" <>
          summary <>
          "\n\n" <>
          manifest_action(manifest, record) <>
          "\n\n<!-- symphony-workflow\n" <> Jason.encode!(decision) <> "\n-->"
    end
  end

  defp manifest_action(manifest, record) do
    items = List.wrap(manifest["items"])
    report? = Enum.any?(items, &(&1["kind"] == "report"))
    request? = Enum.any?(items, &(&1["kind"] in ["mr", "pr"]))
    acceptance_mode = get_in(record, ["workflow", "contract", "acceptance_mode"]) || "separate"

    review_step =
      case {report?, request?} do
        {true, true} ->
          "1. 打开上方报告和 MR，核对验收条件、实际证据、未解决评论及已知限制。"

        {false, true} ->
          "1. 打开上方 MR，检查改动、验证结果和未解决评论。"

        {true, false} ->
          "1. 打开上方报告，核对验收条件、实际证据、结果和适用范围。"
      end

    mr_context =
      if request?,
        do: ["2. 如 MR 符合要求，请完成审查和合并；有修改意见时，在本 Issue 添加 `symphony:rework`。"],
        else: ["2. 本任务没有 MR，这是报告型任务的预期交付。"]

    acceptance_action =
      if acceptance_mode == "merge",
        do: "3. 合并 MR 后，Symphony 将核验该交付；不需要额外添加 `symphony:accept`。",
        else: "3. 如完整交付符合约定，请在本 Issue 添加 `symphony:accept` 完成整体验收。"

    Enum.join(["## 需要你做什么", "", review_step | mr_context ++ [acceptance_action]], "\n")
  end

  defp handoff_action("review") do
    """
    ## 需要你做什么

    请打开上方交付链接并完成审查。如符合约定，请在本 Issue 添加 `symphony:accept`；如需修改，请添加 `symphony:rework` 并说明范围。
    """
  end

  defp handoff_action("decision") do
    """
    ## 需要你做什么

    请在本 Issue 回复明确决定。Symphony 会按授权人的回复继续执行；调度标签不会代替该决定。
    """
  end

  defp handoff_action("blocked") do
    """
    ## 需要你做什么

    请在本 Issue 回复解除阻塞所需的具体操作或资源。收到明确答复后，Symphony 才会恢复执行。
    """
  end

  defp response({:ok, %{status: status}}) when status in 200..299, do: :ok
  defp response(error), do: {:error, error}
end
