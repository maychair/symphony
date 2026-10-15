defmodule SymphonyElixir.Beads.Delivery do
  @moduledoc "Resumable host delivery through the existing guarded tools, with no merge authority."
  alias SymphonyElixir.Beads.{Adapter, RunJournal, Validation}

  @spec run(keyword()) :: {:ok, map()} | {:error, term()}
  def run(opts) do
    issue = opts[:issue]

    with {:ok, %{} = record} <- RunJournal.read(issue.native_ref["run_directory"]),
         true <- record["owner"] == issue.assignee_id || {:error, :delivery_owner_mismatch} do
      if completed?(record, opts), do: reuse(record), else: deliver(record, opts)
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_delivery_binding}
    end
  end

  defp reuse(record) do
    with {:ok, _} <- journal(record, %{"delivery_step" => "completed", "delivery_error" => nil}) do
      {:ok, Map.put(record["delivery"], "reused", true)}
    end
  end

  defp completed?(record, opts) do
    with step when step in ["completed", "handoff", "handoff_confirmed"] <- record["delivery_step"],
         "ready_for_review" <- record["handoff_intent"],
         %{"attempt_id" => attempt, "head_sha" => sha} <- record["delivery"],
         true <- attempt == record["attempt_id"],
         :ok <- Validation.gate(record),
         :ok <- Validation.delivery_head(record, sha),
         {:ok, [task]} <- Adapter.command(opts[:tracker_settings], ["show", record["issue_id"], "--json"]) do
      task["status"] == "blocked" and task["assignee"] == record["owner"]
    else
      _ -> false
    end
  end

  defp deliver(record, opts) do
    with {:ok, _} <- step(record, "checkpoint", "beads_checkpoint", %{}, opts),
         {:ok, receipt} <- validate(record, opts),
         true <- receipt["passed"] == true || {:error, :delivery_validation_failed},
         {:ok, delivery} <- step(record, "publish", "beads_publish", %{}, opts),
         arguments <- Map.merge(delivery, %{"intent" => "ready_for_review", "reason" => "Verified host delivery; configured review and acceptance gates remain in force."}),
         {:ok, _} <- step(record, "handoff", "beads_await_human", arguments, opts),
         {:ok, _} <- journal(record, %{"delivery_step" => "completed", "delivery_error" => nil}) do
      {:ok, Map.put(delivery, "validation_receipt", receipt)}
    end
  end

  defp validate(record, opts) do
    with {:ok, current} <- RunJournal.read(record["directory"]),
         :ok <- Validation.gate(current),
         %{"passed" => true} = receipt <- current["validation_receipt"] do
      {:ok, receipt}
    else
      _ -> step(record, "validate", "beads_validate", %{}, opts)
    end
  end

  defp step(record, name, tool, args, opts) do
    with {:ok, _} <- journal(record, %{"delivery_step" => name, "delivery_error" => nil}) do
      confirm(record, name, Adapter.execute_agent_tool(tool, args, opts))
    end
  end

  defp confirm(record, name, %{"success" => true, "output" => output}) do
    with {:ok, _} <- journal(record, %{"delivery_step" => name <> "_confirmed"}) do
      case Jason.decode(output) do
        {:ok, payload} -> {:ok, payload}
        _ -> {:ok, %{}}
      end
    end
  end

  defp confirm(record, name, result) do
    journal(record, %{"delivery_error" => %{"step" => name, "detail" => result["output"]}})
    {:error, {:delivery_step_failed, name, result["output"]}}
  end

  defp journal(record, changes) do
    with {:ok, current} <- RunJournal.read(record["directory"]), do: RunJournal.checkpoint(current, changes)
  end
end
