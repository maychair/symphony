# Repository plan and review lifecycle

This contract extends repository Issue execution with versioned parent plans and
standalone review. Repository Issues remain the only task source. PRs/MRs own
code and review facts. Symphony owns execution identity, recovery and derived
projections; Codex owns native agent sessions.

The current implementation validates sealed plan graphs and classifies parent
Issues as coordination work. The existing GitLab task path also binds label
decisions to unchanged native candidate notes and rejects unversioned acceptance.
Configured parents now receive complete native scope/approval preflight on
tracker reads, including GitHub/GitLab repository identity and member contracts.
Native execution generation fencing is available for role separation and recovery.
The member lifecycle reducer now selects roles from resolved evidence and applies
candidate, verification, delivery, control and cumulative accounting constraints.
Role-bound Issue evidence publication now has durable intent and native readback
for GitHub and GitLab, including recovery after an uncertain send.
Git-backed command checks now run in isolated verifier worktrees and produce
host-owned process/output receipts that the publisher attests.
Native result selection now checks journal/native identities, retrieves and retains
fixed Git snapshots and re-attests actual command results before returning member evidence.
Native parent/member pause, cancel and source-bound resume decisions now feed
member evidence and fence fresh result publication; remembered source loss blocks
resumption after restart. Child dispatch, retention cleanup and the remaining lifecycle below are not
yet complete. Preflight success alone is not execution eligibility. A parent must never run
as a coding task while coordination support is incomplete. Version 2 and unknown
contract schemas, parent-linked contracts and malformed contract blocks are
also fenced at tracker projection and executor admission; legacy routing labels
cannot bypass the pending plan lifecycle, even when goal mode is disabled.

## Observable requirements

| ID | Required behavior | Evidence required for completion |
|---|---|---|
| W01 | Approve a complete plan once; immutable membership, scope and criteria | Native approval names a sealed revision; edits cannot inherit authority |
| W02 | Each child has one owning repository and one active executor | Full native identity, ownership fence and confirmed native stop before replacement |
| W03 | GitHub/GitLab dependencies can unlock on verified, delivered or published artifacts | Current evidence binds exact retrievable input versions and the requested stage |
| W04 | Independent verification and in-scope repair precede child completion | Separate execution roles, real check receipts and version-bound review evidence |
| W05 | Parent acceptance covers all child deliveries and whole-result integration | Complete immutable manifest, integration inputs, explicit human acceptance |
| W06 | Parent rejection can reopen affected completed children | Native parent rework decision, original criteria and budget, child reopen receipts |
| W07 | Pause, cancellation, scope, budget and questions remain independent controls | A reply cannot release a manual pause; restart cannot erase a restriction |
| W08 | Standalone review uses native reviewer events plus reconciliation, without email or Issues | Assignment, fixed base/head, deduplicated rounds and native publication receipts |
| W09 | New pushes and relevant replies trigger re-review | Empty findings do not disable tracking; repeated replies do not loop |
| W10 | Standalone review only publishes comments and technical conclusions | No native approval, request-changes, code edit or merge action by the review lane |
| W11 | Withdrawal, unmerged closure and merge stop review in every execution phase | Native readback, stopped execution, preserved historical review gaps |
| W12 | Side effects recover after partial success without duplication | Stable intent keys, author-checked remote receipts, unknown results stay blocked |
| W13 | Taskboard and acceptance reports share lifecycle conclusions | Read-only projection distinguishes phase, outcome, restrictions and stale/unknown evidence |
| W14 | Closure and cleanup require independent current facts | Valid conclusion, native closure and stop; safe files and retained dependency artifacts |
| W15 | Builds and active service capabilities are independent of source checkouts | Immutable release artifact, actual running version and non-overlapping takeover |
| W16 | Old records never gain fabricated authority during migration | Source-resolved historical decisions; unsupported/new schemas fail closed |
| W17 | Creation and merge permissions remain separate from execution approval | Explicit creation scope and existing repository grants; no implicit extra tasks |
| W18 | Human controls bind the version and question actually addressed | Source actor and causal/version evidence; ambiguous labels or replies ask for clarification |
| W19 | Repair converges or requests a concrete decision | Evidence-bearing findings, no duplicate work on unchanged inputs, cumulative finite budgets |

