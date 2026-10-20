defmodule SymphonyElixir.TestSupport do
  @workflow_prompt "You are an agent for this repository."

  defmacro __using__(opts) do
    quote do
      use ExUnit.Case
      import ExUnit.CaptureLog

      alias SymphonyElixir.AgentRunner
      alias SymphonyElixir.CLI
      alias SymphonyElixir.Codex.AppServer
      alias SymphonyElixir.Config
      alias SymphonyElixir.HttpServer
      alias SymphonyElixir.Linear.Client
      alias SymphonyElixir.Orchestrator
      alias SymphonyElixir.PromptBuilder
      alias SymphonyElixir.StatusDashboard
      alias SymphonyElixir.Tracker
      alias SymphonyElixir.Tracker.Issue
      alias SymphonyElixir.Workflow
      alias SymphonyElixir.WorkflowStore
      alias SymphonyElixir.Workspace

      import SymphonyElixir.TestSupport,
        only: [write_workflow_file!: 1, write_workflow_file!: 2, restore_env: 2, stop_default_http_server: 0]

      setup_all do
        if unquote(Keyword.get(opts, :runtime, true)),
          do: :ok,
          else: SymphonyElixir.TestSupport.isolate_default_runtime()
      end

      setup do
        workflow_root =
          Path.join(
            System.tmp_dir!(),
            "symphony-elixir-workflow-#{System.pid()}-#{System.unique_integer([:positive])}"
          )

        File.mkdir_p!(workflow_root)
        workflow_file = Path.join(workflow_root, "WORKFLOW.md")
        write_workflow_file!(workflow_file)
        Workflow.set_workflow_file_path(workflow_file)
        if Process.whereis(SymphonyElixir.WorkflowStore), do: SymphonyElixir.WorkflowStore.force_reload()
        stop_default_http_server()

        on_exit(fn ->
          Application.delete_env(:symphony_elixir, :workflow_file_path)
          Application.delete_env(:symphony_elixir, :server_port_override)
          Application.delete_env(:symphony_elixir, :memory_tracker_issues)
          File.rm_rf(workflow_root)
        end)

        :ok
      end
    end
  end

  # Provider/board fixtures must not be consumed by the application's live
  # scheduler. Tests opting out own any runtime they explicitly start.
  def isolate_default_runtime do
    runtime = SymphonyElixir.AgentRuntimeSupervisor
    supervisor = SymphonyElixir.Supervisor
    running? = is_pid(Process.whereis(runtime))
    :ok = Supervisor.terminate_child(supervisor, runtime)

    ExUnit.Callbacks.on_exit(fn ->
      if running?, do: Supervisor.restart_child(supervisor, runtime)
    end)

    :ok
  end

  def write_workflow_file!(path, overrides \\ []) do
    workflow = workflow_content(overrides)
    File.write!(path, workflow)

    if Process.whereis(SymphonyElixir.WorkflowStore) do
      try do
        SymphonyElixir.WorkflowStore.force_reload()
      catch
        :exit, _reason -> :ok
      end
    end

    :ok
  end

  # Run all cleanup steps even if the body or an earlier cleanup failed. ExUnit
  # renders each original exception and stacktrace instead of hiding the cause.
  def with_cleanup(body, cleanups) do
    result = capture_failure(body)
    failures = for cleanup <- cleanups, {:failure, failure} <- [capture_failure(cleanup)], do: failure

    case {result, failures} do
      {{:ok, value}, []} -> value
      {{:failure, {kind, reason, stack}}, []} -> :erlang.raise(kind, reason, stack)
      {{:failure, failure}, rest} -> raise ExUnit.MultiError, errors: [failure | rest]
      {{:ok, _}, rest} -> raise ExUnit.MultiError, errors: rest
    end
  end

  defp capture_failure(fun) do
    {:ok, fun.()}
  catch
    kind, reason -> {:failure, {kind, reason, __STACKTRACE__}}
  end

  def write_review_server(server, root) do
    File.write!(server, """
    #!/usr/bin/env python3
    import sys,json,pathlib,os,subprocess
    root=pathlib.Path(#{inspect(root)});tid='review-thread-'+str(os.getpid());turn=tid+'-turn';cwd=None;step=0
    def state():return root/(tid+'.json')
    def save(status):state().write_text(json.dumps({'id':turn,'status':status}))
    def thread():
      turns=[json.loads(state().read_text())] if state().exists() else []
      return {'id':tid,'status':{'type':'active' if turns and turns[-1]['status']=='inProgress' else 'idle'},'turns':turns}
    def emit(v):print(json.dumps(v),flush=True)
    def tool(name,args):emit({'id':100,'method':'item/tool/call','params':{'threadId':tid,'turnId':turn,'tool':name,'arguments':args}})
    for line in sys.stdin:
      q=json.loads(line);m=q.get('method')
      with (root/'native-requests.jsonl').open('a') as f:f.write(json.dumps(q)+'\\n')
      if m=='initialize':emit({'id':q['id'],'result':{}})
      elif m=='thread/goal/get':emit({'id':q['id'],'result':{'goal':None}})
      elif m=='thread/read':
        tid=q['params'].get('threadId',tid);turn=tid+'-turn'
        emit({'id':q['id'],'result':{'thread':thread()}})
      elif m=='turn/interrupt':
        if not (root/'unconfirmed-stop').exists():save('interrupted')
        emit({'id':q['id'],'result':{}})
      elif m in ['thread/start','thread/resume']:
        cwd=q['params'].get('cwd');tid=q['params'].get('threadId',tid);turn=tid+'-turn'
        emit({'id':q['id'],'result':{'thread':thread()}})
      elif m=='command/exec':
        assert q['params']['sandboxPolicy']=={'type':'readOnly'}
        r=subprocess.run(q['params']['command'],cwd=q['params']['cwd'],text=True,capture_output=True)
        emit({'id':q['id'],'result':{'exitCode':r.returncode,'stdout':r.stdout,'stderr':r.stderr}})
      elif m=='turn/start':
        assert q['params']['sandboxPolicy']=={'type':'readOnly'}
        save('inProgress');emit({'id':q['id'],'result':{'turn':{'id':turn}}})
        if (root/'disconnect').exists():sys.exit(0)
        if (root/'hang').exists():continue
        if (root/'no-submit').exists():
          save('completed');emit({'method':'turn/completed','params':{'threadId':tid,'turn':{'id':turn,'status':'completed'}}})
        else:tool('review_read',{'kind':'diff'})
      elif q.get('id')==100:
        assert q['result']['success'],q
        step+=1
        if step==1:tool('review_read',{'kind':'file','path':'source.txt'})
        elif step==2:tool('review_axis_submit',{'status':'complete','report':'已核对完整差异和相关源文件。','findings':[]})
        else:
          save('completed');emit({'method':'turn/completed','params':{'threadId':tid,'turn':{'id':turn,'status':'completed'}}})
    """)

    File.chmod!(server, 0o755)
  end

  # Native execution is exercised by runner fixtures. Listener-only tests supply
  # two independent completed axes through the same engine result reducer.
  def submit_review(id, arguments) do
    alias SymphonyElixir.ReviewLane.{Finding, Listener}
    key = String.replace_prefix(id, "review:", "")
    record = get_in(:sys.get_state(Listener), [:records, key])
    owner = if record, do: record["execution_owner"]

    if is_nil(owner) do
      Listener.submit(id, owner, arguments)
    else
      with {:ok, submission} <- Finding.validate(arguments, record),
           normalized = fixture_submission(submission, record),
           axes = fixture_axes(record, normalized),
           :ok <- Listener.checkpoint(id, owner, %{"axes" => axes, "native_stop_confirmed" => true}),
           {:ok, result} <- SymphonyElixir.ReviewResult.aggregate(record, axes) do
        Listener.submit(id, owner, %{"completion" => result})
      end
    end
  end

  defp fixture_submission(%{} = submission, _record), do: submission

  defp fixture_submission(findings, record) do
    values =
      Enum.with_index(findings, fn body, index ->
        %{
          "schema_version" => 1,
          "id" => "fixture-#{index}",
          "required" => true,
          "criterion" => "测试约定",
          "version" => %{"head" => record["head"], "base" => record["base"], "target" => record["target_branch"]},
          "location" => "source.cpp:10",
          "evidence" => body,
          "impact" => "可复现的行为不符合约定。",
          "resolution" => "修复行为并通过回归验证。",
          "regression_of" => nil
        }
      end)

    %{"findings" => values, "responses" => []}
  end

  defp fixture_axes(record, submission) do
    Map.new(["standards", "spec"], fn axis ->
      {axis,
       %{
         "status" => "complete",
         "report" => "已完成本轴核对。",
         "thread_id" => record["id"] <> axis,
         "turn_id" => record["id"] <> axis <> "-turn",
         "native_stop_confirmed" => true,
         "reads_verified" => true,
         "findings" => if(axis == "standards", do: submission["findings"], else: []),
         "responses" => if(axis == "standards", do: submission["responses"] || [], else: [])
       }}
    end)
  end

  def restore_env(key, nil), do: System.delete_env(key)
  def restore_env(key, value), do: System.put_env(key, value)

  def stop_default_http_server do
    case Enum.find(Supervisor.which_children(SymphonyElixir.Supervisor), fn
           {SymphonyElixir.HttpServer, _pid, _type, _modules} -> true
           _child -> false
         end) do
      {SymphonyElixir.HttpServer, pid, _type, _modules} when is_pid(pid) ->
        :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.HttpServer)

        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end

        :ok

      _ ->
        :ok
    end
  end

  defp workflow_content(overrides) do
    config =
      Keyword.merge(
        [
          tracker_kind: "linear",
          tracker_endpoint: "https://api.linear.app/graphql",
          tracker_api_token: "token",
          tracker_project_slug: "project",
          tracker_assignee: nil,
          tracker_required_labels: [],
          tracker_active_states: ["Todo", "In Progress"],
          tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"],
          poll_interval_ms: 30_000,
          workspace_root: Path.join(System.tmp_dir!(), "symphony_workspaces"),
          worker_ssh_hosts: [],
          worker_max_concurrent_agents_per_host: nil,
          max_concurrent_agents: 10,
          max_turns: 20,
          max_retry_backoff_ms: 300_000,
          max_concurrent_agents_by_state: %{},
          codex_command: "codex app-server",
          codex_approval_policy: %{reject: %{sandbox_approval: true, rules: true, mcp_elicitations: true}},
          codex_thread_sandbox: "workspace-write",
          codex_turn_sandbox_policy: nil,
          codex_turn_timeout_ms: 3_600_000,
          codex_read_timeout_ms: 5_000,
          codex_stall_timeout_ms: 300_000,
          hook_after_create: nil,
          hook_before_run: nil,
          hook_after_run: nil,
          hook_before_remove: nil,
          hook_timeout_ms: 60_000,
          observability_enabled: true,
          observability_refresh_ms: 1_000,
          observability_render_interval_ms: 16,
          taskboard_enabled: nil,
          taskboard_refresh_ms: nil,
          taskboard_control_token: nil,
          taskboard_provider_token: nil,
          taskboard_projects: nil,
          server_port: nil,
          server_host: nil,
          prompt: @workflow_prompt
        ],
        overrides
      )

    tracker_kind = Keyword.get(config, :tracker_kind)
    tracker_endpoint = Keyword.get(config, :tracker_endpoint)
    tracker_api_token = Keyword.get(config, :tracker_api_token)
    tracker_project_slug = Keyword.get(config, :tracker_project_slug)
    tracker_assignee = Keyword.get(config, :tracker_assignee)
    tracker_required_labels = Keyword.get(config, :tracker_required_labels)
    tracker_active_states = Keyword.get(config, :tracker_active_states)
    tracker_terminal_states = Keyword.get(config, :tracker_terminal_states)
    poll_interval_ms = Keyword.get(config, :poll_interval_ms)
    workspace_root = Keyword.get(config, :workspace_root)
    worker_ssh_hosts = Keyword.get(config, :worker_ssh_hosts)
    worker_max_concurrent_agents_per_host = Keyword.get(config, :worker_max_concurrent_agents_per_host)
    max_concurrent_agents = Keyword.get(config, :max_concurrent_agents)
    max_turns = Keyword.get(config, :max_turns)
    max_retry_backoff_ms = Keyword.get(config, :max_retry_backoff_ms)
    max_concurrent_agents_by_state = Keyword.get(config, :max_concurrent_agents_by_state)
    codex_command = Keyword.get(config, :codex_command)
    codex_approval_policy = Keyword.get(config, :codex_approval_policy)
    codex_thread_sandbox = Keyword.get(config, :codex_thread_sandbox)
    codex_turn_sandbox_policy = Keyword.get(config, :codex_turn_sandbox_policy)
    codex_turn_timeout_ms = Keyword.get(config, :codex_turn_timeout_ms)
    codex_read_timeout_ms = Keyword.get(config, :codex_read_timeout_ms)
    codex_stall_timeout_ms = Keyword.get(config, :codex_stall_timeout_ms)
    hook_after_create = Keyword.get(config, :hook_after_create)
    hook_before_run = Keyword.get(config, :hook_before_run)
    hook_after_run = Keyword.get(config, :hook_after_run)
    hook_before_remove = Keyword.get(config, :hook_before_remove)
    hook_timeout_ms = Keyword.get(config, :hook_timeout_ms)
    observability_enabled = Keyword.get(config, :observability_enabled)
    observability_refresh_ms = Keyword.get(config, :observability_refresh_ms)
    observability_render_interval_ms = Keyword.get(config, :observability_render_interval_ms)
    taskboard_enabled = Keyword.get(config, :taskboard_enabled)
    taskboard_refresh_ms = Keyword.get(config, :taskboard_refresh_ms)
    taskboard_control_token = Keyword.get(config, :taskboard_control_token)
    taskboard_provider_token = Keyword.get(config, :taskboard_provider_token)
    taskboard_projects = Keyword.get(config, :taskboard_projects)
    server_port = Keyword.get(config, :server_port)
    server_host = Keyword.get(config, :server_host)
    prompt = Keyword.get(config, :prompt)

    sections =
      [
        "---",
        "tracker:",
        "  kind: #{yaml_value(tracker_kind)}",
        "  endpoint: #{yaml_value(tracker_endpoint)}",
        "  api_key: #{yaml_value(tracker_api_token)}",
        "  project_slug: #{yaml_value(tracker_project_slug)}",
        "  assignee: #{yaml_value(tracker_assignee)}",
        "  required_labels: #{yaml_value(tracker_required_labels)}",
        "  active_states: #{yaml_value(tracker_active_states)}",
        "  terminal_states: #{yaml_value(tracker_terminal_states)}",
        "polling:",
        "  interval_ms: #{yaml_value(poll_interval_ms)}",
        "workspace:",
        "  root: #{yaml_value(workspace_root)}",
        worker_yaml(worker_ssh_hosts, worker_max_concurrent_agents_per_host),
        "agent:",
        "  max_concurrent_agents: #{yaml_value(max_concurrent_agents)}",
        "  max_turns: #{yaml_value(max_turns)}",
        "  max_retry_backoff_ms: #{yaml_value(max_retry_backoff_ms)}",
        "  max_concurrent_agents_by_state: #{yaml_value(max_concurrent_agents_by_state)}",
        "codex:",
        "  command: #{yaml_value(codex_command)}",
        "  approval_policy: #{yaml_value(codex_approval_policy)}",
        "  thread_sandbox: #{yaml_value(codex_thread_sandbox)}",
        "  turn_sandbox_policy: #{yaml_value(codex_turn_sandbox_policy)}",
        "  turn_timeout_ms: #{yaml_value(codex_turn_timeout_ms)}",
        "  read_timeout_ms: #{yaml_value(codex_read_timeout_ms)}",
        "  stall_timeout_ms: #{yaml_value(codex_stall_timeout_ms)}",
        hooks_yaml(hook_after_create, hook_before_run, hook_after_run, hook_before_remove, hook_timeout_ms),
        observability_yaml(observability_enabled, observability_refresh_ms, observability_render_interval_ms),
        taskboard_yaml(
          taskboard_enabled,
          taskboard_refresh_ms,
          taskboard_control_token,
          taskboard_provider_token,
          taskboard_projects
        ),
        server_yaml(server_port, server_host),
        "---",
        prompt
      ]
      |> Enum.reject(&(&1 in [nil, ""]))

    Enum.join(sections, "\n") <> "\n"
  end

  defp yaml_value(value) when is_binary(value) do
    "\"" <> String.replace(value, "\"", "\\\"") <> "\""
  end

  defp yaml_value(value) when is_integer(value), do: to_string(value)
  defp yaml_value(true), do: "true"
  defp yaml_value(false), do: "false"
  defp yaml_value(nil), do: "null"

  defp yaml_value(values) when is_list(values) do
    "[" <> Enum.map_join(values, ", ", &yaml_value/1) <> "]"
  end

  defp yaml_value(values) when is_map(values) do
    "{" <>
      Enum.map_join(values, ", ", fn {key, value} ->
        "#{yaml_value(to_string(key))}: #{yaml_value(value)}"
      end) <> "}"
  end

  defp yaml_value(value), do: yaml_value(to_string(value))

  defp hooks_yaml(nil, nil, nil, nil, timeout_ms), do: "hooks:\n  timeout_ms: #{yaml_value(timeout_ms)}"

  defp hooks_yaml(hook_after_create, hook_before_run, hook_after_run, hook_before_remove, timeout_ms) do
    [
      "hooks:",
      "  timeout_ms: #{yaml_value(timeout_ms)}",
      hook_entry("after_create", hook_after_create),
      hook_entry("before_run", hook_before_run),
      hook_entry("after_run", hook_after_run),
      hook_entry("before_remove", hook_before_remove)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp worker_yaml(ssh_hosts, max_concurrent_agents_per_host)
       when ssh_hosts in [nil, []] and is_nil(max_concurrent_agents_per_host),
       do: nil

  defp worker_yaml(ssh_hosts, max_concurrent_agents_per_host) do
    [
      "worker:",
      ssh_hosts not in [nil, []] && "  ssh_hosts: #{yaml_value(ssh_hosts)}",
      !is_nil(max_concurrent_agents_per_host) &&
        "  max_concurrent_agents_per_host: #{yaml_value(max_concurrent_agents_per_host)}"
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join("\n")
  end

  defp observability_yaml(enabled, refresh_ms, render_interval_ms) do
    [
      "observability:",
      "  dashboard_enabled: #{yaml_value(enabled)}",
      "  refresh_ms: #{yaml_value(refresh_ms)}",
      "  render_interval_ms: #{yaml_value(render_interval_ms)}"
    ]
    |> Enum.join("\n")
  end

  defp taskboard_yaml(nil, nil, nil, nil, nil), do: nil

  defp taskboard_yaml(enabled, refresh_ms, control_token, provider_token, projects) do
    [
      "taskboard:",
      !is_nil(enabled) && "  enabled: #{yaml_value(enabled)}",
      !is_nil(refresh_ms) && "  refresh_ms: #{yaml_value(refresh_ms)}",
      !is_nil(control_token) && "  control_token: #{yaml_value(control_token)}",
      !is_nil(provider_token) && "  provider_token: #{yaml_value(provider_token)}",
      !is_nil(projects) && "  projects: #{yaml_value(projects)}"
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join("\n")
  end

  defp server_yaml(nil, nil), do: nil

  defp server_yaml(port, host) do
    [
      "server:",
      port && "  port: #{yaml_value(port)}",
      host && "  host: #{yaml_value(host)}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp hook_entry(_name, nil), do: nil

  defp hook_entry(name, command) when is_binary(command) do
    indented =
      command
      |> String.split("\n")
      |> Enum.map_join("\n", &("    " <> &1))

    "  #{name}: |\n#{indented}"
  end
end
