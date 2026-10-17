defmodule SymphonyElixir.TaskSession do
  @moduledoc "Owned local Codex sessions and final activation fences for admitted plan-member generations."
  alias SymphonyElixir.{Codex.AppServer, Config, NativeStop, RunJournal, TaskExecution, TaskObserver, TaskWorkspace}
  alias SymphonyElixir.PromptBuilder
  alias SymphonyElixir.Tracker.Issue

  @identity ~w(directory issue_id attempt_id execution_binding execution_generation workspace task_workspace task_session_id)
  @preparation_identity (@identity -- ~w(workspace task_workspace)) ++ ~w(thread_id)
  @type t :: %{native: AppServer.session(), task_session: map()}

  @doc "Prepare the role workspace and allocate or resume only its own native thread. Admission belongs to TaskExecution."
  @spec start(map(), map(), keyword()) :: {:ok, t()} | {:error, term()}
  def start(record, executions, opts) do
    case prepare_start(%{owner: self(), record: record, executions: executions, opts: opts}) do
      {:error, reason, _context} -> {:error, reason}
      result -> result
    end
  end

  @doc "Execute one freshly admitted role using approved native scope, including owned startup-failure finalization."
  @spec run(map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(record, executions, opts) do
    context = %{owner: self(), record: record, executions: executions, opts: opts}

    with {:ok, current} <- current(context),
         true <- unclaimed_attempt?(current) or {:error, :task_attempt_not_admitted} do
      case prepare_start(context) do
        {:ok, session} -> run_prepared(session, opts)
        {:error, reason, failed} -> finalize(failed, {:error, reason})
      end
    end
  end

  defp unclaimed_attempt?(record), do: record["phase"] == "admitted" and record["task_session_phase"] in [nil, "stopped"]

  defp prepare_start(context) do
    result =
      capture_start(fn ->
        if local?(context.record, context.opts),
          do: TaskWorkspace.prepare(context.record, context.executions, context.opts),
          else: {:error, :unsupported_task_session_transport}
      end)

    case result do
      {:ok, record} -> open_session(%{context | record: record})
      {:error, reason} -> preparation_failed(context, reason)
    end
  end

  defp preparation_failed(context, reason) do
    with {:ok, %{} = record} <- RunJournal.read(context.record["directory"]),
         true <- Map.take(record, @preparation_identity) == Map.take(context.record, @preparation_identity) do
      {:error, reason, %{context | record: record}}
    else
      _ -> {:error, :task_session_no_longer_owned, context}
    end
  end

  defp open_session(context) do
    with {:ok, observation, _deadline} <- capture_start(fn -> activation(context) end),
         {:ok, context} <- claim(context) do
      start_native(context, observation.policy)
    else
      {:error, reason} -> {:error, reason, context}
    end
  end

  defp start_native(context, policy) do
    case capture_start(fn -> AppServer.start_session(context.record["workspace"], session_options(context, policy)) end) do
      {:ok, session} ->
        {:ok, %{native: session, task_session: context}}

      error ->
        {:error, reason} = failed_start(context, error)
        {:error, reason, context}
    end
  end

  defp capture_start(fun) do
    fun.()
  rescue
    error -> {:error, {:task_start_failed, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:task_start_failed, kind, inspect(reason)}}
  end

  defp run_prepared(%{task_session: context} = session, opts) do
    objective =
      capture_start(fn ->
        with {:ok, observation, _} <- activation(context),
             {:ok, prompt} <- PromptBuilder.build_role_prompt(observation),
             :ok <- Keyword.get(opts, :on_ready, fn _ -> :ok end).(observation.record),
             do: {:ok, prompt}
      end)

    case objective do
      {:ok, prompt} -> run_goal(session, prompt, opts)
      {:error, _} = error -> finish_goal(context, error, stop(session))
    end
  end

  defp claim(context) do
    with {:ok, record} <- current(context),
         true <- is_nil(record["task_session_id"]) or record["task_session_phase"] == "stopped" or {:error, :task_session_requires_recovery},
         id = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower),
         {:ok, record} <- RunJournal.checkpoint(record, %{"task_session_id" => id, "task_session_phase" => "opening", "task_observation_error" => nil}) do
      {:ok, %{context | record: record}}
    end
  end

  defp failed_start(context, error) do
    with {:ok, record} <- current(context) do
      stopped = record["native_stop_confirmed"] == true or record["thread_allocation_intent"] != true
      phase = if stopped, do: "stopped", else: "uncertain"
      with :ok <- save(context, %{"task_session_phase" => phase}), do: error
    end
  end

  defp local?(record, opts),
    do: record["backend"] in [nil, "codex"] and is_nil(record["worker_host"]) and is_nil(opts[:worker_host])

  defp session_options(context, policy) do
    record = context.record

    [
      run_record: record,
      execution_policy: policy,
      tracker_settings: Keyword.get(context.opts, :tracker_settings, Config.settings!().tracker),
      task_native_options: Keyword.put(context.opts, :dependency_executions, context.executions),
      resume_thread_id: record["thread_id"],
      expected_turn_id: record["turn_id"] || :no_turns,
      suspend_goal: true,
      on_thread_intent: fn -> before_thread(context) end,
      on_thread_started: fn thread ->
        save(context, %{"phase" => "thread_ready", "thread_id" => thread, "native_stop_confirmed" => true, "task_session_phase" => "ready"})
      end
    ]
  end

  defp before_thread(context) do
    with {:ok, _, _} <- activation(context) do
      save(context, %{"phase" => "thread_start_intent", "backend" => "codex", "thread_allocation_intent" => true, "native_stop_confirmed" => false})
    end
  end

  @doc "Derive finite native activation options; callbacks re-read authority and ownership immediately before the effect."
  @spec activation_options(t()) :: {:ok, keyword()} | {:error, term()}
  def activation_options(%{task_session: context}) do
    with {:ok, observation, deadline} <- activation(context) do
      {:ok,
       [
         deadline: deadline,
         interruptible: true,
         resume_goal: is_binary(observation.record["thread_id"]),
         before_goal: fn -> before_activation(context, "goal") end,
         before_turn: fn -> before_activation(context, "turn") end
       ]}
    end
  end

  defp before_activation(context, mode) do
    with {:ok, _, _} <- activation(context) do
      save(context, %{"phase" => mode <> "_start_intent", "execution_mode" => mode, "native_stop_confirmed" => false})
    end
  end

  defp activation(context) do
    with {:ok, current} <- current(context),
         :ok <- TaskWorkspace.validate(current),
         {:ok, observation} <- TaskExecution.refresh(current, context.executions, Keyword.put(context.opts, :active, false)),
         true <- observation.flow["dispatchable"] and observation.flow["next_binding"] == current["execution_binding"],
         :ok <- TaskWorkspace.validate(observation.record),
         {:ok, deadline} <- deadline(observation.flow, context.opts) do
      {:ok, observation, deadline}
    else
      false -> {:error, :task_activation_not_ready}
      error -> error
    end
  end

  defp deadline(flow, opts) do
    now = System.monotonic_time(:millisecond)
    latest = now + max(0, flow["budget_ms"] - flow["used_ms"])
    deadline = min(Keyword.get(opts, :deadline, latest), latest)
    if is_integer(deadline) and deadline > now, do: {:ok, deadline}, else: {:error, :task_activation_budget_exhausted}
  end

  @doc "Run this role's native Goal with bounded asynchronous control reads, owned event checkpoints and explicit stop proof."
  @spec run_goal(t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_goal(%{task_session: context} = session, objective, opts \\ []) do
    with {:ok, record} <- current(context),
         true <- record["task_session_phase"] == "ready" or {:error, :task_session_not_ready} do
      result = activated_goal(session, objective, opts)
      finish_goal(context, result, stop(session))
    end
  end

  defp finish_goal(context, result, :ok), do: finalize(context, result)

  defp finish_goal(context, result, {:error, reason} = error) do
    with {:ok, _} <- finalize(context, {:error, {:native_stop_failed, reason, result}}), do: error
  end

  defp activated_goal(%{task_session: context} = session, objective, opts) do
    with {:ok, activation} <- activation_options(session),
         {:ok, record} <- current(context),
         {:ok, observer} <- TaskObserver.start_link(record, context.executions, context.opts) do
      try do
        native_goal(session, objective, observer, activation, opts)
      after
        TaskObserver.stop(observer)
      end
    end
  rescue
    error -> {:error, {:task_goal_failed, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:task_goal_failed, kind, inspect(reason)}}
  end

  defp native_goal(%{task_session: context} = session, objective, observer, activation, opts) do
    issue = %Issue{id: context.record["issue_id"], identifier: context.record["issue_id"], title: "Plan member", state: "open"}

    owned = [
      before_goal: fn -> with :ok <- activation[:before_goal].(), do: TaskObserver.activate(observer) end,
      handoff_status: fn -> control_status(context, observer) end,
      before_goal_stop: fn -> with {:ok, _} <- current(context), do: :ok end,
      latest_turn: fn -> current!(context)["turn_id"] end,
      on_message: fn event ->
        native_event(context, event)
        Keyword.get(opts, :on_message, fn _ -> :ok end).(event)
      end
    ]

    AppServer.run_goal(session.native, objective, issue, Keyword.merge(activation, owned))
  end

  defp current!(context) do
    case current(context) do
      {:ok, record} -> record
      {:error, reason} -> raise "Task session ownership lost: #{inspect(reason)}"
    end
  end

  defp control_status(context, observer) do
    record = current!(context)

    if record["task_observation_error"] do
      "blocked"
    else
      control_result(context, record, TaskObserver.take(observer))
    end
  end

  defp control_result(_, _, :pending), do: nil

  defp control_result(context, record, {:ok, observation}) do
    result =
      with :ok <- TaskWorkspace.validate(record),
           {:ok, current} <- TaskExecution.apply_running(record, observation) do
        {:ok, current.flow["stop_required"]}
      end

    case result do
      {:ok, true} -> "blocked"
      {:ok, false} -> nil
      error -> control_result(context, record, error)
    end
  end

  defp control_result(context, _, {:error, reason}) do
    :ok = save(context, %{"task_observation_error" => inspect(reason)})
    "blocked"
  end

  defp native_event(context, %{event: :session_started, thread_id: thread, turn_id: turn}),
    do: save_event(context, %{"phase" => "turn_running", "thread_id" => thread, "turn_id" => turn})

  defp native_event(context, %{event: :goal_updated, goal: goal}),
    do: save_event(context, %{"goal_status" => goal["status"], "goal_thread_id" => goal["threadId"]})

  defp native_event(context, %{event: :turn_completed, payload: payload}) do
    record = current!(context)
    save_event(context, %{"phase" => "goal_waiting", "turn_id" => get_in(payload, ["params", "turn", "id"]), "turn_count" => (record["turn_count"] || 0) + 1})
  end

  defp native_event(_, _), do: :ok
  defp save_event(context, changes), do: :ok = save(context, changes)

  defp finalize(context, result) do
    with {:ok, record} <- current(context),
         {:ok, finished} <- TaskExecution.finish(record, result, context.executions, context.opts) do
      {:ok, Map.put(finished, :native_result, result)}
    end
  end

  @doc "Persist native callbacks only for this caller, attempt, role generation and workspace."
  @spec checkpoint(t(), map()) :: :ok | {:error, term()}
  def checkpoint(%{task_session: context}, changes), do: save(context, changes)

  defp save(context, changes) do
    with {:ok, current} <- current(context),
         {:ok, _} <- RunJournal.checkpoint(current, changes) do
      :ok
    end
  end

  defp current(context) do
    with true <- context.owner == self(),
         {:ok, %{} = record} <- RunJournal.read(context.record["directory"]),
         true <- Map.take(record, @identity) == Map.take(context.record, @identity) do
      {:ok, record}
    else
      {:error, _} = error -> error
      _ -> {:error, :task_session_no_longer_owned}
    end
  end

  @doc "Halt and read back this native thread before recording stop; transport closure alone never confirms it."
  @spec stop(t()) :: :ok | {:error, term()}
  def stop(%{native: session, task_session: context}) do
    if context.owner == self() do
      try do
        with :ok <- save(context, %{"native_stop_confirmed" => false, "task_session_phase" => "stopping"}),
             {:ok, evidence} <- NativeStop.confirm_session(session) do
          save(context, Map.put(evidence, "task_session_phase", "stopped"))
        end
      after
        AppServer.stop_session(session)
      end
    else
      {:error, :task_session_no_longer_owned}
    end
  end
end
