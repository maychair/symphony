defmodule SymphonyElixir.Beads.Brief do
  @moduledoc "Opt-in compact task briefs; custom Workflow instructions are still rendered and validated."
  alias SymphonyElixir.Beads.{Adapter, RunJournal}
  alias SymphonyElixir.{PromptBuilder, Workflow}

  @spec template_hash() :: String.t()
  def template_hash, do: template_hash(Workflow.current())

  @spec template_hash({:ok, map()}) :: String.t()
  def template_hash({:ok, workflow}), do: digest(workflow.prompt_template)

  @spec version(map()) :: String.t()
  def version(task), do: digest(Jason.encode!(task))

  @spec render(map(), map(), keyword()) :: String.t()
  def render(settings, issue, opts) do
    compact = settings.provider["compact_task_context"] == true
    prepared = if compact, do: compact_issue(issue), else: issue
    snapshot = Keyword.get_lazy(opts, :workflow_snapshot, &Workflow.current/0)
    rendered = PromptBuilder.build_prompt(prepared, Keyword.put(opts, :workflow_snapshot, snapshot))
    directory = RunJournal.directory(Adapter.journal_root(settings), issue.id)

    if compact and same_template?(directory, template_hash(snapshot)) do
      delta =
        "Resume Beads task #{issue.id} in this same native thread. " <>
          "Retain its existing Workflow/repository rules. Call beads_task_context for current task/version and frozen policy. " <>
          "Apply only the supplied recovery delta and proceed to its next gate; changed policy requires operator handoff."

      if byte_size(delta) < byte_size(rendered), do: delta, else: rendered
    else
      rendered
    end
  end

  defp same_template?(directory, expected_hash) do
    case RunJournal.read(directory) do
      {:ok, %{"thread_id" => thread, "brief_template_hash" => hash}} when is_binary(thread) -> hash == expected_hash
      _ -> false
    end
  end

  defp compact_issue(issue) do
    fields = ["acceptance_criteria", "notes", "design"]
    native = Enum.reduce(fields, issue.native_ref || %{}, &Map.put(&2, &1, "Read this field from beads_task_context."))
    %{issue | description: "Read the authoritative task body once through beads_task_context.", native_ref: native}
  end

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
