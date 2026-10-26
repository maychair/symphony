defmodule SymphonyElixir.Command do
  @moduledoc "Native command execution in the current repository environment."
  alias SymphonyElixir.RuntimeContext

  @spec run(String.t(), [String.t()]) :: {:ok, String.t()} | {:error, term()}
  def run(executable, args) do
    case capture(executable, args) do
      {output, 0} -> {:ok, output}
      {_output, status} -> {:error, {:command_failed, executable, status}}
    end
  rescue
    error -> {:error, {:command_unavailable, Exception.message(error)}}
  end

  @spec capture(String.t(), [String.t()]) :: {String.t(), non_neg_integer()}
  def capture(executable, args) do
    System.cmd("timeout", ["--signal=TERM", "30s", executable | args],
      stderr_to_stdout: false,
      env: Map.to_list(RuntimeContext.environment())
    )
  end
end
