defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Dispatches client-side tool calls to the configured tracker adapter.
  """

  alias SymphonyElixir.Tracker

  def execute(tool, arguments, binding, opts \\ [])

  @spec execute(String.t() | nil, term(), map(), keyword()) :: map()
  def execute(tool, arguments, %{task_execution: _} = binding, opts),
    do: SymphonyElixir.TaskTools.execute(tool, arguments, binding, opts)

  def execute(tool, arguments, binding, opts) do
    Tracker.execute_bound_agent_tool(binding, tool, arguments, opts)
  end

  @spec bind_session(keyword()) :: {:ok, map()} | {:error, term()}
  def bind_session(opts) do
    case opts[:run_record] do
      %{"execution_binding" => _} = record ->
        SymphonyElixir.TaskTools.bind(record, opts[:execution_policy], Keyword.put(opts[:task_native_options] || [], :tracker_settings, opts[:tracker_settings]))

      _ ->
        {:ok, Keyword.get_lazy(opts, :dynamic_tool_binding, fn -> bind(opts[:tracker_settings]) end)}
    end
  end

  @spec bind(map() | nil) :: map()
  def bind(settings \\ nil) do
    Tracker.bind_agent_tools(settings)
  end
end
