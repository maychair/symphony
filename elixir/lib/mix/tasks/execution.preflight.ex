defmodule Mix.Tasks.Execution.Preflight do
  @moduledoc "Validate repository tracker access and render an optional Issue without dispatch."
  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [workflow: :string, issue: :string])
    SymphonyElixir.Workflow.set_workflow_file_path(Keyword.fetch!(opts, :workflow))
    Mix.Task.run("app.config")
    Enum.each([:yaml_elixir, :ecto, :req], &Application.ensure_all_started/1)

    with :ok <- SymphonyElixir.Config.validate!(),
         {:ok, issues} <- read_issues(opts[:issue]) do
      Enum.each(issues, &SymphonyElixir.PromptBuilder.build_prompt/1)
      Mix.shell().info("Repository tracker preflight passed (#{length(issues)} Issues read; no dispatch).")
    else
      error -> Mix.raise("Repository tracker preflight failed: #{inspect(error)}")
    end
  end

  defp read_issues(nil) do
    SymphonyElixir.Tracker.adapter().fetch_issues_by_states(SymphonyElixir.Config.settings!().tracker.active_states)
  end

  defp read_issues(id) do
    case SymphonyElixir.Tracker.adapter().fetch_issues_by_ids([id]) do
      {:ok, []} -> {:error, :issue_not_found}
      result -> result
    end
  end
end
