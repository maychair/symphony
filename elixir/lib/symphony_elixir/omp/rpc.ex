defmodule SymphonyElixir.Omp.Rpc do
  @moduledoc "OMP's native JSONL transport; host task policy stays in Tracker."
  alias SymphonyElixir.RunJournal
  alias SymphonyElixir.{Config, ExecutionBackend, PathSafety, Tracker}
  @response_ms 30_000
  @max_frame 67_108_864

  @spec start_session(Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    binding = opts[:dynamic_tool_binding] || Tracker.bind_agent_tools(opts[:tracker_settings])
    record = opts[:run_record] || %{}

    with true <- is_nil(opts[:worker_host]) || {:error, :omp_requires_local_executor},
         {:ok, cwd} <- valid_workspace(workspace),
         :ok <- validate_resume(record, opts),
         {:ok, session} <- open(cwd, binding, record) do
      result = initialize(session, opts)
      if match?({:error, _}, result), do: close(session)
      result
    end
  end

  defp valid_workspace(workspace) do
    with {:ok, cwd} <- PathSafety.canonicalize(Path.expand(workspace)),
         {:ok, root} <- PathSafety.canonicalize(Config.local_workspace_root()),
         true <- String.starts_with?(cwd, root <> "/") || {:error, :omp_workspace_outside_root} do
      {:ok, cwd}
    end
  end

  defp validate_resume(record, opts) do
    cond do
      is_nil(opts[:resume_thread_id]) ->
        :ok

      record["backend"] != "omp" ->
        {:error, :execution_backend_changed}

      record["native_stop_confirmed"] != true ->
        {:error, :omp_native_outcome_unknown}

      not is_binary(record["native_session_file"]) ->
        {:error, :omp_missing_session_file}

      native_alive?(record["native_pid"]) ->
        {:error, :omp_executor_active}

      not is_binary(record["native_transcript_sha256"]) ->
        {:error, :omp_missing_transcript_boundary}

      record["native_transcript_sha256"] != transcript_hash(record["native_session_file"]) ->
        {:error, :omp_session_changed}

      true ->
        :ok
    end
  end

  defp open(cwd, binding, record) do
    session_dir = Path.join(record["directory"] || cwd, "omp-sessions")
    File.mkdir_p!(session_dir)
    args = if record["native_session_file"], do: " --resume " <> quote_arg(record["native_session_file"]), else: ""

    overlay =
      case System.get_env("SYMPHONY_OMP_CONFIG") do
        nil ->
          ""

        path ->
          frozen = Path.join(session_dir, "workspace-config.yml")
          File.write!(frozen, File.read!(path))
          " --config " <> quote_arg(frozen)
      end

    command = ExecutionBackend.command() <> overlay <> " --session-dir " <> quote_arg(session_dir) <> args

    env =
      Enum.map(binding.secret_environment_names, &{String.to_charlist(&1), false}) ++
        Enum.map(binding.agent_environment, fn {key, value} -> {String.to_charlist(key), String.to_charlist(value)} end)

    checkpoint(%{record: record}, %{"phase" => "backend_start_intent", "native_stop_confirmed" => false})

    port =
      Port.open(
        {:spawn_executable, System.find_executable("bash") |> String.to_charlist()},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: [~c"-c", String.to_charlist("exec " <> command)],
          cd: String.to_charlist(cwd),
          env: env,
          line: 1_048_576
        ]
      )

    session = %{backend: __MODULE__, port: port, workspace: cwd, binding: binding, record: record}

    checkpoint(session, %{
      "native_pid" => elem(Port.info(port, :os_pid), 1) |> Integer.to_string(),
      "native_stop_confirmed" => false
    })

    {:ok, session}
  rescue
    error -> {:error, {:omp_start_failed, Exception.message(error)}}
  end

  defp initialize(session, opts) do
    deadline = now() + @response_ms

    with {:ok, %{"type" => "ready"}} <- frame(session.port, deadline),
         {:ok, _} <- command(session, %{"type" => "negotiate_protocol", "protocolVersion" => 2}),
         :ok <- fresh_session(session, opts),
         {:ok, _} <- command(session, %{"type" => "set_auto_retry", "enabled" => false}),
         {:ok, _} <- command(session, %{"type" => "set_host_tools", "tools" => tools(session.binding)}),
         {:ok, state} <- command(session, %{"type" => "get_state"}),
         true <- state["isSettled"] == true || {:error, :omp_session_busy},
         true <- is_binary(state["sessionId"]) || {:error, :omp_missing_session_id},
         :ok <- same_session(session.record, state) do
      session = Map.merge(session, %{thread_id: state["sessionId"], model: model_identity(state["model"])})

      checkpoint(session, %{
        "native_session_file" => state["sessionFile"],
        "native_model" => model_identity(state["model"]),
        "thread_id" => state["sessionId"]
      })

      Keyword.get(opts, :on_thread_started, fn _ -> :ok end).(state["sessionId"])
      {:ok, session}
    else
      false -> {:error, :omp_invalid_state}
      other -> other
    end
  end

  defp fresh_session(session, opts) do
    if opts[:resume_thread_id] do
      :ok
    else
      Keyword.get(opts, :on_thread_intent, fn -> :ok end).()

      case command(session, %{"type" => "new_session"}) do
        {:ok, _} -> :ok
        error -> error
      end
    end
  end

  defp same_session(record, state) do
    cond do
      record["thread_id"] && record["thread_id"] != state["sessionId"] ->
        {:error, :omp_session_mismatch}

      record["native_model"] && model_identity(record["native_model"]) != model_identity(state["model"]) ->
        {:error, :omp_model_changed}

      true ->
        :ok
    end
  end

  defp model_identity(model) when is_map(model), do: Map.take(model, ["id", "provider"])
  defp model_identity(_), do: nil

  defp tools(binding) do
    Enum.map(binding.tool_specs, fn spec ->
      %{"name" => spec["name"], "description" => spec["description"], "parameters" => spec["inputSchema"]}
    end)
  end

  @spec run_turn(map(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(session, prompt, issue, opts \\ []) do
    session = Map.put(session, :tool_executor, opts[:tool_executor])
    deadline = opts[:deadline] || now() + Config.settings!().codex.turn_timeout_ms
    id = unique_id()
    callback = opts[:on_message] || fn _ -> :ok end

    with :ok <- ExecutionBackend.check_config(session.record),
         {:ok, state} <- command(session, %{"type" => "get_state"}),
         true <- model_identity(state["model"]) == session.model || {:error, :omp_model_changed},
         true <- state["isSettled"] == true || {:error, :omp_session_busy} do
      Keyword.get(opts, :before_turn, fn -> :ok end).()
      emit(session, callback, :session_started, %{turn_id: id, session_id: session.thread_id <> ":" <> id})
      checkpoint(session, %{"native_prompt_id" => id})
      send_frame(session.port, %{"id" => id, "type" => "prompt", "message" => prompt})
      await_turn(session, issue, callback, id, deadline, nil)
    else
      false -> {:error, :omp_invalid_state}
      error -> error
    end
  end

  defp await_turn(session, issue, callback, id, deadline, result) do
    with {:ok, message} <- frame(session.port, deadline) do
      case message do
        %{"type" => "host_tool_call"} ->
          host_tool(session, issue, callback, message)
          await_turn(session, issue, callback, id, deadline, result)

        %{"type" => "response", "id" => ^id, "success" => false} ->
          {:error, {:omp_prompt_rejected, message["error"]}}

        %{"type" => "prompt_result", "id" => ^id} ->
          await_settled(session, issue, callback, id, deadline, message)

        %{"type" => "session_settled"} when is_map(result) ->
          complete_turn(session, callback, id, result)

        %{"type" => "message_end", "message" => %{"role" => "assistant", "usage" => usage}} ->
          report_usage(session, callback, usage)
          await_turn(session, issue, callback, id, deadline, result)

        %{"type" => "rpc_frame_error"} ->
          {:error, :omp_transport_overflow}

        %{"type" => "extension_ui_request"} ->
          {:error, :omp_operator_input_required}

        _ ->
          emit(session, callback, :notification, %{payload: message})
          await_turn(session, issue, callback, id, deadline, result)
      end
    end
  end

  defp report_usage(session, callback, usage) do
    input = (usage["input"] || 0) + (usage["cacheRead"] || 0) + (usage["cacheWrite"] || 0)
    output = usage["output"] || 0
    previous = Process.get({session.port, :usage}, %{"input_tokens" => 0, "output_tokens" => 0, "total_tokens" => 0})
    delta = %{"input_tokens" => input, "output_tokens" => output, "total_tokens" => input + output}
    totals = Map.merge(previous, delta, fn _, a, b -> a + b end)
    Process.put({session.port, :usage}, totals)
    emit(session, callback, :notification, %{usage: totals})
  end

  defp await_settled(session, issue, callback, id, deadline, message) do
    if message["sessionSettled"] == true,
      do: complete_turn(session, callback, id, message),
      else: await_turn(session, issue, callback, id, deadline, message)
  end

  defp host_tool(session, issue, callback, message) do
    name = message["toolName"]
    # Native RPC host tools belong to the root session. Subagents receive their
    # own native tools, never this host's task binding.
    result =
      if Enum.any?(session.binding.tool_specs, &(&1["name"] == name)),
        do: execute_tool(session, name, message["arguments"], issue),
        else: %{"success" => false, "output" => "Unknown task tool"}

    send_frame(session.port, %{
      "type" => "host_tool_result",
      "id" => message["id"],
      "isError" => result["success"] != true,
      "result" => %{"content" => [%{"type" => "text", "text" => result["output"] || Jason.encode!(result)}]}
    })

    event = if result["success"] == true, do: :tool_call_completed, else: :tool_call_failed
    emit(session, callback, event, %{tool: name})

    case current_record(session) do
      %{"delivery" => delivery} when is_map(delivery) ->
        send_frame(session.port, %{"id" => unique_id(), "type" => "abort_and_restore_queue"})

      %{"blocker_reason" => reason} when is_binary(reason) ->
        send_frame(session.port, %{"id" => unique_id(), "type" => "abort_and_restore_queue"})

      _ ->
        :ok
    end
  end

  defp execute_tool(%{tool_executor: executor}, name, args, _issue) when is_function(executor, 2),
    do: executor.(name, args)

  defp execute_tool(session, name, args, issue),
    do: Tracker.execute_bound_agent_tool(session.binding, name, args, issue: issue)

  defp complete_turn(session, callback, id, result) do
    with {:ok, state} <- command(session, %{"type" => "get_state"}) do
      checkpoint(session, %{
        "native_session_file" => state["sessionFile"],
        "native_message_count" => state["messageCount"]
      })

      case result["status"] do
        "completed" ->
          emit(session, callback, :turn_completed, %{payload: %{"params" => %{"turn" => %{"id" => id}}}})
          {:ok, %{thread_id: session.thread_id, turn_id: id, session_id: session.thread_id <> ":" <> id}}

        "aborted" ->
          aborted_result(session, id)

        _ ->
          {:error, {:omp_provider_error, result["error"]}}
      end
    end
  end

  defp aborted_result(session, id) do
    record = current_record(session)

    if record["delivery"] || record["blocker_reason"],
      do: {:ok, %{thread_id: session.thread_id, turn_id: id, session_id: session.thread_id <> ":" <> id}},
      else: {:error, :omp_turn_aborted}
  end

  @spec stop_session(map()) :: :ok | {:error, term()}
  def stop_session(session) do
    result =
      with {:ok, _} <- command(session, %{"type" => "abort_and_restore_queue"}, 5_000),
           {:ok, state} <- command(session, %{"type" => "get_state"}, 5_000),
           true <- state["isSettled"] == true do
        :ok
      else
        _ -> {:error, :omp_native_stop_unconfirmed}
      end

    pid =
      case Port.info(session.port, :os_pid) do
        {:os_pid, pid} -> Integer.to_string(pid)
        _ -> nil
      end

    close(session)
    result = if result == :ok, do: wait_stopped(pid, now() + 2_000), else: result
    record = current_record(session)

    checkpoint(session, %{
      "native_stop_confirmed" => result == :ok,
      "native_transcript_sha256" => transcript_hash(record["native_session_file"])
    })

    result
  end

  defp wait_stopped(pid, deadline) do
    cond do
      is_nil(pid) ->
        {:error, :omp_native_stop_unconfirmed}

      not native_alive?(pid) ->
        :ok

      now() >= deadline ->
        {:error, :omp_native_stop_unconfirmed}

      true ->
        Process.sleep(10)
        wait_stopped(pid, deadline)
    end
  end

  defp close(session) do
    Process.delete({session.port, :usage})
    if Port.info(session.port), do: Port.close(session.port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp command(session, request, timeout \\ @response_ms) do
    id = unique_id()
    send_frame(session.port, Map.put(request, "id", id))
    response(session.port, id, now() + timeout)
  rescue
    ArgumentError -> {:error, :omp_transport_closed}
  end

  defp response(port, id, deadline) do
    with {:ok, message} <- frame(port, deadline) do
      case message do
        %{"type" => "response", "id" => ^id, "success" => true} -> {:ok, message["data"] || %{}}
        %{"type" => "response", "id" => ^id} -> {:error, {:omp_command_failed, message["error"]}}
        _ -> response(port, id, deadline)
      end
    end
  end

  defp frame(port, deadline, pending \\ "") do
    receive do
      {^port, {:data, {:eol, data}}} ->
        decode_frame(port, deadline, pending <> data)

      {^port, {:data, {:noeol, data}}} when byte_size(pending) + byte_size(data) <= @max_frame ->
        frame(port, deadline, pending <> data)

      {^port, {:exit_status, code}} ->
        {:error, {:omp_exit, code}}
    after
      max(0, deadline - now()) -> {:error, :omp_execution_timeout}
    end
  end

  defp decode_frame(port, deadline, bytes) do
    case Jason.decode(bytes) do
      {:ok, %{"type" => "rpc_chunk", "index" => 0} = chunk} -> chunks(port, deadline, chunk, 0, [])
      {:ok, %{} = message} -> {:ok, message}
      _ -> frame(port, deadline)
    end
  end

  defp chunks(port, deadline, chunk, index, parts) do
    with true <- is_integer(chunk["count"]) and chunk["count"] > 0 and chunk["byteLength"] <= @max_frame,
         {:ok, data} <- Base.decode64(chunk["data"]),
         parts <- [data | parts],
         true <- Enum.reduce(parts, 0, &(byte_size(&1) + &2)) <= @max_frame do
      consume_chunk(port, deadline, chunk, index, parts)
    else
      _ -> {:error, :omp_invalid_chunk}
    end
  end

  defp consume_chunk(port, deadline, chunk, index, parts) do
    if index + 1 == chunk["count"] do
      bytes = parts |> Enum.reverse() |> IO.iodata_to_binary()
      if byte_size(bytes) == chunk["byteLength"], do: Jason.decode(bytes), else: {:error, :omp_invalid_chunk_size}
    else
      with {:ok, next} <- frame(port, deadline),
           true <-
             next["type"] == "rpc_chunk" and next["chunkId"] == chunk["chunkId"] and next["index"] == index + 1 and
               next["count"] == chunk["count"] and next["byteLength"] == chunk["byteLength"] do
        chunks(port, deadline, next, index + 1, parts)
      else
        _ -> {:error, :omp_invalid_chunk_sequence}
      end
    end
  end

  defp send_frame(port, value), do: Port.command(port, Jason.encode!(value) <> "\n")
  defp unique_id, do: "symphony-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
  defp now, do: System.monotonic_time(:millisecond)
  defp quote_arg(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"

  defp transcript_hash(path) when is_binary(path) do
    case File.read(path) do
      {:ok, bytes} -> :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
      _ -> nil
    end
  end

  defp transcript_hash(_), do: nil

  defp native_alive?(pid) when is_binary(pid), do: File.exists?("/proc/" <> pid)
  defp native_alive?(_), do: true
  defp current_record(%{record: %{"directory" => directory}}), do: elem(RunJournal.read(directory), 1) || %{}
  defp current_record(_), do: %{}

  defp checkpoint(%{record: %{"directory" => _}} = session, changes) do
    {:ok, _} = RunJournal.checkpoint(current_record(session), changes)
    :ok
  end

  defp checkpoint(_, _), do: :ok

  defp emit(session, callback, event, details),
    do: callback.(Map.merge(%{event: event, timestamp: DateTime.utc_now(), thread_id: session.thread_id}, details))
end
