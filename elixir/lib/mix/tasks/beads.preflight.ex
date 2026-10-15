defmodule Mix.Tasks.Beads.Preflight do
  @moduledoc "Validate configuration and an optional task prompt without claiming or allocating a session."
  use Mix.Task
  alias SymphonyElixir.Beads.{Adapter, Validation}
  alias SymphonyElixir.{Config, Workflow}

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [workflow: :string, issue: :string])

    unless rest == [] and invalid == [] and is_binary(opts[:workflow]) do
      Mix.raise("Usage: mix beads.preflight --workflow WORKFLOW.md [--issue ID]")
    end

    Workflow.set_workflow_file_path(opts[:workflow])
    Mix.Task.run("app.config")
    Application.ensure_all_started(:yaml_elixir)
    Application.ensure_all_started(:ecto)

    with :ok <- Config.validate!(),
         :ok <- task_preflight(opts[:issue]) do
      Mix.shell().info("Preflight passed; no claim, run admission or native session was created.")
    else
      error -> Mix.raise("Preflight refused: #{inspect(error)}")
    end
  end

  defp task_preflight(nil), do: :ok

  defp task_preflight(id) do
    settings = Config.settings!().tracker

    with true <- settings.kind == "beads" || {:error, :beads_required},
         {:ok, [issue]} <- Adapter.fetch_issues_by_ids([id]),
         {:ok, policy} <- Validation.policy(settings, issue),
         {:ok, _prompt} <- Adapter.preflight(settings, issue, [], policy) do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :task_not_found}
    end
  end
end
