# One review workflow

Manual requests and native MR/PR discovery use `ReviewWorkflow.run/2`. Trigger
adapters identify and authorize a subject; they do not choose another prompt,
axis count, verdict rule or result formatter. The source adapter pins base,
head and an isolated snapshot. A local review needs no repository Issue.

The shared policy has exactly `Common`, `Standards` and `Spec` sections. It is
loaded once and its digest is pinned for the round. Optional `role_files` maps
`standards` and `spec` to the same centrally maintained role TOML files for both
entry points. Only `model` and `model_reasoning_effort` are read from these files;
permission settings cannot be overridden there. Missing or malformed rules fail
before native allocation. Rules provide review criteria, not execution authority.

`ReviewWorkflow` starts two independent native reviewers concurrently and owns
their lifecycle. `ReviewAxis` probes the native read-only sandbox before the
turn, provides bounded read-only source tools, validates structured findings and
records native stop confirmation. The tools cannot read outside the isolated
snapshot or expose repository Git credentials. Shell failures are never silently
upgraded to a broader sandbox.

`ReviewResult` is the only aggregate validator and renderer. Both axes must have
valid completed results, actual read evidence, distinct native identities and
confirmed native stop before an empty finding set can mean pass. Missing input,
failed reads, timeout and missing axis results remain non-pass states. An Agent
exit, an empty list or a successful HTTP POST is never completion evidence.

`Runner` connects this workflow to the existing scheduler and journal;
`Listener` owns native discovery, round identity, execution ownership and durable
recovery. `Finding` continues to own finding identity and independent resolution.
`Publication` owns guarded native transport and receipts, not review judgement.
No review component approves or merges a change.

An admitted worker sends checkpoints directly to the owning listener. Native
discovery may occupy that listener beyond the short observational health-probe
timeout; a health probe is not an execution prerequisite. Checkpoints retain
their bounded request timeout and ownership checks. During listener startup,
only the explicit initializing response or a temporarily unavailable process
uses the existing bounded reconnect window; rejected ownership is never retried.

Execution state, review outcome and publication state are distinct. Only a
complete review with no requested changes renders exactly `LGTM!`, without
visible or hidden metadata. Changed results retain separate Standards and Spec
reports. Native version and policy identities remain in the journal and receipt.
An uncertain markerless send is fenced, not guessed from another generic LGTM
comment and not sent again. Old publication bytes remain frozen for audit; they
cannot supply missing evidence for a new review.

Enabling a listener or changing its journal ownership follows the repository
service reload rules. Updating code does not authorize interruption of other
executions. Live validation and service activation are separate from a passing
source quality gate.

Successful standalone preflight reports the executable's protocol inventory,
including `review_workflow` version 2. Managed launchers require this capability
from the actual package, rather than inferring it from a source checkout or a
tracker-only preflight. Enabled lanes validate the shared policy before startup.
Completed legacy rounds retain their original publication bytes and do not rerun
solely because deployment changes the policy. A new native revision or author
response can still admit a new round under the current protocol.

## Manual entry

`mix symphony.review --workflow REPOSITORY_WORKFLOW --request REQUEST.json`
loads the same lane configuration and calls `ReviewRequest.prepare/2` and
`ReviewWorkflow.run/2`. It emits the canonical result JSON and performs no native
publication. The caller displays its `body`; `failed` and `needs_input` are failures.
A local request specifies `kind: local`, `repository`, `base`, `head` and
`target_branch`, with optional explicit `issue` evidence. The source checkout
stays unchanged; the comparison uses the merge-base. An MR request specifies
`kind: mr`, `project` and `number`; supplied record revisions must match the native
subject. Snapshot paths must stay inside the configured workspace root. Only a
confirmed stopped manual run may clean up its temporary snapshot.

Thread and turn allocation require durable admission before their native request.
Cancellation denies new allocations while still recording observed identities and
stop receipts. Lost allocation replies remain uncertain. An admitted policy digest
cannot be replaced in place, and native sandbox failures remain disqualifying even
if a later tool submits an empty finding set.

Source acquisition uses the existing 30-second bounded command transport.
Native closing Issue URLs are resolved only within the selected repository;
unresolved or foreign closing links remain explicit incomplete evidence. Any
failed file read is sticky for that axis, including non-text input. Large text
is paged inside the native read-only sandbox before crossing the RPC boundary;
neither a large diff nor a large source file is subject to a whole-output cap.
Read RPCs on the turn's owning transport retain concurrent tool requests and
notifications in FIFO order until the turn loop can consume them; awaiting a
source page must not discard another pending read or reorder it behind completion.
Contradictory findings and resolution responses for the same identity in one
round are refused before the finding register can advance.

