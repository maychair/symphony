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
one MR that completely delivers a development task. Set `close_on_conclusion: true` only when the authorizer explicitly grants native
Issue closure after valid acceptance or cancellation. Omitted or false leaves
closure to the human. A stopped execution and successful close readback are
required before the next poll can report ended. An optional `deadline` uses
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

People can also write ordinary explicit requests such as `请暂停这个任务。`,
`Please pause this task.` or `Please resume execution.`. These intents use verified authorizer
identity and source order; resume releases preceding pauses only, including an older pause observed later.
Unclear requests to pause or resume enter a clarification wait. Other prose
remains discussion and requires a concrete decision where its meaning is unclear.
A coordinating human session can translate an authorized decision into the
structured entry. The executing agent may submit manifests and evidence; native
dynamic tools and the decision CLI reject its attempts to originate human control
decisions. This is an auditable tool boundary, not an OS credential sandbox. The
execution must not bypass it through another credentialed client.

## Delivery and acceptance

A published MR and a completed agent turn are execution facts. Intermediate MR
review waits for human review. A verified publication request may specify
`continue_after: "merged"`; only the recorded source version's native merge can
release that review wait. Remaining work then passes admission again. Without
that explicit continuation, review comments and merge do not requeue execution.
Use native `Related to` for separate acceptance, mixed tasks and multiple MRs.
For the final MR, the Workspace publisher accepts `--handoff --manifest-file FILE`.
Prepare every delivery item before publication and use paired `$publication`
placeholders in the current MR item's URL and version. The publisher binds that
verified MR and saves the complete manifest in the same atomic review request.
Symphony verifies the contract and item coverage, posts a human-readable full
checklist with its versioned manifest, and stops execution. Do not combine final
submission with intermediate continuation. Stopped-run polls recover unfinished
review requests, including an already merged MR or a notice beyond the first
comments page, without allocating a replacement executor.

Publish an overall `manifest` decision with data like:

```json
{"contract":"note:ID@VERSION","items":[{"id":"code","kind":"mr","url":"https://gitlab.example/team/project/-/merge_requests/9","version":"FINAL_SOURCE_SHA","criteria":["result"],"checks":true,"review":true}]}
```

The complete manifest covers all declared deliverables and criteria, and each
item's kind and native artifact type must match the agreement. All required MRs
must be merged with the recorded validation/review evidence before conclusion. `checks` and
`review` attest to the linked MR's business validation and technical review;
Symphony does not infer them from an agent exit or GitLab mergeability. Reports
use an Issue note URL ending in `#note_ID`, with the digest of its JSON-encoded
body. Put detailed reports and fixed evidence links in that note. This first
protocol accepts same-repository MRs and Issue-note reports. Other artifact types
must be represented by an evidenced report note; arbitrary mutable URLs are not
accepted as versioned deliverables.

Submitting the complete manifest stops execution. Pending technical review or
unmerged MRs keep the task waiting; only complete native delivery evidence enters
overall acceptance. Separate
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
Successful handoff/rework attempts do not consume the separate cumulative failure
retry counter. Two confirmed-stopped transient failures can retry automatically;
an explicit retry request does not reset that counter or the execution budget.

Cleanup additionally compares current decision-note versions with the last
observation saved by the engine; a newly arrived or edited decision prevents
deletion until reconciliation. It never reconstructs a second decision reducer.
Executor lock receipts bind recovery and release to the recorded attempt/owner;
a late callback from another scheduler cannot finalize the new execution.

A scheduler-owned label removal is recorded before mutation and verified by native
readback. Automatic restoration requires the enabling decision, all restrictions
cleared, unique ownership and confirmed stop. After confirmed stop, scope disputes, exhausted budgets and unclear control
requests produce a deduplicated Issue notice with the required next action.
Repeated polls and a lost local notice receipt do not repost the request.
An unexplained external removal creates `external_routing`; it requires an explicit authorizer release and is not
automatically undone. Every admission and post-hook activation rereads facts.
When the old worker is gone, the poll owner halts the recorded Goal, interrupts
its active native turn and validates native idle under the same execution lock.
It neither starts a new thread nor resumes the stopped Goal. Confirmed observations
update the last turn identity for later recovery; unknown allocation, native errors
or an unproved stop remain waiting. The recorded worker host remains bound to a
resumed thread. Queued stop messages take priority over native Goal handoff checks; active fact
reads are asynchronous and fail closed on error or expiry.

Deploy both the engine and its integration before enabling the option in retained
private workflows. Stop and reconcile the old service using its native execution
records; never launch another instance over an active journal. Keep workspaces,
records and existing executions. Legacy records are readable but receive no
inferred agreement or acceptance; provide a real Issue confirmation before
resuming them. A stale execution lock or unknown native allocation remains a
recovery incident. Do not delete locks to manufacture stop confirmation.
