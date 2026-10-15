defmodule Mix.Tasks.Beads.Resume do
  @moduledoc "Reconcile an observed native Beads run after stopping Symphony and any other executor."
  use Mix.Task
  alias SymphonyElixir.{Beads.Recovery, Config, Workflow}

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [workflow: :string, issue: :string, executor_stopped: :boolean])

    valid = rest == [] and invalid == [] and is_binary(opts[:workflow]) and is_binary(opts[:issue])

    unless valid and opts[:executor_stopped] do
      Mix.raise("Usage: mix beads.resume --workflow WORKFLOW.md --issue ID --executor-stopped (Symphony must be stopped)")
    end

    Workflow.set_workflow_file_path(opts[:workflow])
    Mix.Task.run("app.config")
    Application.ensure_all_started(:yaml_elixir)
    Application.ensure_all_started(:ecto)

    case Recovery.resume(Config.settings!().tracker, opts[:issue], opts[:executor_stopped]) do
      :ok -> Mix.shell().info("Reconciled #{opts[:issue]}; restart Symphony to resume the observed thread.")
      error -> Mix.raise("Recovery refused: #{inspect(error)}")
    end
  end
end
