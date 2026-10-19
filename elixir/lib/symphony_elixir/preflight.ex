defmodule SymphonyElixir.Preflight do
  alias SymphonyElixir.RuntimeContext
  @moduledoc "Read-only tracker validation usable by Mix and the standalone executable."
  alias SymphonyElixir.{Config, PromptBuilder, Tracker}

  @spec run(String.t() | nil) :: {:ok, non_neg_integer()} | {:error, term()}
  def run(issue) do
    Enum.each([:yaml_elixir, :ecto, :req], fn app -> {:ok, _} = Application.ensure_all_started(app) end)

    with {:ok, repositories} <- SymphonyElixir.RepositoryService.load(SymphonyElixir.Workflow.workflow_file_path()) do
      if repositories == [], do: run_repository(issue), else: run_repositories(repositories, issue)
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp run_repository(issue) do
    with :ok <- Config.validate!(),
         {:ok, issues} <- read_issues(issue) do
      Enum.each(issues, &PromptBuilder.build_prompt/1)
      {:ok, length(issues)}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp run_repositories(_, issue) when not is_nil(issue), do: {:error, :repository_issue_selection_required}

  defp run_repositories(repositories, nil) do
    Enum.reduce_while(repositories, {:ok, 0}, fn context, {:ok, total} ->
      result = RuntimeContext.with_context(context, &read_repository/0)

      case result do
        {:ok, count} -> {:cont, {:ok, total + count}}
        {:error, reason} -> {:halt, {:error, {context.id, reason}}}
      end
    end)
  end

  defp read_repository, do: run_repository(nil)

  defp read_issues(nil), do: Tracker.adapter().fetch_issues_by_states(Config.settings!().tracker.active_states)

  defp read_issues(id) do
    case Tracker.adapter().fetch_issues_by_ids([id]) do
      {:ok, []} -> {:error, :issue_not_found}
      result -> result
    end
  end
end
