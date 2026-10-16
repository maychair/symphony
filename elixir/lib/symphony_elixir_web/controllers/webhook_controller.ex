defmodule SymphonyElixirWeb.WebhookController do
  @moduledoc "Authenticated event hints; remote API reconciliation remains authoritative."
  use Phoenix.Controller, formats: [:json]
  alias Plug.Conn
  alias SymphonyElixir.{Config, Orchestrator}

  alias SymphonyElixir.MailReview.Listener
  @spec read_body(Conn.t(), keyword()) :: {:ok, binary(), Conn.t()} | {:more, binary(), Conn.t()} | {:error, term()}
  def read_body(conn, opts) do
    case Conn.read_body(conn, opts) do
      {status, body, conn} when status in [:ok, :more] ->
        {status, body, Conn.assign(conn, :webhook_body, (conn.assigns[:webhook_body] || "") <> body)}

      error ->
        error
    end
  end

  @spec receive_event(Conn.t(), map()) :: Conn.t()
  def receive_event(conn, %{"provider" => "mail"}) do
    config = SymphonyElixir.MailReview.config()
    secret = if config, do: config["replay_secret"], else: nil

    with true <- is_binary(secret) and byte_size(secret) >= 32,
         :ok <- compare(List.first(Conn.get_req_header(conn, "x-symphony-token")), secret),
         :ok <- request_mail_review(conn.body_params) do
      Orchestrator.request_refresh()
      conn |> put_status(202) |> json(%{accepted: true})
    else
      _ -> conn |> put_status(403) |> json(%{error: "mail_replay_rejected"})
    end
  end

  def receive_event(conn, %{"provider" => provider}) do
    settings = Config.settings!().tracker
    secret = resolve(settings.provider["webhook_secret"])
    body = conn.assigns[:webhook_body] || ""

    with true <- settings.kind == provider,
         true <- is_binary(secret) and byte_size(secret) >= 16,
         :ok <- authenticate(conn, provider, secret, body),
         :ok <- scope(settings, provider, conn.body_params) do
      Orchestrator.request_refresh()
      conn |> put_status(202) |> json(%{accepted: true})
    else
      _ -> conn |> put_status(403) |> json(%{error: "webhook_rejected"})
    end
  end

  defp request_mail_review(%{"message_id" => id}) when is_binary(id) and byte_size(id) in 1..512 do
    Listener.ingest(%{"ok" => true, "data" => %{"event" => %{"message_id" => id}}})
  end

  defp request_mail_review(%{"project" => project, "iid" => iid}) when is_binary(project) and is_integer(iid) do
    Listener.request_review(project, iid)
  end

  defp request_mail_review(_payload), do: {:error, :invalid_mail_review_request}

  defp authenticate(conn, "github", secret, body) do
    expected = "sha256=" <> Base.encode16(:crypto.mac(:hmac, :sha256, secret, body), case: :lower)
    compare(List.first(Conn.get_req_header(conn, "x-hub-signature-256")), expected)
  end

  defp authenticate(conn, "gitlab", secret, _body), do: compare(List.first(Conn.get_req_header(conn, "x-gitlab-token")), secret)
  defp authenticate(_conn, _provider, _secret, _body), do: {:error, :unsupported_provider}

  defp compare(actual, expected) when is_binary(actual) and byte_size(actual) == byte_size(expected) do
    if Plug.Crypto.secure_compare(actual, expected), do: :ok, else: {:error, :invalid_signature}
  end

  defp compare(_, _), do: {:error, :invalid_signature}

  defp scope(%{provider: settings}, "github", payload) do
    if get_in(payload, ["repository", "full_name"]) == settings["repo"], do: :ok, else: {:error, :repository_mismatch}
  end

  defp scope(%{provider: settings}, "gitlab", payload) do
    actual = URI.parse(get_in(payload, ["project", "web_url"]) || "")
    expected = URI.parse(settings["api_url"] || "https://gitlab.com/api/v4")
    if actual.host == expected.host and get_in(payload, ["project", "path_with_namespace"]) == settings["project_path"], do: :ok, else: {:error, :repository_mismatch}
  end

  defp resolve("$" <> name), do: System.get_env(name)
  defp resolve(value), do: value
end
