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

      if File.exists?(Application.fetch_env!(:symphony_elixir, :issue_fixture_offline)) do
        {:error, :offline}
      else
        {:ok, Enum.map(ids, &%Issue{id: &1, identifier: "GL-" <> &1, state: "closed"})}
      end
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
    workspace:
      merge_cleanup_command: #{Jason.encode!(command)}
    polling:
      interval_ms: 3600000
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

    {:ok, journal: journal, offline: offline, secret: secret, cleanup_gate: gate, cleanup_log: log}
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
    assert {:ok, [%{iid: 42, project: "team/repo"}]} = RunJournal.merge_events(c.journal, "team/repo")
    assert {:ok, []} = RunJournal.merge_events(c.journal, "other/repo")

    :ok = stop_supervised(Orchestrator)
    File.touch!(c.cleanup_gate)
    start_supervised!(Orchestrator)

    assert await_cleanup(fn -> RunJournal.merge_events(c.journal, "team/repo") == {:ok, []} end)
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
    assert {:ok, []} = RunJournal.issue_events(c.journal, "team/repo")
  end

  test "an acknowledged Issue event survives a failed read and orchestrator restart", c do
    File.touch!(c.offline)
    start_supervised!(Orchestrator)
    assert deliver("team/repo", c.secret, 9).status == 202
    assert_receive {:issue_read, ["9"]}, 1_000
    assert {:ok, ["9"]} = RunJournal.issue_events(c.journal, "team/repo")
    assert {:ok, []} = RunJournal.issue_events(c.journal, "other/repo")

    :ok = stop_supervised(Orchestrator)
    File.rm!(c.offline)
    start_supervised!(Orchestrator)
    assert_receive {:issue_read, ["9"]}, 1_000
    assert :sys.get_state(Orchestrator).next_poll_due_at_ms == nil
    assert {:ok, []} = RunJournal.issue_events(c.journal, "team/repo")
    refute_received {:issue_scan, _}
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

  defp event_payload(:issue, iid),
    do: %{"object_kind" => "issue", "object_attributes" => %{"iid" => iid, "action" => "update"}}

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
