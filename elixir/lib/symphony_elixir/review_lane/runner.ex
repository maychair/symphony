defmodule SymphonyElixir.ReviewLane.Runner do
  @moduledoc "Runs one fixed-base/head read-only review in a disposable source snapshot."
  alias SymphonyElixir.ReviewLane.Listener
  alias SymphonyElixir.{ReviewRequest, Workspace}

  @spec run(SymphonyElixir.Tracker.Issue.t(), pid() | nil, keyword()) :: :ok
  def run(issue, recipient, opts \\ []) do
    case Listener.begin_run(issue.id) do
      {:ok, record, config} ->
        owned_issue = %{issue | native_ref: Map.put(issue.native_ref, "execution_owner", record["execution_owner"])}
        run_admitted(owned_issue, record, config, recipient, opts)

      error ->
        raise "Review execution fenced: #{inspect(error)}"
    end
  end

  defp run_admitted(issue, record, config, recipient, opts) do
    with {:ok, workspace} <- Workspace.create_for_review(issue),
         request = %{"kind" => "mr", "project" => record["project"], "number" => record["iid"], "record" => record, "workspace" => workspace},
         {:ok, context} <- ReviewRequest.prepare(request, config) do
      if is_pid(recipient), do: send(recipient, {:worker_runtime_info, issue.id, %{worker_host: nil, workspace_path: context.repository}})

      execute(issue, record, context, recipient, opts)
    else
      error -> raise "Review execution fenced: #{inspect(error)}"
    end
  rescue
    error ->
      checkpoint(issue, %{"phase" => "failed", "error" => Exception.message(error)})
      reraise error, __STACKTRACE__
  end

  defp execute(issue, record, context, recipient, opts) do
    update = fn message -> if is_pid(recipient), do: send(recipient, {:codex_worker_update, issue.id, message}) end
    workflow_opts = opts |> Keyword.put(:checkpoint, &checkpoint(issue, &1)) |> Keyword.put(:on_message, update)

    case SymphonyElixir.ReviewWorkflow.run(context, workflow_opts) do
      {:ok, result} ->
        publish_result(issue, result)

      {:error, :scheduler_stop} ->
        stopped_before_thread(issue, record)

      {:error, {:scheduler_stop, axes}} ->
        stop_axes(issue, axes)

      error ->
        raise "Review workflow failed: #{inspect(error)}"
    end
  end

  defp publish_result(issue, result) do
    :ok = checkpoint(issue, %{"native_stop_confirmed" => axes_stopped?(result["axes"])})

    case Listener.submit(issue.id, issue.native_ref["execution_owner"], %{"completion" => result}) do
      :ok -> :ok
      {:error, reason} -> raise "Review publication failed: #{inspect(reason)}"
    end
  end

  defp stop_axes(issue, axes) do
    stopped = axes_stopped?(axes)
    :ok = checkpoint(issue, %{"phase" => "fenced", "native_stop_confirmed" => stopped})
    if stopped, do: :ok, else: raise("Review native stop not confirmed")
  end

  defp axes_stopped?(axes), do: Enum.all?(axes, fn {_, axis} -> axis["native_stop_confirmed"] == true end)

  defp checkpoint(issue, changes), do: checkpoint(issue, changes, System.monotonic_time(:millisecond) + 5_000)

  defp checkpoint(issue, changes, deadline) do
    if Listener.health().health == :disabled and System.monotonic_time(:millisecond) < deadline do
      Process.sleep(25)
      checkpoint(issue, changes, deadline)
    else
      Listener.checkpoint(issue.id, issue.native_ref["execution_owner"], changes)
    end
  catch
    :exit, reason ->
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(25)
        checkpoint(issue, changes, deadline)
      else
        exit(reason)
      end
  end

  defp stopped_before_thread(issue, record) do
    if is_nil(record["axes"]), do: checkpoint(issue, %{"phase" => "fenced", "native_stop_confirmed" => true})
  end
end
