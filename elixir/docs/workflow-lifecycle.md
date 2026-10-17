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
for GitHub and GitLab, including recovery after an uncertain send. Bound Codex
sessions now expose dedicated developer/verifier tools for native context,
retained candidates, configured host checks and independent verification.
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

## Role-bound execution tools

An app-server session carrying an `execution_binding` must also receive the exact
`execution_policy` whose digest it names. `DynamicTool.bind_session/1` selects
`TaskTools` before starting the native transport; missing or substituted policy
fails session startup. Such a session cannot select a general tracker binding
through `dynamic_tool_binding`. Legacy and standalone-review sessions retain
their existing tool bindings. `AgentRunner` forwards the bound policy and the
trusted native repository options prepared by the executor admission path.

The tool set is role-specific:

| Tool | Role | Effect |
|---|---|---|
| `task_context` | Developer/verifier | Read the sealed contract, fixed binding, native candidate, source references, restrictions and configured checks |
| `task_candidate` | Developer | Retrieve and retain each declared Git output, then publish one candidate with native readback |
| `task_check` | Verifier | Run an assigned configured command against the fixed candidate through the host check supervisor |
| `task_verification` | Verifier | Combine host command receipts with explicit review checks and source-bound findings, then publish the independent result |

The execution process, attempt, generation and binding are captured when the
session is created. Every call checks the actual caller and current journal,
requires its lock and live native thread, and re-reads the sealed plan and native
controls. Bound sessions require root thread/turn identities on native tool
requests even when the global legacy goal-mode flag is disabled. A copied binding, superseded attempt, stopped execution, closed member,
changed scope or missing remembered control source cannot execute a tool. Native
repository credentials are excluded from the agent environment; credential
references and provider options stay in the host's captured context.

Write/check tools additionally require an active v2 budget ledger with no local
or native restrictions and remaining member budget. The context tool can explain
a pause without releasing it. Candidate reads may observe a newer pause than
the first scope check: those receipts are checkpointed and enforced before a
host check starts. Publication performs its own fresh native scope and control
checks. These reads are not an atomic transaction across providers.

Agents supply candidate output IDs and Git revisions. The host derives kinds,
work identity, input bindings and retrieval sources from the sealed contract and
execution; missing, duplicate or undeclared outputs are rejected. The artifact
store must retain the actual fixed bytes before publication. Only one immutable
result payload may be submitted by a generation; identical retries reuse native
receipts. A different result requires a reconciled new execution generation.

Verifiers cannot supply commands, raw exit codes or arbitrary command results.
`task_check` accepts only a check ID; configured commands run through
`CommandCheck`. Results include up to 16 KiB of integrity-checked output, with an
explicit encoding and truncation flag; the checksum covers the complete output.
Verification combines its actual durable receipts with exactly
the required review check IDs and validates finding criteria/source references.
The lifecycle still decides technical pass, repair or an unresolved decision.
A submission never grants human acceptance, approval, merge, Issue closure or
new task creation. A candidate-only evidence read does not require an unfinished
verification publication to be complete, so prepared verifier results can resume.

This tool boundary is connected to app-server sessions, but is not automatic
plan admission. The v2 dispatch guard remains until current dependencies,
delivery facts, role workspaces and lifecycle scheduling are connected. Non-Git
candidate materialization and native question/decision tools remain pending;
these tools must not be used to bypass those missing lifecycle paths.

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

## Native dependency evidence

`TaskDependencies.read/5` resolves the approved incoming edges of one member.
The host supplies owning journal directories and verification policies, keyed by
full `WorkRef`; agent arguments cannot replace that registry. The reader loads
the current journals and native publications, resolves each producer's own pinned
inputs recursively, re-attests actual command receipts, and applies the same
candidate/check/finding rules used by `TaskLifecycle`.

A `nil` input selection requests current candidate evidence. An existing input
list requests its exact artifact version and native verification source through
`TaskEvidence.read_input/5`. A new candidate does not replace an older pinned
candidate. A newer verification of that *same* candidate supersedes its earlier
verdict; a missing, edited, unconfirmed or conflicting source cannot fall back
to an earlier success. Changed policy, scope or approval also invalidates reuse.
This reader does not decide which versions a parent manifest will select.

