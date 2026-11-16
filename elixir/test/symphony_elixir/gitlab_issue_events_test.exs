defmodule SymphonyElixir.GitLabIssueEventsTest do
  use SymphonyElixir.TestSupport, runtime: false

  alias SymphonyElixir.RunJournal
  alias SymphonyElixirWeb.WebhookController

  defmodule GitLabFixture do
    def fetch_issues_by_states(states) do
      send(owner(), {:issue_scan, states})
      {:ok, []}
    end

    def fetch_issues_by_ids(ids) do
      send(owner(), {:issue_read, ids})

      offline = Application.fetch_env!(:symphony_elixir, :issue_fixture_offline)

      if File.exists?(offline) do
        {:error, :offline}
      else
        {:ok, Enum.map(ids, &fixture_issue(&1, Path.dirname(offline)))}
      end
    end

    def fetch_issues_by_ids(ids, _tracker), do: fetch_issues_by_ids(ids)

    defp fixture_issue(id, root) do
      active = File.exists?(Path.join(root, "issue-open-" <> id))
      %Issue{id: id, identifier: "GL-" <> id, title: "Issue " <> id, state: if(active, do: "opened", else: "closed"), dispatchable: active}
    end

    defp owner, do: Application.fetch_env!(:symphony_elixir, :issue_fixture_owner)
  end

  setup context do
    root = Path.dirname(Workflow.workflow_file_path())
    journal = Path.join(root, "journal")
    offline = Path.join(root, "offline")
    secret = String.duplicate("s", 32)
    gate = Path.join(root, "cleanup-ready")
    log = Path.join(root, "cleanup.log")
    command = ~s(printf '%s\\n' "$1" >> '#{log}'; test -f '#{gate}')

    File.write!(Workflow.workflow_file_path(), """
    ---
    tracker:
      kind: gitlab
      disabled: #{context[:cleanup_only] == true}
      active_states: [opened]
      terminal_states: [closed]
      provider:
        project_path: team/repo
        api_url: https://gitlab.invalid/api/v4
        webhook_secret: "#{secret}"
        event_driven: true
    agent:
      run_journal_dir: "#{journal}"
      max_concurrent_agents: 1
    codex:
      command: sleep 20
    workspace:
      root: "#{Path.join(root, "workspaces")}"
      merge_cleanup_command: #{Jason.encode!(command)}
    polling:
      interval_ms: #{context[:event_retry_ms] || 3_600_000}
    ---
    Issue event fixture
    """)

    :ok = WorkflowStore.force_reload()

    for {key, value} <- [
          gitlab_client_module: GitLabFixture,
          issue_fixture_owner: self(),
          issue_fixture_offline: offline
        ] do
      previous = Application.get_env(:symphony_elixir, key)
      Application.put_env(:symphony_elixir, key, value)

      on_exit(fn ->
        if previous do
          Application.put_env(:symphony_elixir, key, previous)
        else
          Application.delete_env(:symphony_elixir, key)
        end
      end)
    end

    scope = {"https://gitlab.invalid/api/v4", "team/repo"}
    {:ok, journal: journal, scope: scope, offline: offline, secret: secret, cleanup_gate: gate, cleanup_log: log}
  end

  @tag cleanup_only: true
  test "an acknowledged manual merge retries across restart even when Issue dispatch is disabled", c do
    start_supervised!({Task.Supervisor, name: SymphonyElixir.TaskSupervisor})
    start_supervised!(Orchestrator)

    assert deliver("team/repo", c.secret, 41).status == 202
    refute_receive {:issue_read, _}, 100
    refute_received {:issue_scan, _}
    assert deliver("team/repo", c.secret, 42, :merge).status == 202

    assert await_cleanup(fn -> MapSet.size(:sys.get_state(Orchestrator).merge_cleanup_pending) == 1 end)
    assert {:ok, [%{iid: 42, project: "team/repo"}]} = RunJournal.merge_events(c.journal, c.scope)
    assert {:ok, []} = RunJournal.merge_events(c.journal, {"https://gitlab.invalid/api/v4", "other/repo"})

    :ok = stop_supervised(Orchestrator)
    File.touch!(c.cleanup_gate)
    start_supervised!(Orchestrator)

    assert await_cleanup(fn -> RunJournal.merge_events(c.journal, c.scope) == {:ok, []} end)
    assert :sys.get_state(Orchestrator).next_poll_due_at_ms == nil
    assert [failed, recovered] = c.cleanup_log |> File.stream!() |> Enum.map(&Jason.decode!/1)
    assert failed == recovered
    assert recovered["iid"] == 42
    refute_received {:issue_read, _}
    refute_received {:issue_scan, _}
  end

  defp await_cleanup(predicate, attempts \\ 100)
  defp await_cleanup(predicate, 0), do: predicate.()

  defp await_cleanup(predicate, attempts) do
    if predicate.() do
      true
    else
      Process.sleep(10)
      await_cleanup(predicate, attempts - 1)
    end
  end

  test "an authenticated Issue event drives only a scoped native read", c do
    start_supervised!(Orchestrator)
    refute_receive {:issue_scan, _}, 100
    refute_received {:issue_read, _}

    assert deliver("different/repo", c.secret, 6).status == 403
    assert deliver("team/repo", "wrong-token", 7).status == 403
    refute_received {:issue_read, _}
    assert deliver("team/repo", c.secret, 8).status == 202

    assert_receive {:issue_read, ["8"]}, 1_000
    assert :sys.get_state(Orchestrator).next_poll_due_at_ms == nil
    assert deliver("team/repo", c.secret, 10, :note).status == 202
    assert_receive {:issue_read, ["10"]}, 1_000
    assert :sys.get_state(Orchestrator).next_poll_due_at_ms == nil
    refute_received {:issue_scan, _}
    assert {:ok, []} = RunJournal.issue_events(c.journal, c.scope)
  end

  test "an acknowledged Issue event survives a failed read and orchestrator restart", c do
    File.touch!(c.offline)
    start_supervised!(Orchestrator)
    assert deliver("team/repo", c.secret, 9).status == 202
    assert_receive {:issue_read, ["9"]}, 1_000
    assert {:ok, ["9"]} = RunJournal.issue_events(c.journal, c.scope)
    assert {:ok, []} = RunJournal.issue_events(c.journal, {"https://other.invalid/api/v4", "team/repo"})

    :ok = stop_supervised(Orchestrator)
    File.rm!(c.offline)
    start_supervised!(Orchestrator)
    assert_receive {:issue_read, ["9"]}, 1_000
    assert :sys.get_state(Orchestrator).next_poll_due_at_ms == nil
    assert {:ok, []} = RunJournal.issue_events(c.journal, c.scope)
    refute_received {:issue_scan, _}
  end

  test "a queued Issue takes a freed slot without another notification or a scan", c do
    first = Path.join(Path.dirname(c.offline), "issue-open-1")
    second = Path.join(Path.dirname(c.offline), "issue-open-2")
    File.touch!(first)
    File.touch!(second)
    start_supervised!({Task.Supervisor, name: SymphonyElixir.TaskSupervisor})
    start_supervised!(Orchestrator)

    assert deliver("team/repo", c.secret, 1).status == 202
    assert_receive {:issue_read, ["1"]}, 1_000
    assert_receive {:issue_read, ["1"]}, 1_000
    assert await_cleanup(fn -> Map.has_key?(:sys.get_state(Orchestrator).running, "1") end)
    original = :sys.get_state(Orchestrator).running["1"].pid

    assert deliver("team/repo", c.secret, 1, :close).status == 202
    assert_receive {:issue_read, ["1"]}, 1_000
    assert :sys.get_state(Orchestrator).running["1"].pid == original

    assert deliver("team/repo", c.secret, 2).status == 202
    assert_receive {:issue_read, ["2"]}, 1_000
    assert Map.keys(:sys.get_state(Orchestrator).issue_event_candidates) == ["2"]
    refute_receive {:issue_read, _}, 100

    File.rm!(first)
    assert deliver("team/repo", c.secret, 1, :close).status == 202
    assert_receive {:issue_read, ["1"]}, 1_000
    assert_receive {:issue_read, ["2"]}, 1_000
    assert await_cleanup(fn -> Map.keys(:sys.get_state(Orchestrator).running) == ["2"] end)
    refute_received {:issue_scan, _}
  end

  test "accepted work cannot cross a GitLab host change with the same project path", c do
    File.touch!(c.offline)
    start_supervised!(Orchestrator)
    assert deliver("team/repo", c.secret, 9).status == 202
    assert_receive {:issue_read, ["9"]}, 1_000
    assert {:ok, ["9"]} = RunJournal.issue_events(c.journal, c.scope)

    path = Workflow.workflow_file_path()
    File.write!(path, String.replace(File.read!(path), "gitlab.invalid", "other.invalid"))
    :ok = WorkflowStore.force_reload()
    File.rm!(c.offline)
    assert Orchestrator.request_refresh().queued
    refute_receive {:issue_read, _}, 150

    :ok = stop_supervised(Orchestrator)
    start_supervised!(Orchestrator)
    refute_receive {:issue_read, _}, 150
    assert {:ok, ["9"]} = RunJournal.issue_events(c.journal, c.scope)
  end

  @tag event_retry_ms: 50
  test "exhausted Issue and manual cleanup retries stay durable until a new notification", c do
    File.touch!(c.offline)
    start_supervised!({Task.Supervisor, name: SymphonyElixir.TaskSupervisor})
    start_supervised!(Orchestrator)
    assert deliver("team/repo", c.secret, 9).status == 202
    assert deliver("team/repo", c.secret, 42, :merge).status == 202
    for _ <- 1..4, do: assert_receive({:issue_read, ["9"]}, 1_000)

    assert await_cleanup(fn ->
             state = :sys.get_state(Orchestrator)
             state.merge_cleanup_ref == nil and state.next_poll_due_at_ms == nil
           end)

    assert {:ok, ["9"]} = RunJournal.issue_events(c.journal, c.scope)
    assert {:ok, [%{iid: 42}]} = RunJournal.merge_events(c.journal, c.scope)
    assert Enum.count(File.stream!(c.cleanup_log)) == 4
    refute_receive {:issue_read, _}, 125

    File.rm!(c.offline)
    File.touch!(c.cleanup_gate)
    assert deliver("team/repo", c.secret, 9).status == 202
    assert deliver("team/repo", c.secret, 42, :merge).status == 202
    assert_receive {:issue_read, ["9"]}, 1_000
    assert await_cleanup(fn -> RunJournal.merge_events(c.journal, c.scope) == {:ok, []} end)
    assert await_cleanup(fn -> RunJournal.issue_events(c.journal, c.scope) == {:ok, []} end)
    refute_received {:issue_scan, _}
  end

  test "unavailable consumers respond with a retryable status and unrelated events stay idle", c do
    assert deliver("team/repo", c.secret, 8).status == 503
    assert deliver("team/repo", c.secret, 8, :merge).status == 503
    start_supervised!({Task.Supervisor, name: SymphonyElixir.TaskSupervisor})
    start_supervised!(Orchestrator)
    assert deliver("team/repo", c.secret, 8, :ignored).status == 202
    refute_receive {:issue_read, _}, 100
    refute_received {:issue_scan, _}

    # An unavailable spool must not accept a delivery it cannot replay.
    File.mkdir_p!(c.journal)
    File.touch!(Path.join(c.journal, ".gitlab-merges"))
    assert deliver("team/repo", c.secret, 8, :merge).status == 503
    refute File.exists?(c.cleanup_log)
    File.rm!(Path.join(c.journal, ".gitlab-merges"))
    File.touch!(c.cleanup_gate)
    assert deliver("team/repo", c.secret, 8, :merge).status == 202
    assert await_cleanup(fn -> File.exists?(c.cleanup_log) end)
  end

  test "merge cleanup journal rejects foreign and malformed work", c do
    hint = %{provider: "gitlab", project: "team/repo", project_id: 101, iid: 8}
    assert :ok = RunJournal.forget_merge_event(c.journal, c.scope, 8)
    foreign_hint = %{hint | project: "other/repo"}
    assert {:error, :invalid_merge_hint} = RunJournal.remember_merge_event(c.journal, c.scope, foreign_hint)
    assert :ok = RunJournal.remember_merge_event(c.journal, c.scope, hint)

    [file] = Path.wildcard(Path.join(c.journal, ".gitlab-merges/*/*.event"))
    File.write!(file, "{")
    restored = RunJournal.merge_events(c.journal, c.scope)
    assert {:error, {:invalid_gitlab_event, _, {:error, :invalid_merge_hint}}} = restored
    File.rm!(file)
    dir = Path.dirname(file)
    File.rmdir!(dir)
    File.touch!(dir)
    assert {:error, :enotdir} = RunJournal.merge_events(c.journal, c.scope)
  end

  defp deliver(project, secret, iid, kind \\ :issue) do
    payload =
      Map.put(event_payload(kind, iid), "project", %{
        "id" => 101,
        "path_with_namespace" => project,
        "web_url" => "https://gitlab.invalid/" <> project
      })

    conn = Plug.Test.conn(:post, "/", payload) |> Plug.Conn.put_req_header("x-gitlab-token", secret)
    WebhookController.receive_event(conn, %{"provider" => "gitlab"})
  end

  defp event_payload(:ignored, _iid),
    do: %{"object_kind" => "note", "object_attributes" => %{"noteable_type" => "Commit", "action" => "create"}}

  defp event_payload(:issue, iid),
    do: %{"object_kind" => "issue", "object_attributes" => %{"iid" => iid, "action" => "update"}}

  defp event_payload(:close, iid),
    do: %{"object_kind" => "issue", "object_attributes" => %{"iid" => iid, "action" => "close", "state" => "closed"}}

  defp event_payload(:merge, iid),
    do: %{"object_kind" => "merge_request", "object_attributes" => %{"iid" => iid, "action" => "merge", "state" => "merged"}}

  defp event_payload(:note, iid) do
    %{
      "object_kind" => "note",
      "object_attributes" => %{"noteable_type" => "Issue", "action" => "create"},
      "issue" => %{"iid" => iid}
    }
  end
end
