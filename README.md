# Symphony

Symphony turns project work into isolated, autonomous implementation runs, allowing teams to manage
work instead of supervising coding agents.

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

The Elixir implementation also supports a scoped [native Beads development loop](elixir/docs/beads.md): Beads owns tasks and human acceptance, while Symphony journals native execution identities and preserves worktrees.

The Beads extension supports remote review/CI reconciliation in Symphony's existing poll loop, authenticated Webhook hints, bounded same-session repair and verified manual-merge closure. See [Beads operation](elixir/docs/beads.md).

Self-managed GitLab Beads delivery uses an explicit `tracker.provider.gitlab_web_url` web origin, a matching `review_repository` (`host/group/project`), and native `glab --hostname` authentication. Optional `git_remote` (default `origin`), `publish_base` (default `main`) and exact `publish_paths` scope host publication. See [Beads configuration](elixir/docs/beads.md).

Beads runs can freeze task-specific validation policies, expose scoped host task
reads, and preflight strict prompts before claiming work. Opt-in host checks bind
receipts to a clean commit and attempt. Corrected session evidence keeps process
results separate from tool transport status; see [operation](elixir/docs/beads.md).

Beads host delivery uses `beads_checkpoint` (scoped commit only), then
`beads_validate` and `beads_publish`; verification never requires sandbox Git writes.

Beads workflows support retained-worktree preflight, typed blocked/review handoffs,
separate runtime recovery budgets, opt-in compact task briefs and resumable
`beads_deliver`. Host receipts derive from captured log bytes. Native-event JSON/OTLP
keeps operation outcomes separate from exec wrappers; see the Beads operation guide.
