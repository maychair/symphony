defmodule SymphonyElixir.TaskClosure do
  @moduledoc """
  Reconcile a delivered plan member into native Issue closure under a durable fence.

  Closure is a native side effect, never a task conclusion: the member's versioned
  lifecycle must already be completed, delivered, unrestricted and stopped, the
  engine takes the released execution lock before writing, persists its intent
  before the request, and records the receipt only from a read-back state. An
  unconfirmed send is recovered by reading; it is never blindly reposted. This
  module closes no parent and reopens no member: the parent lifecycle and §14
  rework scope belong to their own decision path.
  """
  alias SymphonyElixir.{NativeWork, RunJournal, TaskWorkflow, WorkRef}

  @identity ~w(directory issue_id attempt_id execution_binding execution_generation)

  @doc """
  Close one delivered member at most once.

  `:not_applicable` means the member is not a delivered, stopped and unrestricted
  plan member. `{:ok, record}` carries the confirmed receipt, including the
  idempotent repeat. `{:error, reason}` names the unconfirmed step; nothing is
  deleted or reopened on any path.
  """
  @spec reconcile(map(), map(), keyword()) :: :not_applicable | {:ok, map()} | {:error, term()}
  def reconcile(record, flow, opts) when is_map(record) and is_map(flow) do
    if closeable?(record, flow) do
      conclusion = conclusion(flow)

      if confirmed?(record, conclusion["digest"]),
        do: {:ok, record},
        else: locked(record, conclusion, opts)
    else
      :not_applicable
    end
  end

  def reconcile(_, _, _), do: :not_applicable

  # A member keeps its native Issue open until its own versioned lifecycle proves
  # delivery and the executor lock is released. Native closure is not acceptance,
  # and a parent decision never reaches inside this scope.
  defp closeable?(record, flow) do
    flow["closeable"] == true and flow["phase"] == "completed" and flow["outcome"] == "delivered" and
      flow["execution"] in ["idle", "stopped"] and is_binary(record["directory"]) and valid_work?(record)
  end

  defp valid_work?(record) do
    work = get_in(record, ["execution_binding", "work"])

    WorkRef.validate(work) == :ok and work["kind"] == "issue" and record["issue_id"] == WorkRef.key(work)
  end

  defp locked(record, conclusion, opts) do
    lock = Path.join(record["directory"], "executor.lock")

    case File.mkdir(lock) do
      :ok ->
        try do
          File.write!(Path.join(lock, "reconcile-owner"), System.pid())
          owned(record, conclusion, opts)
        after
          File.rm(Path.join(lock, "reconcile-owner"))
          File.rmdir(lock)
        end

      {:error, :eexist} ->
        {:error, :member_closure_executor_locked}

      {:error, reason} ->
        {:error, {:member_closure_lock_failed, reason}}
    end
  end

  defp owned(record, conclusion, opts) do
    case RunJournal.read(record["directory"]) do
      {:ok, %{} = current} ->
        cond do
          Map.take(current, @identity) != Map.take(record, @identity) -> {:error, :member_closure_attempt_changed}
          confirmed?(current, conclusion["digest"]) -> {:ok, current}
          true -> close(current, conclusion, opts)
        end

      _ ->
        {:error, :member_closure_attempt_unavailable}
    end
  end

  # A send that already started is recovered by reading only: the intent is
  # durable, so a lost response cannot be repaired by writing the Issue twice.
  defp close(record, conclusion, opts) do
    work = record["execution_binding"]["work"]

    if record["closure_status"] == "sending",
      do: confirm(record, conclusion, work, opts),
      else: send_close(record, conclusion, work, opts)
  end

  defp send_close(record, conclusion, work, opts) do
    with {:ok, snapshot} <- NativeWork.read(work, opts),
         true <- snapshot.raw["state"] in ["open", "opened"] or {:error, :member_closure_issue_already_closed},
         {:ok, sending} <- RunJournal.checkpoint(record, %{"closure_intent" => conclusion, "closure_status" => "sending"}) do
      case NativeWork.close(snapshot, opts) do
        :sent -> confirm(sending, conclusion, work, opts)
        {:not_sent, reason} -> resendable(sending, reason)
        {:uncertain, reason} -> {:error, {:member_closure_send_unconfirmed, reason}}
      end
    end
  end

  defp resendable(record, reason) do
    with {:ok, _record} <- RunJournal.checkpoint(record, %{"closure_status" => "prepared"}) do
      {:error, {:member_closure_not_sent, reason}}
    end
  end

  defp confirm(record, conclusion, work, opts) do
    with {:ok, current} <- NativeWork.read(work, opts),
         true <- current.raw["state"] == "closed" or {:error, :member_closure_unconfirmed} do
      receipt = Map.put(conclusion, "source", "issue:" <> NativeWork.snapshot_ref(current))
      RunJournal.checkpoint(record, %{"closure_confirmed" => receipt, "closure_status" => "published"})
    end
  end

  defp confirmed?(record, digest), do: match?(%{"digest" => ^digest}, record["closure_confirmed"])

  defp conclusion(flow) do
    conclusion = %{
      "candidate" => flow["candidate"],
      "contract_sha" => flow["contract_sha"],
      "plan_revision" => flow["plan_revision"],
      "authority" => flow["authority"]
    }

    Map.put(conclusion, "digest", TaskWorkflow.digest(conclusion))
  end
end
