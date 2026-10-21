defmodule SymphonyElixir.WorkflowSession do
  @moduledoc "One native session executing supplied workflow instructions; no business-stage orchestration."
  alias SymphonyElixir.{Codex.AppServer, NativeStop}

  @spec run(map(), keyword()) :: {:ok, map(), map()} | {:error, term(), map()}
  def run(context, opts) do
    backend = Keyword.get(opts, :backend, AppServer)
    checkpoint = Keyword.fetch!(opts, :checkpoint)
    Process.put(__MODULE__, %{runtime: %{"workspace" => context.repository}, result: nil})

    start = [
      dynamic_tool_binding: tool_binding(context),
      on_thread_intent: fn ->
        with :ok <- admission(), do: save(checkpoint, %{"thread_allocation_intent" => true})
      end,
      on_thread_started: fn id -> save(checkpoint, %{"thread_id" => id}) end
    ]

    try do
      case backend.start_session(context.repository, start) do
        {:ok, session} -> run_session(backend, session, context, checkpoint, opts)
        error -> finish({:error, {:session_start_failed, error}}, halt(runtime(), backend))
      end
    after
      Process.delete(__MODULE__)
    end
  end

  defp run_session(backend, session, context, checkpoint, opts) do
    handler = fn message ->
      checkpoint_message(message, checkpoint)

      Keyword.get(opts, :on_message, fn _ -> :ok end).(message)
    end

    turn_opts = [
      interruptible: true,
      deadline: opts[:deadline],
      on_message: handler,
      before_turn: fn -> with :ok <- admission(), do: save(checkpoint, %{"turn_allocation_intent" => true}) end
    ]

    result = backend.run_turn(session, context.prompt, context.issue, turn_opts)
    submitted = Process.get(__MODULE__).result

    outcome =
      if match?({:ok, _}, result) and is_map(submitted),
        do: {:ok, submitted},
        else: {:error, {:workflow_incomplete, result}}

    finish(outcome, Map.merge(runtime(), confirm(backend, session)))
  rescue
    error -> finish({:error, {:workflow_failed, Exception.message(error)}}, Map.merge(runtime(), confirm(backend, session)))
  after
    backend.stop_session(session)
  end

  defp checkpoint_message(%{event: :session_started, turn_id: turn}, checkpoint) do
    case save(checkpoint, %{"turn_id" => turn}) do
      :ok -> :ok
      error -> raise "Workflow turn checkpoint failed: #{inspect(error)}"
    end
  end

  defp checkpoint_message(_, _), do: :ok

  defp save(checkpoint, changes) do
    # Record allocation intent before calling the durable writer. A failed writer
    # must not make a possibly allocated native session look safe to retry.
    state = Process.get(__MODULE__)
    Process.put(__MODULE__, %{state | runtime: Map.merge(state.runtime, changes)})
    checkpoint.(changes)
  end

  defp runtime, do: Process.get(__MODULE__).runtime

  defp finish({:ok, result}, %{"native_stop_confirmed" => true} = runtime), do: {:ok, result, runtime}
  defp finish({:ok, _}, runtime), do: {:error, :native_stop_unconfirmed, runtime}
  defp finish({:error, reason}, runtime), do: {:error, reason, runtime}

  defp confirm(AppServer, session) do
    case NativeStop.confirm_session(session) do
      {:ok, receipt} -> receipt
      {:error, reason} -> %{"native_stop_confirmed" => false, "native_stop_error" => inspect(reason)}
    end
  end

  defp confirm(backend, session), do: %{"native_stop_confirmed" => backend.confirm_session(session) == :ok}

  defp halt(%{"thread_id" => _} = record, backend) do
    case NativeStop.confirm(record, backend: backend) do
      {:ok, receipt} -> Map.merge(record, receipt)
      _ -> Map.put(record, "native_stop_confirmed", false)
    end
  end

  defp halt(record, _backend), do: Map.put(record, "native_stop_confirmed", record["thread_allocation_intent"] != true)

  defp admission do
    receive do
      :symphony_stop -> {:error, :scheduler_stop}
    after
      0 -> :ok
    end
  end

  @spec tool_binding(map()) :: map()
  def tool_binding(context) do
    %{
      adapter: __MODULE__,
      model_settings: Map.get(context, :model_settings, %{}),
      tracker_settings: %{},
      secret_environment_names: context.secret_environment_names,
      agent_environment: context.agent_environment,
      tool_specs: [
        %{
          "name" => "workflow_submit",
          "description" => "Submit the workflow artifact. This records a result, not completion or publication; the caller validates it after the native turn stops.",
          "inputSchema" => %{"type" => "object", "properties" => %{"result" => %{"type" => "object"}}, "required" => ["result"], "additionalProperties" => false}
        }
      ]
    }
  end

  @spec execute_agent_tool(String.t(), term(), keyword()) :: map()
  def execute_agent_tool("workflow_submit", %{"result" => result} = args, _opts) when is_map(result) and map_size(args) == 1 do
    case Process.get(__MODULE__) do
      %{result: nil} = state ->
        Process.put(__MODULE__, %{state | result: result})
        %{"success" => true, "output" => "Artifact recorded. Finish the turn; validation and delivery remain pending."}

      _ ->
        %{"success" => false, "output" => "No active workflow or an artifact was already submitted."}
    end
  end

  def execute_agent_tool(_, _, _), do: %{"success" => false, "output" => "Invalid workflow artifact."}
end
