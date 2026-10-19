defmodule SymphonyElixir.AgentRuntimeSupervisor do
  alias SymphonyElixir.RuntimeContext

  @moduledoc """
  Supervises the scheduler authority together with its agent tasks.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    RuntimeContext.install(opts[:context])

    task_supervisor_name =
      Keyword.get(opts, :task_supervisor_name, SymphonyElixir.TaskSupervisor)

    orchestrator_name = Keyword.get(opts, :orchestrator_name, SymphonyElixir.Orchestrator)

    worker_opts = [name: orchestrator_name, task_supervisor: task_supervisor_name, context: opts[:context]]

    children = [
      Supervisor.child_spec(
        {Task.Supervisor, name: task_supervisor_name},
        id: task_supervisor_name
      ),
      Supervisor.child_spec(
        {SymphonyElixir.Orchestrator, worker_opts},
        id: orchestrator_name
      )
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
