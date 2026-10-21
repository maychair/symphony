# Symphony

Managed deployments can verify the unified review protocol from standalone
preflight. A successful tracker read alone does not establish review capability.

The Taskboard also projects automatic MR/PR review requests as cards, with the
latest round, pinned revision, conclusion, native report links and history.
Manual reviews are excluded. Board refreshes are read-only and do not schedule
work. See [the review workflow](elixir/docs/review-workflow.md).

Symphony turns project work into isolated, autonomous implementation runs, allowing teams to manage
work instead of supervising coding agents.

The Elixir implementation supports an opt-in merged-delivery cleanup command on
its existing polling cycle. Operators can verify merged reviews and retire only
the corresponding safe local worktrees while retaining execution evidence; see
[the lifecycle contract](elixir/README.md#merged-delivery-cleanup).

[![Symphony demo video preview](.github/media/symphony-demo-poster.jpg)](https://player.vimeo.com/video/1186371009?h=5626e4b899)

_In this [demo video](https://player.vimeo.com/video/1186371009?h=5626e4b899), Symphony monitors a Linear board for work and spawns agents to handle the tasks. The agents complete the tasks and provide proof of work: CI status, PR review feedback, complexity analysis, and walkthrough videos. When accepted, the agents land the PR safely. Engineers do not need to supervise Codex; they can manage the work at a higher level._

> [!WARNING]
> Symphony is a low-key engineering preview for testing in trusted environments.

## Running Symphony

### Requirements

Symphony works best in codebases that have adopted
[harness engineering](https://openai.com/index/harness-engineering/). Symphony is the next step --
moving from managing coding agents to managing work that needs to get done.

### Option 1. Make your own

Tell your favorite coding agent to build Symphony in a programming language of your choice:

> Implement Symphony according to the following spec:
> https://github.com/openai/symphony/blob/main/SPEC.md

### Option 2. Use our experimental reference implementation

Check out [elixir/README.md](elixir/README.md) for instructions on how to set up your environment
and run the Elixir-based Symphony implementation. You can also ask your favorite coding agent to
help with the setup:

> Set up Symphony for my repository based on
> https://github.com/openai/symphony/blob/main/elixir/README.md

---

## License

This project is licensed under the [Apache License 2.0](LICENSE).

The Elixir implementation supports repository Issues directly through the GitHub and GitLab adapters. Native Goal execution and durable run identities are tracker-independent. See [repository execution](elixir/docs/repository-issues.md).

Repository Issue routing can additionally restrict `tracker.assignee` (GitLab user ID or GitHub login). The same owner check applies to the personal Taskboard projection, admission, reconciliation, retry, recovery and continuation; unassigned or multiply assigned issues do not match a configured owner.

The Taskboard includes only Issues carrying the human-owned `symphony:todo` membership label; when `tracker.assignee` is configured, the sole native assignee must also match. Membership is checked before lifecycle classification, including closed Issues and detail reads. A todo-only Issue remains visible without authorizing an Agent. Configure `tracker.required_labels: [symphony:todo, symphony:ready]` to require both membership and execution authorization. Keep `symphony:todo` through running, review and completion; removing it removes the Issue from the board. Historical unlabeled closed Issues are not review requests.

For ordinary GitLab Issues using `task_workflow`, Done is verified by read-only native replay of the current agreement, manifest and acceptance sources, matched against the retained lifecycle. The Issue must be closed, its execution completed and its native stop confirmed. Missing, edited or unreadable evidence remains in Human Review. Reading the board neither executes work nor updates its journal.

Verified GitLab MR publication can emit an attempt-scoped `review-request-ATTEMPT.json` in the execution journal. The existing Agent loop verifies the native MR, posts the deduplicated review notification and requests the engine-owned `symphony:review` label, without another Agent call. Handoff never writes or removes the human `symphony:ready` authorization label. Checkpoints expose derived `stage_results`; business validation remains linked evidence and is not inferred from execution completion.

## Versioned task workflow

GitLab repositories can opt into the [versioned task workflow](elixir/docs/task-workflow.md). It separates authorized work, intermediate review, overall acceptance, native closure and confirmed execution stop. Humans drive it with `symphony:ready`, `symphony:rework` and `symphony:accept`; the engine only writes its own `symphony:running`, `symphony:review`, `symphony:blocked` and `symphony:failed` state labels. Label authorization requires a published, unchanged candidate and the actual native actor; acceptance must bind an exact manifest. Enable it only after migrating retained private workflows and their Issue agreements.

## Parent plans and standalone review

The [repository lifecycle contract](elixir/docs/workflow-lifecycle.md) defines sealed cross-repository plans,
version-bound evidence, parent acceptance and comments-only standalone review.
Parent plan Issues are coordination work and never ordinary coding executions.
Plan graph validation, configured member dispatch, fixed parent manifests, native acceptance and scoped
rework are implemented in the isolated workflow branch. Deployment migration and live-provider acceptance
remain to be verified before enabling the new protocol.

Configured parent plans now receive [native preflight](elixir/docs/workflow-lifecycle.md#native-plan-preflight) on tracker reads. This verifies complete cross-repository scope and approval without granting child dispatch or treating Issue closure as dependency evidence.

[Native execution generations](elixir/docs/workflow-lifecycle.md#native-execution-generations) bind roles and fixed inputs, preserve cumulative accounting, and require native stop before replacing a thread. The member lifecycle reducer derives developer/verifier selection from resolved evidence, with finite repair accounting and version-bound delivery checks; GitHub/GitLab Issue evidence publication now persists send intent and verifies native readback. Git-backed verifier commands now produce isolated host receipts, and publication attests those results. Native result selection retains fixed Git snapshots with durable consumer references and re-attests command receipts. Native parent/member controls now preserve the approval grant, bind each resume to its pause and fence fresh publication with durable source receipts. Bound Codex sessions now expose role-specific context, candidate publication, configured host checks and verification tools; command results come from host receipts and calls revalidate native controls. Verified dependency edges now resolve native publications transitively, re-attest host checks and retain consumer references. Role tools revalidate their pinned inputs before effects; new candidates do not silently replace those inputs. Native PR/MR delivery reads now bind the approved target branch and actual merged revision. Delivered dependencies require independent verification of that exact revision, including after squash/rebase; original-head checks cannot unlock them. Markdown report candidates now retain exact UTF-8 content and publish readable evidence to their owning Issue without Git. Independently verified native report publications can satisfy verified, delivered or published dependencies. The native member admission coordinator now derives developer/verifier generations from complete evidence, rechecks under the journal lock and preserves observed pauses before first execution. Generation-owned role workspaces now materialize retained inputs, preserve developer edits on resume and give verifiers a separate fixed candidate checkout. Host checks consume the same manifest under read-only input isolation. Local role sessions now prepare those workspaces, recheck native authority before thread and Goal activation, fence callbacks to the owning process and attempt, and record stop only after native readback. Managed role Goals now observe native controls asynchronously, preserve intervening turn and budget updates, and stop on pauses, role changes or unconfirmed observations. Ownership fences also guard native Goal cleanup. Managed Goal finalization now records one result per attempt, applies finite retry accounting, and releases execution ownership after a durable final phase. Unconfirmed native stop remains an incident and never authorizes a replacement. The member worker now derives role Goals from sealed native scope and runs admission, workspace preparation, execution and finalization together, including startup failures. Synchronous admission-read exceptions release only the unstarted owned attempt and preserve changed ownership for recovery. Report development, independent verification, bounded repair and re-verification are exercised through the native protocol. Configured member execution now resolves every approved member’s repository policy and exact native base branch before entering the role worker. Initial source intent survives partial preparation and branch changes; generation rotation preserves its history. Configured native plans now feed member jobs into the existing scheduler and its shared capacity and retry queue. Durable, launch-bound results drive automatic role continuation; stopped or paused members lose eligibility, while an abruptly killed worker retains its exclusion lock. Legacy entry-point deadlines do not override sealed member budgets. Publication outside the owning Issue, retention cleanup, missing Git object acquisition and automatic crash recovery remain under development; parent manifest, acceptance and scoped rework require migration and live-provider validation.

Native standalone review now uses GitLab repository scans and persisted webhook hints through `review_lane`; mailbox watching and mail replay have been removed. Stable reviewer/publisher IDs, fixed-input rounds and native-stop fencing replace mail-based admission. Review comments now retain per-entry send intent, exact native readback and version-bound conclusions; partial batches resume only after confirmed native stop and current-scope checks. Live review cancellation now interrupts recorded native turns and requires idle readback before confirming stop; uncertain stops retain the snapshot. Review callbacks now bind the admitted worker and attempt, and same-VM Listener restarts stop surviving workers. Review journal reads and writes now use one Linux kernel-locked Python 3 transport, with durable predecessor-controller identity checks before takeover. Existing journals without ownership receipts require migration after old controllers are stopped. GitHub review now has native PR discovery, fixed-head comment readback and reviewer-withdrawal reconciliation. Live-provider acceptance, native orphan recovery after VM loss and deployment handoff remain to be validated.

The repository workflow includes version-bound parent rework and native GitHub/GitLab
review execution. The Workspace integration can retain immutable engine packages
and safely retire completed v2 role materializations while preserving artifact and
execution evidence. See the [lifecycle boundaries](elixir/docs/workflow-lifecycle.md#lifecycle-write-and-retention-boundaries).

Codex sessions disable shell snapshots and login shells on both new and resumed threads.
Shell startup variables (`ZDOTDIR`, `BASH_ENV`, `ENV`) are pinned to `/dev/null`, and
tracker secret names are excluded from tool environments. These constraints prevent automatic
profile-based credential reinjection; they do not isolate readable host files from the same OS user.

## Multiple repositories in one service

A service Workflow may contain a `repositories` list of maps with `id`, `workflow`
(relative to the service Workflow), and optional non-secret `environment`.
One BEAM process and HTTP endpoint host repository-isolated OTP subtrees;
concurrency remains per repository. Each repository owns its Workflow cache,
Orchestrator, task supervisor, review listener, workspaces and execution journals.
Repository IDs, native tracker scope and storage roots must not overlap.
Membership/environment/storage/native ownership changes require a restart; other
Workflow changes use the existing last-known-good reload.

The service's normal tracker configuration is control-only (use an empty memory
tracker). `/runtime`, `/api/v1/state` and the read-only Taskboard aggregate all
repositories. Add `?repository=ID` for scoped API reads, refresh and webhooks.
Ambiguous effects and journal lookups fail closed. Every Codex session excludes
the credential environment names of all repositories in the shared process.
Existing single-repository launch behavior is unchanged.

Repository runtimes may select an independent native GitLab CLI store with `GLAB_CONFIG_DIR` and Git identity through `GIT_CONFIG_PARAMETERS`, `GIT_AUTHOR_NAME`/`GIT_AUTHOR_EMAIL` and `GIT_COMMITTER_NAME`/`GIT_COMMITTER_EMAIL`. These non-secret settings stay repository-scoped across hooks and asynchronous workers; token values remain in native authentication stores or host credential bindings. Selecting a bot does not change the human Issue assignee or grant execution authority.

GitLab task workflows can verify signed Coordinator relays with
`tracker.provider.delegated_authority` (`principal`, bot `publisher`, raw Ed25519
`public_key`). The bot remains the native publisher; verified human authority is
recorded separately. Missing/invalid evidence cannot confer authorization. See the
delegated decision protocol in `elixir/docs/task-workflow.md` (repository root).

Review execution uses one workflow for manual and automatic requests: independent Standards and Spec reviewers, explicit completion evidence, and one result renderer. A complete clean review renders exactly `LGTM!`; incomplete reviews fail. See [the review contract](elixir/docs/review-workflow.md).

## Review workflow boundary

Automatic review executes integration-supplied Workflow/Playbook instructions
through the ordinary native session. Symphony owns admission, execution and
publication receipts; review stages and result criteria are supplied externally.
Manual review uses the same assets without this service. See the
[Review contract](elixir/docs/review-workflow.md). Historical execution records
are retained for audit, never automatically replayed by this change.
