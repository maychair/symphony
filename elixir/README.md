# Symphony Elixir

This directory contains the current Elixir/OTP implementation of Symphony, based on
[`SPEC.md`](../SPEC.md) at the repository root.

> [!WARNING]
> Symphony Elixir is prototype software intended for evaluation only and is presented as-is.
> We recommend implementing your own hardened version based on `SPEC.md`.

## Screenshot

![Symphony Elixir screenshot](../.github/media/elixir-screenshot.png)

## How it works

1. Polls the configured tracker for candidate work (included adapters: Linear, GitHub Issues, Jira
   Cloud, Asana, and GitLab)
2. Creates a workspace per issue
3. Launches Codex in [App Server mode](https://developers.openai.com/codex/app-server/) inside the
   workspace
4. Sends a workflow prompt to Codex
5. Keeps Codex working on the issue until the work is done

The Phoenix service exposes a read-only repository Issue Taskboard at `/` and the lower-level
runtime observability dashboard at `/runtime`. The Taskboard is a projection over configured
GitHub, GitLab, or memory-backed Issues, execution manifests, and the runtime snapshot; it does not
keep a second task database. Its four columns are user-facing views over tracker state, labels, and
Symphony execution observations. Cards open the native Issue in a new tab and expose delivered MRs
or reports as separate links. Linked MRs are read from the tracker, while report evidence comes from
the execution manifest. When `tracker.assignee` is configured, the personal projection includes
only Issues assigned to that identity. Human Review cards state the concrete acceptance or decision action.
Issue operations take place in the tracker. See
[Taskboard](docs/taskboard.md) for state mapping, operator authentication, and the JSON API.

During app-server sessions, the selected tracker adapter may advertise provider-native tools. The
Linear serves `linear_graphql`, GitHub Issues serves `github_api`, Jira Cloud serves
`jira_rest`, Asana serves `asana_api`, and GitLab serves `gitlab_api`. Symphony executes those
tools with configured host-side auth and removes declared tracker-token environment variables from
the Codex child, so the agent does not need a second tracker login.

If a claimed issue moves to a terminal state (`Done`, `Closed`, `Cancelled`, or `Duplicate`),
Symphony stops the active agent for that issue and cleans up matching workspaces.
In native Goal mode, it retains the running entry until the worker confirms native
shutdown and finalizes the durable journal; an unconfirmed stop remains an incident.

### Merged-delivery cleanup

`workspace.merge_cleanup_command` is an optional trusted operator command,
disabled by default. The existing poll cycle starts one asynchronous pass at a
time; slow or failed cleanup does not block task reconciliation. Startup and
subsequent polls use the same path, and changing configuration affects later
passes. The command must independently confirm the native review is merged,
the recorded task is stopped, and the exact local worktree/branch are safe to
remove. Closing an Issue alone is not merge evidence. Ordinary `workspace.retain`
semantics remain unchanged.

The command owns provider-specific merge checks, exclusive execution fencing,
data protection, durable cleanup receipts and operator notices. It must preserve
execution records, stop on dirty or unpublished work, avoid forced removal, and
support restart/partial-failure recovery. A successful command exit means a pass
finished, not that every candidate was removed. This is lifecycle reconciliation,
not another task source or Agent retry loop.

If Codex reports that operator input, approval, or MCP elicitation is required, Symphony keeps the
issue claimed and exposes it as blocked in the runtime state, JSON API, and dashboard. Blocked
entries are in memory only; restarting the orchestrator clears that blocked map, so any still-active
tracker issue can become a dispatch candidate again after restart.

## How to use it

1. Make sure your codebase is set up to work well with agents: see
   [Harness engineering](https://openai.com/index/harness-engineering/).
2. Get a new personal token in Linear via Settings → Security & access → Personal API keys, and
   set it as the `LINEAR_API_KEY` environment variable.
3. Copy this directory's `WORKFLOW.md` to your repo.
4. Optionally copy the `commit`, `push`, `pull`, `land`, and `linear` skills to your repo.
   - The `linear` skill expects Symphony's `linear_graphql` app-server tool for raw Linear GraphQL
     operations such as comment editing or upload flows.
5. Customize the copied `WORKFLOW.md` file for your project.
   - To get your project's slug, right-click the project and copy its URL. The slug is part of the
     URL.
   - When creating a workflow based on this repo, note that it depends on non-standard Linear
     issue statuses: "Rework", "Human Review", and "Merging". You can customize them in
     Team Settings → Workflow in Linear.
6. Follow the instructions below to install the required runtime dependencies and start the service.

## Prerequisites

We recommend using [mise](https://mise.jdx.dev/) to manage Elixir/Erlang versions.

```bash
mise install
mise exec -- elixir --version
```

## Run

```bash
git clone https://github.com/openai/symphony
cd symphony/elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build
mise exec -- ./bin/symphony ./WORKFLOW.md
```

## Burrito releases

Symphony ships self-contained executables built with
[Burrito](https://github.com/burrito-elixir/burrito). They embed Erlang/OTP, Elixir, and Symphony,
but still expect `codex`, `git`, and the selected tracker credentials on the target machine.

Supported release targets:

- `macos_arm64`
- `macos_x86_64`
- `linux_arm64`
- `linux_x86_64`

`v*` tags publish all four targets with checksums. A manual workflow run builds the same
artifacts without creating a release.

The `burrito-nightly` workflow builds each push to `main`, with no scheduled rebuilds.
After all four platform smoke tests pass, it updates the rolling
[`nightly` prerelease](https://github.com/openai/symphony/releases/tag/nightly),
including binaries and checksums. Nightly binaries use a `-nightly` version suffix;
the release notes identify the source commit. Stable releases remain unchanged.

After downloading the executable for your platform from a release:

```bash
chmod +x ./symphony-v0.0.1-macos_arm64
./symphony-v0.0.1-macos_arm64 ./WORKFLOW.md
```

## Configuration

Pass a custom workflow file path to `./bin/symphony` when starting the service:

```bash
./bin/symphony /path/to/custom/WORKFLOW.md
```

If no path is passed, Symphony defaults to `./WORKFLOW.md`.

Optional flags:

- `--logs-root` tells Symphony to write logs under a different directory (default: `./log`)
- `--port` also starts the Phoenix observability service (default: disabled)

The `WORKFLOW.md` file uses YAML front matter for configuration, plus a Markdown body used as the
Codex session prompt.

Minimal example:

```md
---
tracker:
  kind: linear
  provider:
    project_slug: "..."
workspace:
  root: ~/code/workspaces
hooks:
  after_create: |
    git clone git@github.com:your-org/your-repo.git .
agent:
  max_concurrent_agents: 10
  max_turns: 20
taskboard:
  control_token: $SYMPHONY_TASKBOARD_CONTROL_TOKEN
  provider_token: $SYMPHONY_OPERATOR_TRACKER_TOKEN
server:
  host: 127.0.0.1
  port: 8092
codex:
  command: codex app-server
---

You are working on an issue from the configured tracker {{ issue.identifier }}.

Title: {{ issue.title }} Body: {{ issue.description }}
```

Notes:

- If a value is missing, defaults are used.
- `tracker.kind` selects an adapter. Adapter-owned endpoint, scope, and auth settings belong under
  `tracker.provider`; the current Linear adapter still accepts the older flat `endpoint`,
  `api_key`, `project_slug`, and `assignee` aliases for compatibility.
- `tracker.required_labels` is optional. When set, an issue must have every
  configured label to dispatch or continue running. Label matching ignores
  case and surrounding whitespace. A blank configured label matches no issue.
- Safer Codex defaults are used when policy fields are omitted:
  - `codex.approval_policy` defaults to `{"reject":{"sandbox_approval":true,"rules":true,"mcp_elicitations":true}}`
  - `codex.thread_sandbox` defaults to `workspace-write`
  - `codex.turn_sandbox_policy` defaults to a `workspaceWrite` policy rooted at the current issue workspace
- `codex.turn_timeout_ms` is the maximum silence interval while a turn is streaming. Each
  app-server update resets it; it is not a total turn runtime cap.
- Supported `codex.approval_policy` values depend on the targeted Codex app-server version. In the current local Codex schema, string values include `untrusted`, `on-failure`, `on-request`, and `never`, and object-form `reject` is also supported.
- Supported `codex.thread_sandbox` values: `read-only`, `workspace-write`, `danger-full-access`.
- When `codex.turn_sandbox_policy` is set explicitly, Symphony passes the map through to Codex
  unchanged. Compatibility then depends on the targeted Codex app-server version rather than local
  Symphony validation.
- Workflows that run package managers or other commands that resolve external hosts should set
  `networkAccess: true` in `codex.turn_sandbox_policy`; otherwise DNS/network access may be denied
  by the Codex turn sandbox.
- `agent.max_turns` caps how many back-to-back Codex turns Symphony will run in a single agent
  invocation when a turn completes normally but the issue is still in an active state. Default: `20`.
- If the Markdown body is blank, Symphony uses a default prompt template that includes the issue
  identifier, title, and body.
- Use `hooks.after_create` to bootstrap a fresh workspace. For a Git-backed repo, you can run
  `git clone ... .` there, along with any other setup commands you need.
- If a hook needs `mise exec` inside a freshly cloned workspace, trust the repo config and fetch
  the project dependencies in `hooks.after_create` before invoking `mise` later from other hooks.
- For the Linear adapter, `tracker.provider.api_key` reads from `LINEAR_API_KEY` when unset or
  when value is `$LINEAR_API_KEY`. The legacy flat `tracker.api_key` alias behaves the same way.
- Do not put a literal tracker token in a repo-owned `WORKFLOW.md` if Codex can read that
  workspace. Use `$VAR`/host-side secret references so Symphony can keep the token out of the
  child environment.
- For path values, `~` is expanded to the home directory.
- For env-backed path values, use `$VAR`. `workspace.root` resolves `$VAR` before path handling,
  while `codex.command` stays a shell command string and any `$VAR` expansion there happens in the
  launched shell.
- `taskboard.control_token` authenticates write API calls made by the operator UI. The UI requests
  it once per browser session and stores it only in `sessionStorage`.
- `taskboard.provider_token` is the human operator's tracker token. Symphony uses it only for
  Taskboard Issue creation, comments, and explicit human labels, so those writes keep the human
  identity while scheduler writes continue to use the engine identity.
- Both Taskboard secrets should be environment references. Symphony removes these variables from
  agent subprocesses. The read-only Taskboard projections do not require either secret.
- `server.host` defaults to loopback. Set `0.0.0.0` only when the dashboard must be reached from
  another machine on a trusted network, and put an authenticated gateway or private network in
  front of it before exposing it beyond the LAN.

```yaml
tracker:
  provider:
    api_key: $LINEAR_API_KEY
workspace:
  root: $SYMPHONY_WORKSPACE_ROOT
hooks:
  after_create: |
    git clone --depth 1 "$SOURCE_REPO_URL" .
codex:
  command: "$CODEX_BIN --config 'model=\"gpt-5.5\"' app-server"
```

- If `WORKFLOW.md` is missing or has invalid YAML at startup, Symphony does not boot.
- If a later reload fails, Symphony keeps running with the last known good workflow and logs the
  reload error until the file is fixed.
- `server.port` or CLI `--port` enables the Phoenix service. The repository Issue Taskboard is at
  `/`; the original runtime dashboard remains at `/runtime`. Runtime JSON endpoints remain under
  `/api/v1/state`, `/api/v1/<issue_identifier>`, and `/api/v1/refresh`. Taskboard endpoints are
  documented in [Taskboard](docs/taskboard.md).

### Linear adapter profile

- Config: use `tracker.kind: linear` with `tracker.provider.endpoint` (default
  `https://api.linear.app/graphql`), `api_key` (defaults to `LINEAR_API_KEY` and accepts
  `$VAR`), required `project_slug`, and optional `assignee` (a Linear user ID or `me`,
  defaulting to `LINEAR_ASSIGNEE`).
  The legacy flat `tracker.endpoint`, `api_key`, `project_slug`, and `assignee` aliases remain
  supported. `required_labels`, `active_states`, and `terminal_states` stay under `tracker`.
- Scope and paging: candidate reads filter the configured project slug and requested state names,
  following Linear pages of 50. ID refreshes are also project-scoped and batch up to 50 IDs. Empty
  state/ID lists return `{:ok, []}` without a Linear request.
- Identity and normalization: `issue.id` is the Linear issue ID and `issue.native_ref` is currently
  `nil`. Records missing a nonblank ID, identifier, title, or state are dropped from candidate
  pages and fail ID refreshes. State keeps Linear's spelling; integer priorities are preserved and
  other priority values become `nil`; RFC 3339 timestamps are parsed and unusable timestamps become
  `nil`. Labels are trimmed, lowercased, deduplicated, and blanks are dropped; blockers come from
  inverse `blocks` relations.
- Dispatchability: the adapter marks an issue dispatchable only when optional assignee routing
  matches and a `Todo` issue has no non-terminal blocker. The generic scheduler then applies
  active/terminal states, required labels, claims, retries, and concurrency.
- Tool: the Linear adapter advertises `linear_graphql`, accepting either a raw query string or an
  object with nonblank `query` and optional object `variables`. Symphony executes it host-side
  with the session-bound endpoint/token and strips declared token environment variables from the
  Codex child. `project_slug` scopes scheduler reads, not raw tool calls; the tool can access
  whatever the configured Linear token can access.
- Responsibility and errors: `linear_graphql` adds no idempotency key, retry, scope guard, or
  rate-limit policy, so workflows own idempotent mutations and handling provider errors. Read/config
  failures use `{:error, :missing_linear_api_token}`, `{:error, :missing_linear_project_slug}`,
  `{:error, :invalid_linear_endpoint}`, `{:error, :invalid_linear_assignee}`,
  `{:error, :missing_linear_viewer_identity}`, `{:error, {:linear_api_status, status}}`,
  `{:error, {:linear_api_request, reason}}`, `{:error, {:linear_graphql_errors, errors}}`,
  `{:error, :linear_unknown_payload}`, or `{:error, :linear_missing_end_cursor}`. Tool results
  are maps with `"success"`, JSON-string `"output"`, and text `"contentItems"`; invalid
  arguments, missing auth, and transport failures return `"success" => false` with
  `{"error": {"message": ...}}`, while top-level GraphQL errors preserve the response body with
  `"success" => false`.
  For portable reporting, map missing/invalid token, project, endpoint, assignee, or viewer errors
  to `tracker_config` or `tracker_auth`, request failures to `tracker_transport`, non-200 responses to
  `tracker_response` (`429` is `tracker_rate_limited`), GraphQL/unknown payload failures to
  `tracker_payload`, and missing cursors to `tracker_pagination`; logs and tool responses carry the
  human-readable provider detail.

### GitHub Issues adapter

- Config: use `tracker.kind: github` with required `tracker.provider.repo` in `owner/repo` form,
  optional `token` (defaults to `GITHUB_TOKEN` and accepts `$VAR`), and optional `api_url`
  (default `https://api.github.com`, HTTPS only). Set explicit `active_states` and
  `terminal_states`; active entries may be `open` and terminal entries may be `closed`.
- Reads and identity: polling is scoped to the configured repository; `issue.id` is the
  repository issue number, `issue.identifier` is `GH-<number>`, hidden or deleted `404` issues are
  omitted on refresh, and pull requests returned by the Issues API are not dispatchable.
- Tool and auth: `github_api` accepts a relative REST `path` plus optional `params` and JSON
  `body`; Symphony executes it host-side with the session-bound token, removes configured tracker
  credentials and provider authentication aliases from the Codex child, and leaves raw tool access
  limited by that token's GitHub permissions.

### Jira Cloud adapter

- Config: use `tracker.kind: jira` with provider `base_url`, `email`, `api_token`, and required
  `project_key`; the first three default to `JIRA_BASE_URL`, `JIRA_EMAIL`, and `JIRA_API_TOKEN`
  and accept `$VAR`. Set explicit Jira-native `active_states` and `terminal_states`.
- Issues and reads: candidate reads and ID refreshes stay scoped to the configured project and
  requested statuses; `issue.id` is Jira's immutable ID and `issue.identifier` is the issue key.
- Blockers: inward `Blocks` links populate `blocked_by`; issues in Jira's `new` status category
  wait until blockers reach configured terminal states, while in-progress categories keep running.
- Tool: `jira_rest` sends relative `/rest/api/3/` requests host-side with configured Basic auth,
  strips token environment variables from Codex, and can reach whatever the Jira credential can.

### Asana adapter

- Config: use `tracker.kind: asana` with required `tracker.provider.project_gid`, optional
  `endpoint` (default `https://app.asana.com/api/1.0`), and `api_key` (defaults to `ASANA_PAT` and
  accepts `$VAR`); `active_states` and `terminal_states` are project section names.
- Scope: Symphony polls tasks in the configured project, treats their section as state, and omits
  deleted or out-of-project tasks during ID refreshes.
- Tool: `asana_api` sends relative Asana REST requests host-side with the configured auth; Symphony
  strips `ASANA_PAT` and configured token variables from the Codex child, while raw tool calls are
  not limited to the configured project.

### GitLab adapter

- Configure `tracker.kind: gitlab` with `tracker.provider.project_path`, optional `api_url`, and
  `api_key` (default `GITLAB_PAT`); use `opened` and `closed` tracker states.
- Symphony reads project issues by IID and exposes route-safe `GL-<iid>` identifiers.
- `gitlab_api` forwards raw GitLab REST requests with host-side auth and keeps configured tracker
  credentials and provider authentication aliases out of the Codex child.

## Web dashboard

The web UI runs on a minimal Phoenix stack:

- Read-only four-column Repository Issue Taskboard at `/`, with native tracker links
- Original runtime observability dashboard at `/runtime`
- Taskboard and operational JSON APIs under `/api/v1/*`
- Bandit as the HTTP server
- Phoenix dependency static assets for the LiveView client bootstrap
- Tracker issue identifiers link to the tracker-provided URL when it uses `http` or `https`

## Project Layout

- `lib/`: application code and Mix tasks
- `test/`: ExUnit coverage for runtime behavior
- `WORKFLOW.md`: in-repo workflow contract used by local runs
- `../.codex/`: repository-local Codex skills and setup helpers

## Testing

```bash
make all
```

Run the real external end-to-end test only when you want Symphony to create disposable Linear
resources and launch a real `codex app-server` session:

```bash
cd elixir
export LINEAR_API_KEY=...
make e2e
```

Optional environment variables:

- `SYMPHONY_LIVE_LINEAR_TEAM_KEY` defaults to `SYME2E`
- `SYMPHONY_LIVE_SSH_WORKER_HOSTS` uses those SSH hosts when set, as a comma-separated list

`make e2e` runs two live scenarios:
- one with a local worker
- one with SSH workers

If `SYMPHONY_LIVE_SSH_WORKER_HOSTS` is unset, the SSH scenario uses `docker compose` to start two
disposable SSH workers on `localhost:<port>`. The live test generates a temporary SSH keypair,
mounts the host `~/.codex/auth.json` into each worker, verifies that Symphony can talk to them
over real SSH, then runs the same orchestration flow against those worker addresses. This keeps
the transport representative without depending on long-lived external machines.

Set `SYMPHONY_LIVE_SSH_WORKER_HOSTS` if you want `make e2e` to target real SSH hosts instead.

The live test creates a temporary Linear project and issue, writes a temporary `WORKFLOW.md`, runs
a real agent turn, verifies the workspace side effect, requires Codex to comment on and close the
Linear issue, then marks the project completed so the run remains visible in Linear.

Run the opt-in GitHub Issues live test with a disposable/scratch repository:

```bash
cd elixir
export SYMPHONY_LIVE_GITHUB_REPO=owner/scratch-repo
export GITHUB_TOKEN=...
SYMPHONY_RUN_GITHUB_LIVE_E2E=1 mix test test/symphony_elixir/github_live_e2e_test.exs
```

Run the opt-in Jira Cloud live test against a disposable project whose credential can browse,
create, comment on, transition, and delete issues:

```bash
cd elixir
export JIRA_BASE_URL=https://your-site.atlassian.net
export JIRA_EMAIL=...
export JIRA_API_TOKEN=...
export SYMPHONY_LIVE_JIRA_PROJECT_KEY=TEST
SYMPHONY_RUN_JIRA_LIVE_E2E=1 mix test test/symphony_elixir/jira_live_e2e_test.exs
```

Run the opt-in Asana live E2E against disposable Asana resources:

```bash
cd elixir
export ASANA_PAT=...
export SYMPHONY_LIVE_ASANA_WORKSPACE_GID=...
# Required only when the workspace is an organization:
# export SYMPHONY_LIVE_ASANA_TEAM_GID=...
SYMPHONY_RUN_ASANA_LIVE_E2E=1 mix test test/symphony_elixir/asana_live_e2e_test.exs
```

Run the opt-in GitLab live E2E against a disposable project:

```bash
cd elixir
export GITLAB_PAT=...
export SYMPHONY_LIVE_GITLAB_PROJECT_ID=...
SYMPHONY_RUN_GITLAB_LIVE_E2E=1 mix test test/symphony_elixir/gitlab_live_e2e_test.exs
```

## FAQ

### Why Elixir?

Elixir is built on Erlang/BEAM/OTP, which is great for supervising long-running processes. It has an
active ecosystem of tools and libraries. It also supports hot code reloading without stopping
actively running subagents, which is very useful during development.

### What's the easiest way to set this up for my own codebase?

Launch `codex` in your repo, give it the URL to the Symphony repo, and ask it to set things up for
you.

## License

This project is licensed under the [Apache License 2.0](../LICENSE).

## Repository Issue execution

See [repository execution](docs/repository-issues.md) for native Goal sessions, durable execution records and handoffs.

Repository Issue routing can additionally restrict `tracker.assignee` (GitLab user ID or GitHub login). The same owner check applies to the personal Taskboard projection, admission, reconciliation, retry, recovery and continuation; unassigned or multiply assigned issues do not match a configured owner.

Verified GitLab MR publication can emit an attempt-scoped `review-request-ATTEMPT.json` in the execution journal. The existing Agent loop verifies the native MR, posts the deduplicated review notification and requests the engine-owned `symphony:review` label, without another Agent call. Handoff never writes or removes the human `symphony:ready` authorization label. Checkpoints expose derived `stage_results`; business validation remains linked evidence and is not inferred from execution completion.

## Versioned task workflow

GitLab repositories can opt into the [versioned task workflow](docs/task-workflow.md). It separates authorized work, intermediate review, overall acceptance, native closure and confirmed execution stop. Humans drive it with `symphony:ready`, `symphony:rework` and `symphony:accept`; the engine only writes its own `symphony:running`, `symphony:review`, `symphony:blocked` and `symphony:failed` state labels. Label authorization requires a published, unchanged candidate and the actual native actor; acceptance must bind an exact manifest. Enable it only after migrating retained private workflows and their Issue agreements.

## Parent plans and standalone review

The [repository lifecycle contract](docs/workflow-lifecycle.md) defines sealed cross-repository plans,
version-bound evidence, parent acceptance and comments-only standalone review.
Parent plan Issues are coordination work and never ordinary coding executions.
Plan graph validation, configured member dispatch, fixed parent manifests, native acceptance and scoped
rework are implemented in the isolated workflow branch. Deployment migration and live-provider acceptance
remain to be verified before enabling the new protocol.

Configured parent plans now receive [native preflight](docs/workflow-lifecycle.md#native-plan-preflight) on tracker reads. This verifies complete cross-repository scope and approval without granting child dispatch or treating Issue closure as dependency evidence.

[Native execution generations](docs/workflow-lifecycle.md#native-execution-generations) bind roles and fixed inputs, preserve cumulative accounting, and require native stop before replacing a thread. The member lifecycle reducer derives developer/verifier selection from resolved evidence, with finite repair accounting and version-bound delivery checks; GitHub/GitLab Issue evidence publication now persists send intent and verifies native readback. Git-backed verifier commands now produce isolated host receipts, and publication attests those results. Native result selection retains fixed Git snapshots with durable consumer references and re-attests command receipts. Native parent/member controls now preserve the approval grant, bind each resume to its pause and fence fresh publication with durable source receipts. Bound Codex sessions now expose role-specific context, candidate publication, configured host checks and verification tools; command results come from host receipts and calls revalidate native controls. Verified dependency edges now resolve native publications transitively, re-attest host checks and retain consumer references. Role tools revalidate their pinned inputs before effects; new candidates do not silently replace those inputs. Native PR/MR delivery reads now bind the approved target branch and actual merged revision. Delivered dependencies require independent verification of that exact revision, including after squash/rebase; original-head checks cannot unlock them. Markdown report candidates now retain exact UTF-8 content and publish readable evidence to their owning Issue without Git. Independently verified native report publications can satisfy verified, delivered or published dependencies. The native member admission coordinator now derives developer/verifier generations from complete evidence, rechecks under the journal lock and preserves observed pauses before first execution. Generation-owned role workspaces now materialize retained inputs, preserve developer edits on resume and give verifiers a separate fixed candidate checkout. Host checks consume the same manifest under read-only input isolation. Local role sessions now prepare those workspaces, recheck native authority before thread and Goal activation, fence callbacks to the owning process and attempt, and record stop only after native readback. Managed role Goals now observe native controls asynchronously, preserve intervening turn and budget updates, and stop on pauses, role changes or unconfirmed observations. Ownership fences also guard native Goal cleanup. Managed Goal finalization now records one result per attempt, applies finite retry accounting, and releases execution ownership after a durable final phase. Unconfirmed native stop remains an incident and never authorizes a replacement. The member worker now derives role Goals from sealed native scope and runs admission, workspace preparation, execution and finalization together, including startup failures. Synchronous admission-read exceptions release only the unstarted owned attempt and preserve changed ownership for recovery. Report development, independent verification, bounded repair and re-verification are exercised through the native protocol. Configured member execution now resolves every approved member’s repository policy and exact native base branch before entering the role worker. Initial source intent survives partial preparation and branch changes; generation rotation preserves its history. Configured native plans now feed member jobs into the existing scheduler and its shared capacity and retry queue. Durable, launch-bound results drive automatic role continuation; stopped or paused members lose eligibility, while an abruptly killed worker retains its exclusion lock. Legacy entry-point deadlines do not override sealed member budgets. Publication outside the owning Issue, retention cleanup, missing Git object acquisition and automatic crash recovery remain under development; parent manifest, acceptance and scoped rework require migration and live-provider validation.

Native standalone review now uses GitLab repository scans and persisted webhook hints through `review_lane`; mailbox watching and mail replay have been removed. Stable reviewer/publisher IDs, fixed-input rounds and native-stop fencing replace mail-based admission. Review comments now retain per-entry send intent, exact native readback and version-bound conclusions; partial batches resume only after confirmed native stop and current-scope checks. Live review cancellation now interrupts recorded native turns and requires idle readback before confirming stop; uncertain stops retain the snapshot. Review callbacks now bind the admitted worker and attempt, and same-VM Listener restarts stop surviving workers. Review journal reads and writes now use one Linux kernel-locked Python 3 transport, with durable predecessor-controller identity checks before takeover. Existing journals without ownership receipts require migration after old controllers are stopped. GitHub review now has native PR discovery, fixed-head comment readback and reviewer-withdrawal reconciliation. Live-provider acceptance, native orphan recovery after VM loss and deployment handoff remain to be validated.

The packaged executable also supports read-only tracker validation with
`bin/symphony /absolute/path/WORKFLOW.md --preflight [--issue ID]`; this does not
start Symphony's scheduler or HTTP server and needs no Mix project at runtime.
Workspace's launcher retains immutable local packages and can select a fixed
package independently of the development checkout. See
[the lifecycle contract](docs/workflow-lifecycle.md#lifecycle-write-and-retention-boundaries)
for rework, completion evidence, provider review execution and v2 cleanup boundaries.
