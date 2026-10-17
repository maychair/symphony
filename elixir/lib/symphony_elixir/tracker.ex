defmodule SymphonyElixir.Tracker do
  @moduledoc """
  Adapter boundary for issue tracker reads and provider-native agent tools.

  The orchestrator only depends on the read callbacks. Agent-side mutations stay
  behind optional provider-native tools so tracker-specific capabilities do not
  leak into scheduler policy.
  """

  alias SymphonyElixir.{Config, TaskPlan}
  alias SymphonyElixir.MailReview.Listener
  alias SymphonyElixir.Tracker.Issue

  @adapters %{
    "asana" => SymphonyElixir.Asana.Adapter,
    "github" => SymphonyElixir.GitHub.Adapter,
    "gitlab" => SymphonyElixir.GitLab.Adapter,
    "jira" => SymphonyElixir.Jira.Adapter,
    "linear" => SymphonyElixir.Linear.Adapter,
    "memory" => SymphonyElixir.Tracker.Memory
  }

  @callback fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  @callback fetch_issues_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  @callback agent_tool_specs() :: [map()]
  @callback execute_agent_tool(String.t(), term(), keyword()) :: map()
  @callback secret_environment_names(map()) :: [String.t()]
  @callback validate_config(map()) :: :ok | {:error, term()}

  @callback prepare_run(Issue.t(), keyword()) :: {:ok, Issue.t(), keyword()} | {:error, term()}
  @callback finish_run(Issue.t(), keyword(), term()) :: :ok | {:error, term()}
  @callback agent_environment(map()) :: map()

  @optional_callbacks [
    prepare_run: 2,
    finish_run: 3,
    agent_environment: 1,
    agent_tool_specs: 0,
    execute_agent_tool: 3,
    validate_config: 1
  ]

  @spec prepare_run(Issue.t(), keyword()) :: {:ok, Issue.t(), keyword()} | {:error, term()}
  def prepare_run(issue, opts) do
    selected = adapter()

    with {:ok, issue, opts} <- optional(selected, :prepare_run, [issue, Keyword.put(opts, :tracker_adapter, selected)], {:ok, issue, opts}) do
      SymphonyElixir.Execution.prepare(issue, opts)
    end
  end

  @spec finish_run(Issue.t(), keyword(), term()) :: :ok | {:error, term()}
  def finish_run(issue, opts, result) do
    selected = opts[:tracker_adapter] || adapter()

    with :ok <- SymphonyElixir.Execution.finish(issue, opts, result) do
      optional(selected, :finish_run, [issue, opts, result], :ok)
    end
  end

  defp optional(adapter, callback, args, fallback) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, callback, length(args)) do
      apply(adapter, callback, args)
    else
      fallback
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(states) do
    with {:ok, issues} <- adapter().fetch_issues_by_states(states),
         {:ok, reviews} <- review_issues() do
      {:ok, Enum.map(Enum.reject(issues, &("symphony-review" in &1.labels)), &TaskPlan.project/1) ++ Enum.filter(reviews, &(&1.state in states))}
    end
  end

  @spec fetch_issues_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids(issue_ids) do
    {review_ids, normal_ids} = Enum.split_with(issue_ids, &String.starts_with?(&1, "mail-review:"))

    with {:ok, issues} <- adapter().fetch_issues_by_ids(normal_ids),
         {:ok, reviews} <- review_issues() do
      {:ok, Enum.map(Enum.reject(issues, &("symphony-review" in &1.labels)), &TaskPlan.project/1) ++ Enum.filter(reviews, &(&1.id in review_ids))}
    end
  end

  defp review_issues do
    if SymphonyElixir.MailReview.enabled?() and Process.whereis(SymphonyElixir.MailReview.Listener), do: Listener.issues(), else: {:ok, []}
  end

  @doc """
  Captures the selected adapter and effective tracker settings for one
  app-server session so tool advertisement and execution cannot drift across a
  workflow reload.
  """
  @spec bind_agent_tools(map() | nil) :: map()
  def bind_agent_tools(tracker_settings \\ nil) do
    tracker_settings = tracker_settings || Config.settings!().tracker
    adapter = adapter_for_settings!(tracker_settings)

    %{
      agent_environment: optional(adapter, :agent_environment, [tracker_settings], %{}),
      adapter: adapter,
      tracker_settings: tracker_settings,
      tool_specs: adapter_agent_tool_specs(adapter) ++ SymphonyElixir.Execution.tool_specs(),
      secret_environment_names: adapter_secret_environment_names(adapter, tracker_settings)
    }
  end

  @spec execute_bound_agent_tool(map(), String.t(), term(), keyword()) :: map()
  def execute_bound_agent_tool(
        %{adapter: adapter, tracker_settings: tracker_settings},
        tool,
        arguments,
        opts \\ []
      ) do
    if tool == "task_handoff" do
      SymphonyElixir.Execution.handoff(arguments, Keyword.put(opts, :tracker_settings, tracker_settings))
    else
      execute_agent_tool_with_adapter(
        adapter,
        tool,
        arguments,
        Keyword.put(opts, :tracker_settings, tracker_settings)
      )
    end
  end

  @spec validate_config(map()) :: :ok | {:error, term()}
  def validate_config(%{kind: kind} = tracker_settings) do
    with {:ok, adapter} <- adapter_for_kind(kind) do
      if Code.ensure_loaded?(adapter) and function_exported?(adapter, :validate_config, 1) do
        adapter.validate_config(tracker_settings)
      else
        :ok
      end
    end
  end

  @spec adapter() :: module()
  def adapter do
    Config.settings!().tracker
    |> adapter_for_settings!()
  end

  @spec adapter_for_kind(String.t()) :: {:ok, module()} | {:error, term()}
  def adapter_for_kind(kind) do
    case Map.fetch(@adapters, kind) do
      {:ok, adapter} -> {:ok, adapter}
      :error -> {:error, {:unsupported_tracker_kind, kind}}
    end
  end

  defp adapter_for_settings!(%{kind: kind}) do
    {:ok, adapter} = adapter_for_kind(kind)
    adapter
  end

  defp adapter_agent_tool_specs(adapter) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :agent_tool_specs, 0) do
      adapter.agent_tool_specs()
    else
      []
    end
  end

  defp execute_agent_tool_with_adapter(adapter, tool, arguments, opts) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :execute_agent_tool, 3) do
      adapter.execute_agent_tool(tool, arguments, opts)
    else
      unsupported_agent_tool_response(tool)
    end
  end

  defp adapter_secret_environment_names(adapter, tracker_settings) do
    adapter.secret_environment_names(tracker_settings)
  end

  defp unsupported_agent_tool_response(tool) do
    output =
      Jason.encode!(%{
        "error" => %{
          "message" => "Unsupported dynamic tool: #{inspect(tool)}.",
          "supportedTools" => []
        }
      })

    %{
      "success" => false,
      "output" => output,
      "contentItems" => [%{"type" => "inputText", "text" => output}]
    }
  end
end
