defmodule SymphonyElixir.TaskPlanExecution do
  @moduledoc "Translate configured native plans into jobs for the existing scheduler; execution remains owned by the member worker."
  require Logger
  alias SymphonyElixir.{AgentRunner, Config, ExecutionBackend, RunJournal}
  alias SymphonyElixir.{TaskClosure, TaskExecution, TaskExecutionConfig, WorkRef}
  alias SymphonyElixir.TaskPlanAssessment, as: Assessment
  alias SymphonyElixir.TaskPlanManifest
  alias SymphonyElixir.Tracker.Issue

  @spec job?(term()) :: boolean()
  def job?(%Issue{id: id, native_ref: %{"execution_kind" => "plan_member", "work" => work, "parent" => parent}}) do
    WorkRef.validate(work) == :ok and WorkRef.validate(parent) == :ok and
      work["kind"] == "issue" and parent["kind"] == "issue" and id == "member:" <> WorkRef.key(work)
  end

  def job?(_), do: false

  @doc "Discover all configured roots directly from their repositories, including members outside the legacy tracker scope."
  @spec discover(keyword()) :: {:ok, [Issue.t()]} | {:error, term()}
  def discover(opts \\ []) do
    roots = roots(opts)

    if is_list(roots) and Enum.all?(roots, &(WorkRef.validate(&1) == :ok and &1["kind"] == "issue")) do
      {:ok, roots |> Enum.uniq() |> Enum.flat_map(&discover_plan(&1, opts))}
    else
      {:error, :invalid_plan_roots}
    end
  end

  defp roots(opts), do: Keyword.get_lazy(opts, :roots, fn -> Config.settings!().tracker.provider["plan_roots"] || [] end)

  defp discover_plan(parent, opts) do
    state = Keyword.get_lazy(opts, :active_state, fn -> List.first(Config.settings!().tracker.active_states) end)

    result =
      with true <- ExecutionBackend.kind() == "codex" or {:error, :unsupported_task_session_transport},
           true <- (is_binary(state) and state != "") or {:error, :plan_active_state_required},
           {:ok, configured} <- TaskExecutionConfig.prepare(parent, opts) do
        members = Enum.map(configured.plan.members, fn {_key, member} -> project_member(parent, member, configured, state) end)
        blocked = Enum.map(configured.plan.restricted, fn {_key, entry} -> blocked_member(parent, entry, state) end)

        lifecycle =
          case TaskPlanManifest.advance(configured, configured.opts) do
            {:ok, parent_state} ->
              [parent_lifecycle(parent, configured.plan.parent, state, parent_state)]

            {:error, reason} ->
              Logger.warning("parent lifecycle blocked reason=#{inspect(reason)}")
              [blocked_parent(parent, state, reason)]
          end

        {:ok, members ++ blocked ++ lifecycle}
      end

    case result do
      {:ok, members} -> members
      {:error, :parent_not_open} -> recovered_parent(parent, state, opts)
      {:error, reason} -> [blocked_parent(parent, state, reason)]
    end
  end

  defp recovered_parent(parent, state, opts) do
    case TaskPlanManifest.recover_closed(parent, opts) do
      {:ok, %{"status" => "confirmed"}} -> []
      {:ok, %{"status" => "inconsistent"}} -> [blocked_parent(parent, state, :parent_close_inconsistent)]
      {:error, reason} -> [blocked_parent(parent, state, reason)]
    end
  end

  defp project_member(parent, member, configured, state) do
    directory = configured.executions[WorkRef.key(member.work)].directory

    recovery =
      case RunJournal.read(directory) do
        {:ok, record} -> RunJournal.interrupted_member?(record)
        _ -> false
      end

    {flow, closure} = outcome(parent, member, configured)

    %Issue{
      id: "member:" <> WorkRef.key(member.work),
      identifier: "member-" <> WorkRef.key(member.work),
      title: member.raw["title"] || member.contract["goal"],
      description: member.description,
      url: member.url,
      state: state,
      dispatchable: recovery or (flow["dispatchable"] == true and not File.exists?(Path.join(directory, "executor.lock"))),
      native_ref: %{
        "execution_kind" => "plan_member",
        "work" => member.work,
        "parent" => parent,
        "native_state" => closure["native_state"],
        "lifecycle" => flow,
        "closure" => closure_name(closure),
        "closure_projection" => closure,
        "recovery_required" => recovery
      }
    }
  rescue
    error -> blocked_member(parent, %{work: member.work, reason: {:member_projection_failed, Exception.message(error)}}, state)
  catch
    kind, reason -> blocked_member(parent, %{work: member.work, reason: {:member_projection_failed, inspect({kind, reason})}}, state)
  end

  # Native closure is reconciled from the same observation the projection uses;
  # the fence re-derives that observation instead of trusting a cached flow, and
  # the current native state is reported separately from any historical receipt.
  defp outcome(parent, member, configured) do
    case Assessment.assess(parent, member, configured) do
      {:ok, assessment} -> reconcile(assessment, parent, member, configured)
      {:error, reason} -> {%{"dispatchable" => false, "error" => inspect(reason)}, unconfirmed(reason, state_of(member))}
    end
  end

  defp reconcile(assessment, parent, member, configured) do
    opts = Keyword.put(configured.opts, :reobserve, fn -> Assessment.assess(parent, member, configured) end)

    case TaskClosure.reconcile(assessment.record, assessment.flow, opts) do
      {:ok, %{closure: closure}} -> {assessment.flow, closure}
      :not_applicable -> {assessment.flow, not_applicable(state_of(member))}
      {:error, reason} -> {assessment.flow, unconfirmed(reason, state_of(member))}
    end
  end

  defp closure_name(%{"status" => "unconfirmed"} = closure) do
    "unconfirmed:" <> String.trim_leading(closure["reason"], ":")
  end

  defp closure_name(%{"status" => status}), do: status

  defp unconfirmed(reason, state), do: %{"status" => "unconfirmed", "native_state" => state, "reason" => reason_label(reason), "receipt" => nil, "source" => nil}
  defp not_applicable(state), do: %{"status" => "not_applicable", "native_state" => state, "reason" => nil, "receipt" => nil, "source" => nil}

  defp reason_label(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_label({reason, detail}) when is_atom(reason), do: Atom.to_string(reason) <> ":" <> detail_label(detail)
  defp reason_label(reason), do: inspect(reason)
  defp detail_label(detail) when is_atom(detail), do: Atom.to_string(detail)
  defp detail_label(detail), do: inspect(detail)

  defp state_of(%{raw: %{"state" => "closed"}}), do: "closed"
  defp state_of(%{raw: %{"state" => state}}) when state in ["open", "opened"], do: "open"
  defp state_of(_), do: "unknown"

  @doc """
  Read-only member projection for the Taskboard.

  No member is admitted and no native Issue is closed; every card is driven by
  the same current observation the closure reconciler consumes, keyed by the
  validated member `WorkRef` instead of a native number.
  """
  @spec projection(keyword()) :: {:ok, %{optional(String.t()) => map()}} | {:error, term()}
  def projection(opts \\ []) do
    roots = roots(opts)

    if valid_roots?(roots) do
      {:ok, roots |> Enum.uniq() |> Enum.reduce(%{}, &Map.merge(&2, plan_projection(&1, opts)))}
    else
      {:error, :invalid_plan_roots}
    end
  end

  defp plan_projection(parent, opts) do
    state = active_state(opts)

    with true <- ExecutionBackend.kind() == "codex" or {:error, :unsupported_task_session_transport},
         true <- (is_binary(state) and state != "") or {:error, :plan_active_state_required},
         {:ok, configured} <- TaskExecutionConfig.prepare(parent, opts) do
      projection_of(configured)
    else
      {:error, _reason} -> %{}
    end
  end

  @doc "Read the configured members' current lifecycle without native side effects."
  @spec projection_of(map()) :: map()
  def projection_of(configured) do
    parent = configured.plan.plan["parent"]
    current = Map.new(configured.plan.members, fn {key, member} -> {key, read_only_member(parent, member, configured)} end)

    restricted =
      Map.new(configured.plan.restricted, fn {key, entry} ->
        {key, %{work: entry.work, closeable: false, restricted: reason_label(entry.reason)}}
      end)

    Map.merge(current, restricted)
  end

  defp read_only_member(parent, member, configured) do
    directory = configured.executions[WorkRef.key(member.work)].directory
    record = recorded(directory)
    assessment = Assessment.assess(parent, member, configured)
    {flow, snapshot, evidence} = assessment_view(assessment)
    closure = TaskClosure.project(record, flow, snapshot, configured.opts)

    %{
      work: member.work,
      directory: directory,
      closeable: flow["closeable"] == true and closure["status"] == "confirmed",
      flow: flow,
      closure: closure,
      evidence: evidence
    }
  end

  defp recorded(directory) do
    case RunJournal.read(directory) do
      {:ok, %{} = record} -> record
      _ -> nil
    end
  end

  defp assessment_view({:ok, assessment}), do: {assessment.flow, assessment.snapshot, assessment.evidence}
  defp assessment_view({:error, reason}), do: {%{"dispatchable" => false, "error" => inspect(reason)}, nil, nil}

  defp active_state(opts), do: Keyword.get_lazy(opts, :active_state, fn -> List.first(Config.settings!().tracker.active_states) end)

  defp valid_roots?(roots) do
    is_list(roots) and Enum.all?(roots, &(WorkRef.validate(&1) == :ok and &1["kind"] == "issue"))
  end

  # A member whose own contract, scope or repository no longer resolves keeps a
  # readable blocked card instead of failing the whole plan projection.
  defp blocked_member(parent, entry, state) do
    reason = reason_label(entry.reason)

    %Issue{
      id: "member:" <> WorkRef.key(entry.work),
      identifier: "member-" <> WorkRef.key(entry.work),
      title: "Member requires a new authorization",
      state: state,
      native_ref: %{
        "execution_kind" => "plan_member",
        "work" => entry.work,
        "parent" => parent,
        "restricted" => true,
        "reason" => reason,
        "lifecycle" => blocked_lifecycle(entry.reason, reason)
      }
    }
  end

  # A member whose own approved contract drifted keeps a scoped restriction; a
  # member whose native facts could not be read at all reports the read failure.
  defp blocked_lifecycle({:member_projection_failed, _detail}, reason), do: %{"dispatchable" => false, "error" => reason}
  defp blocked_lifecycle(_reason, reason), do: %{"dispatchable" => false, "restricted" => reason}

  defp blocked_parent(parent, state, reason) do
    %Issue{
      id: "plan:" <> WorkRef.key(parent),
      identifier: "plan-" <> WorkRef.key(parent),
      title: "Plan requires reconciliation",
      kind: :plan,
      state: state,
      native_ref: %{"work" => parent, "plan_preflight" => %{"status" => "blocked", "reason" => inspect(reason)}}
    }
  end

  defp parent_lifecycle(parent, snapshot, state, lifecycle) do
    %Issue{
      id: "plan:" <> WorkRef.key(parent),
      identifier: "plan-" <> WorkRef.key(parent),
      title: "Plan " <> lifecycle["status"],
      description: snapshot.description,
      url: snapshot.url,
      kind: :plan,
      state: state,
      dispatchable: false,
      native_ref: %{"work" => parent, "plan_lifecycle" => lifecycle}
    }
  end

  @doc "Run a currently routed member and report its result using this scheduler launch's capability."
  @spec run(Issue.t(), pid() | nil, keyword()) :: :ok
  def run(issue, recipient, opts) do
    result =
      with true <- (job?(issue) and issue.native_ref["parent"] in roots(opts)) or {:error, :plan_member_not_routed} do
        options = Keyword.put(opts, :dispatch_id, issue.id)
        AgentRunner.run_configured_member(issue.native_ref["parent"], issue.native_ref["work"], recipient, options)
      end

    if is_pid(recipient), do: send(recipient, {:member_worker_result, issue.id, self(), opts[:dispatch_token], result})
    :ok
  end

  @doc "Require the durable result and native stop to still belong to the finished attempt before scheduling continuation."
  @spec completed_result(Issue.t(), term()) :: {:ok, map()} | {:error, term()}
  def completed_result(issue, {:ok, %{record: record, outcome: outcome}}) when is_map(record) do
    with true <- job?(issue) and record["issue_id"] == WorkRef.key(issue.native_ref["work"]),
         true <- record["execution_binding"]["work"] == issue.native_ref["work"],
         true <- record["execution_binding"]["authority"]["work"] == issue.native_ref["parent"],
         {:ok, %{"outcome" => ^outcome}} <- TaskExecution.completed_result(record) do
      {:ok, %{outcome: outcome, retry_count: record["retry_count"] || 0}}
    else
      _ -> {:error, :member_result_unconfirmed}
    end
  end

  def completed_result(_issue, {:waiting, _}), do: {:ok, %{outcome: "waiting", retry_count: 0}}
  def completed_result(_issue, result), do: {:error, {:member_worker_failed, result}}
end
