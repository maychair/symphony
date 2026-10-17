// Symphony Taskboard. Tracker content is rendered only with DOM text nodes.

'use strict';

(() => {
  const $ = (selector) => document.querySelector(selector);
  const ROOT = $('#taskboard-app');
  if (!ROOT) return;

  const state = {
    snapshot: null,
    filter: '',
    project: '',
    repo: '',
    loading: false,
    requestError: '',
  };

  const el = (tag, className, text) => {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined && text !== null) node.textContent = String(text);
    return node;
  };

  const clear = (node) => {
    while (node.firstChild) node.removeChild(node.firstChild);
  };

  const safe = (value) => (value === undefined || value === null ? '' : String(value));
  const trackerUrl = (value) => /^https?:\/\//i.test(safe(value)) ? value : null;

  const shortTime = (value) => {
    if (!value) return '';
    const date = new Date(value);
    if (Number.isNaN(date.getTime())) return safe(value);
    const seconds = Math.round((Date.now() - date.getTime()) / 1000);
    if (seconds < 0) return date.toLocaleString();
    if (seconds < 60) return `${seconds}s ago`;
    if (seconds < 3600) return `${Math.floor(seconds / 60)}m ago`;
    if (seconds < 86400) return `${Math.floor(seconds / 3600)}h ago`;
    return date.toLocaleDateString();
  };

  async function jsonRequest(path) {
    const response = await fetch(path, { headers: { accept: 'application/json' } });
    let payload = null;
    try {
      payload = await response.json();
    } catch (_) {
      payload = null;
    }
    if (!response.ok) {
      throw new Error(payload?.error?.message || `Request failed (${response.status})`);
    }
    return payload;
  }

  function cardMatches(card) {
    if (state.project && card.project_id !== state.project) return false;
    if (state.repo && card.repo !== state.repo) return false;
    if (!state.filter) return true;
    const query = state.filter.toLowerCase();
    return [
      card.issue_identifier,
      card.title,
      card.summary,
      card.project,
      card.repo,
      card.agent_status,
      card.human_action?.summary,
      ...(card.labels || []),
      ...(card.artifacts || []).flatMap((artifact) => [artifact.label, artifact.title]),
    ]
      .filter(Boolean)
      .some((value) => String(value).toLowerCase().includes(query));
  }

  function renderFilters() {
    if (!state.snapshot) return;

    const projectSelect = $('#project-filter');
    const previousProject = state.project;
    clear(projectSelect);
    projectSelect.appendChild(new Option('All projects', ''));
    state.snapshot.projects.forEach((project) => {
      const option = new Option(`${project.name}${project.error ? ' (unavailable)' : ''}`, project.id);
      projectSelect.appendChild(option);
    });
    projectSelect.value = state.snapshot.projects.some((project) => project.id === previousProject)
      ? previousProject
      : '';
    state.project = projectSelect.value;

    const repos = [...new Set(
      state.snapshot.projects
        .filter((project) => !state.project || project.id === state.project)
        .map((project) => project.repo)
        .filter(Boolean),
    )].sort();

    const repoSelect = $('#repo-filter');
    const previousRepo = state.repo;
    clear(repoSelect);
    repoSelect.appendChild(new Option('All repos', ''));
    repos.forEach((repo) => repoSelect.appendChild(new Option(repo, repo)));
    repoSelect.value = repos.includes(previousRepo) ? previousRepo : '';
    state.repo = repoSelect.value;
  }

  function renderStats() {
    const host = $('#taskboard-stats');
    clear(host);
    if (!state.snapshot) return;

    const stat = (label, value) => {
      const node = el('span', 'taskboard-stat');
      node.appendChild(el('strong', null, value));
      node.appendChild(document.createTextNode(label));
      host.appendChild(node);
    };

    stat(' issues', state.snapshot.cards.length);
    stat(' projects', state.snapshot.projects.length);
    (state.snapshot.columns || []).forEach((column) => {
      stat(` ${column.toLowerCase()}`, state.snapshot.counts[column] || 0);
    });
    if ((state.snapshot.errors || []).length) {
      stat(' unavailable', state.snapshot.errors.length);
    }
  }

  function renderBanner() {
    const banner = $('#taskboard-banner');
    const errors = state.snapshot?.errors || [];
    const messages = errors.map((error) => `${error.project || error.project_id}: ${error.error}`);
    if (state.requestError) messages.unshift(state.requestError);
    if (!messages.length) {
      banner.classList.add('hidden');
      clear(banner);
      return;
    }
    banner.classList.remove('hidden');
    clear(banner);
    messages.forEach((message) => banner.appendChild(el('div', null, message)));
  }

  function agentTone(status) {
    const normalized = safe(status).toLowerCase();
    if (normalized.includes('run')) return 'running';
    if (normalized.includes('retry') || normalized.includes('waiting to run')) return 'waiting';
    if (normalized.includes('block')) return 'blocked';
    if (normalized.includes('fail')) return 'failed';
    if (normalized.includes('accept')) return 'accepted';
    return 'idle';
  }

  function externalLink(url, className, text, ariaLabel) {
    const href = trackerUrl(url);
    if (!href) return null;

    const node = el('a', className, text);
    node.href = href;
    node.target = '_blank';
    node.rel = 'noopener noreferrer';
    if (ariaLabel) node.setAttribute('aria-label', ariaLabel);
    return node;
  }

  function taskCard(card) {
    const url = trackerUrl(card.url);
    const node = el('article', `task-card${url ? '' : ' unavailable'}`);
    node.dataset.project = card.project_id;
    node.dataset.identifier = card.issue_identifier;
    node.dataset.column = card.column;

    if (url) {
      node.dataset.hasIssueLink = 'true';
    } else {
      node.setAttribute('aria-disabled', 'true');
    }

    const head = el('div', 'task-card-head');
    head.appendChild(el('span', 'task-card-id', card.issue_identifier));
    head.appendChild(el('span', `agent-dot ${agentTone(card.agent_status)}`));
    if (card.priority !== null && card.priority !== undefined) {
      head.appendChild(el('span', 'task-card-priority', `P${card.priority}`));
    }
    node.appendChild(head);

    const title = el('h3');
    const titleLink = externalLink(
      url,
      'task-card-title-link',
      card.title || 'Untitled Issue',
      `Open ${card.issue_identifier || 'Issue'} in ${card.kind || 'tracker'}: ${card.title || 'Untitled Issue'}`,
    );
    if (titleLink) {
      title.appendChild(titleLink);
    } else {
      title.textContent = card.title || 'Untitled Issue';
    }
    node.appendChild(title);

    if (card.summary) node.appendChild(el('p', 'task-card-summary', card.summary));

    const meta = el('div', 'task-card-meta');
    meta.appendChild(el('span', null, card.project || card.repo || 'Repository'));
    if (card.kind) {
      meta.appendChild(el('span', 'separator', '·'));
      meta.appendChild(el('span', null, card.kind));
    }
    node.appendChild(meta);

    if (card.labels?.length) {
      const labels = el('div', 'task-card-labels');
      card.labels.slice(0, 5).forEach((label) => labels.appendChild(el('span', 'task-card-label', label)));
      node.appendChild(labels);
    }

    const action = card.human_action;
    if (action?.summary) {
      const actionNode = el('div', `task-card-action${action.required ? ' required' : ''}`);
      actionNode.appendChild(
        el('span', 'task-card-action-label', action.required ? 'Needs your action' : 'Status'),
      );
      actionNode.appendChild(el('p', null, action.summary));
      node.appendChild(actionNode);
    }

    const foot = el('div', 'task-card-foot');
    foot.appendChild(el('span', 'agent-status', card.agent_status || 'idle'));
    foot.appendChild(el('span', 'task-card-time', shortTime(card.updated_at)));
    node.appendChild(foot);

    const links = el('div', 'task-card-links');
    const issueLink = externalLink(url, 'task-card-link issue', 'Issue ↗');
    if (issueLink) links.appendChild(issueLink);

    (card.artifacts || []).forEach((artifact) => {
      const artifactLink = externalLink(
        artifact.url,
        `task-card-link artifact ${safe(artifact.kind).toLowerCase()}`,
        `${artifact.label || 'Open delivery'} ↗`,
        artifact.title ? `${artifact.label || 'Open delivery'}: ${artifact.title}` : null,
      );
      if (artifactLink) links.appendChild(artifactLink);
    });

    if (links.childElementCount) {
      node.appendChild(links);
    } else {
      node.appendChild(el('div', 'task-card-links unavailable', 'Tracker link unavailable'));
    }

    return node;
  }

  function renderBoard() {
    const board = $('#taskboard-board');
    clear(board);
    if (!state.snapshot) {
      board.appendChild(el('div', 'board-empty', 'Loading issues…'));
      return;
    }

    state.snapshot.columns.forEach((column, index) => {
      const cards = state.snapshot.cards.filter((card) => card.column === column && cardMatches(card));
      const wrap = el('section', 'board-column');
      wrap.dataset.column = column;

      const head = el('header', 'board-column-head');
      head.appendChild(el('h2', null, column));
      head.appendChild(el('span', 'board-column-count', cards.length));
      head.appendChild(el('span', 'board-column-key', index + 1));
      wrap.appendChild(head);

      const list = el('div', 'board-column-list');
      if (cards.length) {
        cards.forEach((card) => list.appendChild(taskCard(card)));
      } else {
        list.appendChild(el('div', 'board-empty', 'No Issues'));
      }
      wrap.appendChild(list);
      board.appendChild(wrap);
    });
  }

  function render() {
    renderFilters();
    renderStats();
    renderBanner();
    renderBoard();
  }

  async function refresh() {
    if (state.loading) return;
    state.loading = true;
    const connection = $('#taskboard-connection');
    try {
      state.snapshot = await jsonRequest('/api/v1/taskboard');
      state.requestError = '';
      connection.textContent = 'Live';
      connection.classList.remove('offline');
      render();
    } catch (error) {
      state.requestError = error.message;
      connection.textContent = 'Offline';
      connection.classList.add('offline');
      renderBanner();
    } finally {
      state.loading = false;
    }
  }

  function openHelp() {
    $('#taskboard-help').classList.remove('hidden');
    $('#taskboard-help-close').focus();
  }

  function closeHelp() {
    $('#taskboard-help').classList.add('hidden');
  }

  function focusSearch() {
    const search = $('#taskboard-filter');
    search.focus();
    search.select();
  }

  $('#taskboard-filter').addEventListener('input', (event) => {
    state.filter = event.target.value;
    renderBoard();
  });
  $('#project-filter').addEventListener('change', (event) => {
    state.project = event.target.value;
    state.repo = '';
    render();
  });
  $('#repo-filter').addEventListener('change', (event) => {
    state.repo = event.target.value;
    renderBoard();
  });
  $('#taskboard-refresh').addEventListener('click', refresh);
  $('#taskboard-help-button').addEventListener('click', openHelp);
  $('#taskboard-help-close').addEventListener('click', closeHelp);
  $('#taskboard-help').addEventListener('click', (event) => {
    if (event.target === event.currentTarget) closeHelp();
  });

  document.addEventListener('keydown', (event) => {
    const inField = ['INPUT', 'TEXTAREA', 'SELECT'].includes(event.target.tagName);
    const helpOpen = !$('#taskboard-help').classList.contains('hidden');

    if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === 'k') {
      event.preventDefault();
      closeHelp();
      focusSearch();
      return;
    }

    if (event.key === 'Escape') {
      if (helpOpen) {
        event.preventDefault();
        closeHelp();
      } else if (inField) {
        event.target.blur();
      }
      return;
    }

    if (inField) return;

    if (event.key === '/') {
      event.preventDefault();
      focusSearch();
    } else if (event.key === 'r') {
      event.preventDefault();
      refresh();
    } else if (event.key === '?') {
      event.preventDefault();
      openHelp();
    }
  });

  const refreshMs = Math.max(1000, Number(ROOT.dataset.refreshMs) || 5000);
  window.setInterval(() => {
    if (document.visibilityState === 'visible') refresh();
  }, refreshMs);
  refresh();
})();
