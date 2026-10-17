defmodule SymphonyElixir.Taskboard.ProviderTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Taskboard.{GitHub, GitLab, Memory, Provider}
  alias SymphonyElixir.Tracker.Issue

  setup do
    provider = %{
      "repo" => "mock/issues",
      "project_path" => "mock/issues",
      "token" => "token",
      "api_key" => "token"
    }

    {:ok, settings: %{Config.settings!().tracker | provider: provider}}
  end

  test "GitHub label writes are skipped when the requested state already exists", %{
    settings: settings
  } do
    absent = issue("GH-7", [])
    present = issue("GH-7", ["symphony:ready"])

    assert :ok = GitHub.add_label(settings, "GH-7", "symphony:ready", label_opts(absent, self()))

    assert_receive {:label_request, "POST", "/repos/mock/issues/issues/7/labels", %{"labels" => ["symphony:ready"]}}

    assert :ok = GitHub.add_label(settings, "GH-7", "symphony:ready", label_opts(present, self()))
    refute_receive {:label_request, "POST", _, _}

    assert :ok = GitHub.remove_label(settings, "GH-7", "symphony:ready", label_opts(present, self()))

    assert_receive {:label_request, "DELETE", "/repos/mock/issues/issues/7/labels/symphony%3Aready", nil}

    assert :ok = GitHub.remove_label(settings, "GH-7", "symphony:ready", label_opts(absent, self()))
    refute_receive {:label_request, "DELETE", _, _}
  end

  test "GitLab label writes are skipped when the requested state already exists", %{
    settings: settings
  } do
    absent = issue("GL-7", [])
    present = issue("GL-7", ["symphony:ready"])

    assert :ok = GitLab.add_label(settings, "GL-7", "symphony:ready", label_opts(absent, self()))

    assert_receive {:label_request, "PUT", "/projects/mock%2Fissues/issues/7", %{"add_labels" => "symphony:ready"}}

    assert :ok = GitLab.add_label(settings, "GL-7", "symphony:ready", label_opts(present, self()))
    refute_receive {:label_request, "PUT", _, %{"add_labels" => _}}

    assert :ok = GitLab.remove_label(settings, "GL-7", "symphony:ready", label_opts(present, self()))

    assert_receive {:label_request, "PUT", "/projects/mock%2Fissues/issues/7", %{"remove_labels" => "symphony:ready"}}

    assert :ok = GitLab.remove_label(settings, "GL-7", "symphony:ready", label_opts(absent, self()))
    refute_receive {:label_request, "PUT", _, %{"remove_labels" => _}}
  end

  test "providers read lifecycle states from the tracker settings", %{settings: settings} do
    tracker = %{
      settings
      | active_states: ["opened", "reopened"],
        terminal_states: ["closed"]
    }

    issues_fun = fn states ->
      send(self(), {:issue_states, states})
      {:ok, []}
    end

    assert {:ok, []} = GitHub.list_issues(tracker, issues_fun: issues_fun)
    assert_receive {:issue_states, ["opened", "reopened", "closed"]}

    assert {:ok, []} = GitLab.list_issues(tracker, issues_fun: issues_fun)
    assert_receive {:issue_states, ["opened", "reopened", "closed"]}
  end

  test "GitHub detail resolves prefixed identifiers through their native Issue number", %{
    settings: settings
  } do
    issue = %{issue("GH-34", []) | id: "34", state: "open", description: "Issue body"}

    issue_fun = fn ids ->
      assert ids == ["34"]
      {:ok, [issue]}
    end

    request_fun = fn _method, path, _query, _body, _settings ->
      body =
        case path do
          "/repos/mock/issues/issues/34" -> %{"number" => 34, "body" => "Issue body"}
          "/repos/mock/issues/issues/34/comments" -> []
          "/repos/mock/issues/issues/34/timeline" -> []
        end

      {:ok, %{status: 200, body: body}}
    end

    assert {:ok, detail} =
             GitHub.issue_detail(settings, "GH-34", issue_fun: issue_fun, request_fun: request_fun)

    assert detail.issue.identifier == "GH-34"
    assert detail.description == "Issue body"
  end

  test "GitLab detail resolves prefixed identifiers through their native Issue number", %{
    settings: settings
  } do
    issue = %{issue("GL-34", []) | id: "34", state: "opened", description: "Issue description"}

    issue_fun = fn ids ->
      assert ids == ["34"]
      {:ok, [issue]}
    end

    request_fun = fn _method, path, _query, _body, _settings ->
      body =
        case path do
          "/projects/mock%2Fissues/issues/34" ->
            %{"iid" => 34, "description" => "Issue description"}

          "/projects/mock%2Fissues/issues/34/notes" ->
            []

          "/projects/mock%2Fissues/issues/34/related_merge_requests" ->
            []
        end

      {:ok, %{status: 200, body: body}}
    end

    assert {:ok, detail} =
             GitLab.issue_detail(settings, "GL-34", issue_fun: issue_fun, request_fun: request_fun)

    assert detail.issue.identifier == "GL-34"
    assert detail.description == "Issue description"
  end

  test "provider resolution and Issue presentation helpers preserve board contracts" do
    assert {:ok, GitHub} = Provider.module_for("github")
    assert {:ok, GitLab} = Provider.module_for("gitlab")
    assert {:ok, Memory} = Provider.module_for("memory")
    assert {:error, {:unsupported_taskboard_tracker, "jira"}} = Provider.module_for("jira")

    assert Provider.summary(nil) == nil
    assert Provider.summary("<!-- internal --> **Readable** [summary](url)") == "Readable summary url"
    assert Provider.summary("<!-- internal only -->") == nil
    assert String.length(Provider.summary(String.duplicate("x", 240))) == 220

    assert Provider.priority(["type:research", "P1"]) == 1
    assert Provider.priority(["type:research"]) == nil
    assert Provider.iso8601(~U[2026-10-17 01:02:03.456789Z]) == "2026-10-17T01:02:03Z"
    assert Provider.iso8601("already-normalized") == "already-normalized"
    assert Provider.iso8601(nil) == nil
  end

  test "provider helpers normalize native Issue numbers, secrets, values, and paths" do
    System.put_env("SYMPHONY_TASKBOARD_PROVIDER_HELPER", " secret ")

    on_exit(fn ->
      System.delete_env("SYMPHONY_TASKBOARD_PROVIDER_HELPER")
      System.delete_env("SYMPHONY_TASKBOARD_PROVIDER_FALLBACK")
    end)

    assert Provider.resolve_secret("$SYMPHONY_TASKBOARD_PROVIDER_HELPER", "fallback") == "secret"
    assert Provider.resolve_secret("$SYMPHONY_TASKBOARD_PROVIDER_FALLBACK", " fallback ") == "fallback"
    assert Provider.resolve_secret("$invalid-name", "fallback") == nil
    assert Provider.resolve_secret(nil, " fallback ") == "fallback"
    assert Provider.resolve_secret(" literal ", "fallback") == "literal"

    assert Provider.present(" value ") == "value"
    assert Provider.present("   ") == nil
    assert Provider.present(nil) == nil
    assert Provider.encode("repo / issue") == "repo%20%2F%20issue"

    assert Provider.issue_number(%Issue{id: "fallback", native_ref: %{"number" => "42"}}) == 42
    assert Provider.issue_number(%Issue{id: "fallback", native_ref: %{"iid" => "43"}}) == 43
    assert Provider.issue_number(%Issue{id: "44"}) == 44
    assert Provider.issue_number(%Issue{id: "not-a-number"}) == nil
    assert Provider.issue_number(%Issue{id: "0"}) == nil
  end

  defp label_opts(issue, test_pid) do
    [
      issue_fun: fn _ids -> {:ok, [issue]} end,
      request_fun: fn method, path, _query, body, _settings ->
        send(test_pid, {:label_request, method, path, body})
        {:ok, %{status: 200, body: %{}}}
      end
    ]
  end

  defp issue(identifier, labels) do
    %Issue{
      id: "7",
      identifier: identifier,
      title: "Label fixture",
      state: "open",
      labels: labels
    }
  end
end
