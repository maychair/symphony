# Versioned repository task workflow

Enable `tracker.provider.task_workflow: true` for GitLab with Codex native Goals.
Other trackers retain their existing execution contract. Configuration rejects an
unsupported combination. The five logical states are `ready`, `running`,
`waiting`, `review` and `ended`. Select exactly one ordinary type label:
`type:research`, `type:development` or `type:mixed`.

People and the engine own different labels. Humans own `symphony:ready`
(authorization and scheduling, kept while the task is live; removing it revokes
scheduling), `symphony:rework` (in-scope rework against an existing criterion) and
`symphony:accept` (accept the current manifest). The engine owns
`symphony:running`, `symphony:review`, `symphony:blocked` and `symphony:failed`;
it never writes a human label, and it repairs its own state label from the journal
on every poll. Each human label event is consumed once by its native event ID, so
a label left in place does not act twice.

Repository Issues own scope, deliverables, decisions and acceptance. The existing
run journal stores decision references, execution restrictions, native identity,
accounting intervals and evidence references. It does not become another task
tracker. Both scheduler polls and native execution use the same journal and
execution exclusion. Poll reconciliation runs independently of available agent
slots and includes retained tasks without routing labels or with closed Issues.

## Confirmed agreement

The sole assigned user confirms the first agreement with two facts: the
`symphony:ready` label and a self-checked contract block in the Issue description.

```html
<!-- symphony-contract
{"contract_sha":"SHA","type":"development","criteria":["result"],"deliverables":[{"id":"code","kind":"mr"}],"acceptor":"123","reviewers":[],"acceptance_mode":"separate","budget_ms":21600000}
-->
```

`contract_sha` is SHA-256 of the remaining JSON object (UTF-8, compact JSON,
sorted keys, unescaped Unicode). The `symphony:ready` label authorizes only when
that digest verifies against its own payload. The recorded authorization stores
`issue_version`, the digest of the whole Issue description; editing any part of
the description, inside or outside the block, invalidates it until a human applies
`symphony:ready` again. The description contains the human-confirmed goal, scope,
permissions and acceptance criteria. IDs in `criteria` and `deliverables` refer to
that agreement. An agreement names an acceptor and optional reviewers explicitly
delegated to request in-scope rework. GitLab membership or an ordinary comment
grants no authority. Later authorization changes require that recorded authorizer.
When a valid description block exists, a note that carries the `authorize` action
must repeat the block's agreement fields (`type`, `criteria`, `deliverables`,
`acceptance_mode`, `acceptor`, `reviewers`, `deadline`, `close_on_conclusion`,
`dependencies`, `budget_ms`) before it is accepted; a note cannot install a different
agreement than the block.

Later decisions are ordinary human-readable Issue notes with this structured
trailer:

```html
<!-- symphony-workflow
{"action":"rework","contract":"label:42@1@2026-10-16T00:00:00Z","data":{"criteria":["result"],"changes":[]}}
-->
```

Research requires reports; development requires MRs; mixed tasks require both.
`separate` is the default. `merge` is permitted only for
one MR that completely delivers a development task. Set `close_on_conclusion: true` only when the authorizer explicitly grants native
Issue closure after valid acceptance or cancellation. Omitted or false leaves
closure to the human. A stopped execution and successful close readback are
required before the next poll can report ended. An optional `deadline` uses
Unix milliseconds and remains in force while paused. Optional `dependencies` are
objects with `id`, `kind` (`issue` or `mr`), positive `number` and optional criterion
list `scope`; omitted scope blocks the whole task. Dependencies are in the same
repository and resolve on native closure or merge.

A decision reference is `note:ID@VERSION`, where VERSION hashes the compact JSON
object containing `body` and `updated_at`, with sorted keys. The authorization
reference is `label:ID@ACTOR@CREATED_AT`, taken from the authorizing
`symphony:ready` label event. Every later decision names a top-level `contract`
with the confirmed authorization reference, alongside `action` and `data`. For
example, this is a complete pause decision:

```json
{"action":"pause","contract":"label:42@1@2026-10-16T00:00:00Z","data":{"restriction":"manual-pause"}}
```

These complete decision objects are the contents of Workspace's `--decision-file`;
the CLI appends the structured trailer to a separate human-readable explanation.
Putting `contract` only inside `data` does not identify the decision's agreement
and is rejected. Identity comes from
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

`symphony:rework` and `symphony:accept` are the label form of the `rework` and
`accept` decisions: the engine derives `criteria` from the recorded agreement and
the manifest from the latest submission, so the labels need no payload. Pause,
resume, restrict, budget, manifest and cancel still use the note form above.

