defmodule SymphonyElixirWeb.WorkbenchController do
  @moduledoc "Authenticated operator bridge. Browser clients use the local workbench proxy."
  use Phoenix.Controller, formats: [:json]
  alias SymphonyElixir.{Config, Orchestrator}
  alias SymphonyElixir.Beads.Workbench
  import Plug.Conn

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params), do: dispatch(conn, fn settings -> Workbench.list(settings) end)

  @spec decide(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def decide(conn, %{"issue" => id, "gate" => gate} = params) do
    dispatch(conn, fn settings ->
      result = Workbench.decide(settings, id, gate, params)
      Orchestrator.request_refresh()
      result
    end)
  end

  @spec artifact(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def artifact(conn, %{"issue" => id, "gate" => gate}) do
    if authorized?(conn) do
      case Workbench.get_artifact(Config.settings!().tracker, id, gate) do
        {:ok, bytes} -> conn |> put_resp_content_type("text/plain") |> put_resp_header("x-content-type-options", "nosniff") |> send_resp(200, bytes)
        error -> reject(conn, error)
      end
    else
      conn |> put_status(403) |> json(%{error: "operator_authentication_required"})
    end
  end

  defp dispatch(conn, operation) do
    if authorized?(conn) do
      case operation.(Config.settings!().tracker) do
        {:ok, result} -> json(conn, %{result: result})
        error -> reject(conn, error)
      end
    else
      conn |> put_status(403) |> json(%{error: "operator_authentication_required"})
    end
  rescue
    _ -> conn |> put_status(503) |> json(%{error: "workbench_unavailable"})
  end

  defp authorized?(conn) do
    expected = System.get_env("SYMPHONY_WORKBENCH_TOKEN")
    actual = List.first(get_req_header(conn, "x-symphony-workbench-token"))
    is_binary(expected) and byte_size(expected) >= 32 and is_binary(actual) and Plug.Crypto.secure_compare(expected, actual)
  end

  defp reject(conn, {:error, reason}), do: conn |> put_status(409) |> json(%{error: inspect(reason)})
  defp reject(conn, _), do: conn |> put_status(409) |> json(%{error: "operation_refused"})
end
