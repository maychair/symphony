# Native Beads development loop

`tracker.kind: beads` uses the installed `bd` CLI (tested contract: 1.3.1 JSON
arrays). Symphony retains its existing Tracker, Orchestrator, AgentRunner and
Codex app-server. Beads owns tasks, dependencies, acceptance and human gates;
Symphony stores execution checkpoints separately. No second scheduler is added.

Start from [WORKFLOW.beads.md](../WORKFLOW.beads.md). Set absolute `BEADS_DIR`,
`SYMPHONY_RUN_JOURNAL_DIR`, `SYMPHONY_WORKTREE_ROOT`, `SYMPHONY_TARGET_REPO` and
`SYMPHONY_BASE_REF` before starting the existing `bin/symphony` executable with
this workflow. Set `SYMPHONY_REVIEW_REPOSITORY` to `github.com/owner/repository` or
`gitlab.com/group/repository` before publication acceptance. Native Codex roles
and credentials remain in the user's existing configuration. The mandatory
routing label is an explicit enablement boundary: add `symphony-enabled` only to
authorized tasks. An empty required-label configuration is rejected.

## Configuration

Provider fields are `bin` (default `bd`), `dir` (optional CLI cwd), `beads_dir`
(absolute path or `$ENV`, defaults to `BEADS_DIR`), `run_journal_dir` (absolute path
or `$ENV`, defaults to the database parent's `symphony-runs` directory),
`timeout_ms` (default 15000), and `review_repository` (required for acceptance).
`active_states` must be `[open, in_progress]`, `terminal_states` `[closed]`.
The local adapter rejects SSH execution; local database paths are not remote
storage. Each run freezes its provider settings and passes the correct
`BEADS_DIR` to native agents and creation/run hooks, even if an inherited value
points elsewhere. The example sandbox permits source work in the worktree;
external Beads mutations use the bounded native tracker tool.

`bd ready` determines initial dependency readiness; `dependency_count` is not a
readiness flag. `bd list --all --limit 0` and `bd show --json` normalize current
records, preserving source `external_ref` and metadata. Acceptance criteria,
design and notes are included in the authoritative agent prompt.

## Admission, delivery and recovery

An exclusive `executor.lock` directory and synced JSON checkpoint are written
before guarded claim, `thread/start` and `turn/start`. Observed thread/turn IDs
are persisted synchronously before further execution. Claims use random owner
incarnations with exact `--if-assignee` and `--if-status` guards. The checkpoint
records database scope, attempt identity, local executor host/PID, workspace and
up to 200 recent transition events. It contains no duplicate task goals.

This version runs one root native turn per Beads admission. Root completion is
filtered by thread and turn; failed/interrupted envelopes are failures. Child
notifications cannot complete the root. Child/unknown server requests receive a
refusal and park the run for human input rather than waiting indefinitely or
auto-approving. Other providers retain their continuation policy and legacy
ID-less fixture compatibility; Beads requires identified terminal events.

Completion without a bound delivery and execution errors move the owned task to
`blocked` with label `human`, metadata `symphony_gate=blocked` and journal phase
`blocked`. Use `beads_await_human` with `intent: blocked` to record a concrete blocker and
release condition; `beads_block` and reason-only calls remain compatible aliases.
A turn ending without either tool records an explicit instruction to inspect native
session evidence before resuming. Local implementation without a review binding
also remains blocked for operator inspection and continuation.

Actual deliveries use `beads_await_human` with both exact `review_url` and full
`head_sha`, then enter journal phase and metadata gate `awaiting_human`. Partial
bindings are refused. These states survive restart and remain visible in the
existing status API (`GET /api/v1/state`) and dashboard, which display the durable
blocker reason or a dependency wait separately from delivery acceptance. No worker exit merges or
closes a task. Remote polling skips preparation blockers; it migrates legacy
awaiting-human records with no delivery or review metadata to `blocked` once the
executor lock is absent, preserving existing notes as the blocker reason.

Uncertain intent, corrupt records, missing IDs, a live lock or lost ownership
blocks admission. There is no dead-PID automatic release. To continue a known
thread, stop Symphony and any App executor first, then run from `elixir/`:

```sh
mise exec -- mix beads.resume --workflow /absolute/WORKFLOW.md --issue bd-ID --executor-stopped
```

This command starts no Orchestrator. On Linux it refuses a still-existing
recorded local executor PID, unknown host or missing native IDs. A native
`thread/resume` must prove idle and the observed last turn terminal before the
exact owner's task is released for continuation. Restart Symphony to resume that
thread. A crash before an ID was observed requires manual investigation; this
command deliberately cannot authorize a replacement thread. Cross-host recovery
and non-Linux executor liveness are not supported. Checkpoints protect process
crashes; directory entries are not fsynced, so power-loss durability is not claimed.

## Explicit acceptance

After human review and the delivered PR/MR has actually merged:

```sh
mise exec -- mix beads.accept --workflow /absolute/WORKFLOW.md --issue bd-ID \
  --review-url https://github.com/owner/repository/pull/123 --accepted-by HUMAN
```

Acceptance requires a durable awaiting-human delivery, observed native IDs,
no executor lock, exact owner, routing labels, the configured repository, exact
review URL and delivered head commit. Bounded `gh`/`glab` reads independently prove
merged state, merge commit and matching head. Arbitrary merged reviews and
model-supplied acceptance claims cannot satisfy this gate. Repeating a successful
operator acceptance is idempotent.

If the bead's `external_ref` is a source Issue URL, add `--close-source` explicitly.
The command verifies that Issue belongs to the same configured repository,
closes it through `gh`/`glab`, confirms closed state, then performs guarded Beads
closure. Missing authority, wrong source scope, API failure or unconfirmed closure
leaves the bead open. Re-entry handles an already-closed source Issue. Informal
non-URL source references must first be resolved by an operator; source metadata
is never overwritten. Neither operator command is advertised as an agent tool.

## Workspace retention and validation

Beads workspaces are always retained, including terminal startup cleanup and
partial creation-hook failures. `workspace.retain: true` also enables retention
for other providers. A retained workspace marker survives workflow reloads;
registered Git worktrees are never removed by `rm_rf`. For other workspaces,
a failing `before_remove` hook vetoes deletion. Explicit Git cleanup belongs to
the operator after reviewing commits, dirty files and ignored artifacts; no
force deletion or fallback is used.

Use an isolated temporary Beads database with a unique enablement label for a
real smoke; never poll production task labels during validation. The existing
HTTP server binds to localhost in the example. Unit fixtures exercise guarded
claim loss, uncertain checkpoints, native root/child lifecycle, inherited wrong
BEADS_DIR, delivery and acceptance refusals. Live external tests remain opt-in.
Run `mise exec -- make all` for the complete owning-project gate. External build
storage should use `MIX_BUILD_ROOT` (which preserves `dev`/`test` partitions), not
a shared `MIX_BUILD_PATH` that combines protocol consolidation across environments.

## Event-driven reconciliation

Enable `tracker.provider.remote_reconcile: true` explicitly. Every routed task
must bind its source Issue URL in Beads `external_ref`; the remote Issue is read
before admission. The repository must match `review_repository`.

The existing Orchestrator poll cycle now reconciles delivery facts through native
`gh` / `glab` authentication. Unresolved review threads, Changes Requested or
failed checks request another bounded turn of the observed idle thread. New
admissions invalidate prior delivery evidence; the exact attempt/turn/head must
be bound again. Unchanged feedback is deduplicated. Configure `max_repair_runs`
(default 3) and `run_budget_ms` (default 600000). A timed-out or ambiguous native
execution remains fenced for operator recovery.

A closed, unmerged review never completes the task. A merge closes the source
Issue and Bead only when the delivered head matches, threads are resolved,
checks succeed (including every configured `required_checks` name), and the
merge actor is in `accepted_merge_actors`. Symphony never performs the merge.
An unavailable API or incomplete paginated GitHub response does not grant
acceptance. GitLab discussion pagination uses the installed glab API command.

`POST /api/v1/webhooks/github` validates the raw-body SHA256 HMAC;
`POST /api/v1/webhooks/gitlab` validates the configured token. Set
`webhook_secret` to an environment reference, with at least 16 bytes. Receipts
persist only event identity/digest/time outside Git. Repository scope and
provider delivery IDs are required. Duplicate receipts still wake reconciliation
so a process crash between receipt and wakeup cannot lose the change. Polling
recovers missed events without a second scheduling service. Configure a secure
reachable endpoint externally to receive real remote Webhooks; the local smoke
uses signed requests and real remote polling.

`GET /api/v1/runs/:issue_identifier` exposes bounded journal events, native
identities, attempts, delivery binding and the reconciled remote state.

## Rapid development and scoped publication

The Workspace rapid-development playbook authorizes current-agent development
in the personal/open-source primary checkout, without subagents or internal
review, using necessary build/syntax checks and a real core-path smoke. Company
projects are excluded. This prototype evolves in place; it is not disposable.
The controlled smoke task uses a retained fixture worktree so its proof-file PR
does not publish the engine's unfinished source.

Native workspace-write sandboxing can protect Git metadata even for authorized
publication. Opt in to the `beads_publish` host tool with the task label
`symphony:publish` and an explicit `publish_paths` list. The tool stages only
those regular relative files, refuses unrelated staged changes, checks the
configured GitHub remote and a `codex/` task branch, uses gh's credential helper,
and reuses an existing open PR. It never merges. Call `beads_publish` (or the
composed `beads_deliver`) to publish, then hand off both the URL and SHA.
Partial URL/SHA handoffs are rejected even when `publish_on_handoff` is configured.
A reason alone always parks an undelivered blocker without publication. Publication intent is journaled before side effects;
commit/push/PR retry inspects actual Git and remote facts.

GitLab read/reconciliation code is present; real GitLab validation requires a
separately authorized account/project. The current real smoke targets the
operator's GitHub fork only. No company GitLab repository is used.

## Self-managed GitLab

Set `tracker.provider.gitlab_web_url` to the exact GitLab web origin (HTTPS by
default; HTTP requires explicit configuration), and `review_repository` to
`host/group/project`. Issue, MR and webhook origins must match; API calls select
the native credential profile explicitly with `glab api --hostname HOST`. Nested
groups are supported. Authentication and API transport remain owned by glab.

Host publication supports GitLab with `git_remote` (default `origin`),
`publish_base` (default `main`) and the existing exact `publish_paths` allowlist.
The configured remote URL must match the configured repository; GitLab uses
native Git/SSH credentials, never GitHub's credential helper. MR creation uses a
JSON request with explicit Content-Type. Only one matching open same-project MR
is reused. Publication still never merges; task-specific operator authorization
and verification remain separate from scheduler reconciliation.

Before-first-turn recovery is an explicit exception to the complete-ID gate: a
stopped executor with a durable thread-ready checkpoint, zero turns and no turn
identity can be inspected. A persisted idle thread must prove an empty turn
list; if the native server explicitly reports no rollout for that exact allocated
thread ID, the journal retains the abandoned allocation and permits a new thread.
No unknown turn-start intent is replayed. Guarded ownership remains unchanged.
An unstarted source Issue that becomes available again releases an in-memory
block only when its journal proves no Run exists. Rebuild the escript after
source changes; compiling modules alone does not refresh bin/symphony.

## Task validation, host context and preflight

A trusted local Beads `metadata.symphony_validation` object overrides
`tracker.provider.validation_policy` before admission. Without either, existing
repository gates remain unchanged. Example rapid policy:

```json
{"mode":"targeted","review":"none","commands":[["python3","-m","compileall","-q","src"]],"timeout_ms":60000}
```

Modes are `targeted`, `full`, and `baseline_diff`; the configured argv arrays
must actually implement the selected scope. Review is `required` (default) or
`none`; this directs the Coordinator and never grants merge authority.
`baseline_diff` requires a nonempty `baseline_authorization` citing explicit
operator/repository authority. Its commands must compare fixed baseline and
candidate failures and return nonzero for any new failure. The host does not
infer a waiver from existing red tests or attempt to interpret arbitrary test
framework output. Keep baseline artifacts outside the active source worktree.

Set `tracker.provider.allow_host_validation: true` only for trusted local task
configuration. This permits host execution of the **frozen** argv arrays, not
commands supplied in tool arguments or remote comments. Commands have a
100–300000 ms per-command budget (default 60000), maximum eight commands, and
GNU `timeout` bounds process groups. Logs stay in the private Run directory.
The existing Run budget remains an outer limit. Host commands are privileged
relative to the agent sandbox, so never copy untrusted Issue text into this
policy without developer authorization.

The no-argument `beads_task_context` tool reads only its currently owned task,
including notes, acceptance criteria, current `updated_at`, metadata, attempt ID
and frozen policy. Output is bounded to 64 KiB; no raw external database access
from the agent sandbox is required. A foreign task ID or owner is rejected.
`beads_validate` executes configured checks on the clean committed task worktree
and journals individual process exit codes and log paths. Commit source changes
before calling it. A receipt opens publication/delivery only for the same
attempt, policy and clean HEAD, and the delivery SHA must match. Changed source
or a new attempt requires new verification. A successful tool transport carrying
`passed: false` is a failed verification. Parking without delivery remains
possible when blocked. Acceptance and remote merge gates are unchanged.

Before admitting a Run or allocating a native session, the adapter checks local
executables, validates the policy and renders the actual strict task prompt.
That exact rendered prompt is reused for the first turn. Invalid templates leave
no claim or journal lock. A changed policy on an existing native thread is
blocked for operator handoff rather than silently changing its authority.
Existing threads cannot acquire new dynamic tool registrations through resume;
use a new authorized task/thread when new tools or policy are required.

```sh
mix beads.preflight --workflow /path/to/WORKFLOW.md --issue task-id
```

This checks configuration and optionally the concrete task without starting a
scheduler, claiming it or creating a session. A live source Issue is still checked
at actual admission. Workflow shell hooks and arbitrary shell command internals
are not executed by preflight.

## Corrected session evidence

```sh
python3 scripts/session_evidence.py --rollout /private/rollout.jsonl \
  --run-record /private/run.json --output /private/session-evidence.json
```

The exporter reads immutable native logs and optionally a matching thread's Run
snapshot. It records historical cwd/commit from `session_meta`, resolves the
actual worktree's Git common directory and remote, and separates transport
response delivery from explicit nested exec-envelope exit codes. Missing or
unrecognized process outcomes, cost and verification remain unknown. A wait
response is not attributed to its initiating command without observed linkage.
No arbitrary JavaScript is executed or guessed, no native logs or third-party
Traces packages are modified, and no internal review relationship is fabricated.
The output contains private repository identity and must stay outside Git.
`/api/v1/runs/:id` additionally exposes the frozen validation policy and receipt.

The no-argument `beads_checkpoint` tool performs only the authorized configured-path
commit using explicit task authority and owner/branch/remote checks. It does not push or
create a review and does not require a validation receipt. Use checkpoint, validate,
then publish when Git metadata is protected in the agent sandbox. Publication
rechecks the receipt after its idempotent commit step and before any push.

## Ready worktrees, typed handoff and recovery budgets

Explicit host-validation tasks now preflight the actual Git worktree before native
thread allocation. The exact untracked regular `.symphony-retain` marker is excluded
only from the engine's status invocation; other files still require a clean commit.
Foreign/tracked markers, symlinks and unrelated dirtiness are rejected. Bootstrap
preserves foreign markers instead of overwriting them. No shared Git ignore changes
or broader sandbox permissions are needed.

`beads_await_human` accepts optional `intent`:

- `blocked`: reason plus optional checkpoint head SHA, without a review URL.
- `ready_for_review`: reason plus both review URL and verified head SHA.

Legacy reason-only and complete URL/SHA forms remain compatible. Partial delivery
is rejected with a corrective error before publication or Run mutation. A blocked
checkpoint is never a delivery or acceptance. Operator merge gates are unchanged.

`Recovery.resume_completed/3` accepts `cause: runtime` or `cause: review` (legacy
default). Runtime recovery increments `runtime_recovery_count`, bounded by provider
`max_runtime_recoveries` (default 2), without consuming review `repair_count` or its
`max_repair_runs` budget. Limits are checked before native inspection/side effects.
Optional observed `actor` and `caused_by_event` persist trigger provenance. Recovery
still requires completed native identity, correct scope, no lock and proven idle;
unknown outcomes do not become retryable merely by selecting a cause.

## Compact briefs and composed delivery

Set `tracker.provider.compact_task_context: true` to read task body/acceptance/notes
once through `beads_task_context`, with `task_version` and frozen policy. The actual
custom Workflow still renders and preflights; only repeated task fields become
host-read references. On the same native thread and unchanged template hash, a
shorter recovery delta may replace resending the full rendered brief. A changed
Workflow resends instructions; a changed policy remains blocked. Mandatory repo
rules and current ownership checks are retained. Default rendering stays compatible.

The no-argument `beads_deliver` uses the existing guarded checkpoint, validate,
publish and ready-for-review handoff steps. Explicit commands and enabled host
validation are required. Every boundary is journaled as `delivery_step`; failures
record `delivery_error`. Receipts capture argv, timestamps, exit code, duration and
SHA-256 of actual log bytes. A failed or stale receipt cannot authorize a push.
Repeated delivery reuses a matching confirmed result; interrupted calls replay
idempotent guarded stages and reconcile a completed handoff by readback. This is
not an atomic Git/API transaction. Granular tools remain available; no new merge
or acceptance authority is introduced.

`session_evidence.py --otlp-out FILE` also exports private native-event spans. JSON
schema version 2 separates wrapper calls from typed native operations, native
command exits from host tool success, and observed verification receipts from
transport completion. Repeated native IDs are deduplicated; incomplete native
coverage retains wrapper evidence rather than inventing a join. Token/cache usage
and explicit recovery provenance are preserved. Missing costs, actor identities
or causal links remain uncaptured; no native transcripts are rewritten.

A proven workspace preflight abort before any thread allocation can be recovered
through the stopped-executor operator path without inventing native IDs. Thread
start/turn intent uncertainty remains fenced; a new admission clears that proof.

## Local checkpoint authority and child tools

Local-only commits can opt in with the current task label `symphony:checkpoint`
and a trusted provider `checkpoint_paths` list. This does not grant publication.
Owner, open source Issue, task branch, repository remote and exact staged paths
are still checked on the host. Existing `symphony:publish` / `publish_paths`
checkpoint callers remain compatible. If both labels exist, checkpoint uses the
local checkpoint list; publication independently requires its original authority.
No sandbox write expansion is needed for shared Git worktree metadata.

Task tools remain bound to the root thread and current turn. An inherited child
or stale-turn tool call gets a structured `root_task_tools_only` failure without
executing the host action or ending the parent Run. The root must provide the
child's task snapshot and perform host actions itself. Unscoped approval requests
continue to stop execution for operator handling; foreign completion events
cannot complete the root turn. No arbitrary child identity is admitted.

Deploy only when the owning executor is idle and stopped. Preserve its Run record
and native identities; supply the explicit local task label and exact trusted
checkpoint paths before recovery. Never grant publication merely to unblock a
local checkpoint, or restart an active Run to apply this package.


## Operator workbench

`GET /api/v1/workbench` returns structured gates, native execution identity and
operator receipts. `POST /api/v1/workbench/:issue/:gate/decide` takes the exact
`binding`, `choice`, `actor` and optional comment. The proxy authenticates using
`X-Symphony-Workbench-Token`, whose value comes from the native
`SYMPHONY_WORKBENCH_TOKEN` environment (at least 32 bytes). It is never sent to
browser JavaScript. Missing credentials deny access.

Gates and decisions live in Beads `metadata.symphony_workbench`. Kinds are
`authorization`, `decision`, `review`, `incident`, `dependency`; a task may have
several concurrent gates. `beads_request_action` parks an owned task with these
gates. Already-registered reason-only tools can send `workbench:v1` followed by
a newline and a JSON object with `gates`. Legacy untyped blockers become
explicit diagnostic incidents rather than guessed authorization requests.

An operation records its decision before effects and returns its original
receipt on identical replay; different choices and stale task/attempt bindings
are refused. Dependency gates use local IDs or configured `project:id` stores.
After all gates resolve, online resume requires confirmed native shutdown, no
executor lock, and a read-only native idle reconciliation. Failure produces a
repair incident rather than blind retry. A repair click creates a deterministic
linked Bead in a trusted `workbench_projects` route; the receiving scheduler
starts the native Goal. Original tasks wait for verified repair closure.

Review must bind a commit and either a scoped MR/PR or immutable local artifact.
Local technical review records acceptance without closing the task or replacing
the final merged-delivery gate. `GET .../:issue/:gate/artifact` only reads the
bound file under configured `workbench_artifact_roots`, rejects symlink paths,
checks its digest, and limits responses to 512 KiB. GitLab acceptance supports
both merge commits and squash commits.

Trusted single-worker maintenance instances can set `workbench_primary_checkout`
to execute in the verified `SYMPHONY_TARGET_REPO` primary checkout. It does not
change normal isolated task workspaces. Publication and merge authority remain
separate; the workbench is not a general command-execution endpoint.

Remote-backed repositories must publish a scoped PR/MR before requesting review.
A local artifact does not substitute for remote delivery. Legacy local-review
gates are presented as publication work, outside the operator review inbox.
The request API rejects local-review gates for configured or detected remotes
and rejects review URLs outside the configured repository.

A manually tracked historical task without any native Run may explicitly mark
a remote gate `manual_delivery: true`. Its acceptance verifies the configured
repository, exact published head and remote merged proof before closing the
manual task. Native Run deliveries continue through normal native acceptance;
no thread/turn identity or validation receipt is fabricated.
