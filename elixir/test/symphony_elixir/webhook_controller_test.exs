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

  defp configure(provider, secret) do
    File.write!(Workflow.workflow_file_path(), """
    ---
    tracker:
      kind: #{provider}
      active_states: [#{if provider == "gitlab", do: "opened", else: "open"}]
      terminal_states: [closed]
      provider:
        repo: team/repo
        project_path: team/repo
        api_url: https://review.invalid/api/v4
        token: fixture
        webhook_secret: #{Jason.encode!(secret)}
    ---
    Webhook fixture
    """)

    :ok = WorkflowStore.force_reload()
  end
end
