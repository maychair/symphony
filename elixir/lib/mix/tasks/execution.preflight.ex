defmodule Mix.Tasks.Execution.Preflight do
  @moduledoc "Validate repository tracker access and render an optional Issue without dispatch."
  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [workflow: :string, issue: :string])
    SymphonyElixir.Workflow.set_workflow_file_path(Keyword.fetch!(opts, :workflow))
    Mix.Task.run("app.config")

    case SymphonyElixir.Preflight.run(opts[:issue]) do
      {:ok, count} -> Mix.shell().info("Repository tracker preflight passed (#{count} Issues read; no dispatch).")
      {:error, reason} -> Mix.raise("Repository tracker preflight failed: #{inspect(reason)}")
    end
  end
end
