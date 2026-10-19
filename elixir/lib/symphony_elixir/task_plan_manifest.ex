defmodule SymphonyElixir.TaskPlanManifest do
  @moduledoc """
  Reconcile the parent plan from current member facts and native decisions.

  An M1 decision never accepts M2. Rework retains the original Issues, contracts,
  evidence history and remaining budgets; it creates no Issue, rollback or new
  authority. Every parent write is read back before it becomes a receipt.
  """

  alias SymphonyElixir.{ArtifactStore, Config, Execution, NativeWork, RunJournal, TaskClosure}
  alias SymphonyElixir.{TaskControl, TaskDecision}
  alias SymphonyElixir.{TaskExecutionConfig, TaskPlan, TaskPlanExecution, TaskReconciler, TaskWorkflow, WorkRef}

  @manifest ~r/<!-- symphony-plan-manifest (\{[^\n]*\}) -->/
  @decision ~r/<!-- symphony-plan-acceptance (\{[^\n]*\}) -->/

  @doc "Assemble a fixed manifest only when every member has a current closure proof."
  @spec assemble(map(), map()) :: {:ok, map()} | {:incomplete, [String.t()]}
  def assemble(plan, projection) do
    members = Enum.map(plan["members"], &manifest_member(&1, projection))
    missing = for %{"status" => status, "work" => work} <- members, status != "completed", do: WorkRef.key(work)

    if missing == [] do
      body = %{
        "schema_version" => 2,
        "plan_revision" => plan["revision"],
        "criteria" => plan["criteria"],
        "integration" => plan["integration"],
        "members" => members
      }

      {:ok, Map.put(body, "revision", TaskWorkflow.digest(body))}
    else
      {:incomplete, missing}
    end
  end

  defp manifest_member(member, projection) do
    work = member["work"]

    case projection[WorkRef.key(work)] do
      %{
        closeable: true,
        flow: flow,
        closure: %{"status" => "confirmed", "native_state" => "closed"} = closure,
        evidence: %{"candidate" => %{} = candidate, "verification" => %{} = verification} = evidence
      } ->
        if complete_evidence?(flow, candidate, verification, evidence, closure) do
          proof = %{
            "candidate" => candidate["digest"],
            "verification" => verification["source"],
            "contract_sha" => flow["contract_sha"],
            "plan_revision" => flow["plan_revision"],
            "artifacts" => Enum.map(candidate["artifacts"], &Map.take(&1, ~w(id kind version source target_branch))),
            "deliveries" => Enum.map(evidence["deliveries"], & &1["source"]) |> Enum.sort(),
            "inputs" => flow["inputs"],
            "closure" => closure["source"]
          }

          Map.merge(proof, %{"work" => work, "criteria" => member["criteria"], "status" => "completed", "evidence" => TaskWorkflow.digest(proof)})
        else
          %{"work" => work, "criteria" => member["criteria"], "status" => "pending"}
        end

      %{restricted: reason} ->
        %{"work" => work, "criteria" => member["criteria"], "status" => "restricted", "reason" => reason}

      _ ->
        %{"work" => work, "criteria" => member["criteria"], "status" => "pending"}
    end
  end

  defp complete_evidence?(flow, candidate, verification, evidence, closure) do
    candidate["digest"] == flow["candidate"] and verification["source"] == flow["verification"] and
      candidate["inputs"] == flow["inputs"] and is_list(candidate["artifacts"]) and candidate["artifacts"] != [] and
      is_list(evidence["deliveries"]) and is_binary(closure["source"])
  end

  @doc "Read immutable manifest publications in native event order."
  @spec manifests(map()) :: [map()]
  def manifests(parent) do
    parent.notes
    |> Enum.reject(&(&1["system"] == true))
    |> Enum.flat_map(&manifest_note/1)
    |> Enum.sort_by(&{&1["at"], &1["note_id"]})
    |> Enum.with_index(1)
    |> Enum.map(fn {entry, index} -> Map.put(entry, "label", "M" <> to_string(index)) end)
  end

  defp manifest_note(note) do
    with [_, json] <- Regex.run(@manifest, note["body"] || ""),
         {:ok, %{"revision" => revision} = payload} <- Jason.decode(json),
         true <- revision == TaskWorkflow.digest(Map.delete(payload, "revision")),
         true <- note["created_at"] == note["updated_at"],
         at when is_integer(at) <- TaskDecision.timestamp(note["created_at"]),
         true <- is_integer(note["id"]) and is_integer(get_in(note, ["author", "id"])) do
      [
        %{
          "payload" => payload,
          "source" => TaskDecision.source_ref(note),
          "note_id" => note["id"],
          "at" => at,
          "actor" => to_string(get_in(note, ["author", "id"]))
        }
      ]
    else
      _ -> []
    end
  end

  @doc "Publish one manifest to the parent Issue, recovering lost responses by native readback."
  @spec publish(map(), map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def publish(parent, plan, manifest, opts) do
    root = Keyword.get_lazy(opts, :journal_root, &Execution.journal_root/0)
    directory = RunJournal.directory(root, WorkRef.key(plan["integration"]))

    with {:ok, %{} = record} <- RunJournal.read(directory),
         true <- record["issue_id"] == WorkRef.key(plan["integration"]) or {:error, :parent_manifest_member_unavailable} do
      TaskClosure.with_fence(record, opts, fn -> publish_owned(parent, plan, manifest, opts, directory) end)
    else
      {:ok, nil} -> {:error, :parent_manifest_member_unavailable}
      error -> error
    end
  end

  defp publish_owned(parent, plan, manifest, opts, directory) do
    with {:ok, %{} = record} <- RunJournal.read(directory),
         {:ok, configured} <- TaskExecutionConfig.prepare(plan["parent"], opts),
         :ok <- same_manifest(configured, manifest),
         :ok <- retain_manifest(record, plan, manifest, opts),
         {:ok, fresh} <- TaskExecutionConfig.prepare(plan["parent"], opts),
         :ok <- same_manifest(fresh, manifest),
         {:ok, snapshot} <- NativeWork.read(parent.work, opts),
         true <- NativeWork.snapshot_ref(snapshot) == NativeWork.snapshot_ref(fresh.plan.parent) or {:error, :parent_manifest_scope_changed},
         {:ok, actor} <- actor(plan, opts),
         {:ok, existing} <- existing_manifest(snapshot, manifest, actor) do
      if existing do
        confirmed_intent(record, manifest, existing)
      else
        send_manifest(record, snapshot, plan, manifest, actor, opts)
      end
    end
  end

  @doc "Pin every fixed member artifact for this manifest before its native publication."
  @spec retain_manifest(map(), map(), map(), keyword()) :: :ok | {:error, term()}
  def retain_manifest(record, plan, manifest, opts) do
    root = Keyword.get(opts, :artifact_store_root, Path.join(Path.dirname(record["directory"]), ".artifacts"))
    owner = %{"kind" => "manifest", "work" => plan["parent"], "revision" => manifest["revision"]}

    manifest["members"]
    |> Enum.flat_map(fn member -> Enum.map(member["artifacts"], &{member["work"], &1}) end)
    |> Enum.reduce_while(:ok, fn {work, artifact}, :ok ->
      result =
        if artifact["kind"] == "report",
          do: ArtifactStore.retain_existing_report(root, work, artifact, owner, opts),
          else: ArtifactStore.retain(root, work, artifact["version"], owner, opts)

      case result do
        {:ok, _} -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp existing_manifest(parent, manifest, actor) do
    case List.last(manifests(parent)) do
      nil ->
        {:ok, nil}

      %{"payload" => ^manifest, "actor" => ^actor} = latest ->
        {:ok, latest}

      %{"payload" => ^manifest} ->
        {:error, :plan_manifest_publication_conflict}

      _ ->
        {:ok, nil}
    end
  end

  defp confirmed_intent(record, manifest, receipt) do
    revision = manifest["revision"]
    source = receipt["source"]

    case record["parent_manifest_intent"] do
      %{"revision" => previous, "status" => "sending"} when previous != revision ->
        {:error, :prior_plan_manifest_unconfirmed}

      %{"revision" => ^revision, "status" => "confirmed", "source" => ^source} ->
        {:ok, receipt}

      %{"revision" => ^revision, "status" => "confirmed"} ->
        {:error, :plan_manifest_source_changed}

      _ ->
        changes = %{"parent_manifest_intent" => %{"revision" => manifest["revision"], "status" => "confirmed", "source" => receipt["source"]}}
        with {:ok, _} <- RunJournal.checkpoint(record, changes), do: {:ok, receipt}
    end
  end

  defp send_manifest(record, parent, plan, manifest, actor, opts) do
    intent = record["parent_manifest_intent"]

    if is_map(intent) and intent["status"] == "sending",
      do: {:error, :plan_manifest_send_unconfirmed},
      else: send_new_manifest(record, parent, plan, manifest, actor, opts)
  end

  defp send_new_manifest(record, parent, plan, manifest, actor, opts) do
    label = "M" <> to_string(length(manifests(parent)) + 1)
    body = manifest_body(manifest, label, acceptor(parent, plan))
    intent = %{"revision" => manifest["revision"], "status" => "sending", "label" => label}

    with {:ok, sending} <- RunJournal.checkpoint(record, %{"parent_manifest_intent" => intent}) do
      case NativeWork.comment(parent, body, actor, opts) do
        {:not_sent, reason} ->
          RunJournal.checkpoint(sending, %{"parent_manifest_intent" => %{intent | "status" => "prepared"}})
          {:error, {:plan_manifest_not_published, reason}}

        _ ->
          confirm_manifest_send(sending, parent.work, manifest, label, actor, intent, opts)
      end
    end
  end

  defp confirm_manifest_send(sending, work, manifest, label, actor, intent, opts) do
    with {:ok, receipt} <- confirm(work, manifest, label, actor, opts),
         changes = %{"parent_manifest_intent" => intent |> Map.put("status", "confirmed") |> Map.put("source", receipt["source"])},
         {:ok, _} <- RunJournal.checkpoint(sending, changes) do
      {:ok, receipt}
    end
  end

  defp actor(plan, opts) do
    catalog = Keyword.get_lazy(opts, :repositories, fn -> Config.settings!().tracker.provider["plan_repositories"] || [] end)

    with {:ok, repository} <- NativeWork.resolve(plan["parent"], catalog),
         actor when is_binary(actor) <- get_in(repository, ["execution", "policy", "engine_actor"]) do
      {:ok, actor}
    else
      _ -> {:error, :plan_manifest_actor_unavailable}
    end
  end

  defp manifest_body(manifest, label, acceptor) do
    candidate = %{
      "label" => label,
      "revision" => manifest["revision"],
      "authorizer" => acceptor,
      "data" => %{"acceptance_items" => manifest["criteria"]}
    }

    "验收清单 #{label}\n\n" <>
      readable_manifest(manifest) <>
      "<!-- symphony-plan-manifest #{TaskWorkflow.canonical_json(manifest)} -->\n" <>
      "<!-- symphony-candidate #{TaskWorkflow.canonical_json(candidate)} -->"
  end

  defp readable_manifest(manifest) do
    members = Enum.map_join(manifest["members"], "\n", &readable_member/1)

    "计划版本：#{manifest["plan_revision"]}\n" <>
      "验收项：#{Enum.map_join(manifest["criteria"], ", ", &safe_line/1)}\n" <>
      "集成任务：#{human_work(manifest["integration"])}\n" <>
      "成果与验证：\n#{members}\n\n"
  end

  defp readable_member(member) do
    artifacts = Enum.map_join(member["artifacts"], ", ", &"#{safe_line(&1["id"])}@#{safe_line(&1["version"])}")
    deliveries = Enum.map_join(member["deliveries"], ", ", &safe_line/1)

    "- #{human_work(member["work"])}：#{artifacts}；验证 #{safe_line(member["verification"])}；交付 #{deliveries}；关闭 #{safe_line(member["closure"])}"
  end

  defp human_work(work), do: "#{work["provider"]} #{work["host"]}/#{work["repository_id"]}##{work["number"]}"
  defp safe_line(value), do: value |> to_string() |> String.replace(~r/[\r\n<>]/u, " ") |> String.trim()

  defp confirm(work, manifest, label, actor, opts) do
    with {:ok, current} <- NativeWork.read(work, opts),
         {:ok, %{} = receipt} <- existing_manifest(current, manifest, actor),
         true <- receipt["label"] == label do
      {:ok, receipt}
    else
      _ -> {:error, {:plan_manifest_unconfirmed, manifest["revision"]}}
    end
  end

  @doc "Resolve only the latest manifest's explicit, unchanged acceptance or rework decision."
  @spec decision(map(), map(), map() | nil) :: {:ok, map() | nil} | {:error, term()}
  def decision(_parent, _plan, nil), do: {:ok, nil}

  def decision(parent, plan, manifest) do
    if plan_manifest?(manifest, plan) do
      current_decision(parent, plan, manifest)
    else
      {:error, :manifest_plan_mismatch}
    end
  end

  defp current_decision(parent, plan, manifest) do
    actor = acceptor(parent, plan)

    events =
      parent.notes
      |> Enum.reject(&(&1["system"] == true))
      |> Enum.flat_map(&decision_note(parent, &1, actor, plan))
      |> Enum.filter(&current_decision?(&1, manifest))
      |> Enum.sort_by(& &1["at"], :desc)

    case events do
      [] -> {:ok, nil}
      [%{"at" => at}, %{"at" => at} | _] -> {:error, :ambiguous_plan_decision}
      [event | _] -> {:ok, event}
    end
  end

  defp plan_manifest?(%{"payload" => payload}, plan) do
    payload["schema_version"] == 2 and payload["plan_revision"] == plan["revision"] and
      payload["criteria"] == plan["criteria"] and payload["integration"] == plan["integration"] and
      manifest_members?(payload["members"], plan["members"])
  end

  defp plan_manifest?(_, _), do: false

  defp manifest_members?(members, planned) when is_list(members) do
    Enum.all?(members, &is_map/1) and Enum.map(members, & &1["work"]) == Enum.map(planned, & &1["work"])
  end

  defp manifest_members?(_, _), do: false

  defp current_decision?(event, manifest) do
    event["revision"] == manifest["payload"]["revision"] and
      event["manifest"] == manifest["source"] and event["at"] > manifest["at"]
  end

  defp acceptor(parent, plan) do
    case TaskReconciler.description_contract(parent.description) do
      %{"acceptance_mode" => "separate", "acceptor" => actor} when is_binary(actor) -> actor
      _ -> plan["authorizer"]
    end
  end

  defp decision_note(parent, note, actor, plan) do
    case Regex.run(@decision, note["body"] || "") do
      [_, json] -> structured_decision(note, actor, plan, json)
      _ -> natural_decision(parent, note, actor, plan)
    end
  end

  defp structured_decision(note, actor, plan, json) do
    with true <- unchanged_actor?(note, actor),
         {:ok, payload} <- Jason.decode(json),
         true <- decision_payload?(payload, plan) do
      [Map.merge(payload, %{"source" => TaskDecision.source_ref(note), "at" => TaskDecision.timestamp(note["created_at"])})]
    else
      _ -> []
    end
  end

  defp natural_decision(parent, note, actor, plan) do
    case unchanged_actor?(note, actor) && TaskControl.bind_reply(parent, note, actor) do
      {:ok, %{"action" => action, "revision" => revision} = event} when action in ["accept", "rework"] ->
        natural_payload(event, action, revision, plan)

      _ ->
        []
    end
  end

  defp natural_payload(event, action, revision, plan) do
    payload = %{"action" => action, "revision" => revision, "manifest" => event["candidate_source"], "criteria" => event["items"]}
    if decision_payload?(payload, plan), do: [Map.merge(payload, %{"source" => event["note_source"], "at" => event["at"]})], else: []
  end

  defp unchanged_actor?(note, actor) do
    is_integer(note["id"]) and note["created_at"] == note["updated_at"] and
      is_integer(TaskDecision.timestamp(note["created_at"])) and to_string(get_in(note, ["author", "id"])) == actor
  end

  defp decision_payload?(%{"action" => "accept"} = payload, _plan) do
    Enum.sort(Map.keys(payload)) in [Enum.sort(~w(action manifest revision)), Enum.sort(~w(action criteria manifest revision))] and
      is_binary(payload["manifest"]) and is_binary(payload["revision"]) and payload["criteria"] in [nil, []]
  end

  defp decision_payload?(%{"action" => "rework", "criteria" => criteria} = payload, plan) do
    Enum.sort(Map.keys(payload)) == Enum.sort(~w(action criteria manifest revision)) and is_binary(payload["manifest"]) and
      is_binary(payload["revision"]) and is_list(criteria) and criteria != [] and length(Enum.uniq(criteria)) == length(criteria) and
      Enum.all?(criteria, &(&1 in plan["criteria"]))
  end

  defp decision_payload?(_, _), do: false

  @doc "Parse native parent notes for diagnostics; this does not prove the engine published the manifest."
  @spec facts(map(), map()) :: map()
  def facts(parent, plan) do
    case parent |> manifests() |> Enum.filter(&plan_manifest?(&1, plan)) |> List.last() do
      nil -> %{"status" => "no_manifest"}
      manifest -> decision_facts(parent, plan, manifest)
    end
  end

  @doc "Project only a manifest whose native source matches a durable publication receipt."
  @spec facts(map(), map(), keyword()) :: map()
  def facts(parent, plan, opts) do
    case parent |> manifests() |> Enum.filter(&plan_manifest?(&1, plan)) |> List.last() do
      nil -> %{"status" => "no_manifest"}
      manifest -> confirmed_facts(parent, plan, manifest, opts)
    end
  end

  defp confirmed_facts(parent, plan, manifest, opts) do
    root = Keyword.get_lazy(opts, :journal_root, &Execution.journal_root/0)
    directory = RunJournal.directory(root, WorkRef.key(plan["integration"]))

    case {RunJournal.read(directory), actor(plan, opts)} do
      {{:ok, %{"parent_manifest_intent" => %{"status" => "confirmed", "source" => source, "revision" => revision}}}, {:ok, actor}} ->
        if source == manifest["source"] and revision == manifest["payload"]["revision"] and manifest["actor"] == actor and
             current_manifest?(plan, manifest, opts),
           do: decision_facts(parent, plan, manifest),
           else: unconfirmed_manifest(manifest)

      _ ->
        unconfirmed_manifest(manifest)
    end
  end

  defp current_manifest?(plan, manifest, opts) do
    with {:ok, configured} <- TaskExecutionConfig.prepare(plan["parent"], opts),
         {:ok, %{"revision" => revision}} <- assemble(plan, TaskPlanExecution.projection_of(configured)) do
      revision == manifest["payload"]["revision"]
    else
      _ -> false
    end
  end

  defp unconfirmed_manifest(manifest) do
    %{"status" => "unconfirmed", "label" => manifest["label"], "revision" => manifest["payload"]["revision"], "source" => manifest["source"]}
  end

  defp decision_facts(parent, plan, manifest) do
    base = %{"label" => manifest["label"], "revision" => manifest["payload"]["revision"], "source" => manifest["source"]}

    case decision(parent, plan, manifest) do
      {:ok, nil} -> Map.put(base, "status", "awaiting_acceptance")
      {:ok, %{"action" => "accept"} = event} -> Map.merge(base, %{"status" => "accepted", "decision" => event["source"]})
      {:ok, %{"action" => "rework"} = event} -> Map.merge(base, %{"status" => "rework", "criteria" => event["criteria"], "decision" => event["source"]})
      {:error, reason} -> Map.merge(base, %{"status" => "unconfirmed", "reason" => inspect(reason)})
    end
  end

  @doc "Advance a configured parent once from its current member and native facts."
  @spec advance(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def advance(configured, opts) do
    plan = configured.plan.plan

    with {:ok, rework_state} <- recover_rework(configured, opts) do
      case assemble(plan, TaskPlanExecution.projection_of(configured)) do
        {:incomplete, missing} -> {:ok, rework_state || %{"status" => "incomplete", "members" => missing}}
        {:ok, manifest} -> publish_and_settle(configured, manifest, opts)
      end
    end
  rescue
    error -> {:error, {:plan_lifecycle_failed, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:plan_lifecycle_failed, kind, inspect(reason)}}
  end

  @doc "Recover a parent close response lost before its durable receipt, without granting new execution."
  @spec recover_closed(WorkRef.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def recover_closed(parent, opts) do
    root = Keyword.get_lazy(opts, :journal_root, &Execution.journal_root/0)

    with {:ok, snapshot} <- NativeWork.read(parent, opts),
         true <- snapshot.raw["state"] == "closed" or {:error, :parent_not_closed},
         {:ok, plan} <- TaskPlan.parse(snapshot.description),
         directory = RunJournal.directory(root, WorkRef.key(plan["integration"])),
         {:ok, %{} = record} <- RunJournal.read(directory) do
      TaskClosure.with_fence(record, opts, fn -> recover_closed_owned(directory, opts) end)
    else
      {:ok, nil} -> {:error, :parent_close_intent_unavailable}
      error -> error
    end
  end

  defp recover_closed_owned(directory, opts) do
    with {:ok, %{"parent_close_intent" => %{"status" => status} = intent} = record} <- RunJournal.read(directory),
         true <- status in ["sending", "confirmed", "inconsistent"] or {:error, :parent_close_intent_unavailable} do
      confirm_close(record, intent, opts)
    else
      _ -> {:error, :parent_close_intent_unavailable}
    end
  end

  defp recover_rework(configured, opts) do
    parent = configured.plan.parent
    plan = configured.plan.plan

    case confirmed_manifest(configured, parent, plan) do
      nil -> {:ok, nil}
      manifest -> recover_decision(configured, parent, plan, manifest, opts)
    end
  end

  defp confirmed_manifest(configured, parent, plan) do
    case configured.executions[WorkRef.key(plan["integration"])] do
      %{directory: directory} -> confirmed_manifest_at(directory, parent, plan)
      _ -> nil
    end
  end

  defp confirmed_manifest_at(directory, parent, plan) do
    with {:ok, %{"parent_manifest_intent" => %{"status" => "confirmed", "revision" => revision, "source" => source}}} <-
           RunJournal.read(directory),
         %{"payload" => %{"revision" => ^revision}, "source" => ^source} = latest <- List.last(manifests(parent)),
         true <- plan_manifest?(latest, plan) do
      latest
    else
      _ -> nil
    end
  end

  defp recover_decision(configured, parent, plan, manifest, opts) do
    case decision(parent, plan, manifest) do
      {:ok, %{"action" => "rework"} = event} -> rework(configured, manifest, event, opts)
      {:ok, _} -> {:ok, nil}
      error -> error
    end
  end

  defp publish_and_settle(configured, manifest, opts) do
    parent = configured.plan.parent
    plan = configured.plan.plan

    with {:ok, receipt} <- publish(parent, plan, manifest, opts),
         {:ok, current} <- NativeWork.read(plan["parent"], opts),
         {:ok, decision} <- decision(current, plan, receipt) do
      settle(configured, manifest, receipt, decision, opts)
    end
  end

  defp settle(_configured, _manifest, receipt, nil, _opts),
    do: {:ok, %{"status" => "awaiting_acceptance", "manifest" => receipt}}

  defp settle(configured, manifest, receipt, %{"action" => "accept"} = decision, opts),
    do: close(configured, manifest, receipt, decision, opts)

  defp settle(configured, _manifest, receipt, %{"action" => "rework"} = decision, opts),
    do: rework(configured, receipt, decision, opts)

  defp close(configured, manifest, receipt, decision, opts) do
    directory = configured.executions[WorkRef.key(configured.plan.plan["integration"])].directory

    with {:ok, %{} = record} <- RunJournal.read(directory) do
      TaskClosure.with_fence(record, opts, fn ->
        close_owned(configured, manifest, receipt, decision, opts, directory)
      end)
    end
  end

  defp close_owned(configured, manifest, receipt, decision, opts, directory) do
    with {:ok, %{} = record} <- RunJournal.read(directory) do
      case record["parent_close_intent"] do
        %{"status" => status} = intent when status in ["sending", "confirmed", "inconsistent"] ->
          recover_close(record, intent, manifest, receipt, decision, opts)

        _ ->
          close_new(record, configured, manifest, receipt, decision, opts)
      end
    end
  end

  defp close_new(record, configured, manifest, receipt, decision, opts) do
    parent = configured.plan.plan["parent"]

    with {:ok, fresh} <- TaskExecutionConfig.prepare(parent, opts),
         :ok <- hold(configured, fresh, manifest),
         {:ok, snapshot} <- NativeWork.read(parent, opts),
         true <- snapshot.raw["state"] in ["open", "opened"] or {:error, :parent_not_open},
         :ok <- current_acceptance(snapshot, fresh.plan.plan, receipt, decision),
         intent = close_intent(fresh, snapshot, receipt, decision),
         {:ok, sending} <- RunJournal.checkpoint(record, %{"parent_close_intent" => intent}) do
      case NativeWork.close(snapshot, opts) do
        {:not_sent, reason} ->
          RunJournal.checkpoint(sending, %{"parent_close_intent" => %{intent | "status" => "prepared"}})
          {:error, {:parent_close_not_sent, reason}}

        _ ->
          recover_close(sending, intent, manifest, receipt, decision, opts)
      end
    end
  end

  defp current_acceptance(snapshot, plan, receipt, decision) do
    expected_manifest = receipt["source"]
    expected_acceptance = decision["source"]

    case {List.last(manifests(snapshot)), decision(snapshot, plan, receipt)} do
      {%{"source" => ^expected_manifest}, {:ok, %{"action" => "accept", "source" => ^expected_acceptance}}} ->
        :ok

      _ ->
        {:error, :parent_acceptance_changed}
    end
  end

  defp close_intent(fresh, snapshot, receipt, decision) do
    %{
      "status" => "sending",
      "manifest" => receipt["source"],
      "revision" => receipt["payload"]["revision"],
      "acceptance" => decision["source"],
      "parent_description" => TaskWorkflow.digest(snapshot.description),
      "parent_notes" => decision_sources(snapshot.notes),
      "members" =>
        Map.new(fresh.plan.members, fn {key, member} ->
          {key, %{"work" => member.work, "source" => NativeWork.snapshot_ref(member)}}
        end)
    }
  end

  defp recover_close(record, intent, manifest, receipt, decision, opts) do
    if intent["manifest"] == receipt["source"] and intent["revision"] == manifest["revision"] and
         intent["acceptance"] == decision["source"] do
      confirm_close(record, intent, opts)
    else
      {:error, :parent_close_prior_intent_unconfirmed}
    end
  end

  defp confirm_close(record, intent, opts) do
    parent = get_in(record, ["execution_binding", "authority", "work"])

    with {:ok, closed} <- NativeWork.read(parent, opts),
         true <- closed.raw["state"] == "closed" or {:error, :parent_close_unconfirmed} do
      status = if intent["status"] != "inconsistent" and stable_intent?(intent, closed, opts), do: "confirmed", else: "inconsistent"
      confirmed = Map.merge(intent, %{"status" => status, "source" => "issue:" <> NativeWork.snapshot_ref(closed)})

      with {:ok, _} <- RunJournal.checkpoint(record, %{"parent_close_intent" => confirmed}) do
        {:ok, close_receipt(confirmed)}
      end
    end
  end

  defp close_receipt(intent) do
    %{
      "status" => intent["status"],
      "source" => intent["source"],
      "manifest" => intent["manifest"],
      "acceptance" => intent["acceptance"],
      "observed_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp hold(configured, fresh, manifest) do
    cond do
      configured.plan.plan["revision"] != fresh.plan.plan["revision"] -> {:error, :parent_plan_revision_changed}
      map_size(fresh.plan.restricted) != 0 -> {:error, :parent_plan_restricted}
      true -> same_manifest(fresh, manifest)
    end
  end

  defp same_manifest(fresh, manifest) do
    expected = manifest["revision"]

    case assemble(fresh.plan.plan, TaskPlanExecution.projection_of(fresh)) do
      {:ok, %{"revision" => ^expected}} -> :ok
      {:ok, _} -> {:error, :parent_manifest_superseded}
      {:incomplete, _} -> {:error, :parent_manifest_incomplete}
    end
  end

  defp stable_intent?(intent, closed, opts) do
    same_parent =
      TaskWorkflow.digest(closed.description) == intent["parent_description"] and
        decision_sources(closed.notes) == intent["parent_notes"]

    same_members = Enum.all?(intent["members"], fn {_key, member} -> member_source?(member, opts) end)
    same_parent and same_members and parent_source?(closed, opts)
  end

  defp parent_source?(snapshot, opts) do
    case NativeWork.read(snapshot.work, opts) do
      {:ok, current} -> NativeWork.snapshot_ref(current) == NativeWork.snapshot_ref(snapshot)
      _ -> false
    end
  end

  defp decision_sources(notes) do
    notes
    |> Enum.reject(&(&1["system"] == true))
    |> Enum.map(&TaskDecision.source_ref/1)
    |> Enum.sort()
  end

  defp member_source?(%{"work" => work, "source" => source}, opts) do
    case NativeWork.read(work, opts) do
      {:ok, current} -> NativeWork.snapshot_ref(current) == source
      _ -> false
    end
  end

  defp rework(configured, receipt, decision, opts) do
    plan = configured.plan.plan

    with :ok <- rework_window(configured),
         {:ok, direct} <- rework_roots(plan, decision["criteria"]),
         {:ok, affected} <- TaskPlan.affected(plan, direct) do
      reopen_members(configured, affected, receipt, decision, opts)
    else
      {:error, :ambiguous_rework_scope} ->
        {:ok, %{"status" => "clarification", "manifest" => receipt, "criteria" => decision["criteria"]}}

      error ->
        error
    end
  end

  defp rework_roots(plan, criteria) do
    roots = Enum.map(criteria, &criterion_root(plan, &1))
    if Enum.all?(roots, &match?({:ok, _}, &1)), do: {:ok, roots |> Enum.map(&elem(&1, 1)) |> Enum.uniq()}, else: {:error, :ambiguous_rework_scope}
  end

  defp criterion_root(plan, criterion) do
    matching = for member <- plan["members"], criterion in member["criteria"], do: member["work"]

    roots =
      Enum.reject(matching, fn work ->
        Enum.any?(matching, fn other ->
          other != work and descendant?(plan, other, work)
        end)
      end)

    case roots do
      [root] -> {:ok, root}
      _ -> {:error, :ambiguous_rework_scope}
    end
  end

  defp descendant?(plan, ancestor, work) do
    {:ok, affected} = TaskPlan.affected(plan, [ancestor])
    work in affected
  end

  defp rework_window(configured) do
    directory = configured.executions[WorkRef.key(configured.plan.plan["integration"])].directory

    with {:ok, record} <- RunJournal.read(directory) do
      case record do
        %{"parent_close_intent" => %{"status" => status}} when status in ["sending", "confirmed", "inconsistent"] ->
          {:error, :parent_rework_after_acceptance}

        _ ->
          :ok
      end
    end
  end

  defp reopen_members(configured, affected, receipt, decision, opts) do
    Enum.reduce_while(affected, {:ok, []}, fn work, {:ok, acc} ->
      case reopen_member(configured, work, receipt, decision, opts) do
        {:ok, result} -> {:cont, {:ok, acc ++ [result]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, %{"status" => "rework", "members" => results}}
      error -> error
    end
  end

  defp reopen_member(configured, work, receipt, decision, opts) do
    directory = configured.executions[WorkRef.key(work)].directory

    with {:ok, %{} = record} <- RunJournal.read(directory),
         true <- record["issue_id"] == WorkRef.key(work) or {:error, :member_rework_identity_changed} do
      TaskClosure.with_fence(record, opts, fn -> reopen_owned(record, work, receipt, decision, opts) end)
    end
  end

  defp reopen_owned(record, work, receipt, decision, opts) do
    with {:ok, %{} = current} <- RunJournal.read(record["directory"]),
         true <- current["issue_id"] == WorkRef.key(work) or {:error, :member_rework_identity_changed},
         {:ok, snapshot} <- NativeWork.read(work, opts) do
      reopen_intent(current, snapshot, work, receipt, decision, opts)
    end
  end

  defp reopen_intent(current, snapshot, work, receipt, decision, opts) do
    prior = current["rework"]

    cond do
      is_map(prior) and prior["parent_source"] == decision["source"] and prior["status"] == "prepared" ->
        send_reopen(current, snapshot, work, receipt, decision, opts)

      is_map(prior) and prior["parent_source"] == decision["source"] ->
        recover_reopen(current, snapshot, work, receipt, decision)

      is_map(prior) and prior["status"] == "sending" ->
        {:error, :member_rework_prior_intent_unconfirmed}

      true ->
        send_reopen(current, snapshot, work, receipt, decision, opts)
    end
  end

  defp recover_reopen(current, snapshot, work, receipt, decision) do
    prior = current["rework"]

    cond do
      prior["status"] == "confirmed" and snapshot.raw["state"] in ["open", "opened", "closed"] ->
        status = if snapshot.raw["state"] == "closed", do: "already_reworked", else: "already_open"
        {:ok, rework_receipt(work, status, "issue:" <> NativeWork.snapshot_ref(snapshot), receipt, decision)}

      snapshot.raw["state"] not in ["open", "opened"] ->
        {:error, :member_rework_unconfirmed}

      prior["status"] == "sending" ->
        confirm_reopen(current, snapshot, work, receipt, decision)

      true ->
        {:error, :member_rework_intent_invalid}
    end
  end

  defp send_reopen(current, snapshot, work, receipt, decision, opts) do
    marker = rework_marker(current, receipt, decision)

    with :ok <- rework_budget(current),
         {:ok, sending} <- RunJournal.checkpoint(current, %{"rework" => marker}) do
      case request_reopen(snapshot, opts) do
        {:error, {:member_rework_not_sent, _} = reason} ->
          RunJournal.checkpoint(sending, %{"rework" => %{marker | "status" => "prepared"}})
          {:error, reason}

        {:ok, status, _source} ->
          confirm_reopen_send(sending, work, receipt, decision, status, opts)

        error ->
          error
      end
    end
  end

  defp confirm_reopen_send(sending, work, receipt, decision, status, opts) do
    with {:ok, current} <- NativeWork.read(work, opts),
         true <- current.raw["state"] in ["open", "opened"] or {:error, :member_rework_unconfirmed} do
      confirm_reopen(sending, current, work, receipt, decision, status)
    end
  end

  defp rework_budget(%{"workflow" => %{"budget_ms" => budget, "used_ms" => used}})
       when is_integer(budget) and is_integer(used) and used < budget,
       do: :ok

  defp rework_budget(_), do: {:error, :member_rework_budget_exhausted}

  defp confirm_reopen(record, snapshot, work, receipt, decision, status \\ "reopened") do
    source = "issue:" <> NativeWork.snapshot_ref(snapshot)
    marker = record["rework"] |> Map.put("status", "confirmed") |> Map.put("source", source)

    with {:ok, _} <- RunJournal.checkpoint(record, %{"rework" => marker}) do
      {:ok, rework_receipt(work, status, source, receipt, decision)}
    end
  end

  defp rework_receipt(work, status, source, receipt, decision) do
    %{"work" => work, "status" => status, "source" => source, "criteria" => decision["criteria"], "manifest" => receipt["source"]}
  end

  defp rework_marker(record, receipt, decision) do
    superseded =
      record
      |> Map.get("publications", %{})
      |> Map.values()
      |> Enum.map(&get_in(&1, ["receipt", "source"]))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    %{
      "parent_source" => decision["source"],
      "manifest" => receipt["source"],
      "criteria" => decision["criteria"],
      "superseded" => superseded,
      "at" => DateTime.from_unix!(decision["at"], :microsecond) |> DateTime.to_iso8601(),
      "status" => "sending"
    }
  end

  defp request_reopen(%{raw: %{"state" => state}} = snapshot, _opts) when state in ["open", "opened"],
    do: {:ok, "already_open", "issue:" <> NativeWork.snapshot_ref(snapshot)}

  defp request_reopen(%{raw: %{"state" => "closed"}} = snapshot, opts) do
    case NativeWork.reopen(snapshot, opts) do
      {:not_sent, reason} -> {:error, {:member_rework_not_sent, reason}}
      _ -> reopened(snapshot.work, opts)
    end
  end

  defp request_reopen(_, _), do: {:error, :member_rework_state_unknown}

  defp reopened(work, opts) do
    with {:ok, current} <- NativeWork.read(work, opts),
         true <- current.raw["state"] in ["open", "opened"] do
      {:ok, "reopened", "issue:" <> NativeWork.snapshot_ref(current)}
    else
      _ -> {:error, :member_rework_unconfirmed}
    end
  end
end
