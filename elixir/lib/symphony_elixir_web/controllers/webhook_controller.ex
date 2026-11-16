defmodule SymphonyElixirWeb.WebhookController do
  @moduledoc "Authenticated event hints; remote API reconciliation remains authoritative."
  use Phoenix.Controller, formats: [:json]
  alias Plug.Conn
  alias SymphonyElixir.{Config, Orchestrator}
  alias SymphonyElixir.GitLab.Adapter, as: GitLabAdapter

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

  defp review_event?(%{body_params: %{"object_kind" => "merge_request"}}, "gitlab"), do: true

  defp review_event?(%{body_params: %{"object_kind" => "note", "object_attributes" => %{"noteable_type" => "MergeRequest"}}}, "gitlab"),
    do: true

  defp review_event?(_conn, "gitlab"), do: false

  defp receive_tracker(conn, provider) do
    settings = Config.settings!().tracker
    secret = resolve(settings.provider["webhook_secret"])
    body = conn.assigns[:webhook_body] || ""

    with true <- settings.kind == provider,
         true <- is_binary(secret) and byte_size(secret) >= 16,
         :ok <- authenticate(conn, provider, secret, body),
         :ok <- scope(settings, provider, conn.body_params) do
      if GitLabAdapter.event_driven?(settings),
        do: acknowledge_gitlab_event(conn, settings.disabled),
        else: acknowledge_tracker(conn, provider, settings.disabled)
    else
      _ -> conn |> put_status(403) |> json(%{error: "webhook_rejected"})
    end
  end

  defp acknowledge_gitlab_event(conn, true), do: acknowledge(conn, true, merge_hint("gitlab", conn.body_params))

  defp acknowledge_gitlab_event(conn, false) do
    case issue_event(conn.body_params) do
      {iid, terminal_change?} -> acknowledge_issue_event(conn, Orchestrator.request_issue_event(iid, terminal_change?))
      nil -> acknowledge_non_issue_event(conn, false, false)
    end
  end

  defp issue_event(%{"object_kind" => "issue", "object_attributes" => %{"iid" => iid, "action" => action}})
       when is_integer(iid) and iid > 0 and action in ["open", "update", "close", "reopen"],
       do: {iid, action in ["close", "reopen"]}

  defp issue_event(%{"object_kind" => "note", "object_attributes" => %{"noteable_type" => "Issue", "action" => action}, "issue" => %{"iid" => iid}})
       when is_integer(iid) and iid > 0 and action in ["create", "update"],
       do: {iid, false}

  defp issue_event(_), do: nil

  defp acknowledge_issue_event(conn, :queued), do: conn |> put_status(202) |> json(%{accepted: true})
  defp acknowledge_issue_event(conn, :unavailable), do: conn |> put_status(503) |> json(%{error: "issue_event_unavailable"})

  defp acknowledge_non_issue_event(conn, disabled, review_delivered) do
    dependency = if disabled, do: :ignored, else: enqueue_merge_dependents(conn.body_params)
    cleanup = enqueue_merge_hint(merge_hint("gitlab", conn.body_params))

    cond do
      dependency == :unavailable -> acknowledge_issue_event(conn, :unavailable)
      cleanup == :unavailable -> conn |> put_status(503) |> json(%{error: "merge_cleanup_unavailable"})
      dependency == :queued or cleanup == :queued or review_delivered -> acknowledge_issue_event(conn, :queued)
      true -> conn |> put_status(202) |> json(%{accepted: false, ignored: true})
    end
  end

  defp enqueue_merge_dependents(%{
         "object_kind" => "merge_request",
         "project" => %{"path_with_namespace" => project},
         "object_attributes" => %{"action" => action, "iid" => iid}
       })
       when is_binary(project) and is_integer(iid) and iid > 0 and action in ["open", "update", "merge", "close", "reopen"] do
    Orchestrator.request_merge_dependents(project, iid)
  end

  defp enqueue_merge_dependents(_), do: :ignored

  defp acknowledge_tracker(%{body_params: %{"object_kind" => "note"}} = conn, "gitlab", disabled) do
    case conn.body_params do
      %{"object_attributes" => %{"noteable_type" => "Issue"}, "issue" => %{"iid" => iid}}
      when is_integer(iid) and iid > 0 ->
        acknowledge_refresh(conn, disabled)

      _ ->
        conn |> put_status(202) |> json(%{accepted: false, ignored: true})
    end
  end

  defp acknowledge_tracker(conn, provider, disabled),
    do: acknowledge(conn, disabled, merge_hint(provider, conn.body_params))

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
      acknowledge(conn, config["disabled"] == true, nil)
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
      tracker = Config.settings!().tracker

      if GitLabAdapter.event_driven?(tracker),
        do: acknowledge_non_issue_event(conn, tracker.disabled, config["disabled"] != true),
        else: acknowledge(conn, config["disabled"] == true, merge_hint(provider, conn.body_params))
    else
      _ -> conn |> put_status(403) |> json(%{error: "review_event_rejected"})
    end
  end

  defp merge_hint("gitlab", %{
         "object_kind" => "merge_request",
         "project" => %{"id" => project_id, "path_with_namespace" => project},
         "object_attributes" => %{"action" => "merge", "state" => "merged", "iid" => iid}
       })
       when is_integer(project_id) and project_id > 0 and is_integer(iid) and iid > 0 and is_binary(project) do
    %{provider: "gitlab", project_id: project_id, project: project, iid: iid}
  end

  defp merge_hint(_, _), do: nil

  defp acknowledge(conn, disabled, hint) do
    case enqueue_merge_hint(hint) do
      :queued when disabled -> conn |> put_status(202) |> json(%{accepted: true})
      :queued -> acknowledge_refresh(conn, false)
      :disabled -> acknowledge_refresh(conn, disabled)
      :unavailable -> conn |> put_status(503) |> json(%{error: "merge_cleanup_unavailable"})
    end
  end

  defp enqueue_merge_hint(nil), do: :disabled
  defp enqueue_merge_hint(hint), do: Orchestrator.request_merge_cleanup(hint)

  defp acknowledge_refresh(conn, true), do: conn |> put_status(202) |> json(%{accepted: false, disabled: true})

  defp acknowledge_refresh(conn, false) do
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