The manual adapter uses the same exclusive journal transport as the listener,
under `state_dir/manual/`. Allocation intents, native identities, stop receipts
and canonical results are durable. A new manual invocation cannot replace a run
whose native stop is uncertain; the journal and snapshot are retained for
recovery. Completed attempts remain in journal history. This is execution
evidence, not another task source or a second review implementation.
The workflow requires an explicit checkpoint owner; it has no no-op production
fallback. The manual lock uses canonical repository identity, independent of
the reviewed revisions, so changing head or a source-path alias cannot bypass
uncertain native execution.

## Automatic review cards

The Taskboard reads an immutable snapshot of the automatic listener. Board reads
never invoke discovery, reconciliation, publication, or scheduling. Manual Skill,
CLI and local review journals are excluded. Only configured native repositories
and current reviewer requests are shown; withdrawn, closed and merged requests
are removed without reviving an older round.

One MR/PR has one stable card showing the latest automatic round and its pinned
head, conclusion, report links and round history. Queued work is Todo; running
and publishing work is In Progress. Done requires a complete canonical review,
confirmed native stop, valid bot publication receipts and the matching versioned
completion proof. Findings can accompany a delivered review. Failure, missing
input, stale eligibility and unconfirmed publication require Human Review.
Review cards need no Issue or Symphony Issue labels. Ordinary Issue membership
and assignment filtering continue to apply to Issue cards.

The restricted reader returns UTF-8 pages of at most 16 KiB for diffs, tracked
files, commit messages and file content. Reviewers follow byte offsets until
`next_offset` is null. The engine rejects skipped offsets and cannot accept a
complete axis until every diff page and every requested source file is read.
A diff path filter is rejected explicitly; paths select source files only.

ReviewAxis supplies a fixed native tool-output history budget of 32,768 tokens
for these pages. The transport applies it independently of model defaults and
role-file settings, so an unknown model alias cannot silently shrink a page in
the model-visible history. Ordinary task sessions retain their native budget.

Axis prompts supply the complete fixed finding version, including the target
branch name. A rejected finding returns its actual validation reason so the
reviewer can correct an invalid version without losing a substantiated finding.
The completeness and fixed-version checks remain mandatory.

The structural view preserves every character outside large quoted `0x` hex
literals. Those literals are explicitly represented as opaque payloads with
decoded byte length, SHA-256 and edge samples. The response also carries the
original stream's byte count and SHA-256. This is a data representation, not a
claim that numeric values have been validated. Reviewers inspect provenance,
generators and consumers, and may request bounded original file bytes using
`representation: raw`. Raw offsets refer to original bytes and allow samples;
raw samples do not advance structural coverage or satisfy missing evidence.
Only complete structural diff and requested source reads count toward axis
completion. Missing required payload validation remains failed/needs_input.

Native stop reads thread metadata without history hydration and follows every
`thread/turns/list` page in ascending order, with item content omitted. An empty
metadata `turns` array proves nothing. Missing pages, repeated cursors and active
or unknown turn states retain the execution fence. Stop never resumes a thread.
Goal error/cancellation callbacks use that same halt operation before recording
stop confirmation, then read back the paused/blocked/terminal Goal state. A
terminal last turn alone cannot hide an earlier unknown or active turn.

Native review CLI and Git commands receive the captured repository environment
without changing the service process environment. Manual journal identity uses
only the verified source repository for local requests, or the native provider,
host, repository ID and MR/PR number for remote requests. Unrelated request fields
cannot select another recovery fence. An independently verified `still_valid`
response completes a round with `changes_requested`; omitted or undecidable
required findings remain `needs_input`. Neither verdict approves or merges code.

The manual store requires a regular `manual/format-version` marker containing
`2`. Only an empty store may be initialized. Unmarked, unknown or linked markers
refuse allocation, including when predecessor records claim completed native
stop. No old-format interpretation, history import or automatic migration is
provided. Before enabling this format over a populated predecessor store, an
operator must verify native stop and retain that entire store as audit material
outside the active manual directory; uncertain stop forbids retirement.
