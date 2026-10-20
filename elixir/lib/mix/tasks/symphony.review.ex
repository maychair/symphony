defmodule Mix.Tasks.Symphony.Review do
  @shortdoc "Run the shared two-axis review pipeline from a JSON request"
  @moduledoc """
  Runs the same ReviewWorkflow used by the automatic review lane.

      mix symphony.review --workflow ../WORKFLOW.md --request request.json

  A request may come from stdin. The command emits only the canonical result
  JSON and never publishes it.
  """

  use Mix.Task
  alias SymphonyElixir.{PathSafety, ReviewLane, ReviewRequest, ReviewWorkflow, TaskWorkflow, Workflow}
  alias SymphonyElixir.ReviewLane.Journal

  @switches [workflow: :string, request: :string]

  @impl Mix.Task
  def run(args) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: @switches)

    if positional != [] or invalid != [] do
      Mix.raise("Usage: mix symphony.review --workflow PATH [--request FILE]")
    end

    request = read_request(opts[:request])

    with {:ok, workflow} <- required_path(opts[:workflow], "workflow"),
         :ok <- Workflow.set_workflow_file_path(workflow),
         _ <- Mix.Task.run("app.config"),
         {:ok, config} <- runtime_config(),
         {:ok, context} <- ReviewRequest.prepare(request, config) do
      run_context(context, request)
    else
      {:error, reason} -> Mix.raise("Review request failed: #{inspect(reason)}")
    end
  end

  defp run_context(context, request) do
    subject =
      context.config
      |> Map.take(~w(provider host))
      |> Map.merge(Map.take(context.record, ~w(project iid)))
      |> Map.put("repository", manual_repository(request["repository"]))

    directory = Path.join([context.config["state_dir"], "manual", TaskWorkflow.digest(subject)])

    case Journal.open(directory) do
      {:ok, journal, previous} ->
        try do
          history = manual_history(previous, subject)
          runtime = context.record |> Map.take(~w(base head target_branch round)) |> Map.merge(%{"phase" => "admitted", "axes" => %{}, "workspace" => context.repository})
          initial = %{"schema_version" => 1, "subject" => subject, "history" => history, "runtime" => runtime}
          Process.put({__MODULE__, journal.port}, initial)
          checkpoint = &manual_checkpoint(journal, &1)
          :ok = checkpoint.(%{})
          execute(context, checkpoint)
        after
          Process.delete({__MODULE__, journal.port})
          Journal.close(journal)
        end

      {:error, reason} ->
        Mix.raise("Manual review journal unavailable at #{directory}: #{inspect(reason)}")
    end
  end

  defp manual_repository(nil), do: nil

  defp manual_repository(path) do
    {:ok, canonical} = PathSafety.canonicalize(path)
    canonical
  end

  defp manual_history(nil, _subject), do: []

  defp manual_history(previous, subject) do
    with {:ok, %{"schema_version" => 1, "subject" => ^subject, "runtime" => %{"axes" => axes} = runtime, "history" => history}} <- Jason.decode(previous),
         true <- is_map(axes) and is_list(history),
         true <- Enum.all?(axes, fn {_name, axis} -> is_map(axis) and axis["native_stop_confirmed"] == true end) do
      history ++ [runtime]
    else
      _ -> Mix.raise("Manual review requires recovery; prior native stop is uncertain. The journal and snapshot are retained.")
    end
  end

  defp manual_checkpoint(journal, changes) do
    key = {__MODULE__, journal.port}
    current = Process.get(key)
    updated = Map.update!(current, "runtime", &Map.merge(&1, changes))
    :ok = Journal.write!(journal, Jason.encode!(updated))
    Process.put(key, updated)
    :ok
  end

  defp execute(context, checkpoint) do
    case ReviewWorkflow.run(context, checkpoint: checkpoint) do
      {:ok, result} ->
        :ok = checkpoint.(%{"phase" => "completed", "result" => result})
        IO.puts(Jason.encode!(result))
        if stopped?(result), do: ReviewRequest.cleanup(context)

      {:error, reason} ->
        Mix.raise("Review failed; snapshot retained at #{context.repository}: #{inspect(reason)}")
    end
  end

  defp stopped?(result), do: Enum.all?(result["axes"], fn {_, axis} -> axis["native_stop_confirmed"] == true end)

  defp read_request(nil) do
    case IO.read(:stdio, :eof) |> Jason.decode() do
      {:ok, request} when is_map(request) -> request
      _ -> Mix.raise("Review request must be a JSON object on stdin")
    end
  end

  defp read_request(path) do
    with {:ok, body} <- File.read(path),
         {:ok, request} when is_map(request) <- Jason.decode(body) do
      request
    else
      reason -> Mix.raise("Review request file is invalid: #{inspect(reason)}")
    end
  end

  defp required_path(nil, name), do: {:error, {:missing_option, name}}
  defp required_path(path, _name) when is_binary(path), do: {:ok, Path.expand(path)}

  defp runtime_config do
    with %{} = config <- ReviewLane.config(),
         :ok <- ReviewLane.validate_config(%{provider: %{"review_lane" => config}}),
         {:ok, _, _} <- ReviewWorkflow.rules(config) do
      {:ok, config}
    else
      nil -> {:error, :review_lane_unavailable}
      error -> error
    end
  end
end
