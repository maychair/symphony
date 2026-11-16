defmodule SymphonyElixirWeb.WebhookControllerTest do
  use SymphonyElixir.TestSupport
  alias Plug.Conn
  alias SymphonyElixirWeb.WebhookController

  test "native webhooks require correct signature, provider and repository" do
    secret = String.duplicate("s", 32)

    for provider <- ["github", "gitlab", "memory"] do
      configure(provider, secret)

      payload =
        if provider == "gitlab",
          do: %{"project" => %{"web_url" => "https://review.invalid/team/repo", "path_with_namespace" => "team/repo"}},
          else: %{"repository" => %{"full_name" => "team/repo"}}

      body = Jason.encode!(payload)
      conn = Plug.Test.conn(:post, "/", body) |> Conn.assign(:webhook_body, body)
      conn = %{conn | body_params: payload}

      {header, signature} =
        if provider == "github",
          do: {"x-hub-signature-256", "sha256=" <> Base.encode16(:crypto.mac(:hmac, :sha256, secret, body), case: :lower)},
          else: {"x-gitlab-token", secret}

      assert WebhookController.receive_event(conn, %{"provider" => provider}).status == 403
      signed = Conn.put_req_header(conn, header, signature)
      assert WebhookController.receive_event(signed, %{"provider" => provider}).status == if(provider == "memory", do: 403, else: 202)
      wrong = %{signed | body_params: %{}}
      assert WebhookController.receive_event(wrong, %{"provider" => provider}).status == 403
      wrong_signature = Conn.put_req_header(conn, header, String.duplicate("x", byte_size(signature)))
      assert WebhookController.receive_event(wrong_signature, %{"provider" => provider}).status == 403
    end

    configure("github", "$SYMPHONY_TEST_WEBHOOK_SECRET")
    System.put_env("SYMPHONY_TEST_WEBHOOK_SECRET", secret)
    on_exit(fn -> System.delete_env("SYMPHONY_TEST_WEBHOOK_SECRET") end)
    assert WebhookController.receive_event(Plug.Test.conn(:post, "/", %{}), %{"provider" => "gitlab"}).status == 403
    assert WebhookController.receive_event(Plug.Test.conn(:post, "/", %{}), %{"provider" => "mail"}).status == 403
  end

  test "body reader preserves exact bytes across partial reads and adapter failures" do
    conn = Plug.Test.conn(:post, "/", "payload")
    assert {:ok, "payload", updated} = WebhookController.read_body(conn, [])
    assert updated.assigns.webhook_body == "payload"
    assert {:ok, "", _} = WebhookController.read_body(updated, [])
    error_conn = %{conn | adapter: {__MODULE__, :failure}}
    assert {:error, :closed} = WebhookController.read_body(error_conn, [])
  end

  @spec read_req_body(term(), keyword()) :: {:error, :closed}
  def read_req_body(:failure, _opts), do: {:error, :closed}

  test "tracker webhook acknowledges disabled state without dispatch refresh" do
    secret = String.duplicate("s", 32)
    configure("github", secret, true)

    payload = %{"repository" => %{"full_name" => "team/repo"}}
    body = Jason.encode!(payload)

    conn =
      Plug.Test.conn(:post, "/", body)
      |> Conn.assign(:webhook_body, body)
      |> Conn.put_req_header("x-hub-signature-256", "sha256=" <> Base.encode16(:crypto.mac(:hmac, :sha256, secret, body), case: :lower))

    conn = %{conn | body_params: payload}

    resp = WebhookController.receive_event(conn, %{"provider" => "github"})
    assert resp.status == 202
    assert Jason.decode!(resp.resp_body) == %{"accepted" => false, "disabled" => true}
  end

  test "authenticated GitLab merge hints reach cleanup with issue dispatch disabled" do
    secret = String.duplicate("s", 32)
    root = Path.dirname(Workflow.workflow_file_path())
    log = Path.join(root, "merge-hints.jsonl")
    gate = Path.join(root, "gate")
    command = ~s(if [ -n "$1" ]; then printf '%s\\n' "$1" >> '#{log}'; while [ ! -f '#{gate}' ]; do sleep 0.01; done; fi)
    configure("gitlab", secret, true, command)

    try do
      assert gitlab_merge(secret, 7, "open").status == 202
      assert gitlab_merge("wrong", 7, "merge").status == 403
      refute File.exists?(log)
      assert gitlab_merge(secret, 7, "merge").status == 202
      await_hints(log, 1)
      assert gitlab_merge(secret, 7, "merge").status == 202
      assert gitlab_merge(secret, 8, "merge").status == 202
      assert read_hints(log) == [%{"provider" => "gitlab", "project_id" => 101, "project" => "team/repo", "iid" => 7}]
      File.touch!(gate)
      await_hints(log, 2)
      assert Enum.map(read_hints(log), & &1["iid"]) == [7, 8]
    after
      File.touch!(gate)
    end
  end

  test "an enabled tracker acknowledges a merge and retries a failing hint on its existing poll" do
    secret = String.duplicate("s", 32)
    root = Path.dirname(Workflow.workflow_file_path())
    log = Path.join(root, "merge-retry.jsonl")
    gate = Path.join(root, "allow")
    command = ~s(if [ -n "$1" ]; then printf '%s\\n' "$1" >> '#{log}'; test -f '#{gate}'; fi)
    configure("gitlab", secret, false, command)

    assert gitlab_merge(secret, 7, "merge").status == 202
    assert eventually(fn -> MapSet.size(:sys.get_state(Orchestrator).merge_cleanup_pending) == 1 end)
    File.touch!(gate)
    send(Orchestrator, :run_poll_cycle)

    assert eventually(fn ->
             state = :sys.get_state(Orchestrator)
             is_nil(state.merge_cleanup_ref) and MapSet.size(state.merge_cleanup_pending) == 0
           end)

    hints = read_hints(log)
    assert length(hints) >= 2
    assert Enum.all?(hints, &(&1["iid"] == 7))
  end

  test "a merge hint gets a retryable response while the configured orchestrator is unavailable" do
    secret = String.duplicate("s", 32)
    configure("gitlab", secret, true, "true")
    supervisor = SymphonyElixir.AgentRuntimeSupervisor
    assert :ok = Supervisor.terminate_child(supervisor, Orchestrator)

    try do
      response = gitlab_merge(secret, 7, "merge")
      assert response.status == 503
      assert Jason.decode!(response.resp_body) == %{"error" => "merge_cleanup_unavailable"}
    after
      assert {:ok, _pid} = Supervisor.restart_child(supervisor, Orchestrator)
    end
  end

  defp eventually(predicate, attempts \\ 100)
  defp eventually(predicate, 0), do: predicate.()

  defp eventually(predicate, attempts) do
    if predicate.() do
      true
    else
      Process.sleep(10)
      eventually(predicate, attempts - 1)
    end
  end

  defp gitlab_merge(secret, iid, action) do
    payload = %{
      "object_kind" => "merge_request",
      "project" => %{"id" => 101, "path_with_namespace" => "team/repo", "web_url" => "https://review.invalid/team/repo"},
      "object_attributes" => %{"iid" => iid, "action" => action, "state" => if(action == "merge", do: "merged", else: "opened")}
    }

    conn = Plug.Test.conn(:post, "/", payload) |> Conn.put_req_header("x-gitlab-token", secret)
    WebhookController.receive_event(conn, %{"provider" => "gitlab"})
  end

  defp await_hints(log, count, attempts \\ 100)
  defp await_hints(log, count, 0), do: assert(length(read_hints(log)) == count)

  defp await_hints(log, count, attempts) do
    if length(read_hints(log)) != count do
      Process.sleep(10)
      await_hints(log, count, attempts - 1)
    end
  end

  defp read_hints(log) do
    case File.read(log) do
      {:ok, lines} -> lines |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
      {:error, :enoent} -> []
    end
  end

  defp configure(provider, secret, disabled \\ false, command \\ nil) do
    File.write!(Workflow.workflow_file_path(), """
    ---
    tracker:
      kind: #{provider}
      disabled: #{disabled}
      active_states: [#{if provider == "gitlab", do: "opened", else: "open"}]
      terminal_states: [closed]
      provider:
        repo: team/repo
        project_path: team/repo
        api_url: https://review.invalid/api/v4
        token: fixture
        webhook_secret: #{Jason.encode!(secret)}
    workspace:
      merge_cleanup_command: #{Jason.encode!(command)}
    polling:
      interval_ms: 3600000
    ---
    Webhook fixture
    """)

    :ok = WorkflowStore.force_reload()
  end
end