A successful `verified` proof names the producer, artifact, immutable version,
verification source, retrieval source and approved criteria. Retained bytes get
a separate dependency owner naming the consumer and a digest of the plan/input
selection. Native snapshots and journal versions are checked again after the
whole acquisition. These sequential fences do not create a cross-provider
transaction. Failed reads may leave conservative retention references; they do
not authorize execution or release existing references.

Role tools use host-only `dependency_executions` options and compare their fixed
binding inputs with the approved edges. They revalidate before context, checks
and result publication, including after candidate acquisition. A failure blocks
the call rather than emitting a result based on unavailable upstream evidence.
The context includes dependency references and their source evidence.

Technical verification is independent of upstream Issue closure, execution
activity, delivery and human acceptance. It neither proves those facts nor
permits replacing an active executor. For `delivered` PR/MR edges, native merge evidence must match the independently
verified candidate version and the approved target branch. Edges requiring
`published` report edges use the owning Issue publication described below. Other
publication kinds still report an explicit evidence gap.
Verified bytes are never promoted to a native merge or publication receipt.
Automatic dispatch/stop reconciliation, input materialization and parent
manifest selection still require integration. Version 2 automatic
dispatch remains fenced until those lifecycle boundaries are connected.

## Native PR/MR delivery

Version 2 PR/MR deliverables require `target_branch` in the sealed contract.
The developer supplies a full native change `target` WorkRef with the candidate's
artifact ID and fixed Git version. The host copies the approved branch into the
candidate; agent arguments cannot replace it. The change must belong to the
owning Issue's exact provider, host and repository. The target participates in
the immutable candidate digest and independent verification.

`NativeWork.read_change/2` verifies the configured native repository and reads
the change twice, retaining native source/target repository IDs, branches, head,
merge state, merge time and actual final revision. A native `closed` state alone
is not merge proof. Missing identity, ambiguous delivery version, invalid time,
permission failure or concurrent change remains an error. Fork source and target
repositories remain distinct; the target repository is where a final merged
candidate is retrieved and verified. Pre-merge fork input materialization still
needs its own source-repository acquisition path.

