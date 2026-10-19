defmodule SymphonyElixir.RepositoryServiceTest do
  use SymphonyElixir.TestSupport, runtime: false
  alias SymphonyElixir.{Execution, RepositoryService, RuntimeContext}
  alias SymphonyElixir.ReviewLane.Listener
  alias SymphonyElixirWeb.{Endpoint, Presenter, RepositoryScope}
  import Plug.Test

  setup do
    root = Path.join(System.tmp_dir!(), "repository-service-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  defp fixture(root) do
    entries =
      for id <- ["alpha", "beta"] do
        path = Path.join(root, id <> ".md")

        config = %{
          "tracker" => %{"kind" => "memory", "project_slug" => id, "active_states" => [], "terminal_states" => []},
          "workspace" => %{"root" => "$SYMPHONY_WORKTREE_ROOT", "retain" => true},
          "agent" => %{"run_journal_dir" => Path.join(root, id <> "-runs")},
          "polling" => %{"interval_ms" => 600_000},
          "hooks" => %{"after_create" => "printf '%s' \"$SYMPHONY_PROJECT\" > scope.txt"}
        }

        write(path, config, id <> " prompt")
        %{"id" => id, "workflow" => path, "environment" => %{"SYMPHONY_WORKTREE_ROOT" => Path.join(root, id <> "-work"), "SYMPHONY_PROJECT" => id}}
      end

    manifest = Path.join(root, "service.md")
    write(manifest, %{"tracker" => %{"kind" => "memory", "active_states" => []}, "repositories" => entries})
    {manifest, entries}
  end

  defp write(path, config, prompt \\ "service") do
    File.write!(path, "---\n" <> Jason.encode!(config) <> "\n---\n" <> prompt)
  end

  defp scope(context, fun), do: RuntimeContext.with_context(context, fun)

  test "multi-repository preflight reports scoped errors without starting any runtime", %{root: root} do
    {manifest, [a | _]} = fixture(root)
    previous = Workflow.workflow_file_path()
    Workflow.set_workflow_file_path(manifest)
    on_exit(fn -> Workflow.set_workflow_file_path(previous) end)
    assert {:ok, 0} = SymphonyElixir.Preflight.run(nil)
    assert {:error, :repository_issue_selection_required} = SymphonyElixir.Preflight.run("7")

    scope(%{id: "not-started", workflow: a["workflow"]}, fn ->
      assert RuntimeContext.whereis(WorkflowStore) == nil
      assert Config.settings!().tracker.project_slug == "alpha"
    end)

    {:ok, workflow} = Workflow.load(a["workflow"])
    write(a["workflow"], put_in(workflow.config, ["tracker", "active_states"], ["Ready"]), "{{ missing }}")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [%Tracker.Issue{id: "7", state: "Ready"}])
    on_exit(fn -> Application.delete_env(:symphony_elixir, :memory_tracker_issues) end)
    assert {:error, {"alpha", _}} = SymphonyElixir.Preflight.run(nil)
    Application.put_env(:symphony_elixir, :workflow_file_path, 123)
    assert {:error, message} = SymphonyElixir.Preflight.run(nil)
    assert is_binary(message)
    Application.put_env(:symphony_elixir, :workflow_file_path, previous)
    assert Process.whereis(SymphonyElixir.RepositoryRegistry) == nil
  end

  test "a listener crash does not terminate active workers or another repository", %{root: root} do
    {manifest, _} = fixture(root)
    {:ok, [context, other] = contexts} = RepositoryService.load(manifest)
    start_supervised!({RepositoryService, contexts})

    scope(context, fn ->
      task_supervisor = RuntimeContext.server(SymphonyElixir.TaskSupervisor)

      {:ok, worker} =
        Task.Supervisor.start_child(
          task_supervisor,
          RuntimeContext.wrap(fn ->
            receive do
              :stop -> :ok
            end
          end)
        )

      listener = RuntimeContext.server(Listener)
      before = GenServer.whereis(listener)
      other_pid = scope(other, fn -> RuntimeContext.whereis(Orchestrator) end)
      Process.exit(before, :kill)
      wait_until(fn -> is_pid(GenServer.whereis(listener)) and GenServer.whereis(listener) != before end)
      assert Process.alive?(worker)
      assert scope(other, fn -> RuntimeContext.whereis(Orchestrator) end) == other_pid
      assert is_map(Listener.health())
      send(worker, :stop)
    end)
  end

  test "both actual dispatch workers retain scope and exclude credentials belonging to every repository", %{root: root} do
    {manifest, entries} = fixture(root)

    for entry <- entries do
      {:ok, workflow} = Workflow.load(entry["workflow"])
      output = Path.join(root, entry["id"] <> "-worker.txt")
      command = "printf '%s|%s|%s' \"$SYMPHONY_PROJECT\" \"${SYMPHONY_CREDENTIAL_A-unset}\" \"${SYMPHONY_CREDENTIAL_B-unset}\" > #{output}"
      config = put_in(workflow.config, ["tracker", "active_states"], ["Ready"])
      config = Map.put(config, "codex", %{"command" => command, "read_timeout_ms" => 500})
      write(entry["workflow"], config)
    end

    previous = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    issue = %Tracker.Issue{id: "7", identifier: "SAME-7", title: "fixture", state: "Ready", dispatchable: true}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    System.put_env("SYMPHONY_CREDENTIAL_A", "fixture-a")
    System.put_env("SYMPHONY_CREDENTIAL_B", "fixture-b")

    on_exit(fn ->
      if previous do
        Application.put_env(:symphony_elixir, :memory_tracker_issues, previous)
      else
        Application.delete_env(:symphony_elixir, :memory_tracker_issues)
      end

      System.delete_env("SYMPHONY_CREDENTIAL_A")
      System.delete_env("SYMPHONY_CREDENTIAL_B")
    end)

    {:ok, contexts} = RepositoryService.load(manifest)
    contexts = Enum.map(contexts, &Map.put(&1, :secrets, ["SYMPHONY_CREDENTIAL_A", "SYMPHONY_CREDENTIAL_B"]))
    start_supervised!({RepositoryService, contexts})
    wait_until(fn -> Enum.all?(entries, &File.exists?(Path.join(root, &1["id"] <> "-worker.txt"))) end)

    for entry <- entries do
      assert File.read!(Path.join(root, entry["id"] <> "-worker.txt")) == entry["id"] <> "|unset|unset"
    end
  end

  defp wait_until(fun, remaining \\ 200)
  defp wait_until(_, 0), do: flunk("observable repository effect did not arrive")

  defp wait_until(fun, remaining) do
    if fun.() do
      :ok
    else
      receive do
      after
        20 -> wait_until(fun, remaining - 1)
      end
    end
  end

  test "one BEAM hosts isolated settings, listeners, hooks and captured asynchronous work", %{root: root} do
    {manifest, _} = fixture(root)
    assert {:ok, [a, b] = contexts} = RepositoryService.load(manifest)
    start_supervised!({RepositoryService, contexts})
    assert RepositoryService.repositories() == contexts
    assert RepositoryService.aggregate?()
    assert RepositoryService.secret_environment_names() == []

    for context <- contexts do
      scope(context, fn ->
        assert Workflow.workflow_file_path() == context.workflow
        assert Config.settings!().tracker.project_slug == context.id
        assert Config.workflow_prompt() == context.id <> " prompt"
        assert RuntimeContext.get_env("SYMPHONY_PROJECT") == context.id
        assert Execution.journal_root() == Path.join(root, context.id <> "-runs")
        assert {:ok, []} = Listener.issues()
        assert is_map(Listener.health())
        assert :ok = Config.validate!()
        task = Task.async(RuntimeContext.wrap(fn -> {Config.settings!().tracker.project_slug, System.pid()} end))
        assert {context.id, System.pid()} == Task.await(task)
        issue = %Tracker.Issue{id: "7", identifier: "SAME-7"}
        assert {:ok, path} = Workspace.create_for_issue(issue)
        assert File.read!(Path.join(path, "scope.txt")) == context.id
        assert {:ok, record} = SymphonyElixir.RunJournal.admit(Execution.journal_root(), issue.id)
        assert record["issue_id"] == "7"
        assert :ok = SymphonyElixir.RunJournal.release_lock(record)
      end)
    end

    assert scope(a, fn -> RuntimeContext.server(Orchestrator) end) != scope(b, fn -> RuntimeContext.server(Orchestrator) end)
    assert RuntimeContext.current() == nil
    assert RuntimeContext.server(Orchestrator) == Orchestrator
    assert RuntimeContext.get_env("SYMPHONY_MISSING_TEST_ENV", "fallback") == "fallback"
    assert_raise RuntimeError, fn -> scope(a, fn -> raise "restored" end) end
    assert RuntimeContext.current() == nil
  end

  test "reject ambiguous ownership, unsafe roots, recursive manifests and secret environment overrides", %{root: root} do
    {manifest, [a, b]} = fixture(root)

    cases = [
      nil,
      [%{}],
      [%{a | "id" => "Bad Id"}],
      [%{a | "environment" => %{"GITLAB_PAT" => "forbidden"}}],
      [a, a],
      [a, %{b | "workflow" => a["workflow"]}],
      [a, %{b | "environment" => a["environment"]}]
    ]

    for entries <- cases do
      write(manifest, %{"repositories" => entries})
      assert {:error, _} = RepositoryService.load(manifest)
    end

    write(a["workflow"], %{"repositories" => []})
    write(manifest, %{"repositories" => [a]})
    assert {:error, :nested_repository_service} = RepositoryService.load(manifest)
    assert {:error, _} = RepositoryService.load(manifest <> "-missing")
    write(manifest, %{})
    assert {:ok, []} = RepositoryService.load(manifest)
    assert RepositoryService.repositories() == []
    assert RepositoryService.secret_environment_names() == []
  end

  test "equivalent native scopes and symlink storage aliases cannot acquire duplicate ownership", %{root: root} do
    {manifest, entries} = fixture(root)

    for {entry, index} <- Enum.with_index(entries) do
      {:ok, workflow} = Workflow.load(entry["workflow"])
      provider = %{"api_key" => "fixture-only", "project_path" => "team/repository"}
      provider = if index == 1, do: Map.put(provider, "api_url", "https://gitlab.com/api/v4/"), else: provider
      tracker = %{"kind" => "gitlab", "provider" => provider, "active_states" => [], "terminal_states" => []}
      write(entry["workflow"], Map.put(workflow.config, "tracker", tracker))
    end

    assert {:error, :repository_ownership_overlap} = RepositoryService.load(manifest)

    for name <- ["GITLAB_PROJECT_PATH", "GITHUB_REPO"] do
      previous = System.get_env(name)
      System.put_env(name, "team/repository")
      on_exit(fn -> restore_env(name, previous) end)
    end

    trackers = [
      %{"kind" => "gitlab", "provider" => %{"api_key" => "fixture-only"}},
      %{"kind" => "gitlab", "provider" => %{"api_key" => "fixture-only", "project_path" => "$GITLAB_PROJECT_PATH"}},
      %{"kind" => "github", "provider" => %{"token" => "fixture-only"}}
    ]

    for tracker <- trackers do
      for entry <- entries do
        {:ok, workflow} = Workflow.load(entry["workflow"])
        tracker = Map.merge(tracker, %{"active_states" => [], "terminal_states" => []})
        write(entry["workflow"], Map.put(workflow.config, "tracker", tracker))
      end

      assert {:error, :repository_ownership_overlap} = RepositoryService.load(manifest)
    end

    {manifest, [a, b]} = fixture(root)
    alias_path = Path.join(root, "alias")
    File.mkdir_p!(a["environment"]["SYMPHONY_WORKTREE_ROOT"])
    File.ln_s!(a["environment"]["SYMPHONY_WORKTREE_ROOT"], alias_path)
    b = put_in(b, ["environment", "SYMPHONY_WORKTREE_ROOT"], alias_path)
    write(manifest, %{"repositories" => [a, b]})
    assert {:error, :repository_ownership_overlap} = RepositoryService.load(manifest)
  end

  test "reload retains last good scope; root membership needs restart", %{root: root} do
    {manifest, entries} = fixture(root)
    {:ok, [context | _] = contexts} = RepositoryService.load(manifest)
    start_supervised!({RepositoryService, contexts})
    assert :ok = RepositoryService.validate_manifest(%{config: %{"repositories" => entries}})
    changed = RepositoryService.validate_manifest(%{config: %{}})
    assert {:error, :repository_membership_changed_restart_required} = changed

    scope(context, fn ->
      {:ok, workflow} = Workflow.current()
      write(context.workflow, put_in(workflow.config, ["tracker", "active_states"], ["Ready"]))
      assert :ok = WorkflowStore.force_reload()
      assert Config.settings!().tracker.active_states == ["Ready"]
      write(context.workflow, put_in(workflow.config, ["workspace", "root"], Path.join(root, "moved")))
      assert {:error, :repository_scope_changed_restart_required} = WorkflowStore.force_reload()
      assert Config.local_workspace_root() == Path.join(root, "alpha-work")
      assert :ok = RepositoryService.validate_manifest(%{config: %{}})
    end)
  end

  test "aggregate and scoped HTTP reads distinguish identical identifiers; scoped effects fail closed", %{root: root} do
    {manifest, _} = fixture(root)
    {:ok, contexts} = RepositoryService.load(manifest)
    start_supervised!({RepositoryService, contexts})

    start_supervised!({HttpServer, port: 0})

    for context <- contexts do
      scope(context, fn ->
        server = RuntimeContext.server(Orchestrator)

        wait_until(fn ->
          due = :sys.get_state(server).next_poll_due_at_ms
          is_integer(due) and due > System.monotonic_time(:millisecond) + 500_000
        end)

        :sys.replace_state(server, fn state ->
          issue = %Tracker.Issue{id: "7", identifier: "SAME-7", state: "Ready"}
          %{state | blocked: %{"7" => %{identifier: "SAME-7", issue: issue, error: "fixture"}}}
        end)
      end)
    end

    assert %{blocked: entries} = RepositoryService.snapshot(5_000)
    assert Enum.sort(Enum.map(entries, & &1.identifier)) == ["alpha:SAME-7", "beta:SAME-7"]
    assert %{counts: %{blocked: 2}, repositories: ["alpha", "beta"]} = Presenter.state_payload(Orchestrator, 5_000)
    assert is_map(RepositoryService.taskboard_snapshot([]))
    assert is_map(SymphonyElixir.Taskboard.snapshot())

    conn = conn(:get, "/api/v1/state?repository=beta") |> Endpoint.call(Endpoint.init([]))
    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["counts"]["blocked"] == 1
    RuntimeContext.install(nil)
    assert %{queued: true} = RepositoryService.refresh()
    assert %{queued: true} = Orchestrator.request_refresh()

    for {path, status} <- [{"/api/v1/runs/7", 400}, {"/api/v1/state?repository=missing", 404}, {"/api/v1/webhooks/gitlab", 400}] do
      assert %{status: ^status, halted: true} = conn(:get, path) |> RepositoryScope.call([])
    end

    selected = %{conn(:get, "/api/v1/taskboard/projects/beta:p") | path_params: %{"project_id" => "beta:p"}, params: %{"project_id" => "beta:p"}}
    assert %{params: %{"project_id" => "p"}} = RepositoryScope.call(selected, [])
    assert RuntimeContext.current().id == "beta"
    RuntimeContext.install(nil)
    assert RepositoryScope.init([]) == []
  end

  test "a repository scheduler restart keeps its context and another repository remains available", %{root: root} do
    {manifest, _} = fixture(root)
    {:ok, [a, b] = contexts} = RepositoryService.load(manifest)
    start_supervised!({RepositoryService, contexts})
    a_runtime = scope(a, fn -> RuntimeContext.server(SymphonyElixir.AgentRuntimeSupervisor) end)
    a_server = scope(a, fn -> RuntimeContext.server(Orchestrator) end)
    b_server = scope(b, fn -> RuntimeContext.server(Orchestrator) end)
    b_pid = GenServer.whereis(b_server)
    assert :ok = Supervisor.terminate_child(a_runtime, a_server)
    assert :unavailable = RepositoryService.snapshot(50)
    assert :unavailable = RepositoryService.refresh()
    assert {:ok, _} = Supervisor.restart_child(a_runtime, a_server)
    assert is_map(Orchestrator.snapshot(a_server, 5_000))
    assert GenServer.whereis(b_server) == b_pid
    assert scope(a, fn -> Config.settings!().tracker.project_slug end) == "alpha"
  end
end
