defmodule SymphonyElixir.MergedWorkspaceCleanup do
  @moduledoc "Single-flight reconciliation of merged deliveries on the existing poll cycle."

  alias SymphonyElixir.Config

  @spec start(Supervisor.supervisor()) :: reference() | nil
  def start(supervisor) do
    case Config.settings!().workspace.merge_cleanup_command do
      command when is_binary(command) and command != "" ->
        task = Task.Supervisor.async_nolink(supervisor, fn -> System.cmd("bash", ["-c", command], stderr_to_stdout: true) end)
        task.ref

      _ ->
        nil
    end
  end
end
