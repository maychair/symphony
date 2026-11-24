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

The session exposes native tools and `workflow_submit`. Publishing-enabled
lanes require one native Review comment. The Agent submits the comment body and
native report URL. After confirmed native stop, the listener checks that the
comment exists on the selected MR or PR, matches the body and URL, and was
written by the configured `publisher_id`. Use the user ID of the account
associated with the active publishing credential. This identity applies to new
receipts and can be rotated without resetting review history. Once verification
succeeds, the listener marks the review completed. Local-only runs retain their submitted result without a comment.
A transient read failure retains the submitted receipt for read-only retry.
The scheduler does not evaluate review conclusions. A `failed` or `needs_input`
result records a blocker without publishing a Review comment. A current GitLab
`needs_input` result with public gap details also sends a separate status
discussion mentioning the configured reviewer. The notice lists confirmed
findings, evidence still needed, ownership and the conditions for requesting
review again. Local-only lanes, ordinary failures and superseded rounds send no
status notice. Each publishing repository must use the credential context of
its configured publisher. The notice never qualifies as a Review verdict or prevents a
replacement review.

The listener persists the send intent in the existing review journal before
posting. Reconciliation rechecks the fixed MR revision, assignment and bot,
then verifies the native discussion by author and body. After an uncertain send,
restarts and webhook replays only read back the notice. A new status notice is
keyed by the repository, MR, round and normalized missing evidence.

Missing submission, interrupted execution or uncertain native stop cannot finish
the execution. Disabling discovery does not interrupt an admitted task. Explicit
cancellation and listener restart preserve native ownership and stop evidence;
no process exit authorizes reclaiming an external resource. Normal resource return
belongs to the Agent's workflow; incomplete tasks retain ownership for explicit
follow-up. The scheduler neither reads slot records nor releases slots.

Each admitted MR or PR has one automatic review to deliver. Before delivery,
a changed head, base, target or policy supersedes the previous execution.
The listener can schedule another attempt on the latest inputs once it has
confirmed the previous executor stopped and checked native discussions for an
existing publisher comment. Reviewer withdrawal fences unfinished work. A new
assignment can replace an unfinished, stopped execution. A completed review
remains completed through later pushes and reviewer changes.

Journal schema 4 records this execution contract. Older journals remain audit-only;
use fresh state for this version. There is no old-result conversion, migration,
publication recovery or engine-owned manual review entry. No review execution
implicitly authorizes source edits, formal approval or merging.
