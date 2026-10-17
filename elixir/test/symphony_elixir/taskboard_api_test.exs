defmodule SymphonyElixirWeb.TaskboardApiTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest

  alias Plug.Conn

  @endpoint SymphonyElixirWeb.Endpoint

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    issue = %Issue{
      id: "1",
      identifier: "MOCK-1",
      title: "Mock Issue",
      description: "A mock Issue description.",
      state: "Todo",
      labels: ["symphony:ready"],
      dispatchable: true
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    Application.put_env(:symphony_elixir, :taskboard_refresh_fun, fn -> :ok end)

    Application.put_env(:symphony_elixir, :taskboard_memory_details, %{
      "MOCK-1" => %{
        "description" => issue.description,
        "comments" => [
          %{id: 1, author: "meichao", body: "Fixture comment", engine: false, created_at: "2026-10-17T00:00:00Z"}
        ],
        "deliveries" => [],
        "execution" => nil
      }
    })

    settings = taskboard_settings()
    endpoint_config = Application.get_env(:symphony_elixir, @endpoint, [])

    Application.put_env(
      :symphony_elixir,
      @endpoint,
      endpoint_config
      |> Keyword.merge(
        server: false,
        secret_key_base: String.duplicate("s", 64),
        taskboard_settings_fun: fn -> settings end,
        runtime_snapshot_fun: fn -> %{running: [], retrying: [], blocked: []} end
      )
    )

    on_exit(fn ->
      Application.put_env(:symphony_elixir, @endpoint, endpoint_config)
      Application.delete_env(:symphony_elixir, :taskboard_memory_details)
      Application.delete_env(:symphony_elixir, :taskboard_refresh_fun)
    end)

    start_supervised!({@endpoint, []})

    {:ok, settings: settings}
  end

  test "serves Taskboard, Runtime, static assets, and read APIs" do
    taskboard_conn = get(build_conn(), "/")
    assert taskboard_conn.status == 200
    assert html_response(taskboard_conn, 200) =~ "taskboard-app"

    runtime_conn = get(build_conn(), "/runtime")
    assert runtime_conn.status == 200
    assert html_response(runtime_conn, 200) =~ "Operations Dashboard"

    assert response(get(build_conn(), "/taskboard.css"), 200) =~ ".taskboard-board"
    assert response(get(build_conn(), "/taskboard.js"), 200) =~ "/api/v1/taskboard"

    state = json_response(get(build_conn(), "/api/v1/taskboard"), 200)
    assert state["columns"] == ["Todo", "In Progress", "Human Review", "Done"]
    assert [%{"issue_identifier" => "MOCK-1", "column" => "Todo"}] = state["cards"]
    assert {:ok, state_json} = Jason.encode(state)
    refute state_json =~ "operator-control"
    refute state_json =~ "operator-provider"

    detail = json_response(get(build_conn(), "/api/v1/taskboard/issues/memory-mock-issues/MOCK-1"), 200)
    assert detail["issue"]["identifier"] == "MOCK-1"
    assert [%{"body" => "Fixture comment"}] = detail["comments"]
  end

  test "requires the operator token for creation, comments, and transitions" do
    body = %{
      "project_id" => "memory-mock-issues",
      "title" => "Created by operator",
      "description" => "Mock body",
      "labels" => ["type:research"]
    }

    unauthorized =
      build_conn()
      |> Conn.put_req_header("content-type", "application/json")
      |> post("/api/v1/taskboard/issues", Jason.encode!(body))

    assert json_response(unauthorized, 401)["error"]["code"] == "operator_token_required"

    created =
      build_conn()
      |> Conn.put_req_header("content-type", "application/json")
      |> Conn.put_req_header("x-symphony-taskboard-token", "operator-control")
      |> post("/api/v1/taskboard/issues", Jason.encode!(body))

    assert %{"identifier" => "MOCK-" <> _} = json_response(created, 201)

    comment =
      build_conn()
      |> Conn.put_req_header("content-type", "application/json")
      |> Conn.put_req_header("x-symphony-taskboard-token", "operator-control")
      |> post(
        "/api/v1/taskboard/issues/memory-mock-issues/MOCK-1/comments",
        Jason.encode!(%{"body" => "Reply from operator"})
      )

    assert %{"body" => "Reply from operator"} = json_response(comment, 200)

    action =
      build_conn()
      |> Conn.put_req_header("content-type", "application/json")
      |> Conn.put_req_header("x-symphony-taskboard-token", "operator-control")
      |> post(
        "/api/v1/taskboard/issues/memory-mock-issues/MOCK-1/actions/dispatch",
        Jason.encode!(%{})
      )

    assert %{"action" => "dispatch", "detail" => "queued for dispatch"} =
             json_response(action, 200)
  end

  defp taskboard_settings do
    settings = Config.settings!()

    tracker = %{
      settings.tracker
      | provider: %{"repo" => "mock/issues", "project_path" => "mock/issues"},
        required_labels: ["symphony:ready"]
    }

    taskboard = %{
      settings.taskboard
      | enabled: true,
        control_token: "operator-control",
        provider_token: "operator-provider",
        projects: []
    }

    %{settings | tracker: tracker, taskboard: taskboard}
  end
end
