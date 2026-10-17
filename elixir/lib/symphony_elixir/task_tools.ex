defmodule SymphonyElixir.TaskTools do
  @moduledoc "Role-bound native tools for an admitted plan-member execution."
  alias SymphonyElixir.{CommandCheck, Config, ExecutionBinding, GitArtifact, NativeWork, RunJournal}
  alias SymphonyElixir.{TaskControl, TaskEvidence, TaskLifecycle, TaskPlanPreflight}
  alias SymphonyElixir.{TaskPublication, TaskWorkflow, WorkRef}

  @identity ~w(directory attempt_id execution_generation execution_binding)
  @command_fields ~w(candidate command exit_code output_sha reason snapshot_valid)

  @spec bind(map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def bind(record, policy, opts) do
    with {:ok, binding} <- ExecutionBinding.normalize(record["execution_binding"]),
         {:ok, ^record} <- ExecutionBinding.bind(record, binding),
         true <- is_map(policy) and TaskWorkflow.digest(policy) == binding["policy_sha"] do
      repositories = Keyword.get_lazy(opts, :repositories, fn -> Config.settings!().tracker.provider["plan_repositories"] || [] end)
      opts = opts |> Keyword.put(:repositories, repositories) |> Keyword.put(:policy, policy)
      identity = Map.take(record, @identity)
      context = %{owner: self(), identity: identity, policy: policy, opts: opts, issue_id: record["issue_id"]}
      tracker = SymphonyElixir.Tracker.bind_agent_tools(opts[:tracker_settings])
      plan_secrets = NativeWork.secret_environment_names(%{provider: %{"plan_repositories" => repositories}})
      secrets = Enum.uniq(tracker.secret_environment_names ++ plan_secrets)
      tools = specs(binding["role"])
      {:ok, %{task_execution: context, tool_specs: tools, agent_environment: %{}, secret_environment_names: secrets}}
    else
      _ -> {:error, :invalid_task_tool_binding}
    end
  end

  @spec execute(String.t() | nil, term(), map(), keyword()) :: map()
  def execute(tool, arguments, %{task_execution: context}, opts) do
    result =
      with true <- (context.owner == self() and issue_matches?(context, opts)) or {:error, :task_tool_owner_mismatch},
           {:ok, arguments} <- arguments(arguments),
           true <- allowed?(tool, arguments, context.identity["execution_binding"]["role"]) or {:error, :invalid_task_tool_call},
           {:ok, record} <- current(context),
           {:ok, record} <- TaskPublication.recover(record, context.opts),
           {:ok, scope} <- scope(record, context) do
        invoke(tool, arguments, scope, context)
      end

    response(result)
  end

  defp issue_matches?(context, opts), do: is_nil(opts[:issue]) or opts[:issue].id == context.issue_id
  defp arguments(value) when is_map(value), do: {:ok, value}

  defp arguments(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, value} when is_map(value) -> {:ok, value}
      _ -> {:error, :invalid_task_tool_arguments}
    end
  end

  defp arguments(_), do: {:error, :invalid_task_tool_arguments}

  defp allowed?("task_context", args, _), do: args == %{}
  defp allowed?("task_candidate", args, "developer"), do: keys?(args, ~w(artifacts summary)) and is_list(args["artifacts"]) and text?(args["summary"])
  defp allowed?("task_check", args, "verifier"), do: keys?(args, ~w(check_id)) and text?(args["check_id"])
  defp allowed?("task_verification", args, "verifier"), do: keys?(args, ~w(review_checks findings summary)) and is_list(args["review_checks"]) and is_list(args["findings"]) and text?(args["summary"])
  defp allowed?(_, _, _), do: false

  defp current(context) do
    with {:ok, %{} = record} <- RunJournal.read(context.identity["directory"]),
         true <- Map.take(record, @identity) == context.identity and text?(record["thread_id"]) and record["native_stop_confirmed"] != true,
         {:ok, ^record} <- ExecutionBinding.bind(record, record["execution_binding"]),
         {:ok, current} <- RunJournal.checkpoint(record, %{}) do
      {:ok, current}
    else
      _ -> {:error, :task_execution_no_longer_owned}
    end
  end

  defp scope(record, context) do
    binding = record["execution_binding"]

    with {:ok, plan} <- TaskPlanPreflight.inspect_plan(binding["authority"]["work"], context.opts),
         true <- plan.authority == binding["authority"] and plan.plan["revision"] == binding["plan_revision"],
         %{} = member <- plan.members[WorkRef.key(binding["work"])],
         true <- member.contract["contract_sha"] == binding["contract_sha"] and member.raw["state"] in ["open", "opened"],
         true <- plan.parent.raw["state"] in ["open", "opened"],
         :ok <- TaskLifecycle.validate_policy(context.policy, member.contract),
         {:ok, controls} <- TaskControl.observe(plan, binding["work"], TaskControl.recorded(record)),
         {:ok, record} <- RunJournal.checkpoint(record, %{"control_receipts" => controls.receipts}) do
      {:ok, %{record: record, plan: plan, member: member, controls: controls}}
    else
      {:error, _} = error -> error
      _ -> {:error, :task_tool_scope_changed}
    end
  end

  defp invoke("task_context", _, scope, context) do
    with {:ok, scope, evidence} <- observe_candidate(scope, context) do
      {:ok,
       %{
         "contract" => scope.member.contract,
         "binding" => scope.record["execution_binding"],
         "candidate" => evidence.candidate,
         "controls" => evidence.controls.restrictions,
         "sources" => evidence.sources,
         "checks" => context.policy["checks"]
       }}
    end
  end

  defp invoke(tool, args, scope, context) do
    with :ok <- runnable(scope), do: act(tool, args, scope, context)
  end

  defp runnable(scope) do
    flow = scope.record["workflow"] || %{}

    valid =
      flow["schema_version"] == 2 and flow["started"] == true and is_map(flow["restrictions"]) and
        map_size(flow["restrictions"]) == 0 and within_budget?(flow, scope.member.contract["budget_ms"])

    if valid and scope.controls.restrictions == [], do: :ok, else: {:error, :task_execution_controlled}
  end

  defp within_budget?(%{"budget_ms" => budget, "used_ms" => used}, limit),
    do: is_integer(budget) and is_integer(used) and used >= 0 and used < min(budget, limit)

  defp within_budget?(_, _), do: false

  defp act("task_candidate", args, scope, context) do
    binding = scope.record["execution_binding"]

    with {:ok, artifacts} <- artifacts(args["artifacts"], scope.member.contract["deliverables"], binding["work"]),
         payload = Map.take(binding, ~w(work contract_sha inputs)) |> Map.put("artifacts", artifacts),
         {:ok, _} <- TaskEvidence.retain_candidate(scope.record, payload, context.opts) do
      publish(scope, context, "candidate", payload, args["summary"])
    end
  end

  defp act("task_check", args, scope, context) do
    with {:ok, scope, candidate, _sources} <- candidate(scope, context),
         true <- args["check_id"] in required(scope) or {:error, :unassigned_verification_check},
         {:ok, record, receipt} <- CommandCheck.run(scope.record, candidate, args["check_id"], context.policy),
         {:ok, output} <- CommandCheck.output(record, receipt["id"]) do
      {:ok, Map.merge(Map.take(receipt, @command_fields ++ ~w(native_stop_confirmed)), output)}
    end
  end

  defp act("task_verification", args, scope, context) do
    with {:ok, scope, _candidate, sources} <- candidate(scope, context),
         :ok <- TaskLifecycle.validate_findings(args["findings"], scope.member.contract["criteria"], sources),
         {:ok, checks} <- checks(scope, context, args["review_checks"]) do
      payload = Map.take(scope.record["execution_binding"], ~w(candidate inputs policy_sha)) |> Map.merge(%{"checks" => checks, "findings" => args["findings"]})
      publish(scope, context, "verification", payload, args["summary"])
    end
  end

  defp candidate(scope, context) do
    binding = scope.record["execution_binding"]

    with {:ok, scope, %{candidate: %{} = candidate} = evidence} <- observe_candidate(scope, context),
         :ok <- runnable(scope),
         true <- candidate["digest"] == binding["candidate"] and candidate["inputs"] == binding["inputs"] do
      {:ok, scope, candidate, evidence.sources}
    else
      {:error, _} = error -> error
      _ -> {:error, :task_candidate_changed}
    end
  end

  defp observe_candidate(scope, context) do
    with {:ok, evidence} <- TaskEvidence.read_candidate(scope.plan, scope.member.work, scope.record, context.policy, context.opts),
         {:ok, record} <- RunJournal.checkpoint(scope.record, %{"control_receipts" => evidence.controls.receipts}) do
      {:ok, %{scope | record: record, controls: evidence.controls}, evidence}
    end
  end

  defp artifacts(items, outputs, work) do
    valid = Enum.all?(items, &(is_map(&1) and keys?(&1, ~w(id version)) and text?(&1["version"])))

    if valid and Enum.sort(Enum.map(items, & &1["id"])) == Enum.sort(Enum.map(outputs, & &1["id"])) do
      {:ok,
       Enum.map(outputs, fn output ->
         item = Enum.find(items, &(&1["id"] == output["id"]))
         Map.merge(item, %{"kind" => output["kind"], "source" => GitArtifact.source_ref(work, item["version"])})
       end)}
    else
      {:error, :candidate_outputs_do_not_match_contract}
    end
  end

  defp required(scope), do: scope.member.contract["verification_checks"] |> Map.values() |> List.flatten() |> Enum.uniq() |> Enum.sort()

  defp checks(scope, context, reviews) do
    expected = Enum.filter(required(scope), &(context.policy["checks"][&1]["kind"] == "review"))
    valid = Enum.all?(reviews, &(is_map(&1) and keys?(&1, ~w(id result rationale)) and &1["result"] in ["passed", "failed"] and text?(&1["rationale"])))

    if valid and Enum.sort(Enum.map(reviews, & &1["id"])) == expected do
      collect_checks(scope, context, reviews)
    else
      {:error, :review_checks_do_not_match_policy}
    end
  end

  defp collect_checks(scope, context, reviews) do
    Enum.reduce_while(required(scope), {:ok, []}, fn id, {:ok, checks} ->
      case check(scope.record, context.policy["checks"][id], id, reviews) do
        {:ok, value} -> {:cont, {:ok, checks ++ [value]}}
        error -> {:halt, error}
      end
    end)
  end

  defp check(record, %{"kind" => "review"}, id, reviews), do: {:ok, Enum.find(reviews, &(&1["id"] == id)) |> Map.put("candidate", record["execution_binding"]["candidate"])}

  defp check(record, %{"kind" => "command"}, id, _) do
    matches =
      Enum.filter(record["check_runs"] || %{}, fn {_, entry} ->
        entry["spec"]["check"] == id and entry["spec"]["binding"] == record["execution_binding"] and entry["spec"]["generation"] == record["execution_generation"]
      end)

    case matches do
      [{_, %{"status" => "completed", "receipt" => receipt}}] -> {:ok, receipt |> Map.take(@command_fields) |> Map.put("id", id)}
      _ -> {:error, :command_check_not_completed}
    end
  end

  defp publish(scope, context, kind, payload, summary) do
    with {:ok, record} <- RunJournal.checkpoint(scope.record, %{}),
         scope = %{scope | record: record},
         :ok <- runnable(scope),
         {:ok, results} <- TaskPublication.observe(scope.record, scope.member, context.policy["engine_actor"]),
         true <- Enum.all?(results, &same_result?(&1.envelope, scope.record, payload)) or {:error, :execution_result_already_submitted},
         {:ok, _record, receipt} <- TaskPublication.publish(scope.record, kind, payload, summary, context.opts) do
      {:ok, receipt}
    end
  end

  defp same_result?(envelope, record, payload),
    do: envelope["generation"] != record["execution_generation"] or envelope["payload"] == payload

  defp response({:ok, value}), do: output(true, %{"data" => value})
  defp response({:error, reason}), do: output(false, %{"error" => inspect(reason)})

  defp output(success, data) do
    text = Jason.encode!(data)
    %{"success" => success, "output" => text, "contentItems" => [%{"type" => "inputText", "text" => text}]}
  end

  defp keys?(map, keys), do: Enum.sort(Map.keys(map)) == Enum.sort(keys)
  defp text?(value), do: is_binary(value) and String.trim(value) != ""

  defp specs(role) do
    context = spec("task_context", "Read the sealed contract, fixed inputs, current candidate, controls and configured checks for this execution.", %{})

    if role == "developer" do
      [
        context,
        spec(
          "task_candidate",
          "Publish the complete candidate for independent verification. Supply each declared output ID and fixed Git revision; the host retrieves and retains it. This does not complete the task.",
          %{
            "artifacts" => array(%{"type" => "object", "additionalProperties" => false, "required" => ~w(id version), "properties" => %{"id" => string(), "version" => string()}}),
            "summary" => string()
          }
        )
      ]
    else
      [
        context,
        spec("task_check", "Run one configured command check on the bound candidate. Supply only its assigned check ID; command and results are host-owned.", %{"check_id" => string()}),
        spec(
          "task_verification",
          "Publish independent verification. Supply review checks and evidence-bearing findings; command checks come from host receipts. No approval, merge or closure occurs.",
          %{
            "review_checks" =>
              array(%{
                "type" => "object",
                "additionalProperties" => false,
                "required" => ~w(id result rationale),
                "properties" => %{"id" => string(), "result" => %{"type" => "string", "enum" => ["passed", "failed"]}, "rationale" => string()}
              }),
            "findings" => array(finding_schema()),
            "summary" => string()
          }
        )
      ]
    end
  end

  defp finding_schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ~w(id criterion status required rationale problem_sha repair_basis_sha evidence),
      "properties" => %{
        "id" => string(),
        "criterion" => string(),
        "required" => %{"type" => "boolean"},
        "rationale" => string(),
        "status" => %{"type" => "string", "enum" => ~w(valid fixed unsubstantiated unknown)},
        "problem_sha" => %{"type" => "string", "pattern" => "^[0-9a-f]{64}$", "description" => "Stable digest of the normalized defect, excluding head and wording changes."},
        "repair_basis_sha" => %{"type" => "string", "pattern" => "^[0-9a-f]{64}$", "description" => "Digest of substantive reproduction or repair evidence; unchanged evidence retains this identity."},
        "evidence" => Map.put(array(string()), "minItems", 1)
      }
    }
  end

  defp spec(name, description, properties),
    do: %{
      "name" => name,
      "description" => description,
      "inputSchema" => %{"type" => "object", "additionalProperties" => false, "required" => Map.keys(properties) |> Enum.sort(), "properties" => properties}
    }

  defp array(items), do: %{"type" => "array", "items" => items}
  defp string, do: %{"type" => "string", "minLength" => 1}
end
