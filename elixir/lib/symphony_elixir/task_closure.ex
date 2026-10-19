defmodule SymphonyElixir.TaskClosure do
  @moduledoc """
  Reconcile a delivered plan member into native Issue closure under a durable fence.

  Closure is a native side effect, never a task conclusion. The assessment that
  produced the business conclusion is re-derived from the same native sources
  while the fence is held, the native write is bound to that observation, and
  the receipt records only what one version proved. A receipt is history: it
  never replaces the current native state, so a manual reopen is reported as it
  is instead of being masked by an older conclusion. An abandoned fence is taken
  over only when its owner can be shown to be gone, or when the durable intent
  allows a read-back that writes nothing to the Issue. This module closes no
  parent and reopens no member: the parent lifecycle and §14 rework scope belong
  to their own decision path.
  """

  alias SymphonyElixir.{NativeWork, RunJournal, TaskWorkflow, WorkRef}

  @identity ~w(directory issue_id attempt_id execution_binding execution_generation)
  @executor_owner "executor-owner.json"
  @owner_file "reconcile-owner.json"
  @legacy_owner "reconcile-owner"
  @default_stale_ms 300_000

  @type closure :: %{required(String.t()) => term()}

  @doc """
  Close one delivered member at most once.

  `:not_applicable` means the member is not a delivered, stopped and
  unrestricted plan member. `{:ok, %{record: record, closure: closure}}`
  carries the versioned closure projection plus the current native state, and
  `{:error, reason}` names the unconfirmed step. Nothing is deleted or reopened
  on any path.
  """
  @spec reconcile(map(), map(), keyword()) :: :not_applicable | {:ok, map()} | {:error, term()}
  def reconcile(record, flow, opts) when is_map(record) and is_map(flow) do
    if closeable?(record, flow) do
      conclusion = conclusion(flow)

      case receipt(record, conclusion) do
        nil -> locked(record, conclusion, opts)
        receipt -> current(record, conclusion, receipt, opts)
      end
    else
      :not_applicable
    end
  end

  def reconcile(_, _, _), do: :not_applicable

  @doc """
  Run `fun` while holding the member's durable execution fence.

  The same fence that guards native closure guards any other member-level side
  effect, so a second reconciler can never write into an attempt another owner
  is already using. An unavailable or unprovable owner returns `{:error, reason}`
  instead of deleting the lock.
  """
  @spec with_fence(map(), keyword(), (-> result)) :: result | {:error, term()} when result: var
  def with_fence(record, opts, fun) when is_map(record) and is_function(fun, 0) do
    case acquire(record, opts) do
      {:ok, release} ->
        try do
          fun.()
        after
          release.()
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A member keeps its native Issue open until its own versioned lifecycle proves
  # delivery and the executor lock is released. Native closure is not acceptance,
  # and a parent decision never reaches inside this scope.
  defp closeable?(record, flow) do
    closeable_flow?(flow) and is_binary(record["directory"]) and valid_work?(record)
  end

  defp closeable_flow?(flow) do
    flow["closeable"] == true and flow["phase"] == "completed" and flow["outcome"] == "delivered" and
      flow["execution"] in ["idle", "stopped"] and flow["restrictions"] == %{}
  end

  defp valid_work?(record) do
    work = get_in(record, ["execution_binding", "work"])

    WorkRef.validate(work) == :ok and work["kind"] == "issue" and record["issue_id"] == WorkRef.key(work)
  end

  # The historical receipt stays valid history; the current native fact is read
  # again, so a manual reopen is reported instead of being replaced by an older
  # confirmation. A read that cannot prove the state stays unknown, which never
  # unlocks dependants or cleanup.
  defp current(record, _conclusion, receipt, opts) do
    result(record, read_current(record, receipt, opts))
  end

  defp read_current(record, receipt, opts) do
    work = record["execution_binding"]["work"]

    case NativeWork.read(work, opts) do
      {:ok, snapshot} -> observed(receipt, snapshot)
      {:error, reason} -> %{"status" => "unconfirmed", "native_state" => "unknown", "receipt" => receipt, "reason" => inspect(reason)}
    end
  end

  defp observed(receipt, snapshot) do
    if snapshot.raw["state"] == "closed" do
      %{"status" => "confirmed", "native_state" => "closed", "receipt" => receipt, "source" => snapshot_source(snapshot)}
    else
      %{"status" => "reopened", "native_state" => "open", "receipt" => receipt, "reason" => "member_closure_reopened", "source" => snapshot_source(snapshot)}
    end
  end

  @doc """
  Read-only closure view for a projection consumer such as the Taskboard.

  Nothing is written and no Issue is closed. A versioned receipt is shown as
  history next to the current native state, a member without a confirmed
  receipt stays unconfirmed, and an unreadable fact stays unknown.
  """
  @spec project(map() | nil, map(), map() | nil, keyword()) :: closure()
  def project(record, flow, snapshot, opts) do
    cond do
      not is_map(flow) -> status("not_applicable", native_state(snapshot))
      not is_map(record) -> status("unconfirmed", native_state(snapshot), "member_closure_journal_missing")
      not closeable?(record, flow) -> status("not_applicable", native_state(snapshot))
      not is_map(receipt(record, conclusion(flow))) -> status("unconfirmed", native_state(snapshot), "member_closure_pending")
      true -> read_current(record, receipt(record, conclusion(flow)), opts)
    end
  end

  defp status(state, native, reason \\ nil) do
    %{"status" => state, "native_state" => native, "reason" => reason, "receipt" => nil, "source" => nil}
  end

  defp native_state(%{raw: %{"state" => "closed"}}), do: "closed"
  defp native_state(%{raw: %{"state" => state}}) when state in ["open", "opened"], do: "open"
  defp native_state(_), do: "unknown"

  defp locked(record, conclusion, opts) do
    case acquire(record, opts) do
      {:ok, release} ->
        try do
          owned(record, conclusion, opts)
        after
          release.()
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp owned(record, conclusion, opts) do
    case RunJournal.read(record["directory"]) do
      {:ok, %{} = current} -> owned_current(record, current, conclusion, opts)
      _ -> {:error, :member_closure_attempt_unavailable}
    end
  end

  defp owned_current(record, current, conclusion, opts) do
    known = receipt(current, conclusion)

    cond do
      Map.take(current, @identity) != Map.take(record, @identity) ->
        {:error, :member_closure_attempt_changed}

      is_map(known) ->
        current(current, conclusion, known, opts)

      true ->
        recheck(current, conclusion, opts)
    end
  end

  # The business conclusion is confirmed again inside the fence from the same
  # native sources. A conclusion that moved while the fence was being taken is
  # never written under the older intent.
  defp recheck(record, conclusion, opts) do
    with {:ok, assessment} <- reobserve(opts),
         :ok <- same_conclusion(assessment.flow, conclusion) do
      rooted = adopt(record, assessment.record)

      if rooted["closure_status"] == "sending",
        do: recover(rooted, conclusion, opts),
        else: send_close(rooted, conclusion, assessment.snapshot, opts)
    end
  end

  defp same_conclusion(flow, conclusion) do
    if closeable_flow?(flow) and conclusion(flow)["digest"] == conclusion["digest"],
      do: :ok,
      else: {:error, :member_closure_conclusion_changed}
  end

  defp adopt(record, %{} = current) do
    if Map.take(current, @identity) == Map.take(record, @identity), do: current, else: record
  end

  # A send that already started is recovered by reading only, and only against
  # the intent that was durable when it started. A newer conclusion never
  # supplies the receipt for an older operation.
  defp recover(record, conclusion, opts) do
    intent = record["closure_intent"]

    cond do
      not is_map(intent) ->
        inconsistent(record, :member_closure_intent_missing, opts)

      intent["digest"] != conclusion["digest"] ->
        inconsistent(record, :member_closure_intent_superseded, opts)

      true ->
        confirm(record, intent, opts)
    end
  end

  defp send_close(record, conclusion, snapshot, opts) do
    with true <- snapshot.raw["state"] in ["open", "opened"] or {:error, :member_closure_issue_already_closed},
         {:ok, sending} <- RunJournal.checkpoint(record, %{"closure_intent" => conclusion, "closure_status" => "sending"}) do
      case NativeWork.close(snapshot, opts) do
        :sent -> confirm(sending, conclusion, opts)
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

  # Read-back plus a business recheck: the native closed fact is kept on every
  # path, and a conclusion that moved during the write is reported as an
  # inconsistency instead of a receipt.
  defp confirm(record, intent, opts) do
    work = record["execution_binding"]["work"]

    with {:ok, current} <- NativeWork.read(work, opts),
         true <- current.raw["state"] == "closed" or {:error, :member_closure_unconfirmed},
         {:ok, assessment} <- reobserve(opts),
         :ok <- same_conclusion(assessment.flow, intent) do
      publish(record, intent, current)
    else
      {:error, :member_closure_conclusion_changed} -> inconsistent(record, :member_closure_conclusion_changed, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  defp publish(record, intent, current) do
    source = snapshot_source(current)
    receipt = Map.merge(intent, %{"source" => source, "observed_at" => now()})
    fact = %{"state" => "closed", "source" => source, "observed_at" => now()}

    case RunJournal.checkpoint(record, %{"closure_confirmed" => receipt, "closure_status" => "published", "closure_current" => fact}) do
      {:ok, updated} ->
        result(updated, %{"status" => "confirmed", "native_state" => "closed", "receipt" => receipt, "source" => source})

      {:error, reason} ->
        {:error, {:member_closure_receipt_unavailable, reason}}
    end
  end

  # Keep the native fact even when the conclusion is no longer trustworthy:
  # dependants and cleanup stay blocked, and nothing is fabricated.
  defp inconsistent(record, reason, opts) do
    work = record["execution_binding"]["work"]

    with {:ok, _record} <- RunJournal.checkpoint(record, %{"closure_current" => native_fact(work, opts), "closure_status" => "inconsistent"}) do
      {:error, reason}
    end
  end

  defp native_fact(work, opts) do
    case NativeWork.read(work, opts) do
      {:ok, snapshot} -> %{"state" => snapshot.raw["state"], "source" => snapshot_source(snapshot), "observed_at" => now()}
      {:error, reason} -> %{"state" => "unknown", "reason" => inspect(reason), "observed_at" => now()}
    end
  end

  defp reobserve(opts) do
    case Keyword.get(opts, :reobserve) do
      fun when is_function(fun, 0) -> read_assessment(fun.())
      _ -> {:error, :member_closure_assessment_unavailable}
    end
  end

  defp read_assessment({:ok, %{flow: flow, record: record, snapshot: snapshot}})
       when is_map(flow) and is_map(record) and is_map(snapshot),
       do: {:ok, %{flow: flow, record: record, snapshot: snapshot}}

  defp read_assessment({:error, reason}), do: {:error, {:member_closure_assessment_unavailable, reason}}
  defp read_assessment(_), do: {:error, :member_closure_assessment_unavailable}

  defp receipt(record, conclusion), do: if(confirmed?(record, conclusion["digest"]), do: record["closure_confirmed"])
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

  defp result(record, closure) do
    base = %{"status" => "unconfirmed", "native_state" => "unknown", "receipt" => nil, "reason" => nil, "source" => nil, "observed_at" => now()}
    {:ok, %{record: record, closure: Map.merge(base, closure)}}
  end

  defp snapshot_source(snapshot), do: "issue:" <> NativeWork.snapshot_ref(snapshot)
  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()

  # --- fencing -----------------------------------------------------------------

  defp lock_dir(record), do: Path.join(record["directory"], "executor.lock")

  defp acquire(record, opts) do
    lock = lock_dir(record)

    case File.mkdir(lock) do
      :ok -> claim(record, lock)
      {:error, :eexist} -> takeover(lock, record, opts)
      {:error, reason} -> {:error, {:member_closure_lock_failed, reason}}
    end
  end

  defp claim(record, lock) do
    owner = owner_record(record)
    temporary = Path.join(lock, @owner_file <> ".claim")

    case write_owner(lock, owner, temporary) do
      :ok ->
        {:ok, fn -> release(lock, owner) end}

      {:error, reason} ->
        abandon_claim(lock, temporary)
        {:error, reason}
    end
  end

  defp abandon_claim(lock, temporary) do
    File.rm(temporary)
    File.rm(Path.join(lock, @owner_file))
    File.rm(Path.join(lock, @legacy_owner))
    File.rmdir(lock)
  end

  defp write_owner(lock, owner, temporary) do
    with :ok <- File.write(temporary, Jason.encode!(owner)),
         :ok <- File.write(Path.join(lock, @legacy_owner), System.pid()),
         :ok <- File.rename(temporary, Path.join(lock, @owner_file)),
         {:ok, body} <- File.read(Path.join(lock, @owner_file)),
         {:ok, ^owner} <- Jason.decode(body) do
      :ok
    else
      _ -> {:error, :member_closure_lock_not_owned}
    end
  end

  defp release(lock, owner) do
    with {:ok, body} <- File.read(Path.join(lock, @owner_file)),
         {:ok, ^owner} <- Jason.decode(body) do
      File.rm(Path.join(lock, @owner_file))
      File.rm(Path.join(lock, @legacy_owner))
      File.rmdir(lock)
    else
      _ -> :ok
    end

    :ok
  end

  # An abandoned fence is taken over only with proof: a reconciler that is
  # provably gone on this node, or a stale fence whose durable intent allows a
  # read-back that writes nothing. An unknown owner is never deleted.
  defp takeover(lock, record, opts) do
    stale_ms = Keyword.get(opts, :closure_lock_stale_ms, @default_stale_ms)

    with {:ok, owner} <- abandoned(lock, record, stale_ms),
         :ok <- still_owned_by(lock, owner) do
      claim(record, lock)
    end
  end

  defp abandoned(lock, record, stale_ms) do
    owner = read_owner(lock)

    cond do
      File.exists?(Path.join(lock, @executor_owner)) -> {:error, :member_closure_executor_locked}
      live?(owner) -> {:error, :member_closure_executor_locked}
      gone?(owner) -> {:ok, owner}
      takeoverable?(owner, record, lock, stale_ms) -> {:ok, owner}
      true -> {:error, :member_closure_owner_unconfirmed}
    end
  end

  # A stale fence is only taken over when the durable state rules out a lost
  # write: either an intent that a read-back can settle, or no ownership record
  # at all, which means the previous reconciler never reached its intent.
  defp takeoverable?(nil, _record, lock, stale_ms), do: stale?(lock, stale_ms)
  defp takeoverable?(_owner, record, lock, stale_ms), do: record["closure_status"] == "sending" and stale?(lock, stale_ms)

  defp still_owned_by(lock, owner) do
    if read_owner(lock) == owner, do: :ok, else: {:error, :member_closure_lock_not_owned}
  end

  defp read_owner(lock) do
    case File.read(Path.join(lock, @owner_file)) do
      {:ok, body} -> decode_owner(body)
      _ -> nil
    end
  end

  defp decode_owner(body) do
    case Jason.decode(body) do
      {:ok, owner} when is_map(owner) -> owner
      _ -> nil
    end
  end

  defp live?(%{"os_pid" => pid, "node" => owner_node, "vm_started_at" => started_at, "erlang_pid" => erlang_pid})
       when is_binary(pid) and is_binary(owner_node) and is_integer(started_at) and is_binary(erlang_pid) do
    pid == System.pid() and owner_node == to_string(node()) and started_at == :erlang.system_info(:start_time) and
      local_process_status(erlang_pid) == :alive
  end

  # Old ownership records have no process identity. Preserve their existing
  # conservative same-VM behavior rather than guessing that an owner died.
  defp live?(%{"os_pid" => pid}) when is_binary(pid), do: pid == System.pid()
  defp live?(_), do: false

  defp local_process_status(pid) do
    if pid |> String.to_charlist() |> :erlang.list_to_pid() |> Process.alive?(), do: :alive, else: :dead
  rescue
    ArgumentError -> :unknown
  end

  defp gone?(%{"os_pid" => pid, "node" => owner_node, "vm_started_at" => started_at, "erlang_pid" => erlang_pid})
       when is_binary(pid) and is_binary(owner_node) and is_integer(started_at) and is_binary(erlang_pid) do
    owner_node == to_string(node()) and
      (not os_pid_alive?(pid) or
         (pid == System.pid() and
            (started_at != :erlang.system_info(:start_time) or local_process_status(erlang_pid) == :dead)))
  end

  defp gone?(%{"node" => node, "os_pid" => pid}) when is_binary(node) and is_binary(pid) do
    node == to_string(node()) and not os_pid_alive?(pid)
  end

  defp gone?(_), do: false

  defp os_pid_alive?(pid) do
    not File.dir?("/proc") or File.dir?("/proc/" <> pid)
  end

  defp stale?(lock, stale_ms) when is_integer(stale_ms) and stale_ms >= 0 do
    files = Enum.map([@owner_file, @legacy_owner, @executor_owner], &Path.join(lock, &1))
    Enum.any?([lock | files], &older_than?(&1, stale_ms))
  end

  defp stale?(_lock, _stale_ms), do: false

  defp older_than?(path, stale_ms) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} -> System.system_time(:second) - mtime >= div(stale_ms, 1000)
      _ -> false
    end
  end

  defp owner_record(record) do
    %{
      "kind" => "closure-reconciler",
      "os_pid" => System.pid(),
      "node" => to_string(node()),
      "vm_started_at" => :erlang.system_info(:start_time),
      "erlang_pid" => self() |> :erlang.pid_to_list() |> to_string(),
      "attempt_id" => record["attempt_id"],
      "issue_id" => record["issue_id"],
      "started_at" => now()
    }
  end
end
