defmodule SymphonyElixirWeb.Layouts do
  @moduledoc """
  Shared layouts for the observability dashboard.
  """

  use Phoenix.Component

  @spec root(map()) :: Phoenix.LiveView.Rendered.t()
  def root(assigns) do
    assigns =
      assigns
      |> assign(:csrf_token, Plug.CSRFProtection.get_csrf_token())
      |> assign(:dashboard_css_url, SymphonyElixirWeb.StaticAssets.dashboard_css_url())
      |> assign(:favicon_url, SymphonyElixirWeb.StaticAssets.favicon_url())
      |> assign(:taskboard_css_url, SymphonyElixirWeb.StaticAssets.taskboard_css_url())
      |> assign(:taskboard_js_url, SymphonyElixirWeb.StaticAssets.taskboard_js_url())

    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={@csrf_token} />
        <title>Symphony Observability</title>
        <link rel="icon" type="image/png" sizes="128x128" href={@favicon_url} />
        <script defer src="/vendor/phoenix_html/phoenix_html.js"></script>
        <script defer src="/vendor/phoenix/phoenix.js"></script>
        <script defer src="/vendor/phoenix_live_view/phoenix_live_view.js"></script>
        <script>
          window.addEventListener("DOMContentLoaded", function () {
            var csrfToken = document
              .querySelector("meta[name='csrf-token']")
              ?.getAttribute("content");

            if (!window.Phoenix || !window.LiveView) return;

            var liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {
              params: {_csrf_token: csrfToken}
            });

            liveSocket.connect();
            window.liveSocket = liveSocket;
          });
        </script>
        <link rel="stylesheet" href={@dashboard_css_url} />
        <link rel="stylesheet" href={@taskboard_css_url} />
        <script defer src={@taskboard_js_url}></script>
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end

  @spec app(map()) :: Phoenix.LiveView.Rendered.t()
  def app(assigns) do
    ~H"""
    <nav class="global-nav" aria-label="Symphony">
      <a class="global-brand" href="/">
        <span class="global-brand-mark">S</span>
        <span>Symphony</span>
      </a>
      <div class="global-links">
        <a href="/" class={if Map.get(assigns, :shell) == "taskboard", do: "active"}>Taskboard</a>
        <a href="/runtime" class={if Map.get(assigns, :shell) == "runtime", do: "active"}>Runtime</a>
      </div>
    </nav>
    <main class={"app-shell app-shell-" <> to_string(Map.get(assigns, :shell, "runtime"))}>
      {@inner_content}
    </main>
    """
  end
end
