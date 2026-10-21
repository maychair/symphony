defmodule SymphonyElixirWeb.WebhookController do
  @moduledoc "Authenticated event hints; remote API reconciliation remains authoritative."
  use Phoenix.Controller, formats: [:json]
  alias Plug.Conn
  alias SymphonyElixir.{Config, Orchestrator}

  alias SymphonyElixir.ReviewLane.{GitHub, GitLab, Listener}
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
    config = SymphonyElixir.ReviewLane.config()

    if config && provider == config["provider"] && review_event?(conn, provider) do
      receive_review(conn, provider, config)
    else
      receive_tracker(conn, provider)
    end
  end

  defp review_event?(conn, "github") do
    event = List.first(Conn.get_req_header(conn, "x-github-event"))

    event in ~w(pull_request pull_request_review pull_request_review_comment pull_request_review_thread issue_comment) and
      (is_map(conn.body_params["pull_request"]) or is_map(get_in(conn.body_params, ["issue", "pull_request"])))
  end

  defp review_event?(conn, "gitlab"), do: conn.body_params["object_kind"] in ["merge_request", "note"]

  defp receive_tracker(conn, provider) do
    settings = Config.settings!().tracker
    secret = resolve(settings.provider["webhook_secret"])
    body = conn.assigns[:webhook_body] || ""

    with true <- settings.kind == provider,
         true <- is_binary(secret) and byte_size(secret) >= 16,
         :ok <- authenticate(conn, provider, secret, body),
         :ok <- scope(settings, provider, conn.body_params) do
      acknowledge(conn, settings.disabled)
    else
      _ -> conn |> put_status(403) |> json(%{error: "webhook_rejected"})
    end
  end

  defp receive_review(conn, "github", config) do
    repository = conn.body_params["repository"] || %{}
    project = repository["full_name"]
    number = get_in(conn.body_params, ["pull_request", "number"]) || get_in(conn.body_params, ["issue", "number"])
    secret = config["webhook_secret"]

    with true <- is_binary(secret) and byte_size(secret) >= 32,
         :ok <- authenticate(conn, "github", secret, conn.assigns[:webhook_body] || ""),
         true <- is_binary(project) and Map.has_key?(config["projects"], project),
         true <- GitHub.repository?(repository, config, project),
         true <- is_integer(number) and number > 0,
         :ok <- Listener.request_review(project, number) do
      acknowledge(conn, config["disabled"] == true)
    else
      _ -> conn |> put_status(403) |> json(%{error: "review_event_rejected"})
    end
  end

  defp receive_review(conn, provider, config) do
    secret = config["webhook_secret"]
    project = get_in(conn.body_params, ["project", "path_with_namespace"])
    native_id = get_in(conn.body_params, ["project", "id"])
    expected_id = get_in(config, ["projects", project, "id"])
    url = get_in(conn.body_params, ["project", "web_url"])
    attributes = if conn.body_params["object_kind"] == "note", do: conn.body_params["merge_request"], else: conn.body_params["object_attributes"]

    with true <- is_binary(secret) and byte_size(secret) >= 32,
         :ok <- authenticate(conn, provider, secret, conn.assigns[:webhook_body] || ""),
         true <- is_integer(expected_id) and native_id == expected_id,
         true <- GitLab.web_url?(url, config, "/" <> project),
         true <- is_map(attributes),
         :ok <- Listener.request_review(project, attributes["iid"]) do
      acknowledge(conn, config["disabled"] == true)
    else
      _ -> conn |> put_status(403) |> json(%{error: "review_event_rejected"})
    end
  end

  defp acknowledge(conn, true), do: conn |> put_status(202) |> json(%{accepted: false, disabled: true})

  defp acknowledge(conn, false) do
    Orchestrator.request_refresh()
    conn |> put_status(202) |> json(%{accepted: true})
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
