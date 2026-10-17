# Repository Issue Taskboard

The Taskboard extends Symphony's Phoenix dashboard without replacing the scheduler or execution
state machine. Repository Issues remain the only task source. Symphony execution journals and the
orchestrator snapshot provide runtime evidence, but neither becomes a second task database.

## Surfaces

| Path | Purpose |
|---|---|
| `/` | Four-column repository Issue Taskboard and side-panel review workflow |
| `/runtime` | Existing runtime, retry, token, and event observability dashboard |
| `/api/v1/taskboard` | Aggregated Taskboard projection |
| `/api/v1/taskboard/projects/:project_id` | One project projection used by remote aggregation |
| `/api/v1/taskboard/issues/:project_id/:issue_identifier` | Issue detail, comments, deliveries, execution evidence, and capabilities |
| `POST /api/v1/taskboard/issues` | Create a repository Issue after an operator-confirmed draft |
| `POST /api/v1/taskboard/issues/:project_id/:issue_identifier/comments` | Publish an operator comment |
| `POST /api/v1/taskboard/issues/:project_id/:issue_identifier/actions/:action` | Request a controlled state transition |
| `/api/v1/state` | Original runtime JSON API |

The projection and detail GET endpoints are readable without a Taskboard control token. Treat the
HTTP port as a private operational surface. When the dashboard leaves loopback, restrict it to a
trusted LAN or place it behind an authenticated reverse proxy. All POST operations require the
control token.

## Four-column projection

The columns are views, not new persisted statuses. The internal scheduler states, labels, retry
queue, native Goal state, and acceptance protocol remain authoritative.

| Column | Projection rule |
|---|---|
| Todo | Open or active Issue that is not running, retrying, blocked, in review, or accepted |
| In Progress | Runtime entry is running/retrying, or the engine's `symphony:running` label is present |
| Human Review | Runtime blocked, `symphony:review`/`symphony:blocked`/`symphony:failed`, accepted but still open, or externally closed without acceptance |
| Done | Tracker state is closed/cancelled/done **and** `symphony:accept` is present |

The projection checks Done before any runtime state. This prevents a stale agent process or retry
entry from moving a verified closed Issue back into execution. An open Issue with
`symphony:accept` stays in Human Review with `accepted; awaiting closure`; it cannot be accepted or
reworked again from the Taskboard. Close it through the normal tracker acceptance flow to finish
the transition.

A successful Agent turn, published pull/merge request, or merged delivery alone does not produce
Done. The existing acceptance decision and native Issue closure remain required.

## Controlled actions

| Action | Valid projected state | Effect |
|---|---|---|
| Dispatch | Todo | Adds the human-owned `symphony:ready` label |
| Pause | In Progress | Removes `symphony:ready` routing authorization |
| Retry now | In Progress with a real retry entry | Requests immediate retry from the orchestrator retry queue |
| Rework | Human Review | Adds an explicit human rework decision and optional comment |
| Accept | Human Review | Adds the human `symphony:accept` decision and optional comment |

Drag and drop maps only to these actions. The API re-reads the current Issue before executing the
action, rejects invalid transitions, and never writes orchestrator memory directly. Dispatch and
pause change routing labels consumed by the existing scheduler. Rework and accept preserve the
versioned task protocol.

The Issue detail panel supports comment drafts on the Issue, linked pull/merge requests, review
state, unresolved comments when the provider exposes them, and a compact execution record. Issue
creation and comments use the configured operator token, not the scheduler token.

## Identity model

Symphony separates two tracker identities:

- The scheduler identity writes engine-owned state labels and runtime notices.
- The human operator identity writes Issues, comments, `symphony:ready`, `symphony:rework`, and
  `symphony:accept` when a person performs those actions in the Taskboard.

The operator token is configured as `taskboard.provider_token` and should resolve from
`$SYMPHONY_OPERATOR_TRACKER_TOKEN`. The scheduler keeps using its own adapter token. The control
token (`taskboard.control_token`) authorizes the browser request and is independent from both
tracker identities.

Neither Taskboard secret belongs in Git or a repository-owned workflow. Both host environment
variables, plus adapter credential variables, are removed from Codex child processes. The browser
keeps the control token in session storage and clears it after an unauthorized response.

## Configuration

```yaml
taskboard:
  enabled: true
  refresh_ms: 5000
  control_token: $SYMPHONY_TASKBOARD_CONTROL_TOKEN
  provider_token: $SYMPHONY_OPERATOR_TRACKER_TOKEN
  projects: []
server:
  host: 127.0.0.1
  port: 8092
```

`server.host` remains loopback by default. Binding `0.0.0.0` is an explicit LAN-access decision.
Read endpoints are not authenticated, so use a firewall or authenticated reverse proxy when the
service is reachable from untrusted networks.

## Multiple projects

One Symphony instance owns one primary tracker configuration. It can aggregate read projections
from other explicitly configured Symphony instances without copying Issue state:

```yaml
taskboard:
  projects:
    - id: workspace
      name: Workspace
      kind: github
      repo: maychair/workspace
      url: http://workspace-symphony.example:8093
      token: $WORKSPACE_SYMPHONY_CONTROL_TOKEN
```

Project IDs must be unique. Each URL points at a reachable Symphony Taskboard. The remote token is
only for that instance's write API. A remote read failure is shown on the board and does not stop
the local project projection.

## Deliberate boundaries

- No Dashi dependency, local Taskboard service, or mirrored task store is introduced.
- The browser cannot write scheduler memory directly.
- Provider review enrichment is best effort; unsupported unresolved-thread queries are labelled
  unavailable instead of rendered as zero.
- Closing an Issue without `symphony:accept` remains in Human Review.
- The scheduler's pause, resume, budget, versioned decision, and acceptance semantics are unchanged.
