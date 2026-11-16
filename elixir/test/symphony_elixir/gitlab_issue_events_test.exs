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

  setup do
    root = Path.dirname(Workflow.workflow_file_path())
    journal = Path.join(root, "journal")
    offline = Path.join(root, "offline")
    secret = String.duplicate("s", 32)

    File.write!(Workflow.workflow_file_path(), """
    ---
    tracker:
      kind: gitlab
      active_states: [opened]
      terminal_states: [closed]
      provider:
        project_path: team/repo
        api_url: https://gitlab.invalid/api/v4
        webhook_secret: "#{secret}"
        event_driven: true
    agent:
      run_journal_dir: "#{journal}"
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

    {:ok, journal: journal, offline: offline, secret: secret}
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

  defp event_payload(:note, iid) do
    %{
      "object_kind" => "note",
      "object_attributes" => %{"noteable_type" => "Issue", "action" => "create"},
      "issue" => %{"iid" => iid}
    }
  end
end
