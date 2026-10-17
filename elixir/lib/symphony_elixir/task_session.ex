defmodule SymphonyElixir.TaskSession do
  @moduledoc "Owned local Codex sessions and final activation fences for admitted plan-member generations."
  alias SymphonyElixir.{Codex.AppServer, Config, NativeStop, RunJournal, TaskExecution, TaskWorkspace}

  @identity ~w(directory issue_id attempt_id execution_binding execution_generation workspace task_workspace task_session_id)
  @type t :: %{native: AppServer.session(), task_session: map()}

  @doc "Prepare the role workspace and allocate or resume only its own native thread. Admission belongs to TaskExecution."
  @spec start(map(), map(), keyword()) :: {:ok, t()} | {:error, term()}
  def start(record, executions, opts) do
    with true <- local?(record, opts) or {:error, :unsupported_task_session_transport},
         {:ok, record} <- TaskWorkspace.prepare(record, executions, opts),
         context = %{owner: self(), record: record, executions: executions, opts: opts},
         {:ok, observation, _deadline} <- activation(context),
         {:ok, context} <- claim(context) do
      case AppServer.start_session(record["workspace"], session_options(context, observation.policy)) do
        {:ok, session} -> {:ok, %{native: session, task_session: context}}
        error -> failed_start(context, error)
      end
    end
  end

  defp claim(context) do
    with {:ok, record} <- current(context),
         true <- is_nil(record["task_session_id"]) or record["task_session_phase"] == "stopped" or {:error, :task_session_requires_recovery},
         id = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower),
         {:ok, record} <- RunJournal.checkpoint(record, %{"task_session_id" => id, "task_session_phase" => "opening"}) do
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
