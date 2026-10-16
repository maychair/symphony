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

Repository Issue routing can additionally restrict `tracker.assignee` (GitLab user ID or GitHub login). The same owner check applies at admission, reconciliation, retry, recovery and continuation; unassigned or multiply assigned issues do not match a configured owner.

Verified GitLab MR publication can emit an attempt-scoped `review-request-ATTEMPT.json` in the execution journal. The existing Agent loop verifies the native MR, posts the deduplicated review notification and requests the engine-owned `symphony:review` label, without another Agent call. Handoff never writes or removes the human `symphony:ready` authorization label. Checkpoints expose derived `stage_results`; business validation remains linked evidence and is not inferred from execution completion.

## Versioned task workflow

GitLab repositories can opt into the [versioned task workflow](elixir/docs/task-workflow.md). It separates authorized work, intermediate review, overall acceptance, native closure and confirmed execution stop. Humans drive it with `symphony:ready`, `symphony:rework` and `symphony:accept`; the engine only writes its own `symphony:running`, `symphony:review`, `symphony:blocked` and `symphony:failed` state labels. Enable it only after migrating retained private workflows and their Issue agreements.
