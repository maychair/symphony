# Repository Issues and durable execution

Use the existing `github` or `gitlab` tracker with native open/closed states and
`tracker.required_labels: [symphony:ready]`. Task content, comments, delivery links
and completion live in the repository. The scheduler does not keep a task mirror.

```yaml
agent:
  goal_mode: true
  run_journal_dir: $SYMPHONY_RUN_JOURNAL_DIR
  run_budget_ms: 21600000
workspace:
  retain: true
```

`goal_mode` is independent of tracker selection. The durable journal records
admission, native thread/turn identities, handoffs, retries and execution incidents.
A directory lock prevents concurrent admission across processes. Restart resumes a
recorded thread only through native idle validation. Unknown thread allocation is
an incident. Confirmed-stopped transient failures receive two scheduler retries;
`symphony:retry` requests a further explicit retry and is consumed on admission.
For a custom internal GitLab HTTP endpoint, explicitly set
`tracker.provider.allow_insecure_http: true`.

The dynamic `task_handoff` tool accepts `kind: review|decision|blocked`, a specific
`reason`, and an optional result `url`. It comments on the assigned Issue and removes
its routing labels. A completed model turn does not close the Issue. Use repository
closing references on a PR/MR when merge satisfies the complete task; otherwise
close only after all agreed acceptance conditions have been met. Dependency links
remain repository content; automatic dependency scheduling is not implemented.

When polling observes a terminal, unrouted or no-longer-visible Issue during a
native Goal, the scheduler requests cooperative shutdown and keeps its running
entry and claim until the worker exits. The worker blocks the Goal, interrupts
its active turn, verifies that turn has stopped, then completes the journal and
releases the executor lock. An unconfirmed native stop is an incident, not a
successful completion. If shutdown has not finished after 60 seconds, the scheduler
stops the worker and records an incident with the executor lock released; it does
not infer that the native Goal stopped. Completion here ends the execution attempt,
not the repository task. This shutdown is independent of the automatic retry limit;
ordinary turn completion and review handoffs retain their existing behavior.

Native REST tools can read and update existing Issues. They reject Issue creation;
creation requires explicit user authorization through the operator's task entry.
The optional MR mail-review lane uses its own execution journal and does not create
Issues. Existing native tracker and non-Goal execution modes remain available.

Run `mix execution.preflight --workflow FILE [--issue NUMBER]` to validate tracker
access and render prompts without starting the scheduler. Runtime diagnostics:
`GET /api/v1/state`, `GET /api/v1/runs/NUMBER`. Webhooks request a scoped refresh;
polling remains the reconciliation fallback. No local task workbench is provided.

Historical tracker databases and run records should be archived before switching.
Use a fresh journal directory for repository Issue IDs. Do not migrate tasks or
create repository Issues without the user's explicit task-creation authorization.
