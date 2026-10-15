defmodule SymphonyElixirWeb.WebhookController do
  @moduledoc "Authenticated event hints; remote API reconciliation remains authoritative."
  use Phoenix.Controller, formats: [:json]
  alias Plug.Conn
  alias SymphonyElixir.Beads.{Adapter, Repository}
  alias SymphonyElixir.{Config, Orchestrator}

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
  def receive_event(conn, %{"provider" => provider}) do
    settings = Config.settings!().tracker
    secret = resolve(settings.provider["webhook_secret"])
    body = conn.assigns[:webhook_body] || ""

    with true <- settings.kind == "beads" and settings.provider["remote_reconcile"] == true,
         true <- is_binary(secret) and byte_size(secret) >= 16,
         :ok <- authenticate(conn, provider, secret, body),
         :ok <- scope(settings, provider, conn.body_params),
         {:ok, id} <- delivery_id(conn, provider),
         {:ok, duplicate} <- remember(settings, provider, id, body) do
      Orchestrator.request_refresh()
      conn |> put_status(202) |> json(%{accepted: true, duplicate: duplicate})
    else
      _ -> conn |> put_status(403) |> json(%{error: "webhook_rejected"})
    end
  end

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

  defp scope(settings, provider, payload) do
    repo =
      case provider do
        "github" ->
          "github.com/" <> (get_in(payload, ["repository", "full_name"]) || "")

        "gitlab" ->
          web_url = get_in(payload, ["project", "web_url"]) || ""
          if Repository.gitlab_url?(settings, web_url), do: URI.parse(web_url).host <> "/" <> (get_in(payload, ["project", "path_with_namespace"]) || ""), else: ""

        _ ->
          ""
      end

    if repo == resolve(settings.provider["review_repository"]), do: :ok, else: {:error, :repository_mismatch}
  end

  defp delivery_id(conn, provider) do
    header = if provider == "github", do: "x-github-delivery", else: "x-gitlab-event-uuid"

    case Conn.get_req_header(conn, header) do
      [id] when byte_size(id) in 1..200 -> {:ok, id}
      _ -> {:error, :missing_delivery_id}
    end
  end

  defp remember(settings, provider, id, body) do
    directory = Path.join(Adapter.journal_root(settings), "webhooks")
    key = Base.encode16(:crypto.hash(:sha256, provider <> ":" <> id), case: :lower)
    record = %{provider: provider, id: id, body_sha256: Base.encode16(:crypto.hash(:sha256, body)), received_at: DateTime.to_iso8601(DateTime.utc_now())}

    with :ok <- File.mkdir_p(directory) do
      case :file.open(String.to_charlist(Path.join(directory, key <> ".json")), [:write, :exclusive, :binary, :raw]) do
        {:ok, file} ->
          try do
            with :ok <- :file.write(file, Jason.encode!(record)), :ok <- :file.sync(file), do: {:ok, false}
          after
            :file.close(file)
          end

        {:error, :eexist} ->
          {:ok, true}

        error ->
          error
      end
    end
  end

  defp resolve("$" <> name), do: System.get_env(name)
  defp resolve(value), do: value
end
