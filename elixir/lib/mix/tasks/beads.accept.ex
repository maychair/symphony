defmodule Mix.Tasks.Beads.Accept do
  @moduledoc "Accept a human-reviewed Beads delivery after verifying the supplied PR/MR was merged."
  use Mix.Task
  alias SymphonyElixir.{Beads.Acceptance, Config, Workflow}

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [workflow: :string, issue: :string, review_url: :string, accepted_by: :string, close_source: :boolean])

    unless rest == [] and invalid == [] and Enum.all?([:workflow, :issue, :review_url, :accepted_by], &is_binary(opts[&1])) do
      Mix.raise("Usage: mix beads.accept --workflow WORKFLOW.md --issue ID --review-url URL --accepted-by HUMAN [--close-source]")
    end

    Workflow.set_workflow_file_path(opts[:workflow])
    Mix.Task.run("app.config")
    Application.ensure_all_started(:yaml_elixir)
    Application.ensure_all_started(:ecto)

    case Acceptance.accept(Config.settings!().tracker, opts[:issue], opts[:review_url], opts[:accepted_by], close_source: opts[:close_source]) do
      :ok -> Mix.shell().info("Accepted #{opts[:issue]} with verified merged review evidence.")
      {:error, reason} -> Mix.raise("Acceptance refused: #{inspect(reason)}")
    end
  end
end
