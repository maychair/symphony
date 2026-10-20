defmodule SymphonyElixirWeb.TaskboardLive do
  @moduledoc "Read-only repository Issue board that links to the native tracker."

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.Config

  @impl true
  def mount(_params, _session, socket) do
    refresh_ms =
      case Config.settings() do
        {:ok, settings} -> settings.taskboard.refresh_ms
        _ -> 5_000
      end

    {:ok,
     socket
     |> assign(:shell, "taskboard")
     |> assign(:refresh_ms, refresh_ms)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section id="taskboard-app" class="taskboard-app" data-refresh-ms={@refresh_ms}>
      <header class="taskboard-toolbar">
        <div class="taskboard-heading">
          <p class="eyebrow">Repository work</p>
          <h1>Taskboard</h1>
          <p class="help-note">Issues: symphony:todo adds membership; symphony:ready authorizes execution. Automatic reviews follow native reviewer requests.</p>
        </div>

        <div class="taskboard-filters">
          <label class="filter-control filter-search">
            <span>Search</span>
            <input id="taskboard-filter" type="search" placeholder="Issue, MR/PR, title, label…" autocomplete="off" />
          </label>
          <label class="filter-control">
            <span>Project</span>
            <select id="project-filter">
              <option value="">All projects</option>
            </select>
          </label>
          <label class="filter-control">
            <span>Repo</span>
            <select id="repo-filter">
              <option value="">All repos</option>
            </select>
          </label>
        </div>

        <div class="toolbar-actions">
          <span id="taskboard-connection" class="connection-state">Connecting</span>
          <button id="taskboard-refresh" class="secondary compact-button" type="button">
            Refresh
          </button>
          <button id="taskboard-help-button" class="icon-button" type="button" title="Keyboard shortcuts (?)">
            ?
          </button>
        </div>
      </header>

      <div id="taskboard-stats" class="taskboard-stats" aria-live="polite"></div>
      <div id="taskboard-banner" class="taskboard-banner hidden" role="status"></div>

      <main class="taskboard-main">
        <div id="taskboard-board" class="taskboard-board" aria-label="Issue board"></div>
      </main>

      <div id="taskboard-help" class="taskboard-overlay hidden" role="dialog" aria-modal="true" aria-labelledby="help-title">
        <div class="taskboard-sheet help-sheet">
          <header class="sheet-head">
            <h2 id="help-title">Taskboard shortcuts</h2>
            <button id="taskboard-help-close" type="button" class="icon-button" aria-label="Close">×</button>
          </header>
          <dl class="shortcut-grid">
            <dt><kbd>Ctrl</kbd>+<kbd>K</kbd></dt><dd>Focus search</dd>
            <dt><kbd>/</kbd></dt><dd>Focus search</dd>
            <dt><kbd>r</kbd></dt><dd>Refresh the board</dd>
            <dt><kbd>Enter</kbd></dt><dd>Open the focused Issue</dd>
            <dt><kbd>Esc</kbd></dt><dd>Close help or clear focus</dd>
          </dl>
          <p class="help-note">
            Issue creation, comments, labels, review decisions, and merge actions stay in GitHub or GitLab.
          </p>
        </div>
      </div>
    </section>
    """
  end
end
