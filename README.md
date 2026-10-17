# Symphony

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

Verified GitLab MR publication can emit an attempt-scoped `review-request-ATTEMPT.json` in the execution journal. The existing Agent loop verifies the native MR, posts the deduplicated review notification and requests the engine-owned `symphony:review` label, without another Agent call. Handoff never writes or removes the human `symphony:ready` authorization label. Checkpoints expose derived `stage_results`; business validation remains linked evidence and is not inferred from execution completion.

## Versioned task workflow

GitLab repositories can opt into the [versioned task workflow](elixir/docs/task-workflow.md). It separates authorized work, intermediate review, overall acceptance, native closure and confirmed execution stop. Humans drive it with `symphony:ready`, `symphony:rework` and `symphony:accept`; the engine only writes its own `symphony:running`, `symphony:review`, `symphony:blocked` and `symphony:failed` state labels. Label authorization requires a published, unchanged candidate and the actual native actor; acceptance must bind an exact manifest. Enable it only after migrating retained private workflows and their Issue agreements.

## Parent plans and standalone review

The [repository lifecycle contract](elixir/docs/workflow-lifecycle.md) defines sealed cross-repository plans,
version-bound evidence, parent acceptance and comments-only standalone review.
Parent plan Issues are coordination work and never ordinary coding executions.
Plan graph validation is available; coordinated dispatch and the remaining
lifecycle integration are still under development.

Configured parent plans now receive [native preflight](elixir/docs/workflow-lifecycle.md#native-plan-preflight) on tracker reads. This verifies complete cross-repository scope and approval without granting child dispatch or treating Issue closure as dependency evidence.

[Native execution generations](elixir/docs/workflow-lifecycle.md#native-execution-generations) bind roles and fixed inputs, preserve cumulative accounting, and require native stop before replacing a thread. The member lifecycle reducer derives developer/verifier selection from resolved evidence, with finite repair accounting and version-bound delivery checks; GitHub/GitLab Issue evidence publication now persists send intent and verifies native readback. Git-backed verifier commands now produce isolated host receipts, and publication attests those results. Native result selection retains fixed Git snapshots with durable consumer references and re-attests command receipts. Native parent/member controls now preserve the approval grant, bind each resume to its pause and fence fresh publication with durable source receipts. Bound Codex sessions now expose role-specific context, candidate publication, configured host checks and verification tools; command results come from host receipts and calls revalidate native controls. Verified dependency edges now resolve native publications transitively, re-attest host checks and retain consumer references. Role tools revalidate their pinned inputs before effects; new candidates do not silently replace those inputs. Native PR/MR delivery reads now bind the approved target branch and actual merged revision. Delivered dependencies require independent verification of that exact revision, including after squash/rebase; original-head checks cannot unlock them. Report/publication delivery, retention cleanup, non-Git inputs and automatic dispatch integration remain under development.

Native standalone review now uses GitLab repository scans and persisted webhook hints through `review_lane`; mailbox watching and mail replay have been removed. Stable reviewer/publisher IDs, fixed-input rounds and native-stop fencing replace mail-based admission. Review comments now retain per-entry send intent, exact native readback and version-bound conclusions; partial batches resume only after confirmed native stop and current-scope checks. Live review cancellation now interrupts recorded native turns and requires idle readback before confirming stop; uncertain stops retain the snapshot. Review callbacks now bind the admitted worker and attempt, and same-VM Listener restarts stop surviving workers. Review journal reads and writes now use one Linux kernel-locked Python 3 transport, with durable predecessor-controller identity checks before takeover. Existing journals without ownership receipts require migration after old controllers are stopped. GitHub review, native orphan recovery after VM loss and the remaining assignment integration are still under development.
