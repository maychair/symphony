defmodule SymphonyElixirWeb.TaskboardLive do
  @moduledoc "Repository Issue Taskboard with a side-panel review workflow."

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
        </div>

        <div class="taskboard-filters">
          <label class="filter-control filter-search">
            <span>Search</span>
            <input id="taskboard-filter" type="search" placeholder="Issue, title, label…" autocomplete="off" />
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
          <button id="taskboard-new" class="compact-button" type="button">
            New issue
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
        <aside id="taskboard-detail" class="taskboard-detail" aria-label="Issue details">
          <div class="detail-empty">
            <span class="detail-empty-mark">⌘</span>
            <h2>Select an Issue</h2>
            <p>Read the full description, comments, execution evidence, and linked PR/MR without leaving the board.</p>
            <p class="keyboard-hint"><kbd>j</kbd> / <kbd>k</kbd> navigate · <kbd>Ctrl</kbd>+<kbd>K</kbd> commands</p>
          </div>
        </aside>
      </main>

      <div id="taskboard-create" class="taskboard-overlay hidden" role="dialog" aria-modal="true" aria-labelledby="create-title">
        <form id="taskboard-create-form" class="taskboard-sheet create-sheet">
          <header class="sheet-head">
            <div>
              <p class="eyebrow">Draft first</p>
              <h2 id="create-title">Create Issue</h2>
            </div>
            <button type="button" class="icon-button" data-close="taskboard-create" aria-label="Close">×</button>
          </header>
          <div class="create-fields">
            <label>
              <span>Project</span>
              <select id="create-project" required></select>
            </label>
            <label>
              <span>Title</span>
              <input id="create-title-input" maxlength="240" required autocomplete="off" />
            </label>
            <label>
              <span>Labels</span>
              <input id="create-labels" placeholder="type:development, priority:p2" autocomplete="off" />
            </label>
            <label class="create-description">
              <span>Description</span>
              <textarea id="create-description" rows="14" placeholder="Goal, scope, permissions, acceptance criteria, and delivery evidence."></textarea>
            </label>
          </div>
          <footer class="sheet-foot">
            <span>Draft is stored locally. Publishing creates the tracker Issue.</span>
            <button type="button" class="secondary" data-close="taskboard-create">Cancel</button>
            <button type="submit">Confirm and create</button>
          </footer>
        </form>
      </div>

      <div id="taskboard-palette" class="taskboard-overlay hidden" role="dialog" aria-modal="true" aria-label="Command palette">
        <div class="taskboard-sheet palette-sheet">
          <input id="taskboard-palette-input" type="text" placeholder="Search issues or commands…" autocomplete="off" />
          <div id="taskboard-palette-list" class="palette-list"></div>
        </div>
      </div>

      <div id="taskboard-help" class="taskboard-overlay hidden" role="dialog" aria-modal="true" aria-labelledby="help-title">
        <div class="taskboard-sheet help-sheet">
          <header class="sheet-head">
            <h2 id="help-title">Keyboard and board actions</h2>
            <button type="button" class="icon-button" data-close="taskboard-help" aria-label="Close">×</button>
          </header>
          <dl class="shortcut-grid">
            <dt><kbd>Ctrl</kbd>+<kbd>K</kbd></dt><dd>Command palette</dd>
            <dt><kbd>j</kbd> / <kbd>k</kbd></dt><dd>Next / previous Issue</dd>
            <dt><kbd>/</kbd></dt><dd>Focus search</dd>
            <dt><kbd>n</kbd></dt><dd>Create an Issue draft</dd>
            <dt><kbd>r</kbd></dt><dd>Refresh the board</dd>
            <dt><kbd>Esc</kbd></dt><dd>Close panel or clear focus</dd>
          </dl>
          <p class="help-note">
            Drag actions are limited to Dispatch, Pause, Rework, and Accept. Invalid transitions are rejected by the API.
          </p>
        </div>
      </div>

      <div id="taskboard-toasts" class="taskboard-toasts" aria-live="polite"></div>
    </section>
    """
  end
end
