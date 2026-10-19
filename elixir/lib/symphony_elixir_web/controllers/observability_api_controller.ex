defmodule SymphonyElixirWeb.ObservabilityApiController do
  alias SymphonyElixir.RuntimeContext

  @moduledoc """
  JSON API for Symphony observability data.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.{Execution, RunJournal}
  alias SymphonyElixirWeb.{Endpoint, Presenter}

  @spec state(Conn.t(), map()) :: Conn.t()
  def state(conn, _params) do
    json(conn, Presenter.state_payload(orchestrator(), snapshot_timeout_ms()))
  end

  @spec run(Conn.t(), map()) :: Conn.t()
  def run(conn, %{"issue_identifier" => id}) do
    if Execution.enabled?() do
      directory = RunJournal.directory(Execution.journal_root(), id)

      case RunJournal.read(directory) do
        {:ok, %{} = record} ->
          json(
            conn,
            Map.take(record, [
              "issue_id",
              "issue_url",
              "phase",
              "attempt_id",
              "attempt_count",
              "thread_id",
              "turn_id",
              "handoff",
              "blocker_reason",
              "updated_at",
              "events"
            ])
          )

        _ ->
          error_response(conn, 404, "run_not_found", "Run not found")
      end
    else
      error_response(conn, 404, "run_not_found", "Run not found")
    end
  end

  @spec issue(Conn.t(), map()) :: Conn.t()
  def issue(conn, %{"issue_identifier" => issue_identifier}) do
    case Presenter.issue_payload(issue_identifier, orchestrator(), snapshot_timeout_ms()) do
      {:ok, payload} ->
        json(conn, payload)

      {:error, :issue_not_found} ->
        error_response(conn, 404, "issue_not_found", "Issue not found")
    end
  end

  @spec refresh(Conn.t(), map()) :: Conn.t()
  def refresh(conn, _params) do
    case Presenter.refresh_payload(orchestrator()) do
      {:ok, payload} ->
        conn
        |> put_status(202)
        |> json(payload)

      {:error, :unavailable} ->
        error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")
    end
  end

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params) do
    error_response(conn, 405, "method_not_allowed", "Method not allowed")
  end

  @spec not_found(Conn.t(), map()) :: Conn.t()
  def not_found(conn, _params) do
    error_response(conn, 404, "not_found", "Route not found")
  end

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end

  defp orchestrator do
    case Endpoint.config(:orchestrator) do
      value when value in [nil, SymphonyElixir.Orchestrator] -> RuntimeContext.server(SymphonyElixir.Orchestrator)
      server -> server
    end
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end
end
