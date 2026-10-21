defmodule SymphonyElixir.WorkflowInstructions do
  @moduledoc "Load configured instruction files without interpreting business stages."
  alias SymphonyElixir.TaskWorkflow

  @spec load(map()) :: {:ok, String.t(), String.t()} | {:error, atom()}
  def load(config) do
    with files when is_list(files) and files != [] <- config["instruction_files"],
         true <- Enum.all?(files, &(is_binary(&1) and Path.type(&1) == :absolute)),
         {:ok, texts} <- read(files) do
      body = Enum.zip_with(files, texts, fn path, text -> "Source: #{path}\n\n#{text}" end) |> Enum.join("\n\n")
      {:ok, body, TaskWorkflow.digest(texts)}
    else
      _ -> {:error, :workflow_instructions_unavailable}
    end
  end

  defp read(files) do
    Enum.reduce_while(files, {:ok, []}, fn file, {:ok, acc} ->
      case File.read(file) do
        {:ok, text} ->
          append_text(text, acc)

        error ->
          {:halt, error}
      end
    end)
  end

  defp append_text(text, acc) do
    if String.valid?(text) and String.trim(text) != "",
      do: {:cont, {:ok, acc ++ [text]}},
      else: {:halt, {:error, :empty_instructions}}
  end
end