GitHub's `merge_commit_sha` is a test commit before merge; after merge it denotes
the final merge/squash/rebase result. GitLab exposes `merge_commit_sha` and
`squash_commit_sha`; when no actual final revision is reported, Symphony does not
substitute the current branch or original head. These reads are GET-only and do
not request merge or platform approval. See the [GitHub pull request API](https://docs.github.com/en/rest/pulls/pulls#get-a-pull-request)
and [GitLab merge request API](https://docs.gitlab.com/api/merge_requests/).

`TaskDelivery` returns native observations: awaiting merge, closed without merge,
verification required, or delivered. This describes native delivery facts, not
technical acceptance or task completion. Role context exposes the exact merged
revision when it differs from the candidate. The developer can publish that
actual final revision as a new candidate in a subsequent admitted generation;
the existing separate verifier then checks its complete fixed snapshot under
the original contract and policy. Prior head verification is retained as history.
No new verifier kind, asserted mapping Boolean or inherited pass bypasses these
checks. Native head-to-result metadata remains attached to the delivery receipt.

Only when the currently selected candidate equals the actual merged revision can
its independent verification support a `delivered` dependency. The reader checks
native delivery again after resolving the full upstream chain. Target-branch
changes, changed native results, missing native access and stale source evidence
block the proof. Direct native observations never close an Issue or select a
parent manifest. General release publication, merge execution policy and full
automatic lifecycle wiring remain pending.

## Native report artifacts and delivery

A sealed `report` output accepts `{id, body}` through `task_candidate`. The host
hashes the exact UTF-8 Markdown bytes with SHA-256 and binds its retrieval source
to the full owning Issue, output ID and content version. A report does not need a
Git commit, branch, change request or working checkout. Reports are bounded to
16 KiB each; the complete publication, including its evidence envelope, is bounded
to 64,000 bytes. Invalid UTF-8, empty content, NUL bytes, reserved engine markers
and native GitLab quick-action lines are rejected before publication.

`ReportArtifact` validates both the inline candidate and retained `report.md`
bytes. `ArtifactStore` uses its existing owned root, atomic snapshot writes,
readback checks and durable consumer references for reports. The record is a
report content receipt, not a Git revision or proof of quality. Altered bytes,
wrong Issue/output scope, corrupt references and inconsistent metadata fail
validation. Report retention follows the same conservative ownership rules as
Git snapshots; release and garbage collection remain pending.

`TaskPublication` puts the readable report text in the owning GitHub/GitLab Issue
comment alongside the versioned candidate envelope. Envelope HTML delimiters are
escaped without changing the report bytes. Existing persisted send intent,
exact-body native readback and uncertain-response recovery apply. Retrying the
same candidate cannot publish a changed report under its old content version.

`TaskDelivery` confirms the exact candidate against its owning journal and native
comment. Its `delivered` observation means only that the readable content was
published; it never asserts independent validity or human acceptance. Before
publication, context reports `publication_unconfirmed`. Missing access, edited or
deleted comments, absent journal provenance and conflicting evidence cannot be
replaced with retained local text.

After a separate verifier validates the selected candidate under the host policy,
`TaskDependencies` can resolve a report edge at `verified`, `delivered` or
`published` stage. Delivered/published edges additionally require current native
publication and recheck it after acquiring the upstream chain. Every stage pins
the exact content and verification source, retaining a consumer reference.
Review-only policies work without Git. Configured command checks still require
their existing isolated Git workspace; report-specific command materialization
is not implemented and those checks are not silently skipped. General release
artifacts, role input materialization and automatic dispatch remain separate
integration work.

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

## Native review ingress

The scheduler now runs `ReviewLane.Listener`; it does not start a mailbox command
or accept the retired mail replay endpoint. Enabled `mail_review` configuration
fails validation with an explicit migration requirement. The new listener uses
`tracker.provider.review_lane`, currently with the GitLab adapter:

```yaml
review_lane:
  enabled: true
  provider: gitlab
  host: gitlab.example
  reviewer_id: 123
  publisher_id: 456
  state_dir: /absolute/private/review-state
  instructions_file: /absolute/trusted/review-instructions.md
  poll_interval_ms: 60000
  webhook_secret: $REVIEW_WEBHOOK_SECRET
  projects:
    team/project:
      id: 789
      checkout: /absolute/registered/source
```

The reviewer and publisher use separately configured stable native user IDs. Project
IDs, paths and URLs must match the configured host. Discovery reads each configured
project's paginated open MRs with `scope=all` and `reviewer_id`, then re-reads each
candidate. This discovers requests even if the first event was lost. Duplicate or
malformed pages and the 100-page limit remain failures, not empty successful scans.
The adapter uses the [GitLab MR list API](https://docs.gitlab.com/api/merge_requests/#list-project-merge-requests)
and [discussion API](https://docs.gitlab.com/api/discussions/). HTTPS is required
by default; a private HTTP instance requires explicit `allow_insecure_http: true`.
The URL and clone-remote checks retain the exact configured host and path.

Authenticated GitLab MR/note webhooks validate the native project identity and
persist a scoped MR hint before acknowledgment. Hints contain repository/number
references, not task content or execution authorization. Duplicate hints coalesce;
failed reads keep the hint across restart. Scans also revisit known requests,
including completed reviews and requests no longer in the assigned-open listing.

A changed fixed head, base, relevant author response or review-instruction digest
selects a new round. No-findings results also respond to new pushes. Relevant
replies need not answer every finding; their IDs/content versions and resolution
state contribute to a stable response digest. Duplicate polling, unrelated replies
and the engine's own marked notes do not create a round. Missing finding sources
block interpretation. Old rounds retain evidence but lose dispatch eligibility.

Before admission the listener reconciles native state again. Closed, merged or
unassigned requests lose eligibility; an observed reopening/reassignment may
start a fresh round after prior native stop is confirmed. Active or uncertain
threads cannot be replaced because the input changed. `Runner` records thread
allocation intent and confirms native stop only after the fixed review turn
completes; merely stopping a process is not that proof. A published result keeps
its existing worker active until that native completion arrives, while refusing
another execution of the same round. Restart during this interval fences the
uncertain thread. Unknown native reads fence eligibility. The review tool is `review_submit`; its only effect is comment
publication, including an explicit no-findings statement. Native approvals,
requests for changes and merges remain outside this tool.

`review-lane.json` stores schema-versioned execution records and pending hints.
A legacy `mail-review.json` beside it blocks startup rather than importing old
execution authority. Migration still requires reconciling old native executions
and publication receipts before activating the new deployment. This change does
not itself restart an existing service. GitHub review discovery, complete native
assignment history, target-branch refresh, automatic uncertain-stop recovery,
task-owned review deduplication remain
necessary for the full lifecycle described below.

## Review publication receipts

`ReviewLane.Publication` owns a versioned batch of finding comments followed by
one round conclusion. Each body includes the fixed base/head, round and a digest
of the native work, response and instruction context. An empty finding set still
publishes an explicit conclusion. All batch bodies are sealed before the first
send. A repeated identical submission reads back the original batch; changing a
sealed submission is rejected.

Each entry advances from `prepared` to `sending` to `published`. The listener
syncs the journal and its directory before issuing a POST, and checkpoints each
read-back receipt separately. POST responses alone never prove delivery. Recovery
matches the exact native repository, discussion/note IDs, stable publisher ID,
full body and creation timestamp. Missing confirmed notes, changed content or
identity, duplicate markers and unexpected comments for never-sent entries are
conflicts. An absent `sending` entry stays uncertain; it is never blindly resent.

On restart, reads recover partial receipts even for old rounds. Continuing an
unsent entry requires confirmed native execution stop and the current head,
base, reviewer, publisher, policy and response context. The same checks run before
every new send and after the final readback. Replies to findings published during
the batch also invalidate its remaining conclusion. A changed version preserves
old receipts and permits a new round only after native stop; it never moves an
unfinished old batch onto the new revision. The round is delivered only after
all findings and its conclusion have native receipts.

Published entries are re-read during reconciliation. Edited, deleted or replaced
comments no longer count as current delivery evidence. A new push does not bypass
an unresolved publication conflict for the same MR. Existing journals that
contain submissions without the complete publication intent are rejected for
migration, rather than inventing send history. Automatic recovery of uncertain
native executions and operator resolution of permanently uncertain sends still
require the execution recovery work described below. No approval or merge API
is exposed by this publisher. Its GitLab write adapter accepts only a new
MR discussion in a configured repository. Comment bodies reject standalone
slash-command lines, including in examples: [GitLab quick actions](https://docs.gitlab.com/user/project/quick_actions/)
can otherwise approve, merge or close native work through a comment. The same
body check protects native Issue evidence publication; rejected submissions do
not acquire a send intent.

## Review execution ownership

Each admission persists an `execution_owner` with an independent attempt token,
the BEAM VM incarnation and the actual worker PID. Checkpoint and submission
calls must present that exact owner and originate from that worker process.
Copying the token to another process is insufficient. A new admission replaces
the token and clears the earlier stop receipt, so delayed callbacks cannot
modify a later attempt even when a process is reused.

Worker checkpoints are limited to execution facts. They cannot edit the native
work identity, fixed inputs, policy, publication batch or owner, or set a round
back to queued. Thread identity and recorded workspace/host/backend cannot
change. Allocation intents cannot be erased, and a confirmed stop cannot be
reset through a worker callback. The Listener owns business phase transitions.

Thread and turn allocation each require one durable intent per attempt and a
fresh native scope check. Turn admission additionally requires the recorded
thread identity. A repeated intent, revoked assignment, changed head or policy,
or suspended configuration denies allocation. The app-server client honors
failed thread-observation and pre-turn callbacks rather than continuing native
execution after the journal rejects them.

The Listener monitors admitted workers itself; scheduler cleanup no longer
writes failure checkpoints using only a round ID. Worker exit proves that no
native work remains only when neither allocation intent nor any thread identity
was recorded. Allocated native work stays uncertain until native stop is proven.
While a submission is publishing, each subsequent write rechecks owner liveness
after native scope validation. Confirmed earlier comments remain recoverable;
owner exit cannot send the rest of the batch.

After a Listener restart in the same VM, surviving recorded workers receive a
stop request through their existing native connection. The round remains fenced
against new allocation and submission, but its authentic owner can still report
native identities observed in flight and the eventual stop result. Other VM
incarnations and legacy ownerless active records do not gain callback authority
or inferred stop confirmation. Journal exclusion is described below; native
orphan recovery after VM loss remains under development.

## Exclusive review journal ownership

The opt-in review lane requires Linux, Python 3, a local filesystem with working
`flock`/atomic rename/fsync semantics, and `/proc` visibility of the service's
processes. All controllers for one review lane must share the same durable
`state_dir`; separate journal copies do not coordinate with each other. One
journal broker owns both the kernel lock and every journal read and write. A separate lock-holder beside ordinary Listener file writes would
allow an old Listener to keep writing after the lock-holder died.

`review-journal.lock` is permanent and must not be deleted to recover a service.
The broker checks the held inode against that path before each operation.
`review-journal-owner.json` records the Listener's VM/process ticket, BEAM OS PID
and process start time, machine, boot and PID namespace, and clean-release fact.
The Listener passes its BEAM PID explicitly: a spawned port's parent may instead
be `erl_child_setup`. Writes replace the journal atomically after file fsync and
sync the containing directory before acknowledging persistence.

Acquiring the kernel lock is necessary but insufficient. A successor also needs
a clean predecessor release, a dead Listener in the same live VM, or a foreign
VM's OS process proven absent/replaced in the same machine, boot and namespace.
A living predecessor, unreadable/malformed receipt or unknown process context
fences admission. EOF, broker death and timeout do not manufacture clean release.
A failed transport cannot be reused for further writes. A second Listener fails
before discovery or publication; copied transport handles do not confer ownership.

Journal ownership proves only controller exclusion. It does not prove that a
previous native app-server, thread or turn has stopped. Existing record-level
native-stop and worker-owner gates still apply, including after a real OS
controller exits. Retained native execution remains uncertain until its separate
stop evidence can be established.

An existing `review-lane.json` without an ownership receipt fails with
`review_journal_owner_missing_migration_required`; it is not silently claimed.
Older binaries do not honor this lock, so rollout must stop and verify all old
controllers before explicit migration. Cross-host/boot/namespace recovery and
native orphan takeover are not automated. Retain the journal and snapshots for
operator recovery; deleting receipts to bypass exclusion is not a migration.

## Live review cancellation

The scheduler requests graceful stop when an active review loses eligibility,
closes, merges, or is superseded. It retains the running slot while the worker
handles that request. Before native allocation, the worker checks for a pending
stop; with no prior allocation or recorded thread, that establishes that no
native work started. Otherwise transport closure is never stop evidence.

The live worker uses `NativeStop.confirm_session/1` through the same app-server
transport that owns its thread. It halts any native Goal, interrupts active turns
even when no Goal exists, and requires a subsequent `thread/read` to prove idle
state and reconciled terminal turns before closing that transport. It never
calls `thread/start`, `thread/resume`, or `turn/start` during stop. An interrupt
acknowledgment alone cannot establish stop. The caller persists the observation
with the thread, final turn, workspace, host and observation time.

`NativeStop.confirm/2` provides separate recorded-thread recovery, preserving the
recorded workspace and worker host. Its caller must establish prior executor
exclusion before using a new transport. Reading stored history does not prove
that an earlier executor has exited; live cancellation never falls back to this
path when its owning connection fails. This distinction follows the
[app-server thread read and interrupt protocol](https://developers.openai.com/codex/app-server).

Review execution errors use the same halt-and-readback path. Unknown state stays
fenced. The scheduler's stop timeout may terminate a local worker, but preserves
the review snapshot and does not manufacture native stop confirmation. The
shared cleanup entry also preserves review snapshots during terminal polling,
retry cleanup and startup cleanup. Snapshot retention release and automatic
orphan review takeover remain unimplemented;
restart recovery must first establish exclusive execution ownership and reject
late callbacks from an earlier worker. The stop helper supplies observations,
not ownership or permission to take over another worker's thread.

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
