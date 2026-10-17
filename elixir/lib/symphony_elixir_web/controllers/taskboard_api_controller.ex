defmodule SymphonyElixirWeb.TaskboardApiController do
  @moduledoc "JSON API for the Taskboard projection and operator actions."

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.{Config, Taskboard}
  alias SymphonyElixirWeb.Endpoint

  @error_statuses %{
    taskboard_project_not_found: {404, "project_not_found"},
    taskboard_issue_not_found: {404, "issue_not_found"},
    invalid_taskboard_transition: {409, "invalid_taskboard_transition"},
    unsupported_taskboard_action: {422, "unsupported_taskboard_action"},
    issue_not_retrying: {409, "issue_not_retrying"},
    orchestrator_unavailable: {503, "orchestrator_unavailable"},
    operator_identity_not_configured: {503, "operator_identity_not_configured"},
    operator_control_token_not_configured: {503, "operator_control_token_not_configured"},
    remote_operator_token_not_configured: {503, "remote_operator_token_not_configured"},
    issue_title_required: {422, "issue_title_required"},
    comment_body_required: {422, "comment_body_required"},
    issue_closed: {409, "issue_closed"}
  }

  @spec state(Conn.t(), map()) :: Conn.t()
  def state(conn, _params) do
    json(conn, Taskboard.snapshot(taskboard_opts()))
  end

  @spec project(Conn.t(), map()) :: Conn.t()
  def project(conn, %{"project_id" => project_id}) do
    respond(conn, Taskboard.project_snapshot(project_id, taskboard_opts()))
  end

  @spec issue(Conn.t(), map()) :: Conn.t()
  def issue(conn, %{"project_id" => project_id, "issue_identifier" => identifier}) do
    respond(conn, Taskboard.issue_detail(project_id, identifier, taskboard_opts()))
  end

  @spec create_issue(Conn.t(), map()) :: Conn.t()
  def create_issue(conn, params) do
    with_operator(conn, fn ->
      project_id = params["project_id"]

      case Taskboard.create_issue(project_id, params, taskboard_opts()) do
        {:ok, payload} -> json(put_status(conn, 201), payload)
        error -> task_error(conn, error)
      end
    end)
  end

  @spec comment(Conn.t(), map()) :: Conn.t()
  def comment(conn, %{"project_id" => project_id, "issue_identifier" => identifier} = params) do
    with_operator(conn, fn ->
      respond(conn, Taskboard.comment(project_id, identifier, params["body"], taskboard_opts()))
    end)
  end

  @spec transition(Conn.t(), map()) :: Conn.t()
  def transition(conn, %{
        "project_id" => project_id,
        "issue_identifier" => identifier,
        "action" => action
      }) do
    with_operator(conn, fn ->
      body = Map.drop(conn.body_params, ["project_id", "issue_identifier", "action"])
      respond(conn, Taskboard.perform_action(project_id, identifier, action, body, taskboard_opts()))
    end)
  end

  defp with_operator(conn, fun) do
    if Taskboard.authorized?(settings(), conn |> get_req_header("x-symphony-taskboard-token") |> List.first()) do
      fun.()
    else
      error(conn, 401, "operator_token_required", "A valid Taskboard operator token is required")
    end
  end

  defp respond(conn, {:ok, payload}), do: json(conn, payload)
  defp respond(conn, error), do: task_error(conn, error)

  defp task_error(conn, {:error, reason}) do
    {status, code} =
      Map.get(@error_statuses, reason, {502, "taskboard_operation_failed"})

    error(conn, status, code, format_reason(reason))
  end

  defp format_reason(reason) when is_atom(reason), do: reason |> Atom.to_string() |> String.replace("_", " ")
  defp format_reason(reason), do: inspect(reason)

  defp error(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end

  defp settings do
    fun = Endpoint.config(:taskboard_settings_fun)

    if is_function(fun, 0) do
      fun.()
    else
      Config.settings!()
    end
  end

  defp taskboard_opts do
    opts = [settings: settings()]

    case Endpoint.config(:runtime_snapshot_fun) do
      fun when is_function(fun, 0) -> Keyword.put(opts, :runtime_snapshot_fun, fun)
      _ -> opts
    end
  end
end