These are acceptance requirements, not claims that a green unit suite proves an
end-to-end deployment. Verification must include native provider behavior,
restart/failure injection and the actual deployed capabilities.

## Work identity

A `WorkRef` has exactly five fields:

```json
{"provider":"github","host":"github.example","repository_id":"123","kind":"issue","number":12}
```

`repository_id` is the stable native repository ID, serialized as a string.
`number` is the repository-local native Issue/PR/MR number. Supported kinds are
`issue` and `pr` for GitHub; `issue` and `mr` for GitLab. Host names are lowercase,
without a scheme, credentials, path, default HTTPS port or trailing dot; a
non-default port is part of the identity. The configured native adapter must
verify repository identity; a user-authored URL is not that verification.

`WorkRef.key/1` hashes the canonical identity. Display URLs, names and workspace
paths are not identity. A bare Issue number is insufficient across repositories.

## Sealed plan

A native parent Issue carries one `symphony-plan` HTML comment with JSON content.
`TaskPlan.seal/1` constructs the revision and `validate/1` checks the schema,
digest, complete membership, allocations, DAG and integration coverage. Sealing
is preparation, not approval or permission to create Issues.

The plan fields are:

- `schema_version`: currently 1; unsupported versions are rejected.
- `parent`: the native parent Issue's WorkRef.
- `contract_sha`: checksum of the parent goal, scope and acceptance contract;
  changing parent requirements cannot inherit approval of an unchanged graph.
- `authorizer`: the native identity allowed to approve this plan.
- `criteria`: distinct parent acceptance criterion IDs.
- `members`: one entry per child, containing `work`, `contract_sha`, parent
  `criteria` covered, `budget_ms`, and a `human_gate` boolean. Child contracts
  contain the goal, non-goals, technical criteria, outputs and delivery rules.
- `dependencies`: edges with `from`, `to`, `artifact`, required `stage`
  (`verified`, `delivered`, `published`) and the producer's technical `criteria`.
- `integration`: a member responsible for whole-result integration. Every other
  member must reach it through the dependency graph.
- `budget_ms`: optional total cap, stored as null if absent. Each member still
  has a finite budget; allocations must fit a declared total.
- `revision`: canonical SHA-256 of all fields except `revision`.

All listed members are required. Optional exploratory steps remain within a
child's authorized implementation, not silently optional parent deliveries.
A provider preflight must additionally resolve every child contract, verify its
checksum, outputs and edge criteria, confirm access and the current parent
identity, and resolve the human approval. Static graph validation alone cannot
admit work.

`TaskPlan.member/3` rejects a current child contract that differs from the sealed
plan. `affected/2` returns changed members and transitive consumers in dependency
order; unaffected branches retain their evidence. New membership or changed
criteria requires a new authorized revision.

Parent Issues are tagged `kind: :plan` and cannot pass ordinary issue routing or
`Execution.prepare/2`. Malformed or duplicate plan blocks remain coordination
work with a visible error; they must not fall through to coding execution.

## Native plan preflight

`tracker.provider.plan_roots` lists explicitly selected parent `WorkRef` objects.
`plan_repositories` contains the permitted repository read contexts. Each entry
has `provider`, `host`, `repository_id`, `path`, `api_url` and `credential` (an
explicit `$ENVIRONMENT_VARIABLE` reference). Explicit GitHub/GitLab environment
references must resolve their named variable; a missing variable cannot fall back
to the global token or repository setting for another execution context.
No repository or endpoint is learned
from Issue prose. Credentials remain outside journals and are included in the
executor secret-environment exclusion list. For example:

```yaml
tracker:
  provider:
    plan_roots:
      - {provider: github, host: github.example, repository_id: "10", kind: issue, number: 1}
    plan_repositories:
      - provider: github
        host: github.example
        repository_id: "10"
        path: team/project
        api_url: https://github.example/api/v3
        credential: $PLAN_PROJECT_TOKEN
```

