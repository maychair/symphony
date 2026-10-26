# Configured Review Workflow

The listener discovers native reviewer requests and retains disabled-state,
review-once and execution-ownership checks. It does not orchestrate Standards or
Spec. `ReviewLane.Runner` pins the source and starts one ordinary `WorkflowSession`
with configured instructions. Native delegation, when authorized by the supplied
workflow, is an Agent capability rather than an engine-owned two-axis scheduler.

Configure `instruction_files` as a nonempty list of absolute Markdown file paths.
The integration owns these files, normally a Workflow and a Playbook. Their exact
texts are hashed together and checked again after source preparation. The engine
has no knowledge of their repository layout or business-stage headings.
Configure `result_command` as an executable/argument array. It receives `--input`
and a private JSON file, validates the workflow artifact and returns canonical JSON.
The integration supplies this same tool to manual review. No engine build or
running Symphony service is needed for manual review.

The submitted artifact is passed through with the fixed execution `record`.
The validator owns business fields, finding resolution and technical verdicts;
Symphony persists the returned `finding_register` and `verdict` without deriving
or validating their business schema. Subsequent rounds pass that retained state
back to the same configured validator. Execution ownership, native stop and
publication readback remain engine responsibilities.

The workflow reads linked requirements through its provider tools and assesses
their coverage. Source preparation passes native MR text unchanged; it does not
select Issue links, truncate requirements or judge their completeness. Artifact
transport preserves the validator's full JSON output without a separate size cap.
Publication tracks confirmed native comment receipts without inspecting findings;
reply changes are observed for every published comment, including clean reviews.

The session exposes ordinary native tools and `workflow_submit`, which records
one artifact. Submission alone does not complete a run. The native turn must end,
stop must be confirmed, the configured validator must accept the result, and the
provider adapter must confirm the exact publication under the admitted identity
and fixed revision. Missing submission, interrupted execution and unconfirmed
native stop cannot become a clean result. Read failures are investigated by the
workflow, not counted or permanently latched by a special read proxy.

Execution checkpoints contain the single native thread/turn and allocation and
stop evidence. The listener does not merge business-axis runtime dictionaries.
A disabled listener stops discovery and queued admission without interrupting an
already admitted execution. Cancellation remains explicit. An uncertain native
allocation or publication is fenced instead of starting a replacement attempt.

Protocol 3 accepts only canonical workflow results and a single published body.
Old result formats and multi-comment publication execution are rejected; retain
historical audit files separately and never replay old executions. The native
single-review admission rule still applies after code or instruction changes.
There is no `mix symphony.review` or engine-owned manual journal.

No review component approves or merges changes. Native identity isolation,
workspace safety and exact publication readback remain required even when the
operator permits broad filesystem reading.
