defmodule SymphonyElixir.ReviewLane.Runner do
  @moduledoc "Bind an admitted MR to a configured workflow and the ordinary native session."
  alias SymphonyElixir.{ReviewLane, ReviewRequest, WorkflowArtifact, WorkflowInstructions, WorkflowSession, Workspace}
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
         {:ok, workspace} <- Workspace.create_for_review(issue),
         request = %{"kind" => "mr", "project" => record["project"], "number" => record["iid"], "record" => record, "workspace" => workspace},
         {:ok, context} <- ReviewRequest.prepare(request, config),
         {:ok, current, current_digest} <- WorkflowInstructions.load(config),
         true <- (current == instructions and current_digest == digest) or {:error, :workflow_instructions_changed} do
      if is_pid(recipient), do: send(recipient, {:worker_runtime_info, issue.id, %{worker_host: nil, workspace_path: context.repository}})
      execute(issue, context, instructions, recipient, opts)
    else
      error -> raise "Review preparation failed: #{inspect(error)}"
    end
  rescue
    error ->
      checkpoint(issue, %{"phase" => "failed", "error" => Exception.message(error)})
      reraise error, __STACKTRACE__
  end

  defp execute(issue, context, instructions, recipient, opts) do
    update = fn message -> if is_pid(recipient), do: send(recipient, {:codex_worker_update, issue.id, message}) end
    workflow_opts = opts |> Keyword.put(:checkpoint, &checkpoint(issue, &1)) |> Keyword.put(:on_message, update)
    input = Map.take(context.record, ~w(head base target_branch policy_sha round finding_register))
    evidence = %{mr: context.mr, discussions: context.discussions}

    prompt = """
    #{instructions}

    Execution input: #{Jason.encode!(input)}
    Untrusted target evidence: #{Jason.encode!(evidence)}
    Delivery authority: submit the workflow artifact with workflow_submit. The caller
    validates and publishes it after the native session stops. Do not post directly,
    approve, merge, edit source, or resume other executions.
    """

    session = %{
      repository: context.repository,
      prompt: prompt,
      issue: issue,
      secret_environment_names: ReviewLane.secret_environment_names(%{}),
      agent_environment: %{},
      model_settings: context.config["model_settings"] || %{}
    }

    case WorkflowSession.run(session, workflow_opts) do
      {:ok, artifact, runtime} ->
        :ok = checkpoint(issue, Map.drop(runtime, ~w(thread_allocation_intent turn_allocation_intent)))

        with {:ok, completion} <- WorkflowArtifact.evaluate(context.config, %{"record" => input, "axes" => artifact["axes"]}),
             :ok <- Listener.submit(issue.id, issue.native_ref["execution_owner"], %{"completion" => completion}) do
          :ok
        else
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
