defmodule SymphonyElixir.WorkflowArtifact do
  @moduledoc "Run a configured artifact validator; business schemas belong to the supplied tool."

  @spec evaluate(map(), map()) :: {:ok, map()} | {:error, term()}
  def evaluate(config, payload) do
    case config["result_command"] do
      [executable | args] when is_binary(executable) -> invoke(executable, args, payload)
      _ -> {:error, :workflow_result_command_required}
    end
  end

  defp invoke(executable, args, payload) do
    directory = Path.join(System.tmp_dir!(), "symphony-artifact-" <> Base.encode16(:crypto.strong_rand_bytes(16)))

    with :ok <- File.mkdir(directory) do
      try do
        File.chmod!(directory, 0o700)
        input = Path.join(directory, "input.json")
        File.write!(input, Jason.encode!(payload))

        case System.cmd("timeout", ["--signal=TERM", "30s", executable | args ++ ["--input", input]], stderr_to_stdout: false) do
          {output, 0} when byte_size(output) <= 1_048_576 -> decode(output)
          _ -> {:error, :workflow_artifact_rejected}
        end
      after
        File.rm_rf(directory)
      end
    end
  rescue
    _ -> {:error, :workflow_artifact_unavailable}
  end

  defp decode(output) do
    case Jason.decode(output) do
      {:ok, %{} = result} -> {:ok, result}
      _ -> {:error, :invalid_workflow_artifact}
    end
  end
end
