defmodule SymphonyElixir.Codex.AppServer do
  @moduledoc """
  Minimal client for the Codex app-server JSON-RPC 2.0 stream over stdio.
  """

  require Logger
  alias SymphonyElixir.{Codex.DynamicTool, Config, PathSafety, SSH}

  @initialize_id 1
  @thread_start_id 2
  @turn_start_id 3
  @port_line_bytes 1_048_576
  @goal_read_id 4
  @goal_start_id 5
  @goal_stop_id 6
  @goal_interrupt_id 7
  @goal_inspect_id 8
  @max_stream_log_bytes 1_000
  @type session :: %{
          port: port(),
          metadata: map(),
          approval_policy: String.t() | map(),
          auto_approve_requests: boolean(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map(),
          thread_id: String.t(),
          workspace: Path.t(),
          worker_host: String.t() | nil,
          dynamic_tool_binding: map()
        }

  @spec run(Path.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(workspace, prompt, issue, opts \\ []) do
    with {:ok, session} <- start_session(workspace, opts) do
      try do
        run_turn(session, prompt, issue, opts)
      after
        stop_session(session)
      end
    end
  end

  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)
    dynamic_tool_binding = Keyword.get_lazy(opts, :dynamic_tool_binding, fn -> DynamicTool.bind(opts[:tracker_settings]) end)

    on_thread_intent = Keyword.get(opts, :on_thread_intent, fn -> :ok end)
    on_thread_started = Keyword.get(opts, :on_thread_started, fn _id -> :ok end)

    with {:ok, expanded_workspace} <- validate_workspace_cwd(workspace, worker_host),
         {:ok, port} <- start_port(expanded_workspace, worker_host, dynamic_tool_binding) do
      metadata = port_metadata(port, worker_host)

      with {:ok, session_policies} <- session_policies(expanded_workspace, worker_host, opts),
           {:ok, thread_id} <-
             do_start_session(
               port,
               expanded_workspace,
               session_policies,
               dynamic_tool_binding,
               opts,
               on_thread_intent
             ),
           :ok <- SymphonyElixir.ExecutionBinding.check_native_identity(opts[:run_record] || %{}, %{"thread_id" => thread_id}) do
        on_thread_started.(thread_id)

        {:ok,
         %{
           port: port,
           metadata: metadata,
           approval_policy: session_policies.approval_policy,
           auto_approve_requests: auto_approve?(session_policies, dynamic_tool_binding),
           thread_sandbox: session_policies.thread_sandbox,
           turn_sandbox_policy: session_policies.turn_sandbox_policy,
           thread_id: thread_id,
           workspace: expanded_workspace,
           worker_host: worker_host,
           dynamic_tool_binding: dynamic_tool_binding
         }}
      else
        {:error, reason} ->
          stop_port(port)
          {:error, reason}
      end
    end
  end

  defp auto_approve?(policies, _binding) do
    policies.approval_policy == "never"
  end

  defp execution_context(executor, thread_id, turn_id, _binding) do
    strict = Config.settings!().agent.goal_mode
    %{executor: executor, thread_id: thread_id, turn_id: turn_id, strict: strict}
  end

  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(
        %{
          port: port,
          metadata: metadata,
          approval_policy: approval_policy,
          auto_approve_requests: auto_approve_requests,
          turn_sandbox_policy: turn_sandbox_policy,
          thread_id: thread_id,
          workspace: workspace,
          dynamic_tool_binding: dynamic_tool_binding
        },
        prompt,
        issue,
        opts \\ []
      ) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)

    tool_executor =
      Keyword.get(opts, :tool_executor, fn tool, arguments ->
        DynamicTool.execute(tool, arguments, dynamic_tool_binding, issue: issue)
      end)

    Keyword.get(opts, :before_turn, fn -> :ok end).()

    case start_turn(port, thread_id, prompt, issue, workspace, approval_policy, turn_sandbox_policy) do
      {:ok, turn_id} ->
        session_id = "#{thread_id}-#{turn_id}"
        Logger.info("Codex session started for #{issue_context(issue)} session_id=#{session_id}")

        emit_message(
          on_message,
          :session_started,
          %{
            session_id: session_id,
            thread_id: thread_id,
            turn_id: turn_id
          },
          metadata
        )

        case await_turn_completion(
               port,
               on_message,
               Map.put(execution_context(tool_executor, thread_id, turn_id, dynamic_tool_binding), :deadline, opts[:deadline]),
               auto_approve_requests
             ) do
          {:ok, result} ->
            Logger.info("Codex session completed for #{issue_context(issue)} session_id=#{session_id}")

            {:ok,
             %{
               result: result,
               session_id: session_id,
               thread_id: thread_id,
               turn_id: turn_id
             }}

          {:error, reason} ->
            Logger.warning("Codex session ended with error for #{issue_context(issue)} session_id=#{session_id}: #{inspect(reason)}")

            emit_message(
              on_message,
              :turn_ended_with_error,
              %{
                session_id: session_id,
                reason: reason
              },
              metadata
            )

            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("Codex session failed for #{issue_context(issue)}: #{inspect(reason)}")
        emit_message(on_message, :startup_failed, %{reason: reason}, metadata)
        {:error, reason}
    end
  end

  @doc "Run the task's native Goal; automatic Goal turns belong to this executor, not a UI parent."
  @spec run_goal(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_goal(session, objective, issue, opts \\ []) do
    handler = Keyword.get(opts, :on_message, &default_on_message/1)

    executor = fn tool, arguments ->
      DynamicTool.execute(tool, arguments, session.dynamic_tool_binding, issue: issue)
    end

    with {:ok, existing} <- read_goal(session),
         :ok <- resumable_goal(existing, opts) do
      Keyword.get(opts, :before_goal, fn -> :ok end).()

      context =
        execution_context(executor, session.thread_id, nil, session.dynamic_tool_binding)
        |> Map.merge(%{
          goal_mode: true,
          goal_status: "active",
          goal_ack: false,
          goal_running: false,
          goal_stop_requested: nil,
          deadline: opts[:deadline] || System.monotonic_time(:millisecond) + Config.settings!().codex.turn_timeout_ms,
          handoff_status: Keyword.get(opts, :handoff_status, fn -> nil end)
        })

      send_message(session.port, %{
        "id" => @goal_start_id,
        "method" => "thread/goal/set",
        "params" => %{
          "threadId" => session.thread_id,
          "objective" => if(existing, do: existing["objective"], else: objective),
          "status" => "active",
          "origin" => "user"
        }
      })

      result =
        try do
          receive_loop(session.port, handler, Config.settings!().codex.turn_timeout_ms, "", context, session.auto_approve_requests)
        rescue
          error -> {:error, {:goal_stream_failed, Exception.message(error)}}
        end

      case result do
        {:ok, _} ->
          Keyword.get(opts, :on_goal_stopped, fn _ -> :ok end).(true)
          result

        {:error, _} ->
          confirmed = stop_goal_after_error(session, opts)
          Keyword.get(opts, :on_goal_stopped, fn _ -> :ok end).(confirmed)
          result
      end
    end
  end

  defp read_goal(session) do
    send_message(session.port, %{"id" => @goal_read_id, "method" => "thread/goal/get", "params" => %{"threadId" => session.thread_id}})

    case await_response(session.port, @goal_read_id) do
      {:ok, %{"goal" => nil}} ->
        {:ok, nil}

      {:ok, %{"goal" => goal}} ->
        if valid_goal?(goal, session.thread_id), do: {:ok, goal}, else: {:error, :invalid_goal_response}

      {:ok, result} ->
        {:error, {:invalid_goal_response, result}}

      error ->
        error
    end
  end

  defp valid_goal?(goal, thread_id) do
    is_map(goal) and goal["threadId"] == thread_id and
      goal["status"] in ["active", "paused", "blocked", "usageLimited", "budgetLimited", "complete"] and
      is_binary(goal["objective"])
  end

  defp resumable_goal(nil, _opts), do: :ok
  defp resumable_goal(%{"status" => "active"}, _opts), do: :ok

  defp resumable_goal(%{"status" => status}, opts) do
    if opts[:resume_goal] == true and status in ["blocked", "complete"],
      do: :ok,
      else: {:error, {:native_goal_requires_explicit_resume, status}}
  end

  defp stop_goal_after_error(session, opts) do
    turn_id = Keyword.get(opts, :latest_turn, fn -> nil end).()

    with {:ok, goal} <- halt_goal(session),
         true <- goal["threadId"] == session.thread_id do
      emit_message(Keyword.get(opts, :on_message, &default_on_message/1), :goal_updated, %{goal: goal}, port_metadata(session.port, nil))

      if is_binary(turn_id) do
        send_message(session.port, %{
          "id" => @goal_interrupt_id,
          "method" => "turn/interrupt",
          "params" => %{"threadId" => session.thread_id, "turnId" => turn_id}
        })

        await_response(session.port, @goal_interrupt_id)
      end

      send_message(session.port, %{
        "id" => @goal_inspect_id,
        "method" => "thread/read",
        "params" => %{"threadId" => session.thread_id, "includeTurns" => true}
      })

      case await_response(session.port, @goal_inspect_id) do
        {:ok, %{"thread" => thread}} -> thread["id"] == session.thread_id and reconciled_turn?(thread, turn_id || :no_turns)
        _ -> false
      end
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  defp halt_goal(session) do
    with {:ok, goal} when is_map(goal) <- read_goal(session) do
      if goal["status"] in ["paused", "blocked", "usageLimited", "budgetLimited", "complete"] do
        {:ok, goal}
      else
        block_goal(session)
      end
    end
  end

  defp block_goal(session) do
    send_message(session.port, %{
      "id" => @goal_stop_id,
      "method" => "thread/goal/set",
      "params" => %{"threadId" => session.thread_id, "status" => "blocked", "origin" => "automatic"}
    })

    case await_response(session.port, @goal_stop_id) do
      {:ok, %{"goal" => goal}} -> {:ok, goal}
      error -> error
    end
  end

  @spec stop_session(session()) :: :ok
  def stop_session(%{port: port}) when is_port(port) do
    stop_port(port)
  end

  defp validate_workspace_cwd(workspace, nil) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Config.local_workspace_root()
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:invalid_workspace_cwd, :workspace_root, canonical_workspace}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          {:ok, canonical_workspace}

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:invalid_workspace_cwd, :symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:invalid_workspace_cwd, :outside_workspace_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:invalid_workspace_cwd, :path_unreadable, path, reason}}
    end
  end

  defp validate_workspace_cwd(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:invalid_workspace_cwd, :empty_remote_workspace, worker_host}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:invalid_workspace_cwd, :invalid_remote_workspace, worker_host, workspace}}

      true ->
        {:ok, workspace}
    end
  end

  defp start_port(workspace, nil, dynamic_tool_binding) do
    executable = System.find_executable("bash")

    if is_nil(executable) do
      {:error, :bash_not_found}
    else
      port =
        Port.open(
          {:spawn_executable, String.to_charlist(executable)},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: [~c"-lc", String.to_charlist(local_launch_command(dynamic_tool_binding))],
            cd: String.to_charlist(workspace),
            env: tracker_secret_port_env(dynamic_tool_binding) ++ agent_port_env(dynamic_tool_binding),
            line: @port_line_bytes
          ]
        )

      {:ok, port}
    end
  end

  defp start_port(workspace, worker_host, dynamic_tool_binding) when is_binary(worker_host) do
    remote_command = remote_launch_command(workspace, dynamic_tool_binding)
    SSH.start_port(worker_host, remote_command, line: @port_line_bytes)
  end

  defp local_launch_command(dynamic_tool_binding) do
    [
      tracker_secret_unset_command(dynamic_tool_binding),
      agent_environment_command(dynamic_tool_binding),
      "exec #{SymphonyElixir.ExecutionBackend.command()}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" && ")
  end

  defp remote_launch_command(workspace, dynamic_tool_binding) when is_binary(workspace) do
    [
      "cd #{shell_escape(workspace)}",
      tracker_secret_unset_command(dynamic_tool_binding),
      agent_environment_command(dynamic_tool_binding),
      "exec #{SymphonyElixir.ExecutionBackend.command()}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" && ")
  end

  defp agent_port_env(binding) do
    Enum.map(binding.agent_environment, fn {name, value} -> {String.to_charlist(name), String.to_charlist(value)} end)
  end

  defp agent_environment_command(binding) do
    case Enum.map(binding.agent_environment, fn {name, value} -> "export #{name}=#{shell_escape(value)}" end) do
      [] -> nil
      entries -> Enum.join(entries, " && ")
    end
  end

  defp tracker_secret_port_env(dynamic_tool_binding) do
    dynamic_tool_binding.secret_environment_names
    |> valid_environment_names()
    |> Enum.map(fn name -> {String.to_charlist(name), false} end)
  end

  defp tracker_secret_unset_command(dynamic_tool_binding) do
    case dynamic_tool_binding.secret_environment_names |> valid_environment_names() do
      [] -> nil
      names -> "unset " <> Enum.join(names, " ")
    end
  end

  defp valid_environment_names(names) do
    Enum.filter(names, fn name ->
      is_binary(name) and String.match?(name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/)
    end)
  end

  defp port_metadata(port, worker_host) when is_port(port) do
    base_metadata =
      case :erlang.port_info(port, :os_pid) do
        {:os_pid, os_pid} ->
          %{codex_app_server_pid: to_string(os_pid)}

        _ ->
          %{}
      end

    case worker_host do
      host when is_binary(host) -> Map.put(base_metadata, :worker_host, host)
      _ -> base_metadata
    end
  end

  defp send_initialize(port) do
    payload = %{
      "method" => "initialize",
      "id" => @initialize_id,
      "params" => %{
        "capabilities" => %{
          "experimentalApi" => true
        },
        "clientInfo" => %{
          "name" => "symphony-orchestrator",
          "title" => "Symphony Orchestrator",
          "version" => "0.1.0"
        }
      }
    }

    send_message(port, payload)

    with {:ok, _} <- await_response(port, @initialize_id) do
      send_message(port, %{"method" => "initialized", "params" => %{}})
      :ok
    end
  end

  defp session_policies(workspace, nil, opts) do
    if Keyword.get(opts, :review_only, false) do
      {:ok, %{approval_policy: "never", thread_sandbox: "read-only", turn_sandbox_policy: %{"type" => "readOnly"}}}
    else
      Config.codex_runtime_settings(workspace)
    end
  end

  defp session_policies(workspace, worker_host, _opts) when is_binary(worker_host) do
    Config.codex_runtime_settings(workspace, remote: true)
  end

  defp do_start_session(port, workspace, session_policies, dynamic_tool_binding, opts, on_intent) do
    with :ok <- send_initialize(port) do
      on_intent.()

      open_thread(port, workspace, session_policies, dynamic_tool_binding, opts)
    end
  end

  defp open_thread(port, workspace, policies, binding, opts) do
    case opts[:resume_thread_id] do
      id when is_binary(id) -> open_existing_thread(port, id, workspace, policies, opts)
      _ -> start_thread(port, workspace, policies, binding)
    end
  end

  defp open_existing_thread(port, id, workspace, policies, opts) do
    cond do
      opts[:halt_only] ->
        with :ok <- suspend_goal_for_resume(port, id, opts), do: inspect_thread(port, id, opts)

      opts[:inspect_only] ->
        inspect_thread(port, id, opts)

      true ->
        resume_thread(port, id, workspace, policies, opts)
    end
  end

  defp resume_thread(port, thread_id, workspace, policies, opts) do
    with :ok <- suspend_goal_for_resume(port, thread_id, opts) do
      do_resume_thread(port, thread_id, workspace, policies, opts)
    end
  end

  # An active persisted Goal can allocate a turn as a side effect of resume.
  # Suspend it before loading the thread; admission/lease precedes explicit set.
  defp suspend_goal_for_resume(port, thread_id, opts) do
    if opts[:suspend_goal] do
      session = %{port: port, thread_id: thread_id}

      case read_goal(session) do
        {:ok, nil} ->
          :ok

        {:ok, _goal} ->
          halt_goal_for_resume(session, opts)

        error ->
          error
      end
    else
      :ok
    end
  end

  defp halt_goal_for_resume(session, opts) do
    with :ok <- ensure_goal_halted(session), do: maybe_interrupt_active(session, opts)
  end

  defp maybe_interrupt_active(session, opts) do
    if opts[:interrupt_active] do
      send_message(session.port, %{"id" => @goal_inspect_id, "method" => "thread/read", "params" => %{"threadId" => session.thread_id, "includeTurns" => true}})

      case await_response(session.port, @goal_inspect_id) do
        {:ok, %{"thread" => %{"id" => id, "turns" => turns}}} when id == session.thread_id and is_list(turns) ->
          turns |> Enum.filter(&(&1["status"] == "inProgress")) |> Enum.reduce_while(:ok, &interrupt_active_turn(session, &1, &2))

        error ->
          {:error, {:native_stop_inspection_failed, error}}
      end
    else
      :ok
    end
  end

  defp interrupt_active_turn(session, %{"id" => turn}, :ok) do
    send_message(session.port, %{"id" => @goal_interrupt_id, "method" => "turn/interrupt", "params" => %{"threadId" => session.thread_id, "turnId" => turn}})

    case await_response(session.port, @goal_interrupt_id) do
      {:ok, _} -> {:cont, :ok}
      error -> {:halt, {:error, {:native_turn_interrupt_unconfirmed, error}}}
    end
  end

  defp interrupt_active_turn(_, _, _), do: {:halt, {:error, :native_turn_identity_missing}}

  defp ensure_goal_halted(session) do
    case halt_goal(session) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp inspect_thread(port, thread_id, opts) do
    send_message(port, %{"id" => @thread_start_id, "method" => "thread/read", "params" => %{"threadId" => thread_id, "includeTurns" => true}})

    case await_response(port, @thread_start_id) do
      {:ok, %{"thread" => %{"id" => ^thread_id, "status" => %{"type" => status}} = thread}} when status in ["idle", "notLoaded"] ->
        case reconciled_observation(thread, opts) do
          {:ok, observation} ->
            Keyword.get(opts, :on_thread_observed, fn _ -> :ok end).(observation)
            {:ok, thread_id}

          error ->
            error
        end

      {:ok, result} ->
        {:error, {:resume_thread_not_proven_idle, result}}

      error ->
        error
    end
  end

  defp reconciled_observation(thread, opts) do
    turns = thread["turns"] || []
    expected = opts[:expected_turn_id]
    index = Enum.find_index(turns, &(&1["id"] == expected))
    suffix = if is_integer(index), do: Enum.drop(turns, index), else: []

    cond do
      reconciled_turn?(thread, expected) ->
        {:ok, %{turn_id: expected, additional_turns: 0}}

      halted_observation?(turns, opts) ->
        {:ok, %{turn_id: get_in(List.last(turns) || %{}, ["id"]), additional_turns: length(turns)}}

      terminal_suffix?(suffix, opts) ->
        {:ok, %{turn_id: List.last(suffix)["id"], additional_turns: length(suffix) - 1}}

      true ->
        {:error, :native_turn_not_reconciled}
    end
  end

  defp halted_observation?(turns, opts) do
    opts[:halt_only] == true and Enum.all?(turns, &(&1["status"] in ["completed", "failed", "interrupted"]))
  end

  defp terminal_suffix?(turns, opts) do
    opts[:reconcile_terminal_turns] == true and turns != [] and
      Enum.all?(turns, &(&1["status"] in ["completed", "failed", "interrupted"]))
  end

  defp do_resume_thread(port, thread_id, workspace, policies, opts) do
    send_message(port, %{
      "id" => @thread_start_id,
      "method" => "thread/resume",
      "params" => %{
        "threadId" => thread_id,
        "cwd" => workspace,
        "approvalPolicy" => policies.approval_policy,
        "sandbox" => policies.thread_sandbox,
        "config" => thread_sandbox_config(policies)
      }
    })

    case await_response(port, @thread_start_id) do
      {:ok, %{"thread" => %{"id" => ^thread_id, "status" => %{"type" => "idle"}} = thread}} ->
        case reconciled_turn?(thread, opts[:expected_turn_id]) do
          true -> {:ok, thread_id}
          false -> {:error, :native_turn_not_reconciled}
        end

      {:ok, result} ->
        {:error, {:resume_thread_not_proven_idle, result}}

      error ->
        error
    end
  end

  defp reconciled_turn?(%{"turns" => []}, :no_turns), do: true
  defp reconciled_turn?(_thread, nil), do: true

  defp reconciled_turn?(thread, expected_turn) do
    case List.last(thread["turns"] || []) do
      %{"id" => ^expected_turn, "status" => status} when status in ["completed", "failed", "interrupted"] -> true
      _ -> false
    end
  end

  defp start_thread(
         port,
         workspace,
         %{approval_policy: approval_policy, thread_sandbox: thread_sandbox} = policies,
         dynamic_tool_binding
       ) do
    send_message(port, %{
      "method" => "thread/start",
      "id" => @thread_start_id,
      "params" => %{
        "approvalPolicy" => approval_policy,
        "sandbox" => thread_sandbox,
        "config" => thread_sandbox_config(policies),
        "cwd" => workspace,
        "dynamicTools" => dynamic_tool_binding.tool_specs
      }
    })

    case await_response(port, @thread_start_id) do
      {:ok, %{"thread" => thread_payload}} ->
        case thread_payload do
          %{"id" => thread_id} -> {:ok, thread_id}
          _ -> {:error, {:invalid_thread_payload, thread_payload}}
        end

      other ->
        other
    end
  end

  # Native Goal turns use thread defaults rather than explicit turn/start policy.
  defp thread_sandbox_config(%{thread_sandbox: "workspace-write", turn_sandbox_policy: policy}) do
    %{
      "sandbox_workspace_write.network_access" => policy["networkAccess"] == true,
      "sandbox_workspace_write.writable_roots" => policy["writableRoots"] || [],
      "sandbox_workspace_write.exclude_slash_tmp" => policy["excludeSlashTmp"] == true,
      "sandbox_workspace_write.exclude_tmpdir_env_var" => policy["excludeTmpdirEnvVar"] == true
    }
  end

  defp thread_sandbox_config(_policies), do: %{}

  defp start_turn(port, thread_id, prompt, issue, workspace, approval_policy, turn_sandbox_policy) do
    send_message(port, %{
      "method" => "turn/start",
      "id" => @turn_start_id,
      "params" => %{
        "threadId" => thread_id,
        "input" => [
          %{
            "type" => "text",
            "text" => prompt
          }
        ],
        "cwd" => workspace,
        "title" => "#{issue.identifier}: #{issue.title}",
        "approvalPolicy" => approval_policy,
        "sandboxPolicy" => turn_sandbox_policy
      }
    })

    case await_response(port, @turn_start_id) do
      {:ok, %{"turn" => %{"id" => turn_id}}} -> {:ok, turn_id}
      other -> other
    end
  end

  defp await_turn_completion(port, on_message, tool_executor, auto_approve_requests) do
    receive_loop(
      port,
      on_message,
      Config.settings!().codex.turn_timeout_ms,
      "",
      tool_executor,
      auto_approve_requests
    )
  end

  defp receive_loop(port, on_message, timeout_ms, pending_line, tool_executor, auto_approve_requests) do
    receive do
      :symphony_stop when is_map_key(tool_executor, :goal_mode) -> {:error, :scheduler_stop}
    after
      0 -> receive_available(port, on_message, timeout_ms, pending_line, tool_executor, auto_approve_requests)
    end
  end

  defp receive_available(port, on_message, timeout_ms, pending_line, tool_executor, auto_approve_requests) do
    tool_executor = check_goal_handoff(port, tool_executor)
    remaining = remaining_time(tool_executor[:deadline], timeout_ms)
    wait_ms = if tool_executor[:goal_mode], do: min(1_000, min(timeout_ms, remaining)), else: min(timeout_ms, remaining)

    receive do
      :symphony_stop when is_map_key(tool_executor, :goal_mode) ->
        {:error, :scheduler_stop}

      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)
        handle_incoming(port, on_message, complete_line, timeout_ms, tool_executor, auto_approve_requests)

      {^port, {:data, {:noeol, chunk}}} ->
        receive_loop(
          port,
          on_message,
          timeout_ms,
          pending_line <> to_string(chunk),
          tool_executor,
          auto_approve_requests
        )

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      wait_ms ->
        if goal_waiting?(tool_executor) do
          receive_loop(port, on_message, timeout_ms, pending_line, tool_executor, auto_approve_requests)
        else
          {:error, timeout_reason(tool_executor[:deadline])}
        end
    end
  end

  defp remaining_time(nil, timeout), do: timeout
  defp remaining_time(deadline, _timeout), do: max(0, deadline - System.monotonic_time(:millisecond))

  defp goal_waiting?(context) do
    context[:goal_mode] && context[:deadline] && System.monotonic_time(:millisecond) < context.deadline
  end

  defp timeout_reason(nil), do: :turn_timeout

  defp timeout_reason(deadline) do
    if System.monotonic_time(:millisecond) >= deadline, do: :execution_budget_exhausted, else: :turn_timeout
  end

  defp handle_incoming(port, on_message, data, timeout_ms, context, auto_approve_requests) do
    raw = to_string(data)

    case Jason.decode(raw) do
      {:ok, %{"method" => _method} = payload} ->
        route_event(port, on_message, payload, raw, timeout_ms, context, auto_approve_requests)

      {:ok, %{"id" => id} = payload} when id in [@goal_start_id, @goal_stop_id] ->
        if context[:goal_mode] do
          handle_goal_reply(port, on_message, payload, timeout_ms, context, auto_approve_requests)
        else
          handle_decoded_result(port, on_message, {:ok, payload}, raw, timeout_ms, context, auto_approve_requests)
        end

      decoded ->
        handle_decoded_result(
          port,
          on_message,
          decoded,
          raw,
          timeout_ms,
          context,
          auto_approve_requests
        )
    end
  end

  defp route_event(port, handler, payload, raw, timeout, context, auto) do
    cond do
      goal_event?(payload, context) -> handle_goal_event(port, handler, payload, timeout, context, auto)
      root_event?(payload, context) -> handle_decoded_result(port, handler, {:ok, payload}, raw, timeout, context, auto)
      true -> handle_unscoped_event(port, handler, payload, timeout, context, auto)
    end
  end

  defp goal_event?(payload, %{goal_mode: true} = context) do
    params = payload["params"] || %{}
    params["threadId"] == context.thread_id and payload["method"] in ["thread/goal/updated", "thread/goal/cleared", "turn/started"]
  end

  defp goal_event?(_payload, _context), do: false

  defp handle_goal_event(_port, _handler, %{"method" => "thread/goal/cleared"}, _timeout, _context, _auto),
    do: {:error, :native_goal_cleared}

  defp handle_goal_event(port, handler, %{"method" => "thread/goal/updated", "params" => %{"goal" => goal}}, timeout, context, auto) do
    if goal["threadId"] == context.thread_id and goal["status"] in ["active", "paused", "blocked", "usageLimited", "budgetLimited", "complete"] do
      emit_message(handler, :goal_updated, %{goal: goal}, port_metadata(port, nil))
      finish_or_wait_goal(port, handler, timeout, %{context | goal_status: goal["status"]}, auto)
    else
      {:error, :invalid_native_goal_identity}
    end
  end

  defp handle_goal_event(port, handler, %{"method" => "turn/started", "params" => %{"turn" => %{"id" => turn_id}}}, timeout, context, auto)
       when is_binary(turn_id) do
    cond do
      context.goal_running and context.turn_id == turn_id ->
        receive_loop(port, handler, timeout, "", context, auto)

      context.goal_running ->
        {:error, :overlapping_native_goal_turns}

      true ->
        session = %{thread_id: context.thread_id, turn_id: turn_id, session_id: context.thread_id <> "-" <> turn_id}
        emit_message(handler, :session_started, session, port_metadata(port, nil))
        context = %{context | turn_id: turn_id, goal_running: true}

        if context.goal_stop_requested do
          interrupt_goal_turn(port, context.thread_id, turn_id)
        end

        receive_loop(port, handler, timeout, "", context, auto)
    end
  end

  defp handle_goal_event(_port, _handler, _payload, _timeout, _context, _auto), do: {:error, :invalid_native_goal_event}

  defp handle_goal_reply(_port, _handler, %{"error" => error}, _timeout, _context, _auto), do: {:error, {:goal_request_failed, error}}

  defp handle_goal_reply(port, handler, %{"result" => %{"goal" => goal}}, timeout, context, auto) do
    if valid_goal?(goal, context.thread_id) do
      emit_message(handler, :goal_updated, %{goal: goal}, port_metadata(port, nil))
      finish_or_wait_goal(port, handler, timeout, %{context | goal_ack: true, goal_status: goal["status"]}, auto)
    else
      {:error, :invalid_native_goal_identity}
    end
  end

  defp handle_goal_reply(_port, _handler, _payload, _timeout, _context, _auto), do: {:error, :invalid_goal_response}

  defp finish_or_wait_goal(port, handler, timeout, context, auto) do
    if context.goal_ack and not context.goal_running and context.goal_status != "active" do
      {:ok, %{goal_status: context.goal_status, thread_id: context.thread_id, turn_id: context.turn_id}}
    else
      receive_loop(port, handler, timeout, "", context, auto)
    end
  end

  defp maybe_request_goal_handoff(port, %{goal_mode: true, goal_stop_requested: nil} = context) do
    case context.handoff_status.() do
      status when status in ["complete", "blocked"] ->
        send_message(port, %{
          "id" => @goal_stop_id,
          "method" => "thread/goal/set",
          "params" => %{"threadId" => context.thread_id, "status" => status, "origin" => "automatic"}
        })

        if context.goal_running and is_binary(context.turn_id) do
          interrupt_goal_turn(port, context.thread_id, context.turn_id)
        end

        %{context | goal_stop_requested: status}

      _ ->
        context
    end
  end

  defp maybe_request_goal_handoff(_port, context), do: context

  defp interrupt_goal_turn(port, thread, turn) do
    params = %{"threadId" => thread, "turnId" => turn}
    send_message(port, %{"id" => @goal_interrupt_id, "method" => "turn/interrupt", "params" => params})
  end

  defp check_goal_handoff(port, %{goal_mode: true} = context) do
    now = System.monotonic_time(:millisecond)

    if now >= Map.get(context, :next_handoff_check, now) do
      context |> Map.put(:next_handoff_check, now + 1_000) |> then(&maybe_request_goal_handoff(port, &1))
    else
      context
    end
  end

  defp check_goal_handoff(_port, context), do: context

  defp handle_unscoped_event(port, on_message, %{"id" => id, "method" => "item/tool/call"} = payload, timeout, context, auto) do
    result = %{
      "success" => false,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" =>
            Jason.encode!(%{
              error: %{
                code: "root_task_tools_only",
                detail:
                  "Task tools are bound to the root thread and turn. " <>
                    "Ask the root agent for a task snapshot or host action."
              }
            })
        }
      ]
    }

    send_message(port, %{"id" => id, "result" => result})
    metadata = metadata_from_message(port, payload)
    emit_message(on_message, :tool_call_failed, %{payload: payload, scope_rejected: true}, metadata)
    receive_loop(port, on_message, timeout, "", context, auto)
  end

  defp handle_unscoped_event(port, on_message, %{"id" => id} = payload, _timeout, _context, _auto) do
    send_message(port, %{"id" => id, "error" => %{"code" => -32_001, "message" => "Request is outside the root execution; human review required."}})
    emit_message(on_message, :turn_input_required, %{payload: payload}, metadata_from_message(port, payload))
    {:error, {:unscoped_server_request, payload}}
  end

  defp handle_unscoped_event(port, on_message, _payload, timeout, context, auto) do
    receive_loop(port, on_message, timeout, "", context, auto)
  end

  defp root_event?(payload, context) do
    params = payload["params"] || %{}
    thread = params["threadId"] || params["thread_id"]
    turn = params["turnId"] || get_in(params, ["turn", "id"])

    thread_matches?(thread, context) and turn_matches?(turn, payload, context)
  end

  defp thread_matches?(nil, context), do: not context.strict
  defp thread_matches?(thread, context), do: thread == context.thread_id

  defp turn_matches?(_turn, %{"method" => method}, %{goal_mode: true, goal_running: false})
       when method in ["turn/completed", "turn/failed", "turn/cancelled"], do: false

  defp turn_matches?(nil, payload, context), do: not context.strict or (not terminal_event?(payload) and not Map.has_key?(payload, "id"))
  defp turn_matches?(turn, _payload, context), do: turn == context.turn_id

  defp terminal_event?(payload), do: payload["method"] in ["turn/completed", "turn/failed", "turn/cancelled"]

  defp complete_turn(port, handler, payload, timeout, %{goal_mode: true} = context, auto) do
    result = terminal_turn_result(payload, context.strict)
    interrupted = context.goal_stop_requested && get_in(payload, ["params", "turn", "status"]) == "interrupted"

    if match?({:ok, _}, result) or interrupted do
      context = maybe_request_goal_handoff(port, %{context | goal_running: false})
      finish_or_wait_goal(port, handler, timeout, context, auto)
    else
      result
    end
  end

  defp complete_turn(_port, _handler, payload, _timeout, context, _auto) do
    terminal_turn_result(payload, context.strict)
  end

  defp handle_decoded_result(port, handler, decoded, raw, timeout, context, auto) do
    case decoded do
      {:ok, %{"method" => "turn/completed"} = payload} ->
        emit_turn_event(handler, :turn_completed, payload, raw, port, payload)

        complete_turn(port, handler, payload, timeout, context, auto)

      {:ok, %{"method" => "turn/failed", "params" => _} = payload} ->
        emit_turn_event(
          handler,
          :turn_failed,
          payload,
          raw,
          port,
          Map.get(payload, "params")
        )

        {:error, {:turn_failed, Map.get(payload, "params")}}

      {:ok, %{"method" => "turn/cancelled", "params" => _} = payload} ->
        emit_turn_event(
          handler,
          :turn_cancelled,
          payload,
          raw,
          port,
          Map.get(payload, "params")
        )

        {:error, {:turn_cancelled, Map.get(payload, "params")}}

      {:ok, %{"method" => method} = payload}
      when is_binary(method) ->
        handle_turn_method(
          port,
          handler,
          payload,
          raw,
          method,
          timeout,
          context,
          auto
        )

      {:ok, payload} ->
        emit_message(
          handler,
          :other_message,
          %{
            payload: payload,
            raw: raw
          },
          metadata_from_message(port, payload)
        )

        receive_loop(port, handler, timeout, "", context, auto)

      {:error, _reason} ->
        log_non_json_stream_line(raw, "turn stream")

        if protocol_message_candidate?(raw) do
          emit_message(
            handler,
            :malformed,
            %{
              payload: raw,
              raw: raw
            },
            metadata_from_message(port, %{raw: raw})
          )
        end

        receive_loop(port, handler, timeout, "", context, auto)
    end
  end

  defp terminal_turn_result(payload, strict) do
    case get_in(payload, ["params", "turn", "status"]) do
      "completed" -> {:ok, :turn_completed}
      nil when not strict -> {:ok, :turn_completed}
      status -> {:error, {:turn_failed, %{"status" => status, "turn" => get_in(payload, ["params", "turn"])}}}
    end
  end

  defp emit_turn_event(on_message, event, payload, payload_string, port, payload_details) do
    emit_message(
      on_message,
      event,
      %{
        payload: payload,
        raw: payload_string,
        details: payload_details
      },
      metadata_from_message(port, payload)
    )
  end

  defp handle_turn_method(
         port,
         on_message,
         payload,
         payload_string,
         method,
         timeout_ms,
         tool_executor,
         auto_approve_requests
       ) do
    metadata = metadata_from_message(port, payload)

    case maybe_handle_approval_request(
           port,
           method,
           payload,
           payload_string,
           on_message,
           metadata,
           tool_executor.executor,
           auto_approve_requests
         ) do
      :input_required ->
        emit_message(
          on_message,
          :turn_input_required,
          %{payload: payload, raw: payload_string},
          metadata
        )

        {:error, {:turn_input_required, payload}}

      :approved ->
        context = maybe_request_goal_handoff(port, tool_executor)
        receive_loop(port, on_message, timeout_ms, "", context, auto_approve_requests)

      :approval_required ->
        emit_message(
          on_message,
          :approval_required,
          %{payload: payload, raw: payload_string},
          metadata
        )

        {:error, {:approval_required, payload}}

      :unhandled ->
        if needs_input?(method, payload) do
          emit_message(
            on_message,
            :turn_input_required,
            %{payload: payload, raw: payload_string},
            metadata
          )

          {:error, {:turn_input_required, payload}}
        else
          emit_message(
            on_message,
            :notification,
            %{
              payload: payload,
              raw: payload_string
            },
            metadata
          )

          Logger.debug("Codex notification: #{inspect(method)}")
          receive_loop(port, on_message, timeout_ms, "", tool_executor, auto_approve_requests)
        end
    end
  end

  defp maybe_handle_approval_request(
         port,
         "item/commandExecution/requestApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "acceptForSession",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "item/tool/call",
         %{"id" => id, "params" => params} = payload,
         payload_string,
         on_message,
         metadata,
         tool_executor,
         _auto_approve_requests
       ) do
    tool_name = tool_call_name(params)
    arguments = tool_call_arguments(params)

    result =
      tool_name
      |> tool_executor.(arguments)
      |> normalize_dynamic_tool_result()

    send_message(port, %{
      "id" => id,
      "result" => result
    })

    event =
      case result do
        %{"success" => true} -> :tool_call_completed
        _ when is_nil(tool_name) -> :unsupported_tool_call
        _ -> :tool_call_failed
      end

    emit_message(on_message, event, %{payload: payload, raw: payload_string}, metadata)

    :approved
  end

  defp maybe_handle_approval_request(
         port,
         "execCommandApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "approved_for_session",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "applyPatchApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "approved_for_session",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "item/fileChange/requestApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "acceptForSession",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "item/tool/requestUserInput",
         %{"id" => id, "params" => params} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    maybe_auto_answer_tool_request_user_input(
      port,
      id,
      params,
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         _port,
         _method,
         _payload,
         _payload_string,
         _on_message,
         _metadata,
         _tool_executor,
         _auto_approve_requests
       ) do
    :unhandled
  end

  defp normalize_dynamic_tool_result(%{"success" => success} = result) when is_boolean(success) do
    output =
      case Map.get(result, "output") do
        existing_output when is_binary(existing_output) -> existing_output
        _ -> dynamic_tool_output(result)
      end

    content_items =
      case Map.get(result, "contentItems") do
        existing_items when is_list(existing_items) -> existing_items
        _ -> dynamic_tool_content_items(output)
      end

    result
    |> Map.put("output", output)
    |> Map.put("contentItems", content_items)
  end

  defp normalize_dynamic_tool_result(result) do
    %{
      "success" => false,
      "output" => inspect(result),
      "contentItems" => dynamic_tool_content_items(inspect(result))
    }
  end

  defp dynamic_tool_output(%{"contentItems" => [%{"text" => text} | _]}) when is_binary(text), do: text
  defp dynamic_tool_output(result), do: Jason.encode!(result, pretty: true)

  defp dynamic_tool_content_items(output) when is_binary(output) do
    [
      %{
        "type" => "inputText",
        "text" => output
      }
    ]
  end

  defp approve_or_require(
         port,
         id,
         decision,
         payload,
         payload_string,
         on_message,
         metadata,
         true
       ) do
    send_message(port, %{"id" => id, "result" => %{"decision" => decision}})

    emit_message(
      on_message,
      :approval_auto_approved,
      %{payload: payload, raw: payload_string, decision: decision},
      metadata
    )

    :approved
  end

  defp approve_or_require(
         _port,
         _id,
         _decision,
         _payload,
         _payload_string,
         _on_message,
         _metadata,
         false
       ) do
    :approval_required
  end

  defp maybe_auto_answer_tool_request_user_input(
         port,
         id,
         params,
         payload,
         payload_string,
         on_message,
         metadata,
         true
       ) do
    case tool_request_user_input_approval_answers(params) do
      {:ok, answers, decision} ->
        send_message(port, %{"id" => id, "result" => %{"answers" => answers}})

        emit_message(
          on_message,
          :approval_auto_approved,
          %{payload: payload, raw: payload_string, decision: decision},
          metadata
        )

        :approved

      :error ->
        :input_required
    end
  end

  defp maybe_auto_answer_tool_request_user_input(
         _port,
         _id,
         _params,
         _payload,
         _payload_string,
         _on_message,
         _metadata,
         false
       ),
       do: :input_required

  defp tool_request_user_input_approval_answers(%{"questions" => questions}) when is_list(questions) do
    answers =
      Enum.reduce_while(questions, %{}, fn question, acc ->
        case tool_request_user_input_approval_answer(question) do
          {:ok, question_id, answer_label} ->
            {:cont, Map.put(acc, question_id, %{"answers" => [answer_label]})}

          :error ->
            {:halt, :error}
        end
      end)

    case answers do
      :error -> :error
      answer_map when map_size(answer_map) > 0 -> {:ok, answer_map, "Approve this Session"}
      _ -> :error
    end
  end

  defp tool_request_user_input_approval_answers(_params), do: :error

  defp tool_request_user_input_approval_answer(%{"id" => question_id, "options" => options})
       when is_binary(question_id) and is_list(options) do
    if String.starts_with?(question_id, "mcp_tool_call_approval_") do
      case tool_request_user_input_approval_option_label(options) do
        nil -> :error
        answer_label -> {:ok, question_id, answer_label}
      end
    else
      :error
    end
  end

  defp tool_request_user_input_approval_answer(_question), do: :error

  defp tool_request_user_input_approval_option_label(options) do
    options
    |> Enum.map(&tool_request_user_input_option_label/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      labels ->
        Enum.find(labels, &(&1 == "Approve this Session")) ||
          Enum.find(labels, &(&1 == "Approve Once")) ||
          Enum.find(labels, &approval_option_label?/1)
    end
  end

  defp tool_request_user_input_option_label(%{"label" => label}) when is_binary(label), do: label
  defp tool_request_user_input_option_label(_option), do: nil

  defp approval_option_label?(label) when is_binary(label) do
    normalized_label =
      label
      |> String.trim()
      |> String.downcase()

    String.starts_with?(normalized_label, "approve") or String.starts_with?(normalized_label, "allow")
  end

  defp await_response(port, request_id) do
    with_timeout_response(port, request_id, Config.settings!().codex.read_timeout_ms, "")
  end

  defp with_timeout_response(port, request_id, timeout_ms, pending_line) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)
        handle_response(port, request_id, complete_line, timeout_ms)

      {^port, {:data, {:noeol, chunk}}} ->
        with_timeout_response(port, request_id, timeout_ms, pending_line <> to_string(chunk))

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        {:error, :response_timeout}
    end
  end

  defp handle_response(port, request_id, data, timeout_ms) do
    payload = to_string(data)

    case Jason.decode(payload) do
      {:ok, %{"id" => ^request_id, "error" => error}} ->
        {:error, {:response_error, error}}

      {:ok, %{"id" => ^request_id, "result" => result}} ->
        {:ok, result}

      {:ok, %{"id" => ^request_id} = response_payload} ->
        {:error, {:response_error, response_payload}}

      {:ok, %{} = other} ->
        Logger.debug("Ignoring message while waiting for response: #{inspect(other)}")
        with_timeout_response(port, request_id, timeout_ms, "")

      {:error, _} ->
        log_non_json_stream_line(payload, "response stream")
        with_timeout_response(port, request_id, timeout_ms, "")
    end
  end

  defp log_non_json_stream_line(data, stream_label) do
    text =
      data
      |> to_string()
      |> String.trim()
      |> String.slice(0, @max_stream_log_bytes)

    if text != "" do
      if String.match?(text, ~r/\b(error|warn|warning|failed|fatal|panic|exception)\b/i) do
        Logger.warning("Codex #{stream_label} output: #{text}")
      else
        Logger.debug("Codex #{stream_label} output: #{text}")
      end
    end
  end

  defp protocol_message_candidate?(data) do
    data
    |> to_string()
    |> String.trim_leading()
    |> String.starts_with?("{")
  end

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp stop_port(port) when is_port(port) do
    case :erlang.port_info(port) do
      :undefined ->
        :ok

      _ ->
        try do
          Port.close(port)
          :ok
        rescue
          ArgumentError ->
            :ok
        end
    end
  end

  defp emit_message(on_message, event, details, metadata) when is_function(on_message, 1) do
    message = metadata |> Map.merge(details) |> Map.put(:event, event) |> Map.put(:timestamp, DateTime.utc_now())
    on_message.(message)
  end

  defp metadata_from_message(port, payload) do
    port |> port_metadata(nil) |> maybe_set_usage(payload)
  end

  defp maybe_set_usage(metadata, payload) when is_map(payload) do
    usage = Map.get(payload, "usage") || Map.get(payload, :usage)

    if is_map(usage) do
      Map.put(metadata, :usage, usage)
    else
      metadata
    end
  end

  defp maybe_set_usage(metadata, _payload), do: metadata

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp default_on_message(_message), do: :ok

  defp tool_call_name(params) when is_map(params) do
    case Map.get(params, "tool") || Map.get(params, :tool) || Map.get(params, "name") || Map.get(params, :name) do
      name when is_binary(name) ->
        case String.trim(name) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp tool_call_name(_params), do: nil

  defp tool_call_arguments(params) when is_map(params) do
    Map.get(params, "arguments") || Map.get(params, :arguments) || %{}
  end

  defp tool_call_arguments(_params), do: %{}

  defp send_message(port, message) do
    line = Jason.encode!(message) <> "\n"
    Port.command(port, line)
  end

  defp needs_input?("mcpServer/elicitation/request", payload) when is_map(payload), do: true

  defp needs_input?(method, payload)
       when is_binary(method) and is_map(payload) do
    String.starts_with?(method, "turn/") && input_required_method?(method, payload)
  end

  defp needs_input?(_method, _payload), do: false

  defp input_required_method?(method, payload) when is_binary(method) do
    method in [
      "turn/input_required",
      "turn/needs_input",
      "turn/need_input",
      "turn/request_input",
      "turn/request_response",
      "turn/provide_input",
      "turn/approval_required"
    ] || request_payload_requires_input?(payload)
  end

  defp request_payload_requires_input?(payload) do
    params = Map.get(payload, "params")
    needs_input_field?(payload) || needs_input_field?(params)
  end

  defp needs_input_field?(payload) when is_map(payload) do
    Map.get(payload, "requiresInput") == true or
      Map.get(payload, "needsInput") == true or
      Map.get(payload, "input_required") == true or
      Map.get(payload, "inputRequired") == true or
      Map.get(payload, "type") == "input_required" or
      Map.get(payload, "type") == "needs_input"
  end

  defp needs_input_field?(_payload), do: false
end
