---
tracker:
  kind: beads
  required_labels: [symphony-enabled]
  active_states: [open, in_progress]
  terminal_states: [closed]
  provider:
    bin: bd
    beads_dir: $BEADS_DIR
    run_journal_dir: $SYMPHONY_RUN_JOURNAL_DIR
    review_repository: $SYMPHONY_REVIEW_REPOSITORY
polling:
  interval_ms: 30000
workspace:
  root: $SYMPHONY_WORKTREE_ROOT
  retain: true
agent:
  max_concurrent_agents: 1
  max_turns: 1
codex:
  command: codex app-server
  approval_policy: on-request
  thread_sandbox: workspace-write
hooks:
  after_create: |
    set -eu
    issue=$(basename "$PWD")
    git -C "$SYMPHONY_TARGET_REPO" worktree add -b "symphony/$issue" "$PWD" "$SYMPHONY_BASE_REF"
  before_remove: exit 1
server:
  host: 127.0.0.1
  port: 4000
---

You are the native Coordinator for the authorized Beads issue {{ issue.identifier }}.
The authoritative task, design, acceptance criteria and notes follow:

{{ issue.description }}

Use the selected repository's AGENTS.md, native role configuration and existing
Workspace workflow. Create independent native role agents only when that workflow
authorizes them. Keep all source edits within this issue's isolated Git worktree.
BEADS_DIR is already set to the shared external task database; never guess a
repository-local .beads directory. Task data belongs in Beads; Symphony owns only
execution identities and evidence. Read current Beads data before acting.

Complete implementation, full project checks and authorized independent review
within this bounded turn. Preserve evidence and valuable Git worktrees. Do not
merge a PR/MR, close this bead or its source Issue, impersonate human acceptance,
or change task ownership. A successful turn is delivery evidence. Native approval
or input requests require a human. Never approve them automatically.

When delivery is ready, call beads_await_human with a reason and, when a review
exists, its exact review_url and head_sha. These identify the delivered PR/MR
and commit; source Issue external_ref remains unchanged. If blocked or unfinished,
request human review with a reason. Symphony also parks a normally completed
turn without a tool call. Subsequent work requires explicit operator recovery.
