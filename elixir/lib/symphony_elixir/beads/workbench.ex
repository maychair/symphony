defmodule SymphonyElixir.Beads.Workbench do
  @moduledoc "Structured gates and operator receipts stored in Beads; execution remains scheduler owned."
  alias SymphonyElixir.Beads.{Adapter, RunJournal, Recovery, Acceptance}
  @kinds ~w(authorization decision review incident dependency)

  @spec list(map()) :: {:ok, [map()]} | {:error, term()}
  def list(settings) do
    with {:ok, issues} <- Adapter.command(settings, ["list", "--all", "--limit", "0", "--json"]) do
      {:ok, Enum.map(issues, &present(settings, &1))}
    end
  end

  @spec envelope(map()) :: map()
  def envelope(issue) do
    value = get_in(issue, ["metadata", "symphony_workbench"])
    if is_binary(value), do: Jason.decode!(value), else: value || %{"gates" => []}
  rescue
    _ -> %{"gates" => [], "invalid" => true}
  end

  @spec present(map(), map()) :: map()
  def present(settings, issue) do
    env = envelope(issue)
    record = record(settings, issue["id"])

    gates =
      Enum.map(env["gates"] || [], fn gate ->
        gate |> Map.drop(["artifact_path"]) |> Map.put("stale", gate["binding"] != binding(issue, record))
      end)

    %{
      "id" => issue["id"],
      "title" => issue["title"],
      "status" => issue["status"],
      "updated_at" => issue["updated_at"],
      "phase" => if(get_in(issue, ["metadata", "symphony_gate"]) == "local_accepted", do: "local_accepted", else: record["phase"]),
      "thread_id" => record["thread_id"],
      "turn_id" => record["turn_id"],
      "gates" => gates,
      "receipts" => env["receipts"] || [],
      "unclassified" => issue["status"] == "blocked" and not Enum.any?(gates, &(!&1["stale"] and &1["state"] in ["pending", "waiting_repair"]))
    }
  end

  @doc "Versioned JSON supports already-registered reason-only native tools."
  @spec capture(map(), String.t(), String.t()) :: :ok | {:error, term()}
  def capture(settings, id, reason) do
    with {:ok, issue} <- issue(settings, id) do
      existing = envelope(issue)["gates"] || []
      current = binding(issue, record(settings, id))

      if Enum.any?(existing, &(&1["binding"] == current)) do
        :ok
      else
        gates =
          case reason do
            "workbench:v1\n" <> json ->
              case Jason.decode(json) do
                {:ok, %{"gates" => gates}} -> gates
                _ -> []
              end

            _ ->
              [
                %{
                  "kind" => "incident",
                  "title" => "执行报告需要诊断",
                  "reason" => "任务停止时未提供结构化的解除条件，需要维护方诊断执行记录。",
                  "repair_project" => "symphony",
                  "repair_scope" => "核对原任务 " <> id <> " 的 Beads 及 Run 记录，诊断停止原因并补齐门禁。不得增加仿真次数、放宽验收标准或自动发布。"
                }
              ]
          end

        case request(settings, id, gates, "scheduler") do
          {:ok, _} -> :ok
          error -> error
        end
      end
    end
  end

  @doc "Only an applied operator receipt can authorize exact clean-head publication."
  @spec publication_authority(map(), String.t()) :: map() | nil
  def publication_authority(settings, id) do
    with {:ok, issue} <- issue(settings, id) do
      (envelope(issue)["receipts"] || [])
      |> Enum.reverse()
      |> Enum.find_value(fn receipt ->
        limits = get_in(receipt, ["selected_option", "limits"]) || %{}

        if receipt["state"] == "applied" and limits["publication"] == true and
             limits["repository"] == settings.provider["review_repository"] and
             is_binary(limits["head_sha"]) and is_list(limits["paths"]) and limits["paths"] != [],
           do: limits
      end)
    else
      _ -> nil
    end
  end

  @spec request(map(), String.t(), term(), String.t()) :: {:ok, map()} | {:error, term()}
  def request(settings, id, gates, actor) when is_list(gates) and length(gates) in 1..12 do
    serial(settings, id, fn ->
      with {:ok, issue} <- issue(settings, id),
           true <- issue["status"] != "closed" || {:error, :task_closed},
           :ok <- validate_gates(gates) do
        env = envelope(issue)
        binding = binding(issue, record(settings, id))

        gates =
          Enum.map(gates, fn gate ->
            gate
            |> Map.put("id", random_id())
            |> Map.put("binding", binding)
            |> Map.put("state", "pending")
            |> Map.put("requested_at", now())
            |> Map.put("requested_by", actor)
            |> Map.put("binding_issue_id", id)
          end)

        with :ok <- persist(settings, issue, Map.merge(env, %{"gates" => gates})) do
          {:ok, present(settings, Map.put(issue, "metadata", Map.put(issue["metadata"] || %{}, "symphony_workbench", Map.put(env, "gates", gates))))}
        end
      else
        false -> {:error, :invalid_request}
        error -> error
      end
    end)
  end

  def request(_, _, _, _), do: {:error, :invalid_gates}

  @spec decide(map(), String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def decide(settings, id, gate_id, params) do
    serial(settings, id, fn ->
      with {:ok, issue} <- issue(settings, id),
           env <- envelope(issue),
           gate when is_map(gate) <- Enum.find(env["gates"] || [], &(&1["id"] == gate_id)),
           true <- gate["binding"] == params["binding"] || {:error, :stale_action},
           actor when is_binary(actor) and byte_size(actor) in 1..128 <- params["actor"] do
        previous = Enum.find(env["receipts"] || [], &(&1["gate_id"] == gate_id))

        cond do
          previous && previous["choice"] != params["choice"] ->
            {:error, :already_decided}

          previous && previous["state"] == "applied" ->
            {:ok, previous}

          gate["binding"] != binding(issue, record(settings, id)) ->
            {:error, :stale_action}

          previous ->
            apply_receipt(settings, issue, env, gate, previous)

          gate["state"] != "pending" ->
            {:error, :action_not_pending}

          true ->
            with {:ok, receipt} <- validate_decision(gate, params, actor),
                 env <- Map.put(env, "receipts", Enum.take((env["receipts"] || []) ++ [receipt], -100)),
                 :ok <- persist(settings, issue, env) do
              apply_receipt(settings, issue, env, gate, receipt)
            end
        end
      else
        nil -> {:error, :action_not_found}
        {:error, _} = error -> error
        _ -> {:error, :invalid_decision}
      end
    end)
  end

  defp validate_decision(gate, params, actor) do
    choice = params["choice"]

    allowed =
      case gate["kind"] do
        type when type in ["authorization", "decision"] -> Enum.map(gate["options"] || [], & &1["id"])
        "review" -> ["accept", "revise"]
        "incident" -> ["start_repair"]
        _ -> []
      end

    if choice in allowed do
      selected = Enum.find(gate["options"] || [], &(&1["id"] == choice))

      {:ok,
       %{
         "gate_id" => gate["id"],
         "choice" => choice,
         "actor" => actor,
         "selected_option" => selected,
         "decided_at" => now(),
         "state" => "recorded",
         "comment" => String.slice(to_string(params["comment"] || ""), 0, 4000)
       }}
    else
      {:error, :invalid_choice}
    end
  end

  defp apply_receipt(_settings, _issue, _env, _gate, %{"state" => "applied"} = receipt), do: {:ok, receipt}

  defp apply_receipt(settings, issue, env, gate, receipt) do
    result =
      case {gate["kind"], receipt["choice"]} do
        {"incident", "start_repair"} -> start_repair(settings, issue, gate)
        {"review", "accept"} -> accept(settings, issue, gate, receipt["actor"])
        {"review", "revise"} -> {:ok, %{}}
        {type, _} when type in ["authorization", "decision"] -> {:ok, %{}}
        _ -> {:error, :unsupported_action}
      end

    with {:ok, extra} <- result,
         updated_gate <- Map.merge(gate, if(gate["kind"] == "incident", do: %{"state" => "waiting_repair", "repair" => extra}, else: %{"state" => "resolved"})),
         applied <- receipt |> Map.merge(extra) |> Map.put("state", "applied") |> Map.put("applied_at", now()),
         env <-
           env
           |> Map.put("gates", Enum.map(env["gates"], &if(&1["id"] == gate["id"], do: updated_gate, else: &1)))
           |> Map.put("receipts", Enum.map(env["receipts"], &if(&1["gate_id"] == gate["id"], do: applied, else: &1))),
         {:ok, current} <- issue(settings, issue["id"]),
         :ok <- persist(settings, current, env) do
      if gate["kind"] in ["authorization", "decision"] or receipt["choice"] == "revise" do
        Adapter.command(settings, ["update", issue["id"], "--append-notes", "Operator workbench decision (applies only to this bound request): " <> Jason.encode!(applied), "--json"])
      end

      continuation = maybe_resume(settings, issue["id"])
      {:ok, Map.put(applied, "continuation", if(continuation == :ok, do: "reconciled", else: "needs_repair"))}
    end
  end

  @spec preflight_failure(map(), String.t(), term()) :: :ok | {:error, term()}
  def preflight_failure(settings, id, reason) do
    directory = RunJournal.directory(Adapter.journal_root(settings), id)

    with {:ok, issue} <- issue(settings, id),
         true <- issue["status"] == "open" and issue["assignee"] in [nil, ""],
         {:ok, nil} <- RunJournal.read(directory),
         false <- File.exists?(Path.join(directory, "executor.lock")),
         {:ok, _} <-
           Adapter.command(settings, [
             "update",
             id,
             "--if-status",
             "open",
             "--if-assignee",
             "",
             "--status",
             "blocked",
             "--set-metadata",
             "workbench_preflight_failed=true",
             "--set-metadata",
             "symphony_gate=blocked",
             "--append-notes",
             "Pre-session scheduler failure: " <> inspect(reason),
             "--json"
           ]),
         {:ok, _} <-
           request(
             settings,
             id,
             [
               %{
                 "kind" => "incident",
                 "title" => "调度启动失败",
                 "reason" => "任务在创建原生会话前失败，尚未开始开发或仿真。需要维护方修复启动条件。",
                 "repair_project" => "symphony",
                 "repair_scope" => "诊断任务 " <> id <> " 的调度前置检查失败，读取原始记录并修复配置或接口。当前没有原生执行身份，不得虚构会话或直接改为完成。"
               }
             ],
             "scheduler"
           ) do
      :ok
    else
      {:error, _} = error -> error
      _ -> :ok
    end
  end

  @spec maybe_resume(map(), String.t()) :: :ok | {:error, term()}
  def maybe_resume(settings, id) do
    with {:ok, issue} <- issue(settings, id),
         true <- issue["status"] == "blocked",
         gates when gates != [] <- envelope(issue)["gates"],
         true <- Enum.all?(gates, &satisfied?(settings, &1)),
         record <- record(settings, id),
         true <- Enum.all?(gates, &(&1["binding"] == binding(issue, record))),
         :ok <- release_resolved_external_edges(settings, id, gates),
         true <- if(record == %{}, do: resume_unstarted(settings, issue), else: true),
         true <- record["native_stop_confirmed"] != false,
         false <- File.exists?(Path.join(record["directory"], "executor.lock")) do
      case Recovery.resume_online(settings, id) do
        :ok ->
          :ok

        {:error, reason} = error ->
          incident = %{
            "id" => random_id(),
            "kind" => "incident",
            "title" => "原任务未能安全恢复",
            "reason" => "决策已记录，但原生执行对账未通过；需要修复后继续，系统不会重复启动旧执行。",
            "repair_project" => "symphony",
            "repair_scope" => "诊断任务 " <> id <> " 的恢复失败 " <> inspect(reason) <> "。保留原执行身份与已记录决策，禁止盲目重试。",
            "binding" => binding(issue, record),
            "state" => "pending",
            "requested_at" => now()
          }

          env = envelope(issue)
          persist(settings, issue, Map.put(env, "gates", gates ++ [incident]))
          error
      end
    else
      _ -> :ok
    end
  end

  defp resume_unstarted(settings, issue) do
    if get_in(issue, ["metadata", "workbench_preflight_failed"]) in [true, "true"] and
         RunJournal.read(RunJournal.directory(Adapter.journal_root(settings), issue["id"])) == {:ok, nil} do
      Adapter.command(settings, ["update", issue["id"], "--if-status", "blocked", "--if-assignee", "", "--status", "open", "--remove-label", "human", "--set-metadata", "symphony_gate=ready", "--json"])
    end

    false
  end

  defp release_resolved_external_edges(settings, id, gates) do
    # Cross-store marker edges cannot resolve through bd's local database alone.
    for gate <- gates, gate["kind"] == "dependency", ref <- gate["depends_on"] || [], String.contains?(ref, ":") do
      if dependency_closed?(settings, ref) do
        Adapter.command(settings, ["dep", "remove", id, "external:" <> ref, "--json"])
      end
    end

    :ok
  end

  @spec reconcile(map(), map()) :: :ok | {:error, term()}
  def reconcile(settings, issue) do
    serial(settings, issue["id"], fn -> maybe_resume(settings, issue["id"]) end)
  end

  defp satisfied?(_settings, %{"state" => "resolved"}), do: true

  defp satisfied?(settings, %{"kind" => "dependency", "depends_on" => ids}) when is_list(ids) and ids != [] do
    Enum.all?(ids, &dependency_closed?(settings, &1))
  end

  defp satisfied?(settings, %{"state" => "waiting_repair", "repair" => %{"project" => project, "id" => id}}) do
    dependency_closed?(settings, project <> ":" <> id)
  end

  defp satisfied?(_, _), do: false

  defp dependency_closed?(settings, reference) do
    case String.split(reference, ":", parts: 2) do
      [id] ->
        match?({:ok, %{"status" => "closed"}}, issue(settings, id))

      [project, id] ->
        case get_in(settings.provider, ["workbench_projects", project]) do
          %{"beads_dir" => directory} -> match?({:ok, %{"status" => "closed"}}, issue(target_settings(settings, directory), id))
          _ -> false
        end
    end
  end

  defp start_repair(settings, issue, gate) do
    project = gate["repair_project"]

    with %{"beads_dir" => directory, "label" => label, "prefix" => prefix} <- get_in(settings.provider, ["workbench_projects", project]),
         true <- (is_binary(gate["repair_scope"]) and gate["repair_scope"] != "") || {:error, :missing_repair_scope} do
      target = target_settings(settings, directory)
      id = prefix <> "-wb-" <> String.slice(digest(gate["incident_key"] || gate["id"]), 0, 12)

      case issue(target, id) do
        {:ok, _} ->
          {:ok, %{"project" => project, "id" => id}}

        _ ->
          description =
            "User authorized repair from workbench gate #{gate["id"]}, originating task #{issue["id"]}.\n" <>
              gate["reason"] <>
              "\nRepair scope: " <>
              gate["repair_scope"] <>
              "\nPreserve unrelated edits. Continue until validated repair delivery or a concrete blocker. No implicit publication, merge, acceptance or additional simulation authority."

          case Adapter.command(target, [
                 "create",
                 "--id",
                 id,
                 "--title",
                 "修复：" <> gate["title"],
                 "--description",
                 description,
                 "--acceptance",
                 "修复限定故障并验证解除条件，提供复现/修复结果与具体交付；不自动关闭、合并或增加仿真授权。",
                 "--type",
                 "bug",
                 "--priority",
                 "1",
                 "--labels",
                 label,
                 "--metadata",
                 Jason.encode!(%{
                   "workbench_origin" => %{"issue_id" => issue["id"], "gate_id" => gate["id"]},
                   "rapid_development" => true
                 }),
                 "--json"
               ]) do
            {:ok, _} -> {:ok, %{"project" => project, "id" => id}}
            error -> error
          end
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :repair_project_not_configured}
    end
  end

  defp accept(settings, issue, gate, actor) do
    cond do
      is_binary(gate["review_url"]) ->
        case Acceptance.accept(settings, issue["id"], gate["review_url"], actor) do
          :ok -> {:ok, %{}}
          error -> error
        end

      gate["delivery_kind"] == "local" ->
        accept_local(settings, issue, gate, actor)

      true ->
        {:error, :missing_delivery}
    end
  end

  defp accept_local(settings, issue, gate, actor) do
    record = record(settings, issue["id"])
    workspace = record["workspace"] || gate["workspace"]

    with true <- not File.exists?(Path.join(record["directory"] || RunJournal.directory(Adapter.journal_root(settings), issue["id"]), "executor.lock")) || {:error, :executor_active},
         true <- (is_binary(workspace) and is_binary(gate["head_sha"])) || {:error, :missing_delivery_identity},
         {head, 0} <- System.cmd("git", ["-C", workspace, "rev-parse", "--verify", "--end-of-options", (gate["delivery_ref"] || "HEAD") <> "^{commit}"], stderr_to_stdout: false),
         true <- String.trim(head) == gate["head_sha"] || {:error, :delivery_changed},
         {:ok, bytes} <- artifact(settings, gate),
         true <- digest(bytes) == gate["artifact_sha256"] || {:error, :delivery_changed},
         {:ok, _} <-
           Adapter.command(settings, [
             "update",
             issue["id"],
             "--if-status",
             issue["status"],
             "--if-assignee",
             issue["assignee"] || "",
             "--status",
             issue["status"],
             "--remove-label",
             "human",
             "--set-metadata",
             "symphony_gate=local_accepted",
             "--set-metadata",
             "symphony_accepted_by=" <> actor,
             "--append-notes",
             "Operator accepted exact local delivery " <>
               gate["head_sha"] <> "; technical local review only, not task closure or remote merge. Continue remaining authorized delivery gates; do not repeat this accepted review.",
             "--json"
           ]) do
      {:ok, %{}}
    else
      {:error, _} = error -> error
      _ -> {:error, :local_delivery_verification_failed}
    end
  end

  @spec artifact(map(), map()) :: {:ok, binary()} | {:error, term()}
  def artifact(settings, gate) do
    path = gate["artifact_path"]
    roots = settings.provider["workbench_artifact_roots"] || []

    with true <- is_binary(path),
         path <- Path.expand(path),
         true <- Enum.any?(roots, &(path != Path.expand(&1) and String.starts_with?(path, Path.expand(&1) <> "/"))),
         false <- symlink_parent?(path),
         {:ok, %{type: :regular, size: size}} when size <= 524_288 <- File.stat(path),
         {:ok, bytes} <- File.read(path) do
      {:ok, bytes}
    else
      _ -> {:error, :artifact_unavailable}
    end
  end

  defp symlink_parent?("/"), do: false

  defp symlink_parent?(path) do
    case File.lstat(path) do
      {:ok, %{type: :symlink}} -> true
      {:ok, _} -> symlink_parent?(Path.dirname(path))
      _ -> true
    end
  end

  @spec get_artifact(map(), String.t(), String.t()) :: {:ok, binary()} | {:error, term()}
  def get_artifact(settings, id, gate_id) do
    with {:ok, issue} <- issue(settings, id),
         gate when is_map(gate) <- Enum.find(envelope(issue)["gates"] || [], &(&1["id"] == gate_id)),
         {:ok, bytes} <- artifact(settings, gate),
         true <- digest(bytes) == gate["artifact_sha256"] || {:error, :delivery_changed} do
      {:ok, bytes}
    else
      {:error, _} = error -> error
      _ -> {:error, :artifact_unavailable}
    end
  end

  @spec validate_request(term()) :: :ok | {:error, term()}
  def validate_request(gates) when is_list(gates) and length(gates) in 1..12, do: validate_gates(gates)
  def validate_request(_), do: {:error, :invalid_gates}

  defp validate_gates(gates) do
    valid =
      Enum.all?(gates, fn gate ->
        is_map(gate) and gate["kind"] in @kinds and text?(gate["title"], 160) and text?(gate["reason"], 4000) and
          (gate["kind"] not in ["authorization", "decision"] or valid_options?(gate["options"])) and
          (gate["kind"] != "dependency" or (is_list(gate["depends_on"]) and gate["depends_on"] != [] and Enum.all?(gate["depends_on"], &text?(&1, 160)))) and
          (gate["kind"] != "review" or
             (text?(gate["head_sha"], 64) and
                (text?(gate["review_url"], 1000) or
                   (gate["delivery_kind"] == "local" and text?(gate["artifact_path"], 2000) and text?(gate["artifact_sha256"], 64)))))
      end)

    if valid and byte_size(Jason.encode!(gates)) <= 65536, do: :ok, else: {:error, :invalid_gates}
  end

  defp valid_options?(options) when is_list(options) and length(options) in 1..8 do
    Enum.all?(options, &(is_map(&1) and text?(&1["id"], 80) and text?(&1["label"], 160) and text?(&1["description"], 4000))) and
      length(Enum.uniq_by(options, & &1["id"])) == length(options)
  end

  defp valid_options?(_), do: false
  defp text?(value, limit), do: is_binary(value) and byte_size(value) in 1..limit
  defp target_settings(settings, directory), do: Map.update!(settings, :provider, &Map.put(&1, "beads_dir", directory))

  defp issue(settings, id) do
    if is_binary(id) and Regex.match?(~r/^[A-Za-z0-9_.:-]{1,160}$/, id) do
      case Adapter.command(settings, ["show", id, "--json"]) do
        {:ok, [issue]} -> {:ok, issue}
        error -> error
      end
    else
      {:error, :invalid_issue_id}
    end
  end

  defp record(settings, id) do
    case RunJournal.read(RunJournal.directory(Adapter.journal_root(settings), id)) do
      {:ok, %{} = record} -> record
      _ -> %{}
    end
  end

  defp binding(issue, record) do
    digest(
      Jason.encode!([
        issue["id"],
        issue["status"],
        issue["assignee"],
        issue["description"],
        issue["acceptance_criteria"],
        record["attempt_id"],
        record["blocker_reason"] || record["handoff_reason"],
        get_in(record, ["delivery", "head_sha"])
      ])
    )
  end

  defp persist(settings, issue, envelope) do
    case Adapter.command(settings, [
           "update",
           issue["id"],
           "--if-status",
           issue["status"],
           "--if-assignee",
           issue["assignee"] || "",
           "--status",
           issue["status"],
           "--set-metadata",
           "symphony_workbench=" <> Jason.encode!(envelope),
           "--json"
         ]) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp serial(settings, id, operation), do: :global.trans({{__MODULE__, Adapter.beads_dir(settings), id}, self()}, operation)
  defp random_id, do: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  defp now, do: DateTime.to_iso8601(DateTime.utc_now())
end
