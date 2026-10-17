// Symphony Taskboard. Tracker content is rendered only with textContent.

'use strict';

(() => {
  const $ = (selector) => document.querySelector(selector);
  const ROOT = $('#taskboard-app');
  if (!ROOT) return;

  const TOKEN_KEY = 'symphony.taskboard.operatorToken';
  const DRAFT_KEY = 'symphony.taskboard.issueDraft';
  const state = {
    snapshot: null,
    selected: null,
    detail: null,
    filter: '',
    project: '',
    repo: '',
    paused: false,
    loadingDetail: false,
    paletteItems: [],
    paletteIndex: 0,
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

  const duration = (seconds) => {
    if (seconds === undefined || seconds === null) return '';
    if (seconds < 60) return `${Math.floor(seconds)}s`;
    if (seconds < 3600) return `${Math.floor(seconds / 60)}m`;
    return `${Math.floor(seconds / 3600)}h`;
  };

  let toastTimer = null;
  function toast(message, kind = 'ok') {
    const host = $('#taskboard-toasts');
    clear(host);
    host.appendChild(el('div', `taskboard-toast ${kind}`, message));
    window.clearTimeout(toastTimer);
    toastTimer = window.setTimeout(() => clear(host), 4200);
  }

  function operatorToken() {
    const current = sessionStorage.getItem(TOKEN_KEY);
    if (current) return current;
    const entered = window.prompt('Enter the Symphony Taskboard operator token');
    if (!entered) return null;
    sessionStorage.setItem(TOKEN_KEY, entered);
    return entered;
  }

  async function jsonRequest(path, options = {}) {
    const response = await fetch(path, options);
    let payload = null;
    try {
      payload = await response.json();
    } catch (_) {
      payload = null;
    }
    if (!response.ok) {
      const message = payload?.error?.message || `Request failed (${response.status})`;
      const error = new Error(message);
      error.status = response.status;
      throw error;
    }
    return payload;
  }

  async function operatorRequest(path, body) {
    const token = operatorToken();
    if (!token) throw new Error('Operator token required');
    try {
      return await jsonRequest(path, {
        method: 'POST',
        headers: {
          'content-type': 'application/json',
          'x-symphony-taskboard-token': token,
        },
        body: JSON.stringify(body || {}),
      });
    } catch (error) {
      if (error.status === 401) sessionStorage.removeItem(TOKEN_KEY);
      throw error;
    }
  }

  function selectedCard() {
    if (!state.selected || !state.snapshot) return null;
    return state.snapshot.cards.find((card) => keyFor(card) === state.selected) || null;
  }

  const keyFor = (card) => `${card.project_id}|${card.issue_identifier}`;

  function cardMatches(card) {
    if (state.project && card.project_id !== state.project) return false;
    if (state.repo && card.repo !== state.repo) return false;
    if (!state.filter) return true;
    const query = state.filter.toLowerCase();
    return [card.issue_identifier, card.title, card.summary, card.project, card.repo, ...(card.labels || [])]
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
    if (!errors.length) {
      banner.classList.add('hidden');
      clear(banner);
      return;
    }
    banner.classList.remove('hidden');
    clear(banner);
    errors.forEach((error) => {
      banner.appendChild(el('div', null, `${error.project || error.project_id}: ${error.error}`));
    });
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

  function taskCard(card) {
    const node = el('article', 'task-card');
    node.dataset.project = card.project_id;
    node.dataset.identifier = card.issue_identifier;
    node.dataset.column = card.column;
    const acceptedPendingClosure =
      card.column === 'Human Review' && (card.labels || []).includes('symphony:accept');
    node.draggable = !acceptedPendingClosure;
    node.tabIndex = 0;
    if (state.selected === keyFor(card)) node.classList.add('selected');

    const head = el('div', 'task-card-head');
    head.appendChild(el('span', 'task-card-id', card.issue_identifier));
    head.appendChild(el('span', `agent-dot ${agentTone(card.agent_status)}`));
    if (card.priority !== null && card.priority !== undefined) {
      head.appendChild(el('span', 'task-card-priority', `P${card.priority}`));
    }
    node.appendChild(head);

    node.appendChild(el('h3', null, card.title || 'Untitled Issue'));
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

    const foot = el('div', 'task-card-foot');
    foot.appendChild(el('span', 'agent-status', card.agent_status || 'idle'));
    if (card.updated_at) foot.appendChild(el('span', 'task-card-time', shortTime(card.updated_at)));
    node.appendChild(foot);

    node.addEventListener('click', () => openIssue(card.project_id, card.issue_identifier));
    node.addEventListener('keydown', (event) => {
      if (event.key === 'Enter' || event.key === ' ') {
        event.preventDefault();
        openIssue(card.project_id, card.issue_identifier);
      }
    });
    node.addEventListener('dragstart', (event) => {
      state.paused = true;
      event.dataTransfer.setData('text/plain', keyFor(card));
      event.dataTransfer.effectAllowed = 'move';
      node.classList.add('dragging');
    });
    node.addEventListener('dragend', () => {
      state.paused = false;
      node.classList.remove('dragging');
    });
    return node;
  }

  function transitionFor(card, targetColumn) {
    if (!card || card.column === targetColumn) return null;
    if (card.column === 'Todo' && targetColumn === 'In Progress') return { action: 'dispatch' };
    if (card.column === 'In Progress' && targetColumn === 'Todo') return { action: 'pause' };
    if (card.column === 'Human Review' && targetColumn === 'In Progress') return { action: 'rework' };
    if (card.column === 'Human Review' && targetColumn === 'Done') return { action: 'accept' };
    return null;
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

      wrap.addEventListener('dragover', (event) => {
        if (!state.snapshot.capabilities.drag_and_drop) return;
        event.preventDefault();
        wrap.classList.add('drop-target');
      });
      wrap.addEventListener('dragleave', () => wrap.classList.remove('drop-target'));
      wrap.addEventListener('drop', async (event) => {
        event.preventDefault();
        wrap.classList.remove('drop-target');
        state.paused = false;
        const key = event.dataTransfer.getData('text/plain');
        const card = state.snapshot.cards.find((entry) => keyFor(entry) === key);
        const transition = transitionFor(card, column);
        if (!card) return;
        const acceptedPendingClosure =
          card.column === 'Human Review' && (card.labels || []).includes('symphony:accept');
        if (acceptedPendingClosure) {
          toast('Acceptance is already recorded. Close the Issue in the tracker to move it to Done.', 'error');
          return;
        }
        if (!transition) {
          toast(`No authorized transition from ${card.column} to ${column}`, 'error');
          return;
        }
        await runAction(card, transition.action);
      });
      board.appendChild(wrap);
    });
  }

  function renderDetailEmpty(message) {
    const panel = $('#taskboard-detail');
    clear(panel);
    const empty = el('div', 'detail-empty');
    empty.appendChild(el('span', 'detail-empty-mark', '⌘'));
    empty.appendChild(el('h2', null, message || 'Select an Issue'));
    empty.appendChild(el('p', null, 'Read the complete Issue, comments, execution evidence, and linked delivery in this panel.'));
    empty.appendChild(el('p', 'keyboard-hint', 'j / k navigate · Ctrl+K commands'));
    panel.appendChild(empty);
  }

  function detailSection(title) {
    const section = el('section', 'detail-section');
    section.appendChild(el('h3', null, title));
    return section;
  }

  function formatLabel(value) {
    return safe(value).replaceAll('_', ' ');
  }

  function deliveryNode(delivery) {
    const node = el('div', 'delivery');
    const head = el('div', 'delivery-head');
    const title = delivery.title || `${String(delivery.kind || 'delivery').toUpperCase()} ${delivery.number || ''}`;
    head.appendChild(el('span', 'delivery-title', title));
    if (delivery.url && /^https?:\/\//i.test(delivery.url)) {
      const link = el('a', 'issue-link', 'open');
      link.href = delivery.url;
      link.target = '_blank';
      link.rel = 'noreferrer noopener';
      head.appendChild(link);
    }
    node.appendChild(head);

    const facts = el('div', 'delivery-facts');
    [
      delivery.merge_status && `merge: ${formatLabel(delivery.merge_status)}`,
      delivery.review_state && `review: ${formatLabel(delivery.review_state)}`,
      delivery.checks && `checks: ${formatLabel(delivery.checks)}`,
      delivery.unresolved_comments !== null &&
        delivery.unresolved_comments !== undefined &&
        `unresolved: ${delivery.unresolved_comments}`,
      delivery.unresolved_supported === false && 'unresolved comments unavailable',
    ].filter(Boolean).forEach((fact) => facts.appendChild(el('span', 'delivery-fact', fact)));
    node.appendChild(facts);
    return node;
  }

  function renderDetail() {
    if (!state.detail) {
      renderDetailEmpty(state.loadingDetail ? 'Loading Issue…' : 'Select an Issue');
      return;
    }

    const detail = state.detail;
    const card = detail.card || selectedCard() || {};
    const issue = detail.issue || {};
    const panel = $('#taskboard-detail');
    clear(panel);

    const head = el('header', 'detail-head');
    head.appendChild(el('span', 'detail-id', issue.identifier || card.issue_identifier || 'Issue'));
    if (issue.url && /^https?:\/\//i.test(issue.url)) {
      const link = el('a', 'issue-link', 'Open tracker');
      link.href = issue.url;
      link.target = '_blank';
      link.rel = 'noreferrer noopener';
      head.appendChild(link);
    }
    const close = el('button', 'icon-button', '×');
    close.type = 'button';
    close.title = 'Close details (Esc)';
    close.addEventListener('click', () => {
      state.selected = null;
      state.detail = null;
      render();
      renderDetailEmpty();
    });
    head.appendChild(close);
    panel.appendChild(head);

    panel.appendChild(el('h2', 'detail-title', issue.title || card.title || 'Untitled Issue'));
    panel.appendChild(
      el(
        'p',
        'detail-subtitle',
        [detail.project?.name || card.project, issue.state || card.tracker_state, card.column]
          .filter(Boolean)
          .join(' · '),
      ),
    );

    const labels = detailSection('Labels and state');
    const labelRow = el('div', 'task-card-labels');
    (detail.labels || issue.labels || card.labels || []).forEach((label) =>
      labelRow.appendChild(el('span', 'task-card-label', label)));
    labelRow.appendChild(el('span', 'agent-status', card.agent_status || 'state unavailable'));
    labels.appendChild(labelRow);
    panel.appendChild(labels);

    const actions = detailSection('Operator actions');
    const actionRow = el('div', 'detail-actions');
    const actionButton = (label, action, tone) => {
      if (!detail.capabilities?.[action]) return;
      const button = el('button', tone || 'secondary', label);
      button.type = 'button';
      button.addEventListener('click', () => runAction(card, action));
      actionRow.appendChild(button);
    };
    if (card.column === 'Todo') actionButton('Dispatch', 'dispatch');
    if (card.column === 'In Progress') actionButton('Pause', 'pause');
    if (card.agent_status === 'retrying') actionButton('Retry now', 'retry');
    const acceptedPendingClosure =
      card.column === 'Human Review' && (card.labels || []).includes('symphony:accept');
    if (card.column === 'Human Review' && !acceptedPendingClosure) {
      actionButton('Request rework', 'rework');
      actionButton('Accept manifest', 'accept');
    }
    if (actionRow.childNodes.length) {
      actions.appendChild(actionRow);
      if (card.column === 'Human Review' && !acceptedPendingClosure) {
        actions.appendChild(
          el(
            'p',
            'action-note',
            'Accept records symphony:accept. Close the Issue in the tracker after acceptance to move it to Done.',
          ),
        );
      }
      panel.appendChild(actions);
    } else if (acceptedPendingClosure) {
      actions.appendChild(
        el('p', 'action-note', 'Acceptance is recorded. Close the Issue in the tracker to move it to Done.'),
      );
      panel.appendChild(actions);
    }

    const description = detailSection('Description');
    description.appendChild(
      el('pre', 'detail-description', detail.description || issue.description || 'No description provided.'),
    );
    panel.appendChild(description);

    if (detail.deliveries?.length) {
      const deliveries = detailSection('Linked PR / MR');
      const list = el('div', 'delivery-list');
      detail.deliveries.forEach((delivery) => list.appendChild(deliveryNode(delivery)));
      deliveries.appendChild(list);
      panel.appendChild(deliveries);
    } else {
      const deliveries = detailSection('Linked PR / MR');
      deliveries.appendChild(el('p', 'comment-body', 'No linked pull or merge request was found for this Issue.'));
      panel.appendChild(deliveries);
    }

    if (detail.execution) {
      const execution = detailSection('Execution record');
      const facts = el('div', 'delivery-facts');
      [
        detail.execution.phase && `phase: ${formatLabel(detail.execution.phase)}`,
        detail.execution.attempt_count && `attempts: ${detail.execution.attempt_count}`,
        detail.execution.thread_id && `thread: ${detail.execution.thread_id}`,
        detail.execution.updated_at && `updated: ${shortTime(detail.execution.updated_at)}`,
      ].filter(Boolean).forEach((fact) => facts.appendChild(el('span', 'delivery-fact', fact)));
      execution.appendChild(facts);
      const events = detail.execution.events || [];
      if (events.length) {
        const list = el('div', 'event-list');
        events.slice(-10).forEach((event) => {
          const row = el('div', 'event-row');
          row.appendChild(el('time', null, shortTime(event.at || event.timestamp || event.updated_at)));
          row.appendChild(
            el(
              'span',
              null,
              event.message || event.event || event.kind || event.type || JSON.stringify(event),
            ),
          );
          list.appendChild(row);
        });
        execution.appendChild(list);
      }
      panel.appendChild(execution);
    }

    const comments = detailSection(`Comments (${(detail.comments || []).length})`);
    const commentList = el('div', 'comment-list');
    if (!detail.comments?.length) {
      commentList.appendChild(el('p', 'comment-body', 'No comments yet.'));
    } else {
      detail.comments.forEach((comment) => {
        const node = el('article', `comment ${comment.engine ? 'engine' : ''}`);
        const commentHead = el('div', 'comment-head');
        commentHead.appendChild(el('span', 'comment-author', comment.author || 'unknown'));
        commentHead.appendChild(el('span', null, comment.engine ? 'Agent' : 'Human'));
        if (comment.created_at) commentHead.appendChild(el('span', null, shortTime(comment.created_at)));
        node.appendChild(commentHead);
        node.appendChild(el('pre', 'comment-body', comment.body || ''));
        commentList.appendChild(node);
      });
    }
    comments.appendChild(commentList);
    panel.appendChild(comments);

    if (detail.capabilities?.comment) {
      const composer = detailSection('Reply');
      composer.classList.add('comment-composer');
      const textarea = el('textarea');
      textarea.id = 'taskboard-comment';
      textarea.placeholder = 'Reply on the Issue. Review decisions remain explicit label actions.';
      composer.appendChild(textarea);
      const foot = el('div', 'composer-foot');
      foot.appendChild(el('span', null, 'Published through the tracker with the operator identity.'));
      const post = el('button', null, 'Post comment');
      post.type = 'button';
      post.addEventListener('click', () => postComment(textarea));
      foot.appendChild(post);
      composer.appendChild(foot);
      panel.appendChild(composer);
    }
  }

  function render() {
    renderFilters();
    renderStats();
    renderBanner();
    renderBoard();
    if (state.selected && !state.detail) renderDetailEmpty();
    document.querySelectorAll('.task-card').forEach((card) => {
      if (`${card.dataset.project}|${card.dataset.identifier}` === state.selected) {
        card.classList.add('selected');
      }
    });
  }

  async function refresh(options = {}) {
    if (state.paused) return;
    const connection = $('#taskboard-connection');
    try {
      state.snapshot = await jsonRequest('/api/v1/taskboard');
      connection.textContent = 'Live';
      connection.classList.remove('offline');
      render();
      if (options.refreshDetail && state.selected) {
        const card = selectedCard();
        if (card) await openIssue(card.project_id, card.issue_identifier, { quiet: true });
      }
    } catch (error) {
      connection.textContent = 'Offline';
      connection.classList.add('offline');
      if (!options.quiet) toast(error.message, 'error');
    }
  }

  async function openIssue(projectId, identifier, options = {}) {
    state.selected = `${projectId}|${identifier}`;
    state.loadingDetail = true;
    render();
    renderDetailEmpty('Loading Issue…');
    try {
      state.detail = await jsonRequest(
        `/api/v1/taskboard/issues/${encodeURIComponent(projectId)}/${encodeURIComponent(identifier)}`,
      );
    } catch (error) {
      state.detail = null;
      if (!options.quiet) toast(error.message, 'error');
    } finally {
      state.loadingDetail = false;
      renderDetail();
      render();
    }
  }

  async function runAction(card, action) {
    if (!card) return;
    let comment = '';
    if (action === 'rework' || action === 'accept') {
      comment = $('#taskboard-comment')?.value?.trim() || '';
      const prompt = action === 'rework'
        ? 'Request in-scope rework for this Issue?'
        : 'Accept the current verified delivery? Close the Issue in the tracker afterward to move it to Done.';
      if (!window.confirm(prompt)) return;
    }

    try {
      const payload = await operatorRequest(
        `/api/v1/taskboard/issues/${encodeURIComponent(card.project_id)}/${encodeURIComponent(card.issue_identifier)}/actions/${encodeURIComponent(action)}`,
        { comment },
      );
      toast(payload.detail || `${action} requested`);
      await refresh({ quiet: true, refreshDetail: true });
      if (state.selected) await openIssue(card.project_id, card.issue_identifier, { quiet: true });
    } catch (error) {
      toast(error.message, 'error');
    }
  }

  async function postComment(textarea) {
    const body = textarea.value.trim();
    const card = selectedCard();
    if (!body || !card) return;
    try {
      await operatorRequest(
        `/api/v1/taskboard/issues/${encodeURIComponent(card.project_id)}/${encodeURIComponent(card.issue_identifier)}/comments`,
        { body },
      );
      textarea.value = '';
      toast('Comment posted');
      await openIssue(card.project_id, card.issue_identifier, { quiet: true });
    } catch (error) {
      toast(error.message, 'error');
    }
  }

  function loadDraft() {
    try {
      return JSON.parse(localStorage.getItem(DRAFT_KEY) || '{}');
    } catch (_) {
      return {};
    }
  }

  function saveDraft() {
    const draft = {
      project_id: $('#create-project').value,
      title: $('#create-title-input').value,
      labels: $('#create-labels').value,
      description: $('#create-description').value,
    };
    try {
      localStorage.setItem(DRAFT_KEY, JSON.stringify(draft));
    } catch (_) {
      // Draft persistence is a convenience; publishing still works without it.
    }
  }

  function openCreate() {
    if (!state.snapshot) return;
    const writable = state.snapshot.projects.filter((project) => project.write_enabled);
    if (!writable.length) {
      toast('Taskboard writes require an operator token and provider identity', 'error');
      return;
    }

    const select = $('#create-project');
    clear(select);
    writable.forEach((project) => select.appendChild(new Option(`${project.name} (${project.kind})`, project.id)));

    const draft = loadDraft();
    if (writable.some((project) => project.id === draft.project_id)) {
      select.value = draft.project_id;
    } else if (state.project && writable.some((project) => project.id === state.project)) {
      select.value = state.project;
    }
    $('#create-title-input').value = draft.title || '';
    $('#create-labels').value = draft.labels || '';
    $('#create-description').value = draft.description || '';
    $('#taskboard-create').classList.remove('hidden');
    $('#create-title-input').focus();
  }

  async function submitCreate(event) {
    event.preventDefault();
    const form = event.currentTarget;
    if (!form.reportValidity()) return;
    if (!window.confirm('Publish this draft as a repository Issue?')) return;
    const projectId = $('#create-project').value;

    const labels = $('#create-labels').value
      .split(',')
      .map((label) => label.trim())
      .filter(Boolean);

    try {
      const created = await operatorRequest('/api/v1/taskboard/issues', {
        project_id: projectId,
        title: $('#create-title-input').value.trim(),
        labels,
        description: $('#create-description').value,
      });
      localStorage.removeItem(DRAFT_KEY);
      $('#taskboard-create').classList.add('hidden');
      form.reset();
      toast(`${created.identifier || 'Issue'} created`);
      await refresh({ quiet: true });
      if (created.identifier) openIssue(created.project_id || projectId, created.identifier);
    } catch (error) {
      toast(error.message, 'error');
    }
  }

  function visibleCards() {
    return state.snapshot ? state.snapshot.cards.filter(cardMatches) : [];
  }

  function moveSelection(delta) {
    const cards = visibleCards();
    if (!cards.length) return;
    const current = cards.findIndex((card) => keyFor(card) === state.selected);
    const next = current < 0 ? 0 : Math.max(0, Math.min(cards.length - 1, current + delta));
    openIssue(cards[next].project_id, cards[next].issue_identifier);
  }

  function paletteCommands() {
    const commands = visibleCards().map((card) => ({
      label: `${card.issue_identifier} · ${card.title}`,
      hint: `${card.project} · ${card.column}`,
      run: () => openIssue(card.project_id, card.issue_identifier),
    }));
    commands.push(
      { label: 'Create a new Issue', hint: 'n', run: openCreate },
      { label: 'Refresh Taskboard', hint: 'r', run: () => refresh() },
    );
    return commands;
  }

  function drawPalette() {
    const list = $('#taskboard-palette-list');
    clear(list);
    if (!state.paletteItems.length) {
      list.appendChild(el('div', 'palette-item', 'No matches'));
      return;
    }
    state.paletteItems.forEach((command, index) => {
      const row = el('div', `palette-item ${index === state.paletteIndex ? 'active' : ''}`);
      row.appendChild(el('strong', null, command.label));
      row.appendChild(el('span', null, command.hint || ''));
      row.addEventListener('click', () => {
        closeOverlay('taskboard-palette');
        command.run();
      });
      list.appendChild(row);
    });
  }

  function updatePalette(query) {
    const q = query.trim().toLowerCase();
    state.paletteItems = paletteCommands()
      .filter((command) => !q || `${command.label} ${command.hint || ''}`.toLowerCase().includes(q))
      .slice(0, 50);
    state.paletteIndex = 0;
    drawPalette();
  }

  function openPalette() {
    $('#taskboard-palette').classList.remove('hidden');
    const input = $('#taskboard-palette-input');
    input.value = '';
    updatePalette('');
    input.focus();
  }

  function closeOverlay(id) {
    document.getElementById(id)?.classList.add('hidden');
  }

  function closeTopOverlay() {
    const overlays = ['taskboard-palette', 'taskboard-create', 'taskboard-help'];
    const open = overlays.find((id) => !document.getElementById(id).classList.contains('hidden'));
    if (open) {
      closeOverlay(open);
      return true;
    }
    if (state.selected) {
      state.selected = null;
      state.detail = null;
      render();
      renderDetailEmpty();
      return true;
    }
    return false;
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
  $('#taskboard-refresh').addEventListener('click', () => refresh({ refreshDetail: true }));
  $('#taskboard-new').addEventListener('click', openCreate);
  $('#taskboard-help-button').addEventListener('click', () => $('#taskboard-help').classList.remove('hidden'));
  $('#taskboard-create-form').addEventListener('submit', submitCreate);
  ['#create-project', '#create-title-input', '#create-labels', '#create-description'].forEach((selector) => {
    $(selector).addEventListener('input', saveDraft);
    $(selector).addEventListener('change', saveDraft);
  });
  document.querySelectorAll('[data-close]').forEach((button) => {
    button.addEventListener('click', () => closeOverlay(button.dataset.close));
  });
  $('#taskboard-palette-input').addEventListener('input', (event) => updatePalette(event.target.value));

  document.addEventListener('keydown', (event) => {
    const inField = ['INPUT', 'TEXTAREA', 'SELECT'].includes(event.target.tagName);
    const paletteOpen = !$('#taskboard-palette').classList.contains('hidden');

    if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === 'k') {
      event.preventDefault();
      closeOverlay('taskboard-palette');
      openPalette();
      return;
    }

    if (event.key === 'Escape') {
      if (closeTopOverlay()) event.preventDefault();
      else if (inField) event.target.blur();
      return;
    }

    if (paletteOpen) {
      if (event.key === 'ArrowDown') {
        event.preventDefault();
        state.paletteIndex = Math.min(state.paletteItems.length - 1, state.paletteIndex + 1);
        drawPalette();
      } else if (event.key === 'ArrowUp') {
        event.preventDefault();
        state.paletteIndex = Math.max(0, state.paletteIndex - 1);
        drawPalette();
      } else if (event.key === 'Enter') {
        event.preventDefault();
        const command = state.paletteItems[state.paletteIndex];
        if (command) {
          closeOverlay('taskboard-palette');
          command.run();
        }
      }
      return;
    }

    if (inField) return;

    if (event.key === 'j') {
      event.preventDefault();
      moveSelection(1);
    } else if (event.key === 'k') {
      event.preventDefault();
      moveSelection(-1);
    } else if (event.key === '/') {
      event.preventDefault();
      $('#taskboard-filter').focus();
    } else if (event.key === 'n') {
      event.preventDefault();
      openCreate();
    } else if (event.key === 'r') {
      event.preventDefault();
      refresh({ refreshDetail: true });
    } else if (event.key === '?') {
      event.preventDefault();
      $('#taskboard-help').classList.remove('hidden');
    }
  });

  const refreshMs = Math.max(1000, Number(ROOT.dataset.refreshMs) || 5000);
  window.setInterval(() => refresh({ quiet: true }), refreshMs);
  renderDetailEmpty();
  refresh();
})();
