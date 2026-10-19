defmodule SymphonyElixirWeb.RepositoryScope do
  @moduledoc "Select an explicit repository before any scoped HTTP read or effect."
  import Plug.Conn
  alias SymphonyElixir.{RepositoryService, RuntimeContext}

  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _) do
    RuntimeContext.install(nil)

    conn =
      register_before_send(conn, fn sent ->
        RuntimeContext.install(nil)
        sent
      end)

    conn = fetch_query_params(conn)
    {id, conn} = selection(conn)

    case {RepositoryService.repositories(), id} do
      {[], _} ->
        conn

      {_, nil} ->
        unscoped(conn)

      {repositories, id} ->
        case Enum.find(repositories, &(&1.id == id)) do
          nil ->
            reject(conn, 404, "repository_not_found")

          context ->
            RuntimeContext.install(context)
            conn
        end
    end
  end

  defp selection(%{path_params: %{"project_id" => project}} = conn) do
    case String.split(project, ":", parts: 2) do
      [id, project] -> {id, %{conn | path_params: Map.put(conn.path_params, "project_id", project), params: Map.put(conn.params, "project_id", project)}}
      _ -> {conn.query_params["repository"], conn}
    end
  end

  defp selection(conn), do: {conn.query_params["repository"], conn}

  defp unscoped(conn) do
    if {conn.method, conn.request_path} in [{"GET", "/api/v1/state"}, {"GET", "/api/v1/taskboard"}, {"POST", "/api/v1/refresh"}], do: conn, else: reject(conn, 400, "repository_required")
  end

  defp reject(conn, status, reason), do: conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(%{error: %{code: reason}})) |> halt()
end
