# Configured Review Workflow

Symphony discovers native reviewer requests, enforces configured admission and
shared concurrency, starts an ordinary Agent session and records its execution.
The supplied Workflow and Playbook own review preparation, investigation,
validation, authorized delivery and resource cleanup. Manual callers use the same
instructions without running Symphony.

Configure `instruction_files` with absolute paths to those instructions. Their
contents are pinned at admission. The Runner passes the target URL, repository,
fixed base/head/target, instruction digest and a stable owner (`issue.id`) to the
Agent. `projects` requires native repository IDs; local checkouts are no longer
required. The session starts in isolated execution scratch space under
`workspace.root`, without cloning a source tree or running development hooks.
The Agent selects tools and uses their returned checkout explicitly for source
commands and code navigation. Symphony does not know pool paths or tool internals.

`result_command` is optional caller-supplied command data included in the prompt.
When provided, the Workflow directs the Agent to invoke it. Symphony does not run
it or interpret review axes, finding transitions or technical verdicts.
`model_settings` selects the ordinary session model. `publish_results: false`
restricts the Agent to local results; the default permits publication under the
supplied Workflow. This is instruction-level authority, not an OS sandbox. The
scheduler never posts review comments, in either mode.

The session exposes native tools and `workflow_submit`, which accepts an opaque
result map after the Agent completes its workflow and cleanup. The listener
stores that map as `workflow_result` only after confirmed native stop. Generic
`failed` or `needs_input` status retains a failed execution; other submitted
results finish the execution without asserting a clean review or publication.
The existing board projects the execution and Agent-provided result/report links;
it does not independently validate review conclusions or delivery.

Missing submission, interrupted execution or uncertain native stop cannot finish
the execution. Disabling discovery does not interrupt an admitted task. Explicit
cancellation and listener restart preserve native ownership and stop evidence;
no process exit authorizes reclaiming an external resource. Normal resource return
belongs to the Agent's workflow; incomplete tasks retain ownership for explicit
follow-up. The scheduler neither reads slot records nor releases slots.

Native review-once admission, reviewer withdrawal, fixed-input changes, journal
ownership and concurrency remain scheduler concerns. The Agent reads MR text,
discussions and linked requirements through ordinary provider tools. It checks
current target revisions and native delivery under the supplied Workflow.
Symphony does not reconstruct author-response rounds or replay publication.

Journal schema 4 records this execution contract. Older journals remain audit-only;
use fresh state for this version. There is no old-result conversion, migration,
publication recovery or engine-owned manual review entry. No review execution
implicitly authorizes source edits, formal approval or merging.
