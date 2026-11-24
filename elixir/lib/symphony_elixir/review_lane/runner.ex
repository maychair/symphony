defmodule SymphonyElixir.ReviewLane.Runner do
  @moduledoc "Bind an admitted MR to a configured workflow and the ordinary native session."
  alias SymphonyElixir.{ReviewLane, WorkflowInstructions, WorkflowSession, Workspace}
  alias SymphonyElixir.ReviewLane.Listener

  @spec run(SymphonyElixir.Tracker.Issue.t(), pid() | nil, keyword()) :: :ok
  def run(issue, recipient, opts \\ []) do
    case Listener.begin_run(issue.id) do
      {:ok, record, config} ->
        owned = %{issue | native_ref: Map.put(issue.native_ref, "execution_owner", record["execution_owner"])}
        run_admitted(owned, record, config, recipient, opts)

      error ->
        raise "Review execution fenced: #{inspect(error)}"
    end
  end

  defp run_admitted(issue, record, config, recipient, opts) do
    with {:ok, instructions, digest} <- WorkflowInstructions.load(config),
         true <- digest == record["policy_sha"] or {:error, :workflow_instructions_changed},
         {:ok, workspace} <- Workspace.create_for_review(issue) do
      if is_pid(recipient), do: send(recipient, {:worker_runtime_info, issue.id, %{worker_host: nil, workspace_path: workspace}})
      execute(issue, record, config, workspace, instructions, recipient, opts)
    else
      error -> raise "Review preparation failed: #{inspect(error)}"
    end
  rescue
    error ->
      checkpoint(issue, %{"phase" => "failed", "error" => Exception.message(error)})
      reraise error, __STACKTRACE__
  end

  defp execute(issue, record, config, workspace, instructions, recipient, opts) do
    update = fn message -> if is_pid(recipient), do: send(recipient, {:codex_worker_update, issue.id, message}) end
    workflow_opts = opts |> Keyword.put(:checkpoint, &checkpoint(issue, &1)) |> Keyword.put(:on_message, update)

    input =
      Map.take(record, ~w(project iid url work head base target_branch policy_sha round))
      |> Map.put("owner", issue.id)

    prompt = """
    #{instructions}

    Execution input: #{Jason.encode!(input)}
    Delivery authority: #{delivery(config)}
    Execute the supplied workflow with ordinary tools, then submit its result with
    workflow_submit. Symphony records the result and stops the session; it does not
    prepare source, validate review content, publish results or release your resources.
    The session directory is execution scratch space, not a source checkout.
    If this execution cannot acquire a clean worktree or verify the pinned
    checkout after the workflow's permitted recovery steps, end the round as a
    local execution failure. Follow the workflow's cleanup for resources you
    acquired, then submit directly through workflow_submit with result fields
    status: "failed", failure_kind: "worktree_acquire", and reason: a concise
    description of the local error. Do not post a comment or discussion in this
    case. Use needs_input only for evidence the project can provide.
    Apply this rule if the supplied workflow describes a checkout failure as an evidence gap.
    Configured result tool: #{Jason.encode!(config["result_command"])}
    Do not approve, merge, edit source, or resume other executions.
    """

    session = %{
      repository: workspace,
      prompt: prompt,
      issue: issue,
      secret_environment_names: ReviewLane.secret_environment_names(%{}),
      agent_environment: %{},
      model_settings: config["model_settings"] || %{}
    }

    case WorkflowSession.run(session, workflow_opts) do
      {:ok, artifact, runtime} ->
        :ok = checkpoint(issue, Map.drop(runtime, ~w(thread_allocation_intent turn_allocation_intent)))

        case Listener.submit(issue.id, issue.native_ref["execution_owner"], %{"completion" => artifact}) do
          :ok -> :ok
          error -> raise "Workflow result rejected: #{inspect(error)}"
        end

      {:error, reason, runtime} ->
        :ok = checkpoint(issue, Map.drop(runtime, ~w(thread_allocation_intent turn_allocation_intent)))

        if runtime["native_stop_confirmed"] == true and cancelled?(reason) do
          checkpoint(issue, %{"phase" => "fenced"})
        else
          raise "Workflow failed: #{inspect(reason)}"
        end
    end
  end

  defp delivery(%{"publish_results" => false}), do: "Keep results local. Do not publish comments or results."

  defp delivery(_config),
    do:
      "Publish one completed review comment to the selected target and read it back. Submit its exact body and native comment URL in the result. If review is incomplete, report the blocker through workflow_submit without publishing a review comment."

  defp cancelled?({:session_start_failed, {:error, :scheduler_stop}}), do: true
  defp cancelled?({:workflow_incomplete, {:error, :scheduler_stop}}), do: true
  defp cancelled?(_), do: false

  defp checkpoint(issue, changes), do: checkpoint(issue, changes, System.monotonic_time(:millisecond) + 5_000)

  defp checkpoint(issue, changes, deadline) do
    case Listener.checkpoint(issue.id, issue.native_ref["execution_owner"], changes) do
      {:error, :review_lane_initializing} -> exit(:review_lane_initializing)
      reply -> reply
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
end