Unmapped rework or nonempty changes creates a scope restriction. It does not
expand authorization. Local restrictions leave independent criteria available;
a changed active work scope stops and rechecks the native execution before
continuing with fresh instructions. Task-wide pauses and cancellation override
all execution. A release cannot remove a later pause. Dependency satisfaction,
budget extension and pause release each affect only their own restrictions.

People can also write ordinary explicit requests such as `请暂停这个任务。`,
`Please pause this task.` or `Please resume execution.`. These intents use verified authorizer
identity and source order; resume releases preceding pauses, including an older
pause observed later, and the decision handoff of the question it answers. Unclear
requests to pause or resume enter a clarification wait.

A blocking question is answered in the Issue itself. While the agent's handoff
holds a task-scope decision restriction, the sole assignee's first note after the
engine posted its question releases that restriction, so answering needs no
label. Answering is not resuming: it leaves a pause the owner asked for in
place, and only an explicit resume releases that pause. Notes carry second
precision, so a note in the question's own second counts only when its note id
follows the notice. Engine notices end with a `<!-- symphony-engine-notice -->`
line of their own; the engine never answers its own question, and a reply that
quotes the notice counts. A review handoff is unchanged and still waits for
`symphony:accept` or `symphony:rework`.

Other prose remains discussion and requires a concrete decision where its meaning
is unclear.
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

The final handoff includes a `需要你做什么` section. It links the submitted
artifacts, states when a report-only task correctly has no MR, and names the
remaining action: merge the approved MR, add `symphony:accept` for separate
acceptance, or request in-scope rework. The Scheduler generates this section
from the manifest and acceptance mode so the action does not depend on an
executor inventing prose.

Publish an overall `manifest` decision using this complete `--decision-file` object:

```json
{
  "action": "manifest",
  "contract": "label:42@1@2026-10-16T00:00:00Z",
  "data": {
    "contract": "label:42@1@2026-10-16T00:00:00Z",
    "items": [{"id":"code","kind":"mr","url":"https://gitlab.example/team/project/-/merge_requests/9","version":"FINAL_SOURCE_SHA","criteria":["result"],"checks":true,"review":true}]
  }
}
```

For a manifest, both `contract` fields are required and must name the same
authorization: the top-level field binds the decision, and `data.contract` binds
the delivery manifest. The MR publisher's `--manifest-file` instead takes only
the `data` object shown above, with paired `$publication` placeholders for the
current MR. It constructs the complete decision when posting the handoff.

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
Its complete `--decision-file` object is:

```json
{"action":"accept","contract":"label:42@1@2026-10-16T00:00:00Z","data":{"manifest":"note:MANIFEST_ID@MANIFEST_VERSION"}}
```

Use the authorization label's reference for `contract` and the submitted manifest
note's reference for `data.manifest`; they identify different source decisions.
The authorization reference comes from the `symphony:ready` label, so use its
`label:ID@ACTOR@CREATED_AT` value. The `symphony:accept` label carries no manifest
ref of its own: it accepts the manifest current when the poll reduces events, so a
manifest note and an `symphony:accept` label that arrive in the same poll are
applied in source order.

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
rework backoff charge the task, including across restart. Human pause, decisions,
MR review and overall acceptance stop charging only after native stop confirmation.
Intervals are settled once; retries and new attempts do not reset consumption.
Each attempt is capped by both the configured run limit and remaining allowance.
A backwards wall clock stops work for a decision rather than granting new time.
Successful handoff/rework attempts do not consume the separate cumulative failure
counter. One confirmed-stopped transient failure is reworked automatically; the
next failure becomes a persistent Incident that only a new human decision clears.
There is no retry label, and a fresh decision does not reset the counter or the
execution budget.
Recording an Incident clears any pending `resume_requested`, so a rework granted
while a run was still executing cannot silently recover a later failure. Recovery
requires a new human decision and an executor state of confirmed stop: a run that
failed before it allocated a thread is recoverable by a later decision, while a
possibly-live thread stays an incident until the native stop is confirmed.

Cleanup additionally compares current decision-note versions with the last
observation saved by the engine; a newly arrived or edited decision prevents
deletion until reconciliation. It never reconstructs a second decision reducer.
Executor lock receipts bind recovery and release to the recorded attempt/owner;
a late callback from another scheduler cannot finalize the new execution.

The engine writes only its own state labels, and every write is verified by native
readback before it is trusted. It never adds or removes a human label; an
unexplained removal of `symphony:ready` creates an `external_routing` restriction
that needs an explicit authorizer release. After confirmed stop, scope disputes,
exhausted budgets and unclear control requests produce a deduplicated Issue notice
with the required next action.
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
