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

Completion and errors move the owned task to `blocked` with label `human` and
metadata `symphony_gate=awaiting_human`. This state survives restart and is visible
in the existing local status API (`GET /api/v1/state`) and dashboard. No worker
exit merges or closes a task. The optional `beads_await_human` tool can also bind
an exact `review_url` and full `head_sha` to this run's delivery checkpoint. It
cannot accept or close tasks.

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
and reuses an existing open PR. It never merges. `publish_on_handoff: true`
allows an existing `beads_await_human` call without URL/head to publish and bind
the result before parking, useful for persisted threads whose native tool schema
predates `beads_publish`. Publication intent is journaled before side effects;
commit/push/PR retry inspects actual Git and remote facts.

GitLab read/reconciliation code is present; real GitLab validation requires a
separately authorized account/project. The current real smoke targets the
operator's GitHub fork only. No company GitLab repository is used.
