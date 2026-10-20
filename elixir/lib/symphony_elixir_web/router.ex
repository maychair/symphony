defmodule SymphonyElixirWeb.Router do
  @moduledoc """
  Router for Symphony's observability dashboard and API.
  """

  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :repository do
    plug(SymphonyElixirWeb.RepositoryScope)
  end

  pipeline :browser do
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {SymphonyElixirWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  scope "/", SymphonyElixirWeb do
    get("/dashboard.css", StaticAssetController, :dashboard_css)
    get("/taskboard.css", StaticAssetController, :taskboard_css)
    get("/taskboard.js", StaticAssetController, :taskboard_js)
    get("/favicon.png", StaticAssetController, :favicon)
    get("/vendor/phoenix_html/phoenix_html.js", StaticAssetController, :phoenix_html_js)
    get("/vendor/phoenix/phoenix.js", StaticAssetController, :phoenix_js)
    get("/vendor/phoenix_live_view/phoenix_live_view.js", StaticAssetController, :phoenix_live_view_js)
  end

  scope "/", SymphonyElixirWeb do
    pipe_through(:browser)

    live("/", TaskboardLive, :index)
    live("/runtime", DashboardLive, :index)
  end

  scope "/", SymphonyElixirWeb do
    pipe_through(:repository)

    post("/api/v1/webhooks/:provider", WebhookController, :receive_event)
    get("/api/v1/taskboard", TaskboardApiController, :state)
    get("/api/v1/taskboard/projects/:project_id", TaskboardApiController, :project)
    get("/api/v1/taskboard/issues/:project_id/:issue_identifier", TaskboardApiController, :issue)
    post("/api/v1/taskboard/issues", TaskboardApiController, :create_issue)
    post("/api/v1/taskboard/issues/:project_id/:issue_identifier/comments", TaskboardApiController, :comment)

    post(
      "/api/v1/taskboard/issues/:project_id/:issue_identifier/actions/:action",
      TaskboardApiController,
      :transition
    )

    get("/api/v1/runs/:issue_identifier", ObservabilityApiController, :run)
    get("/api/v1/state", ObservabilityApiController, :state)

    match(:*, "/", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/state", ObservabilityApiController, :method_not_allowed)
    post("/api/v1/refresh", ObservabilityApiController, :refresh)
    match(:*, "/api/v1/refresh", ObservabilityApiController, :method_not_allowed)
    get("/api/v1/:issue_identifier", ObservabilityApiController, :issue)
    match(:*, "/api/v1/:issue_identifier", ObservabilityApiController, :method_not_allowed)
    match(:*, "/*path", ObservabilityApiController, :not_found)
  end
end
