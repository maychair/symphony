# Versioned repository task workflow

Enable `tracker.provider.task_workflow: true` for GitLab with Codex native Goals.
Other trackers retain their existing execution contract. Configuration rejects an
unsupported combination. The five logical states are `ready`, `running`,
`waiting`, `review` and `ended`; routing still uses `symphony:ready` and the
one-use `symphony:retry`. Select exactly one ordinary type label:
`type:research`, `type:development` or `type:mixed`.

Repository Issues own scope, deliverables, decisions and acceptance. The existing
run journal stores decision references, execution restrictions, native identity,
accounting intervals and evidence references. It does not become another task
tracker. Both scheduler polls and native execution use the same journal and
execution exclusion. Poll reconciliation runs independently of available agent
slots and includes retained tasks without routing labels or with closed Issues.

## Confirmed agreement

The sole assigned user confirms the first agreement. Its note is the authority
baseline; later authorization changes require that recorded authorizer. An
agreement names an acceptor and optional reviewers explicitly delegated to request
in-scope rework. GitLab membership or an ordinary comment grants no authority.

Decisions are ordinary human-readable Issue notes with this structured trailer:

```html
<!-- symphony-workflow
{"action":"authorize","data":{"issue_version":"DESCRIPTION_DIGEST","type":"development","criteria":["result"],"deliverables":[{"id":"code","kind":"mr"}],"acceptor":"123","reviewers":[],"acceptance_mode":"separate","budget_ms":21600000}}
-->
```

`issue_version` is SHA-256 of the JSON-encoded Issue description (UTF-8, compact
JSON, unescaped Unicode). The description contains the human-confirmed goal,
scope, permissions and acceptance criteria. IDs in `criteria` and `deliverables`
refer to that agreement. Research requires reports; development requires MRs;
mixed tasks require both. `separate` is the default. `merge` is permitted only for
one MR that completely delivers a development task. An optional `deadline` uses
Unix milliseconds and remains in force while paused. Optional `dependencies` are
objects with `id`, `kind` (`issue` or `mr`), positive `number` and optional criterion
list `scope`; omitted scope blocks the whole task. Dependencies are in the same
repository and resolve on native closure or merge.

A decision reference is `note:ID@VERSION`, where VERSION hashes the compact JSON
object containing `body` and `updated_at`, with sorted keys. Every later decision
names `contract` with the confirmed authorization reference. Identity comes from
the native note author, never the payload. Notes are paginated, ordered by source
version time and deduplicated durably across restart. Edits form new versions;
previous operations are not undone. Edited or missing authorization, manifest or
acceptance evidence cannot grant new permission or prove completion.

| Action | Actor and required data |
| --- | --- |
| `pause` | Authorizer; optional stable `restriction` ID; always task-wide |
| `resume`, `release` | Authorizer; `restrictions` names exactly the restrictions being released |
| `restrict` | Authorizer; `kind`, optional `restriction`, `scope`, detectable dependency `condition` |
| `budget` | Authorizer; positive `add_ms`, added once to the cumulative limit |
| `rework` | Acceptor or delegated reviewer; existing `criteria`, `changes: []` |
| `manifest` | Authorizer or acceptor; complete delivery data below |
| `accept` | Acceptor; `manifest` names the submitted manifest reference |
| `cancel` | Authorizer; nonempty `reason`; cancellation is distinct from acceptance |

Unmapped rework or nonempty changes creates a scope restriction. It does not
expand authorization. Local restrictions leave independent criteria available;
a changed active work scope stops and rechecks the native execution before
continuing with fresh instructions. Task-wide pauses and cancellation override
all execution. A release cannot remove a later pause. Dependency satisfaction,
budget extension and pause release each affect only their own restrictions.

People can also post a standalone `暂停任务`, `停止执行`, `Pause task`,
`恢复执行` or `Resume execution`. These explicit intents use verified authorizer
identity and source order; resume releases preceding pauses only. Other prose
remains discussion and requires a concrete decision where its meaning is unclear.
An agent can translate an authorized human decision into the structured entry;
it must not invent that authorization or impersonate a different native author.

## Delivery and acceptance

A published MR and a completed agent turn are execution facts. Intermediate MR
review waits for human review. A verified publication request may specify
`continue_after: "merged"`; only the recorded source version's native merge can
release that review wait. Remaining work then passes admission again. Without
that explicit continuation, review comments and merge do not requeue execution.
Use native `Related to` for separate acceptance, mixed tasks and multiple MRs.

Publish an overall `manifest` decision with data like:

```json
{"contract":"note:ID@VERSION","items":[{"id":"code","url":"https://gitlab.example/team/project/-/merge_requests/9","version":"FINAL_SOURCE_SHA","criteria":["result"],"checks":true,"review":true}]}
```

The complete manifest covers all declared deliverables and criteria. `checks` and
`review` attest to the linked MR's business validation and technical review;
Symphony does not infer them from an agent exit or GitLab mergeability. Reports
use an Issue note URL ending in `#note_ID`, with the digest of its JSON-encoded
body. Put detailed reports and fixed evidence links in that note. This first
protocol accepts same-repository MRs and Issue-note reports. Other artifact types
must be represented by an evidenced report note; arbitrary mutable URLs are not
accepted as versioned deliverables.

Submitting the manifest enters overall acceptance and stops execution. Separate
acceptance requires the acceptor's `accept` decision naming that exact manifest.
Merge acceptance requires the declared single MR, verified source version,
recorded checks/review evidence and native merge. A substantive report or source
change invalidates the affected acceptance; submit and accept a new manifest.

A valid conclusion, native Issue closure and confirmed native stop are three
separate facts. Only all three produce `ended`. An externally closed Issue with
no valid basis remains waiting; it is not reopened automatically. Reopening adds
an explicit `reopen` restriction. A pause does not revoke an existing merge
acceptance agreement, and a legitimate merge during pause can conclude the task
without restarting an agent. Cleanup is independent of business acceptance.

## Accounting, recovery and rollout

The first configured limit is frozen into cumulative execution accounting unless
the authorizer specifies another budget. Active execution, automatic waiting and
retry backoff charge the task, including across restart. Human pause, decisions,
MR review and overall acceptance stop charging only after native stop confirmation.
Intervals are settled once; retries and new attempts do not reset consumption.
Each attempt is capped by both the configured run limit and remaining allowance.
A backwards wall clock stops work for a decision rather than granting new time.

A scheduler-owned label removal is recorded before mutation and verified by native
readback. Automatic restoration requires the enabling decision, all restrictions
cleared, unique ownership and confirmed stop. An unexplained external removal
creates `external_routing`; it requires an explicit authorizer release and is not
automatically undone. Every admission and post-hook activation rereads facts.
Queued stop messages take priority over native Goal handoff checks; active fact
reads are asynchronous and fail closed on error or expiry.

Deploy both the engine and its integration before enabling the option in retained
private workflows. Stop and reconcile the old service using its native execution
records; never launch another instance over an active journal. Keep workspaces,
records and existing executions. Legacy records are readable but receive no
inferred agreement or acceptance; provide a real Issue confirmation before
resuming them. A stale execution lock or unknown native allocation remains a
recovery incident. Do not delete locks to manufacture stop confirmation.
