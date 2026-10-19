defmodule SymphonyElixir.Preflight do
  @moduledoc "Read-only tracker validation usable by Mix and the standalone executable."
  alias SymphonyElixir.{Config, PromptBuilder, Tracker}

  @spec run(String.t() | nil) :: {:ok, non_neg_integer()} | {:error, term()}
  def run(issue) do
    Enum.each([:yaml_elixir, :ecto, :req], fn app -> {:ok, _} = Application.ensure_all_started(app) end)

    with :ok <- Config.validate!(),
         {:ok, issues} <- read_issues(issue) do
      Enum.each(issues, &PromptBuilder.build_prompt/1)
      {:ok, length(issues)}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp read_issues(nil), do: Tracker.adapter().fetch_issues_by_states(Config.settings!().tracker.active_states)

  defp read_issues(id) do
    case Tracker.adapter().fetch_issues_by_ids([id]) do
      {:ok, []} -> {:error, :issue_not_found}
      result -> result
    end
  end
end
