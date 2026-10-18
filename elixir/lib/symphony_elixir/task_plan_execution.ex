defmodule SymphonyElixir.TaskPlanExecution do
  @moduledoc "Translate configured native plans into jobs for the existing scheduler; execution remains owned by the member worker."
  alias SymphonyElixir.{AgentRunner, Config, ExecutionBackend, RunJournal, TaskExecution, TaskExecutionConfig, WorkRef}
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
        {:ok, members}
      end

    case result do
      {:ok, members} -> members
      {:error, reason} -> [blocked_parent(parent, state, reason)]
    end
  end

  defp project_member(parent, member, configured, state) do
    result = TaskExecution.observe(parent, member.work, configured.executions, configured.opts)
    directory = configured.executions[WorkRef.key(member.work)].directory

    recovery =
      case RunJournal.read(directory) do
        {:ok, record} -> RunJournal.interrupted_member?(record)
        _ -> false
      end

    flow =
      case result do
        {:ok, observation} -> observation.flow
        {:error, reason} -> %{"dispatchable" => false, "error" => inspect(reason)}
      end

    %Issue{
      id: "member:" <> WorkRef.key(member.work),
      identifier: "member-" <> WorkRef.key(member.work),
      title: member.raw["title"] || member.contract["goal"],
      description: member.description,
      url: member.url,
      state: state,
      dispatchable: recovery or (flow["dispatchable"] == true and not File.exists?(Path.join(directory, "executor.lock"))),
      native_ref: %{"execution_kind" => "plan_member", "work" => member.work, "parent" => parent, "native_state" => member.raw["state"], "lifecycle" => flow, "recovery_required" => recovery}
    }
  rescue
    error -> blocked_member(parent, member, state, Exception.message(error))
  catch
    kind, reason -> blocked_member(parent, member, state, inspect({kind, reason}))
  end

  defp blocked_member(parent, member, state, reason) do
    %Issue{
      id: "member:" <> WorkRef.key(member.work),
      identifier: "member-" <> WorkRef.key(member.work),
      title: member.contract["goal"],
      url: member.url,
      description: member.description,
      state: state,
      native_ref: %{"execution_kind" => "plan_member", "work" => member.work, "parent" => parent, "lifecycle" => %{"dispatchable" => false, "error" => reason}}
    }
  end

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
