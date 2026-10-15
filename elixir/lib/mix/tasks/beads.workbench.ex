defmodule Mix.Tasks.Beads.Workbench do
  @moduledoc "Import operator-audited structured workbench requests without starting another scheduler."
  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [workflow: :string, input: :string])
    unless opts[:workflow] && opts[:input], do: Mix.raise("--workflow and --input required")
    SymphonyElixir.Workflow.set_workflow_file_path(opts[:workflow])
    Mix.Task.run("app.config")
    Application.ensure_all_started(:yaml_elixir)
    Application.ensure_all_started(:ecto)
    requests = opts[:input] |> File.read!() |> Jason.decode!()
    settings = SymphonyElixir.Config.settings!().tracker

    Enum.each(requests, fn request ->
      case SymphonyElixir.Beads.Workbench.request(settings, request["issue_id"], request["gates"], "operator-migration") do
        {:ok, _} -> Mix.shell().info("Imported " <> request["issue_id"])
        error -> Mix.raise(inspect(error))
      end
    end)
  end
end
