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
Child dispatch, artifact verification and the remaining lifecycle below are not
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
unchanged with valid source times. A later non-authorize control or unresolvable
control blocks preflight; it never falls back to an older approval. Full pause,
resume and rework interpretation remains part of the pending execution lifecycle.
Approval evidence binds the parent WorkRef, native note version and plan revision.

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
  code and output checksum; every review has a result and rationale. Check
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

Native evidence authentication/publication, parent rework, fine-grained execution
under criterion restrictions, shared board projection and effect integration
remain pending. In particular, supplying a `sources` list is not itself proof
that an external artifact was retrieved or a real command was executed.

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