GitHub.com uses `https://api.github.com`; Enterprise uses the configured host's
`/api/v3`. GitLab uses `/api/v4`. A nondefault port belongs to the host identity;
HTTP requires explicit `allow_insecure_http: true` and includes port 80 in that
identity. Duplicate identities and a foreign API host are rejected before any
request. Native repository metadata must match both the stable ID and registered
path. GitHub PRs cannot be substituted for Issues, and GitLab project IDs must
match the target. Identity mismatch or rename requires updating the configured
path after checking the same native ID.

A parent and every member have one self-checked `symphony-contract` block with
`schema_version: 2`. In addition to its checksum it includes:

- `work` and `parent`: complete native identities; `parent` is null on the root.
- `goal`, `non_goals`, `criteria` and `criteria_details`: the goal and exclusions,
  distinct criterion IDs, and an exact ID-to-observable-requirement map. Mutable
  progress prose outside this block is not the semantic contract.
- `authorizer`: the sole native assignee's stable user ID.
- `budget_ms`: finite on every child; optional on the root. The root cap matches
  the plan cap, and child allocations match their plan member entries.
- `acceptance_mode` and `acceptor`: the root uses `separate` and names its
  acceptor. Ordinary children use `technical` with a null acceptor. A child with
  an explicit human gate uses `separate` and names its acceptor.
- `deliverables`: distinct entries with `id`, `kind` and covered `criteria`.
  Together they cover the whole contract. Every dependency edge names an actual
  producer deliverable and only criteria covered by that deliverable.

A readable parent approval note ends with:

```html
<!-- symphony-plan-decision {"action":"authorize","revision":"FULL_PLAN_REVISION"} -->
```

The native actor must match the sealed parent authorizer. The note must be
unchanged with valid source times. The latest explicit approval supplies the grant;
pause and resume decisions cannot replace that grant or expand its scope. Tied
latest approvals, edited decisions and unresolvable control sources block
preflight. Approval evidence binds the parent WorkRef, native note version and
plan revision. A parent with active controls projects `restricted` with its
restriction kinds, while retaining the exact original approval source.

`TaskPlanPreflight.inspect_plan/2` returns all member snapshots or an error;
it never returns a partial eligible set. Reads paginate comments, detect duplicate
pages, and re-read Issue content after reading comments. After all members have
been checked, the parent and its decision sources are read again. These are read
fences, not a distributed transaction: dispatch and every later effect must
reconcile fresh evidence again. The tracker exposes only a compact
`native_ref.plan_preflight` projection, without copying all member content into
the parent or another task tracker. The local Issue URL and revision must match
the verified parent, so a pasted plan cannot inherit the original's projection.

