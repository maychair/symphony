defmodule SymphonyElixir.MergedWorkspaceCleanup do
  alias SymphonyElixir.RuntimeContext
  @moduledoc "Single-flight reconciliation of merged deliveries on the existing poll cycle."

  alias SymphonyElixir.Config

  @spec enabled?() :: boolean()
  def enabled? do
    command = Config.settings!().workspace.merge_cleanup_command
    is_binary(command) and command != ""
  end

  @spec start(Supervisor.supervisor(), Enumerable.t()) :: reference() | nil
  def start(supervisor, hints \\ []) do
    case Config.settings!().workspace.merge_cleanup_command do
      command when is_binary(command) and command != "" ->
        task =
          Task.Supervisor.async_nolink(
            supervisor,
            RuntimeContext.wrap(fn -> run(command, Enum.to_list(hints)) end)
          )

        task.ref

      _ ->
        nil
    end
  end

  defp run(command, []), do: invoke(command, [])

  defp run(command, hints) do
    Enum.reduce(hints, {"", 0}, fn hint, previous ->
      case invoke(command, ["merge-cleanup", Jason.encode!(hint)]) do
        {_, 0} -> previous
        failure -> failure
      end
    end)
  end

  defp invoke(command, args) do
    System.cmd("bash", ["-c", command | args], stderr_to_stdout: true, env: Map.to_list(RuntimeContext.environment()))
  end
end
