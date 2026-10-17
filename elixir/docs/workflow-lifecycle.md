# Repository plan and review lifecycle

This contract extends repository Issue execution with versioned parent plans and
standalone review. Repository Issues remain the only task source. PRs/MRs own
code and review facts. Symphony owns execution identity, recovery and derived
projections; Codex owns native agent sessions.

The current implementation validates sealed plan graphs and classifies parent
Issues as coordination work. Parent dispatch, provider evidence reconciliation
and the remaining lifecycle below are not yet complete. A parent must never run
as a coding task while coordination support is incomplete.

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