Native reads use the documented [GitHub repository endpoint](https://docs.github.com/en/rest/repos/repos#get-a-repository),
[GitHub Issue comments](https://docs.github.com/en/rest/issues/comments#list-issue-comments),
[GitLab project endpoint](https://docs.gitlab.com/api/projects/#get-a-single-project)
and [GitLab Issue notes](https://docs.gitlab.com/api/notes/#list-all-issue-notes).

## Native controls

`TaskControl` separates the sealed grant from the current restrictions on its
execution. `authority/2` resolves the latest unambiguous parent approval.
`observe/3` reads parent controls and, for a member, only that member's controls.
A parent pause/cancel therefore affects every member; a child pause does not
in itself block an independent sibling. Dependency eligibility remains a separate
calculation. Control receipts include the complete native work identity so equal
note numbers on different Issues or providers cannot collide.

The structured native transport uses an unchanged `symphony-plan-decision` block
on the parent or `symphony-task-decision` block on the child. Both bind the full
plan `revision`; child decisions also bind their sealed `contract_sha`.
The supported control actions are `pause`, `cancel` and `resume`. A resume names
one exact prior pause source in `restriction`. Multiple pauses require their own
releases. The release must occur strictly later, on the same Issue, by its sealed
authorizer. Equal native timestamps are not ordered by note ID or arrival time.
A resume cannot clear a cancellation, another Issue's control, scope changes,
missing evidence or an exhausted budget. A new approval is not a resume.

Known foreign actors, system notes and ordinary unbound prose cannot control
execution. Unknown actors, edited/malformed structured decisions, extra fields,
unsupported actions and stale plan/member revisions remain explicit gaps.
The current structured reader is an internal transport boundary; the planned
human-facing reply/label interpretation must still prove unique actor, target
and version bindings. Users are not required to compose this JSON. Question
resolution, scope changes, cancellation closure, parent acceptance/rework and
cross-plan control migration are not supplied by this reader.

Every successful observation returns active restrictions, source-specific releases,
current sources and an immutable source-receipt map. The lifecycle projection
retains that map in its execution journal, including already released pauses.
Later reads must confirm every remembered pause and resume at the same version;
deleting a release cannot silently leave a task unpaused. `recorded/1` combines
prior projection receipts with publication-time receipts without hiding conflicts.
These are decision readback receipts, not a second task database or new authority.

Before a fresh candidate/verification POST, `TaskPublication` rechecks the current
parent and member controls and checkpoints their receipts before returning either
a blocked result or sending intent. Thus an observed pause still prevents a later
publication after its comment disappears or the process restarts. Recovery of an
already sent result only reads and records the original effect; it does not resend
under a pause. A cancelled result is never presented as human acceptance.

`TaskEvidence.read_member/5` returns these controls alongside artifact/result facts
and re-reads the parent after artifact acquisition as well as the member. A pause
arriving during retrieval invalidates the observation. The lifecycle consumes
`control_receipts` with the restrictions/releases and requests stopping an active
executor; a missing remembered source blocks execution. The scheduler must still
apply that stop intent and confirm native shutdown. Read fences do not promise an
atomic transaction across Issues/providers or instant cancellation of remote work.

## Native execution generations

`RunJournal.admit/3` accepts an `execution_binding` derived by the lifecycle from
verified native facts. It binds the full work identity, developer/verifier role,
plan revision, child contract checksum, parent approval reference, fixed input
versions and verification references, candidate digest and runtime policy digest.
A verifier must name a candidate; a developer also binds the candidate being
repaired or delivered. Initial development has no candidate. Input ordering is canonicalized; reordering
unchanged inputs resumes the same generation rather than allocating another.

This binding is an execution boundary, not proof that its inputs are verified or
that the work is authorized. The lifecycle must still check those native facts,
all restrictions, remaining budget and finite retry/repair limits before calling
admission. The member reducer derives role selection, but native evidence producers
and automatic dispatch integration are still pending.

Changing role or fixed inputs requires a confirmed stop of the recorded native
thread. Allocation without a known thread remains uncertain even if a local
boolean says it stopped. An old unbound native session requires explicit
migration. A new generation archives the previous role and native execution
receipt, removes its resume identity, and preserves cumulative budget and retry
and repair counters. The app-server client rejects a provider response that
reuses an earlier generation's thread before it can start a verifier turn.

Bound checkpoints require the current executor or reconciliation lock and a
matching journal revision. Writes serialize inside the scheduler VM; a previous
attempt or stale callback cannot overwrite a newer generation, clear its binding
or release its lock. Damaged binding/history records fail closed on recovery.
These guards do not imply child completion, independent verification success or
permission to publish, merge or close an Issue.

## Member lifecycle reducer

`TaskLifecycle.assess/2` consumes the complete `TaskPlanPreflight` result, one
member WorkRef, its execution journal, current adapter-resolved evidence and a
finite verification policy. It returns phase, outcome, action, restrictions,
desired binding, dispatchability, stop requirement and closure eligibility.
It performs no native writes and does not enable version 2 dispatch by itself.

The policy names `engine_actor`, finite nonnegative `max_retries` and
`max_repairs`, and a `checks` map. Each check is a `command` with its exact
command, or a `review`. The sealed child contract adds `verification_checks`,
an exact map from every criterion to nonempty check IDs. Missing assignments
prevent eligibility; successful graph preflight alone does not satisfy this.

Resolved evidence has lists of current `sources`, `restrictions`, `releases`,
`dependencies` and `deliveries`, an `active` execution fact, and nullable
`candidate`, `verification` and `acceptance` records. These are trusted adapter
outputs, not a wire format that agents may self-certify:

- Dependencies name producer, artifact, version, verification, retrieval,
  criteria and stage. Exactly one matching proof must meet each sealed edge.
- A candidate binds work, contract checksum, fixed inputs and exact artifact
  IDs/kinds/versions/sources. Its digest covers that payload. Publication binds
  the engine actor and current source; its generation/thread must occur in the
  journal as development under the same authority, scope and inputs.
- Verification binds that candidate, inputs and policy, with a separate recorded
  verifier thread. Every required command has its exact command, integer exit
  code, output checksum, completed reason and an unchanged checked snapshot;
  every review has a result and rationale. Check
  success is derived by check kind. Missing checks or failed commands cannot be
  overridden by an otherwise clean review.
- Findings bind original criteria, status, required/advisory classification,
  rationale, current evidence, a stable `problem_sha` for the normalized
  problem and `repair_basis_sha` for the substantive reproduction/repair basis.
  Producers must exclude publication IDs, head-only changes and wording from
  these identities; a new basis requires evidence of actual progress. Invalid or undecidable findings wait for
  a decision; valid required findings select in-scope development.
- Delivery maps each candidate artifact to its delivered version and current
  native source. A transformed version requires mapping and delivered-check
  evidence. Technical children need no human acceptance; an explicitly gated
  child requires its designated actor's exact-candidate acceptance.

Old candidate/input/policy verification remains historical and selects current
verification. A current-target record with invalid provenance blocks. A missing
previous candidate does not silently restart initial implementation.

`TaskLifecycle.start/3` records the admitted execution generation before charging
or counting repair. `repair_history` and elapsed budget remain journal accounting.
Only an actual repair admission increments the repair count; infrastructure
retries retain their separate count. Republishing an unchanged problem cannot
create another automatic repair. A materially new repair basis can permit
another bounded repair of the same problem. Exhausted budgets, finite limits and clock
regression block new execution. Waiting for a human stops charging only after
native stop; resource/dependency waiting retains existing accounting semantics.

Native restrictions survive disappearance of their source. A resolved release
must name that restriction's exact source; releasing one does not clear others.
The adapter must authenticate and order restrictions/releases before supplying
them. The reducer cannot infer a resume from a missing pause comment.

A complete proof cannot yield a completed outcome while execution is active or
uncertain. Changed completed conclusions require a decision instead of silently
reopening work. `closeable` is a derived eligibility flag, not a close receipt:
the effect owner must re-read native sources and stop facts, record its intent,
perform the authorized close and read back the result.

The result evidence reader below supplies authenticated candidate, verification
and retrieval sources together with native pause/cancel/resume controls.
Dependency/delivery evidence, parent rework,
fine-grained criterion restrictions, shared board projection and effect integration
remain pending. Supplying an arbitrary `sources` list is not proof of retrieval
or command execution.

## Native evidence publication

`TaskPublication.publish/5` appends an engine-owned candidate or verification
report to the execution binding's owning Issue. It requires a recorded native
thread, the matching generation/role, fixed input references and policy digest.
Candidates belong to developers; verification reports belong to verifiers and
name their bound candidate. This API never approves, requests changes, merges,
creates or closes native work.

Before a new send, the publisher resolves the entire current native plan again
and checks the exact parent approval, revision, member contract and open state.
`NativeWork.comment/4` then resolves the configured credential's native
`/user` identity and re-reads the target Issue plus all comments. Its snapshot
fence includes comment versions, so a concurrent comment edit can block a write
even if the Issue's own version did not change. These are sequential read fences,
not a cross-provider transaction.

The body contains a readable summary, one canonical `symphony-evidence`
envelope and the engine-notice marker. The envelope includes the payload,
execution binding, native generation/thread, publishing actor and an intent
digest of those fixed result/execution fields. Presentation text is frozen within
that intent; rewording it cannot create a second publication for the same result. It cannot be consumed as a human decision.
The journal preserves publication intents and native receipts; it does not copy
the Issue's goals or maintain another task tracker.

Publication proceeds through `prepared -> sending -> published`. The journal
records `sending` before the HTTP write. HTTP 201 alone never proves
publication: complete native readback must find exactly one matching intent,
the expected actual author, exact body and unchanged source timestamps. The
receipt names the WorkRef, native note ID and full source version.

Retries and restarts recover a sending intent by reading the provider. A lost
response followed by a matching note produces the original receipt. An absent,
altered, foreign or ambiguous note remains unconfirmed and cannot cause another
POST. A failure proven to occur before the write preserves a prepared intent.
The journal's version/owner fence prevents late callbacks from overwriting a
concurrent recovery or a newer role.

Reusing the same completed intent revalidates its receipt. Recovering an old
send may preserve a historical receipt after authority changes, but does not
grant new execution or make that result current. Every consumer must reconcile
its own current authority, candidate, inputs and check policy.

An engine-authored comment alone does not prove that a command ran or an artifact
was retrieved. Verification publication now attests each supplied command result
against the host-owned receipts below. Git-backed result acquisition and
selection, local retention and native control checks are implemented; non-Git check inputs and
automatic execution wiring remain pending. Version 2 dispatch stays fenced.

## Supervised command checks

`CommandCheck.run/4` executes a policy check for the current verifier generation.
The candidate's canonical digest, work, scope and fixed inputs must match its
execution binding. A command policy names `artifact`, the exact `command`
and a positive finite `timeout_ms`; the selected candidate artifact must identify
a full Git commit available in the recorded isolated developer worktree.
Primary checkouts are rejected as executor sources.

The executor creates a separate detached worktree at that commit. Dirty developer
changes are not copied. A prepared check requires a clean snapshot, including
untracked/ignored files; interrupted setup retains its intent and cannot adopt
an unknown directory or redirect its specification through a symlink. The command
budget is clipped to the remaining cumulative task budget after preparation.
The supervisor also observes the absolute launch deadline, so process startup
does not grant another full timeout.

The embedded Python supervisor requires Linux, Python 3, Git, child-subreaper
support and Landlock ABI 3 or newer. It starts commands with an explicit small
environment. Commands may write only their check worktree and dedicated temporary
directory. System runtime/configuration directories and Git metadata are readable;
host journal receipts and the developer checkout are not writable. Optional
policy `path` and `read_roots` select installed tools and their read-only runtime
directories. They participate in the policy digest. Unsupported isolation never
falls back to an unrestricted command.

The supervisor merges stdout/stderr into a bounded 1 MiB transcript, hashes the
stored bytes and records actual exit status, termination reason, elapsed time,
snapshot validity and native stop. Timeouts, cancellation and output overflow
terminate the process tree. The subreaper also collects background descendants
that create another session. An ended shell alone is insufficient stop proof.
Checks that modify tracked candidate content retain stop evidence but cannot
attest success for the original candidate.

The host journal records `prepared -> running -> completed`. A running check
without a valid supervisor receipt is recovered by reading, never by relaunching.
Cancellation requests a stop; its return does not assert that the process has
stopped. Stale callbacks cannot overwrite later cancellation/recovery.
`RunJournal.admit/3` and execution-generation rotation both reject replacement
while host-check stop is unknown, even if the agent thread itself has stopped.

`TaskPublication` compares supplied command results with the matching verifier
generation's actual receipts and transcripts before publishing. Missing or edited
receipts, invented exit codes and modified output cannot become verification.
The lifecycle requires a completed command on an unchanged snapshot; a timeout
or a supervisor error cannot pass by carrying an exit-code-shaped field.
Independent review conclusions remain the verifier's evidence-bearing judgments.

Check worktrees and transcripts are separate: once a receipt records the checked
snapshot, removing that worktree need not erase the command evidence or require
rerunning it. Retaining the referenced candidate artifact itself remains the
artifact owner's responsibility. Automatic cleanup and the
role-aware tool/dispatch integration are still pending.

## Native result evidence

`TaskEvidence.read_member/5` consumes a preflight result, one member WorkRef,
its owning execution journal, current verification policy and native read options.
It rechecks the complete plan/authority, reads current member comments and checks
the member snapshot again after acquisition. Changed scope or concurrent native
changes prevent returning a current result. Native access is read-only: it never
creates an Issue, reposts a report or grants execution/closure authority. Resolved
artifact bytes and their retention references are persisted locally.

`TaskPublication.observe/3` validates recorded envelope structure and compares
native author, body, note identity and version with published receipts. A sending
intent must be reconciled before consumption, even when its comment exists.
Unrecorded engine results and malformed journals remain explicit gaps. Foreign
copies of a known publication ID cannot hide ambiguity.

Selection uses the highest recorded execution generation under the current plan,
authority, member contract and publisher identity. Conflicting results from one
generation are ambiguous; loss of the selected source never falls back to an
older success. Verification additionally matches the selected candidate, pinned
inputs and current policy. A policy change leaves the candidate available but
requires a new applicable verifier result. Execution identities must occur in
the owning journal/history, and command evidence is re-attested against its
actual supervisor receipt and transcript. Review conclusions remain attributable
judgments from that independent verifier.

Git-backed artifacts identify a full commit and the deterministic source from
`GitArtifact.source_ref/2`. `NativeWork.read_git/3` first checks native repository
identity against the configured catalog. It then retrieves commit metadata, the
complete tree and every blob at that fixed version. GitHub trees are traversed
by object identity; GitLab tree pages always use the pinned commit. Missing,
truncated or malformed trees, duplicate/unsafe paths and mismatched object bytes
cannot produce a retrieval receipt. Blob content is checked against its Git
object hash; receipts also record file modes, byte counts and SHA-256 digests.

The reader uses GitHub [tree](https://docs.github.com/en/rest/git/trees)
and [blob](https://docs.github.com/en/rest/git/blobs) APIs
and [GitLab repository APIs](https://docs.gitlab.com/api/repositories/). GitLab
raw blobs preserve original bytes; its client disables body decoding on raw
endpoints so a JSON file is not converted into a different representation.

Acquisition defaults to a 100 MiB total content limit and a 30-second traversal
deadline, configurable by host options `artifact_max_bytes` and
`artifact_timeout_ms`. It stops between requests and rejects results arriving
after the deadline; an in-flight read retains the HTTP client's transport timeout.
Tree depth is limited to 100 and entries to 10,000. Unresolved Git LFS pointers
and gitlinks fail explicitly. Symlink contents are returned as data, never followed
or extracted. Read results contain the acquired bytes separately from receipt
metadata; constructing a source reference alone proves nothing.

This interface supplies candidate/verification/retrieval facts, not a complete
lifecycle observation. Its `controls` result includes restrictions, releases and
source receipts. The owner must separately resolve dependencies,
native activity, deliveries and acceptance. It cannot fill those facts with
assumed empty values. Current acquisition covers Git-backed artifacts in the
member's verified repository; verification materialization, non-Git
artifacts, fork-source resolution, LFS/submodules and dispatch wiring remain
under development. A successful retrieval is neither publication-stage proof
nor a promise that the remote version will remain available indefinitely.

## Retained artifacts

`ArtifactStore.retain/5` stores a fully acquired snapshot independently of executor
worktrees and records an immutable retention owner. The store is keyed by native
repository identity and exact commit; its validated receipt binds sorted paths,
file modes, Git object hashes, SHA-256 digests and total bytes. Source identifiers
remain portable; local store paths are not artifact identities.

`TaskEvidence` uses `.artifacts` under the owning journal root by default. Host
options may select an absolute `artifact_store_root`. Its parent directory must
already exist. The store creates its own private directory and ownership marker;
unknown existing directories and symlinked path components are rejected. Artifacts
and references are private files, outside developer/check worktrees. Native
credentials and task goals are not copied into this storage.

A new snapshot is fetched through `NativeWork`, fully validated, written to an
exclusive temporary file, synced and published using a non-overwriting hard link.
Directory entries are synced before success, including when a concurrent writer
already published identical bytes. The ownership marker uses the same complete-file
publication rule. Interrupted temporary files are not visible as snapshots.
Existing conflicting data is preserved and reported, never replaced by a retry.

Every read rechecks the exact repository/version, receipt structure, binary bytes,
object hashes and current content-size limit. Directory/file path collisions,
duplicate entries, malformed content and altered receipts fail closed. Registered
repository scope is still required. A missing snapshot may be acquired natively;
a corrupt existing snapshot is not silently redownloaded over. Cached content
does not bypass current parent approval, member scope or native publication reads.
It can remain usable when the Git-object endpoint is temporarily unavailable,
provided those controlling facts are still confirmed.

Each retention owner has `kind` (`candidate`, `dependency` or `manifest`), a full
Issue `work` reference and an immutable `revision` digest. Candidate owners must
match their producer; dependency/manifest owners can name another member or parent.
The reference binds the owner to the artifact source and full receipt digest.
`TaskEvidence` pins selected candidate artifacts automatically; separate consumers
can pin the same bytes without duplicating storage. Retrying one pin is idempotent.
Removing a worktree or selecting a newer candidate does not erase older pins.

`ArtifactStore.read/4` returns validated retained bytes without native requests.
`references/4` enumerates confirmed owners; damaged reference files are an error,
not an empty reference set. These records describe content ownership and retention,
not another task tracker, verification verdict or release authorization.

The store currently retains references conservatively. Release, garbage collection
under current dependency/manifest facts and project retention policy, cross-host
transfer, and materializing retained bytes for new checks still require integration.
The existing worktree cleaner cannot infer that deleting a worktree releases an
artifact. Byte snapshots preserve files and modes, not a complete Git history.

## Execution and evidence

```text
parent approval -> dependency eligibility -> developer -> independent verifier
                                              ^                 |
                                              +-- scoped repair-+
                                                                |
                                                   verified fixed artifact
                                                                |
                                                      native delivery
                                                                |
                                                   child stopped/completed
                                                                |
                                          integration + complete parent manifest
                                                                |
                                               human acceptance -> native closure
```

A verified artifact unlocks a consumer only if the exact version is retrievable
and the edge permits that stage. Issue closure is not dependency evidence. A new
upstream version does not change a pinned old artifact, but a changed selected
parent delivery invalidates evidence that only covers the old combination.
Merge/squash/rebase results require an explicit source-to-delivery mapping and
checks appropriate to the actual delivered version.

Every proof must identify its artifact and input versions, criteria, checks,
review role, native source and applicable policy. `checks=true`, an agent exit,
or resolved discussion alone is not verification. Reports have evidence and
quality criteria without being forced to produce a code PR/MR.

Parent acceptance names one complete manifest. Rejection of original criteria
can reopen affected original child Issues within their original remaining
budgets, retaining historical delivery and avoiding automatic rollback or new
Issues. A manually reopened Issue, drift alone or a post-acceptance new problem
does not independently grant new execution authority.

## Review and recovery

Standalone review has a distinct work kind and assignment generation, fixed
base/head/target context, relevant response digest and policy revision. Author
comments, edits and pushes are facts to reconcile; an engine's own comment is
never a human decision. Review publication is comments only. Human native
approval/request-changes and merge remain separate facts.

A changed head makes old results historical. Merge ends further review but does
not manufacture a clean review for an unreviewed revision. Removal and unmerged
closure stop work; reopened/reassigned requests establish a new valid cycle.

Persist side-effect intent before acting and recover native receipts before
retrying. A partial comment batch remains partial until all required receipts
are confirmed. A new head during recovery prevents continuing a stale batch.
Reconciliation covers first-event loss and paginated discovery, not only records
already present in a journal.

Parent pause stops new eligibility and requests each member's stop; it is not an
atomic cross-provider transaction. Unknown native state prevents replacement,
publication and cleanup. Clearing one restriction never clears another. Budget
consumption survives retries and reopening.

The lifecycle projection is the single business interpretation used by the
board and reporting. Cleanup independently rechecks current sources and local
file safety. It preserves artifacts still referenced by live dependencies or
pending manifests, without requiring all worktrees to remain forever.
