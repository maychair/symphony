defmodule SymphonyElixir.RepositorySupervisor do
  @moduledoc "One repository's isolated OTP subtree inside the shared service."
  use Supervisor
  alias SymphonyElixir.{AgentRuntimeSupervisor, RuntimeContext, WorkflowStore}
  alias SymphonyElixir.ReviewLane.Listener

  @spec start_link(map()) :: Supervisor.on_start()
  def start_link(context) do
    RuntimeContext.with_context(context, fn ->
      Supervisor.start_link(__MODULE__, context, name: RuntimeContext.server(__MODULE__))
    end)
  end

  @impl true
  def init(context) do
    RuntimeContext.install(context)

    children = [
      {WorkflowStore, context: context},
      {AgentRuntimeSupervisor,
       context: context,
       name: RuntimeContext.server(AgentRuntimeSupervisor),
       task_supervisor_name: RuntimeContext.server(SymphonyElixir.TaskSupervisor),
       orchestrator_name: RuntimeContext.server(SymphonyElixir.Orchestrator)},
      {Listener, context: context, name: RuntimeContext.server(Listener)}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
