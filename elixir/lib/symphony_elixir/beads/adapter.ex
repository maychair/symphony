defmodule SymphonyElixir.Beads.Adapter do
  @moduledoc """
  Local Beads CLI adapter. Task routing uses `bd ready`; execution uses guarded
  claims and a separate durable journal. Only an explicit operator command accepts
  delivery. Agent tools can request human review but cannot merge or close tasks.
  """
  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Beads.{Acceptance, Brief, Delivery, Publication, RunJournal, SourceIssue, Validation}
  alias SymphonyElixir.{Config, Tracker.Issue, Workflow}

  @impl true
  def validate_config(settings) do
    cond do
      settings.provider["goal_mode"] not in [nil, true, false] -> {:error, :invalid_goal_mode}
      not (is_integer(settings.provider["run_budget_ms"] || 600_000) and (settings.provider["run_budget_ms"] || 600_000) > 0) -> {:error, :invalid_run_budget}
      settings.required_labels == [] or "" in settings.required_labels -> {:error, :beads_requires_routing_labels}
      not absolute_directory?(beads_dir(settings)) -> {:error, :beads_requires_absolute_beads_dir}
      not absolute_directory?(journal_root(settings)) -> {:error, :beads_requires_absolute_journal_dir}
      settings.active_states != ["open", "in_progress"] -> {:error, :beads_active_states_must_exclude_human_gate}
      settings.terminal_states != ["closed"] -> {:error, :beads_terminal_states_must_be_closed}
      true -> :ok
    end
  end

  @impl true
  def secret_environment_names(_settings), do: []

  @impl true
  def fetch_issues_by_states([]), do: {:ok, []}

  def fetch_issues_by_states(states) do
    settings = Config.settings!().tracker

    with {:ok, records} <- read_records(settings, ["list", "--all", "--limit", "0", "--json"]),
         {:ok, ready} <- read_records(settings, ["ready", "--limit", "0", "--json"]),
         {:ok, blocked} <- read_records(settings, ["blocked", "--json"]) do
      readiness = readiness(ready, blocked)
      {:ok, records |> Enum.filter(&(&1["status"] in states)) |> Enum.map(&normalize(&1, readiness))}
    end
  end

  @impl true
  def fetch_issues_by_ids([]), do: {:ok, []}

  def fetch_issues_by_ids(ids) do
    settings = Config.settings!().tracker

    with {:ok, ready} <- read_records(settings, ["ready", "--limit", "0", "--json"]),
         {:ok, blocked} <- read_records(settings, ["blocked", "--json"]) do
      readiness = readiness(ready, blocked)
      Enum.reduce_while(ids, {:ok, []}, &fetch_one(settings, &1, &2, readiness))
    end
  end

  defp fetch_one(settings, id, {:ok, issues}, ready_ids) do
    case read_records(settings, ["show", id, "--json"]) do
      {:ok, records} -> {:cont, {:ok, issues ++ Enum.map(records, &normalize(&1, ready_ids))}}
      error -> {:halt, error}
    end
  end

  @impl true
  def prepare_run(%Issue{} = issue, opts) do
    settings = freeze_settings(Config.settings!().tracker)
    opts = Keyword.put(opts, :workflow_snapshot, Workflow.current())
    scope = %{"beads_dir" => beads_dir(settings), "provider_dir" => settings.provider["dir"]}

    with true <- is_nil(opts[:worker_host]) || {:error, :beads_requires_local_executor},
         :ok <- source_ready(settings, issue),
         {:ok, policy} <- Validation.policy(settings, issue),
         {:ok, prompt} <- preflight(settings, issue, opts, policy),
         {:ok, record} <- RunJournal.admit(journal_root(settings), issue.id),
         true <- record["beads_dir"] in [nil, beads_dir(settings)] || {:error, :run_scope_mismatch},
         {:ok, record} <- RunJournal.checkpoint(record, scope |> Map.put("validation_policy", policy) |> Map.put("brief_template_hash", Brief.template_hash(opts[:workflow_snapshot]))),
         :ok <- claim(settings, issue, record),
         {:ok, record} <- RunJournal.checkpoint(record, %{"phase" => "claimed"}) do
      native_ref =
        (issue.native_ref || %{})
        |> Map.put("beads_dir", beads_dir(settings))
        |> Map.put("run_directory", record["directory"])
        |> Map.put("validation_policy", policy)

      prepared = %{issue | assignee_id: record["owner"], state: "in_progress", native_ref: native_ref}
      tracker = %{settings | provider: Map.put(settings.provider, "beads_dir", beads_dir(settings))}
      {:ok, prepared, opts |> Keyword.put(:prepared_prompt, prompt) |> Keyword.put(:run_record, record) |> Keyword.put(:tracker_settings, tracker)}
    end
  end

  @impl true
  def finish_run(issue, opts, result) do
    case opts[:run_record] do
      %{} = record ->
        settings = opts[:tracker_settings]
        current = latest_record(record)
        phase = if is_nil(current["delivery"]), do: "blocked", else: "awaiting_human"
        reason = current["blocker_reason"] || "Run ended without a delivery: #{inspect(result)}. Inspect native session evidence before resuming."

        with :ok <- finish_delivery(settings, issue.id, current, phase, reason) do
          if current["native_stop_confirmed"] == false do
            case RunJournal.checkpoint(latest_record(current), %{"phase" => phase}) do
              {:ok, _} -> :ok
              error -> error
            end
          else
            RunJournal.complete(latest_record(current), phase)
          end
        end

      _ ->
        :ok
    end
  end

  @spec preflight(map(), Issue.t(), keyword(), map()) :: {:ok, String.t()} | {:error, term()}
  def preflight(settings, issue, opts, policy) do
    executable = settings.provider["bin"] || "bd"
    prepared = %{issue | native_ref: Map.put(issue.native_ref || %{}, "validation_policy", policy)}
    host_enabled = settings.provider["allow_host_validation"] == true
    timeout_available = not is_nil(System.find_executable("timeout"))
    codex = Config.settings!().codex.command |> String.split() |> List.first()

    with true <- not is_nil(System.find_executable(executable)) || {:error, :beads_executable_missing},
         true <- (policy["commands"] == [] or host_enabled) || {:error, :host_validation_not_enabled},
         true <- (policy["commands"] == [] or timeout_available) || {:error, :validation_timeout_missing},
         true <- not is_nil(System.find_executable(codex)) || {:error, :codex_executable_missing} do
      with :ok <- unchanged_policy(settings, issue, policy) do
        {:ok, Brief.render(settings, prepared, opts) <> policy_prompt(policy)}
      end
    end
  rescue
    _ -> {:error, :prompt_preflight_failed}
  end

  defp policy_prompt(policy) do
    "\nFrozen validation policy: " <>
      Jason.encode!(policy) <>
      "\nUse beads_task_context for current task reads. Call beads_deliver for guarded checkpoint/validation/publication/review handoff; granular tools remain available." <>
      " A review value of none selects direct development without subagents or internal review. This never grants merge authority." <>
      " For preparation blockers use beads_await_human with intent: blocked and a concrete release condition; beads_block remains a compatible alias."
  end

  defp unchanged_policy(settings, issue, policy) do
    directory = RunJournal.directory(journal_root(settings), issue.id)

    case RunJournal.read(directory) do
      {:ok, %{"thread_id" => thread} = previous} when is_binary(thread) ->
        old = previous["validation_policy"]

        if old == policy or (is_nil(old) and policy["commands"] == []),
          do: :ok,
          else: {:error, :validation_policy_changed_for_existing_thread}

      {:ok, _} ->
        :ok

      error ->
        error
    end
  end

  defp source_ready(settings, issue) do
    reference = issue.native_ref["external_ref"]
    if settings.provider["remote_reconcile"] == true and reference not in [nil, ""] do
      case SourceIssue.read(settings, reference) do
        {:ok, %{closed: false}} -> :ok
        {:ok, %{closed: true}} -> {:error, :source_issue_closed}
        error -> error
      end
    else
      :ok
    end
  end

  defp latest_record(record) do
    case RunJournal.read(record["directory"]) do
      {:ok, %{} = current} -> current
      _ -> record
    end
  end

  @impl true
  def agent_environment(settings), do: %{"BEADS_DIR" => beads_dir(settings)}

  @impl true
  def agent_tool_specs do
    [
      %{
        "name" => "beads_task_context",
        "description" => "Read only this owned task from the host, including current notes and frozen validation policy. No database sandbox write access needed.",
        "inputSchema" => %{"type" => "object", "properties" => %{}, "additionalProperties" => false}
      },
      %{
        "name" => "beads_validate",
        "description" => "Execute the frozen, explicitly enabled host validation commands on the clean committed task worktree. Returns process exit codes; never accepts or merges.",
        "inputSchema" => %{"type" => "object", "properties" => %{}, "additionalProperties" => false}
      },
      %{
        "name" => "beads_deliver",
        "description" =>
          "Checkpoint configured paths, execute/reuse current verification, publish and park for configured review/acceptance. Journals each stage; repeated completed delivery is idempotent. Never merges.",
        "inputSchema" => %{"type" => "object", "properties" => %{}, "additionalProperties" => false}
      },
      %{
        "name" => "beads_checkpoint",
        "description" =>
          "Commit only configured authorized task paths on the host before validation. Requires symphony:checkpoint plus checkpoint_paths, or existing publication authority. Never pushes, opens reviews or merges.",
        "inputSchema" => %{"type" => "object", "properties" => %{}, "additionalProperties" => false}
      },
      %{
        "name" => "beads_publish",
        "description" => "Publish only pre-authorized configured paths to a task-branch PR. Requires symphony:publish label. Never merges. Returns review_url/head_sha.",
        "inputSchema" => %{"type" => "object", "properties" => %{}, "additionalProperties" => false}
      },
      %{
        "name" => "beads_request_action",
        "description" => "Park this task with structured workbench gates. Kinds: authorization/decision (exact options and limits), review (exact delivery identity and review URL or local artifact), incident (repair project and bounded scope), dependency (task references). Never infer authorization from old notes. Do not label resource queue waiting as a gate.",
        "inputSchema" => %{"type" => "object", "properties" => %{
          "reason" => %{"type" => "string"},
          "gates" => %{"type" => "array", "minItems" => 1, "maxItems" => 12, "items" => %{"type" => "object"}}
        }, "required" => ["reason", "gates"], "additionalProperties" => false}
      },
      %{
        "name" => "beads_block",
        "description" => "Park an undelivered task with a concrete preparation blocker and release condition. Resumable by the operator; never requests delivery acceptance.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{"reason" => %{"type" => "string"}},
          "required" => ["reason"],
          "additionalProperties" => false
        }
      },
      %{
        "name" => "beads_await_human",
        "description" =>
          "Request acceptance of a delivered review. Requires review_url and head_sha (or configured host publication). Use intent: blocked and a reason for preparation blockers; reason-only calls remain compatible. Never merges or closes.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "intent" => %{"type" => "string", "enum" => ["blocked", "ready_for_review"]},
            "reason" => %{"type" => "string"},
            "review_url" => %{"type" => "string"},
            "head_sha" => %{"type" => "string"}
          },
          "required" => ["reason"],
          "additionalProperties" => false
        }
      }
    ]
  end

  @impl true
  def execute_agent_tool("beads_task_context", arguments, opts) when arguments == %{} do
    issue = opts[:issue]
    settings = opts[:tracker_settings]

    with {:ok, record} <- Validation.owned_record(settings, issue),
         {:ok, [current]} <- command(settings, ["show", issue.id, "--json"]),
         true <- (current["assignee"] == issue.assignee_id and current["status"] == "in_progress") || {:error, :not_owned_by_symphony} do
      fields = Map.take(current, ["id", "title", "description", "design", "acceptance_criteria", "notes", "status", "updated_at", "external_ref", "metadata"])
      metadata = Map.delete(fields["metadata"] || %{}, "symphony_validation")
      payload = fields |> Map.put("metadata", metadata) |> Map.put("task_version", Brief.version(fields))
      payload = Map.merge(payload, %{"validation_policy" => record["validation_policy"], "attempt_id" => record["attempt_id"]})
      if byte_size(Jason.encode!(payload)) <= 65_536, do: tool_result_payload(payload), else: tool_result({:error, :task_context_too_large})
    else
      error -> tool_result(error)
    end
  end

  def execute_agent_tool("beads_validate", arguments, opts) when arguments == %{} do
    case Validation.run(opts[:tracker_settings], opts[:issue]) do
      {:ok, receipt} -> tool_result_payload(receipt)
      error -> tool_result(error)
    end
  end

  def execute_agent_tool("beads_block", %{"reason" => reason} = arguments, opts)
      when is_binary(reason) and map_size(arguments) == 1 do
    execute_agent_tool("beads_await_human", Map.put(arguments, "intent", "blocked"), opts)
  end

  # Compatibility for existing agents: a reason alone describes an undelivered blocker.
  def execute_agent_tool("beads_await_human", %{"reason" => reason} = arguments, opts)
      when is_binary(reason) and map_size(arguments) == 1 do
    execute_agent_tool("beads_block", arguments, opts)
  end

  def execute_agent_tool("beads_await_human", %{"reason" => reason} = arguments, opts) when is_binary(reason) do
    issue = opts[:issue]
    settings = opts[:tracker_settings]

    result =
      with true <- String.trim(reason) != "" || {:error, :blocker_reason_required},
           :ok <- validate_handoff(arguments),
           {:ok, [record]} <- command(settings, ["show", issue.id, "--json"]),
           true <- record["assignee"] == issue.assignee_id and is_binary(issue.assignee_id),
           {:ok, arguments} <- publish_on_handoff(settings, issue, arguments),
           :ok <- record_delivery(settings, issue, arguments),
           :ok <- checkpoint_handoff(issue, arguments) do
        finish_handoff(settings, issue, arguments)
      else
        {:error, _} = error -> error
        _ -> {:error, :not_owned_by_symphony}
      end

    tool_result(result)
  end

  def execute_agent_tool("beads_request_action", %{"reason" => reason, "gates" => gates}, opts) when is_binary(reason) do
    issue = opts[:issue]
    settings = opts[:tracker_settings]
    result = with {:ok, [current]} <- command(settings, ["show", issue.id, "--json"]),
         true <- current["assignee"] == issue.assignee_id || {:error, :not_owned_by_symphony},
         {:ok, record} <- RunJournal.read(issue.native_ref["run_directory"]),
         :ok <- SymphonyElixir.Beads.Workbench.validate_request(gates),
         :ok <- block_undelivered(settings, issue.id, record, reason),
         {:ok, result} <- SymphonyElixir.Beads.Workbench.request(settings, issue.id, gates, issue.assignee_id) do
      {:ok, result}
    end
    case result do
      {:ok, result} -> tool_result_payload(result)
      error -> tool_result(error)
    end
  end

  def execute_agent_tool("beads_deliver", arguments, opts) when arguments == %{} do
    case Delivery.run(opts) do
      {:ok, result} -> tool_result_payload(result)
      error -> tool_result(error)
    end
  end

  def execute_agent_tool("beads_checkpoint", arguments, opts) when arguments == %{} do
    case Publication.checkpoint(opts[:tracker_settings], opts[:issue]) do
      {:ok, result} -> tool_result_payload(result)
      error -> tool_result(error)
    end
  end

  def execute_agent_tool("beads_publish", %{} = arguments, opts) when map_size(arguments) == 0 do
    case Publication.publish(opts[:tracker_settings], opts[:issue]) do
      {:ok, delivery} -> tool_result_payload(delivery)
      error -> tool_result(error)
    end
  end

  def execute_agent_tool(_tool, _arguments, _opts), do: tool_result({:error, :unsupported_tool})

  @spec validate_handoff(map()) :: :ok | {:error, term()}
  def validate_handoff(arguments) do
    intent = arguments["intent"]
    url = arguments["review_url"]
    sha = arguments["head_sha"]

    case {intent, url, sha} do
      {"blocked", nil, sha} -> checkpoint_reference(sha)
      {nil, nil, nil} -> :ok
      {mode, url, sha} when mode in [nil, "ready_for_review"] and is_binary(url) and is_binary(sha) -> :ok
      _ -> {:error, {:invalid_handoff, "blocked: reason and optional checkpoint head_sha; ready_for_review: reason, review_url and head_sha"}}
    end
  end

  defp checkpoint_reference(nil), do: :ok

  defp checkpoint_reference(sha) when is_binary(sha) do
    if String.match?(sha, ~r/^[a-fA-F0-9]{40,64}$/), do: :ok, else: {:error, :invalid_checkpoint_reference}
  end

  defp checkpoint_reference(_sha), do: {:error, :invalid_checkpoint_reference}

  defp finish_handoff(settings, issue, %{"intent" => "blocked", "reason" => reason}) do
    with {:ok, record} <- RunJournal.read(issue.native_ref["run_directory"]) do
      block_undelivered(settings, issue.id, record, reason)
    end
  end

  defp finish_handoff(settings, issue, arguments) do
    with :ok <- await_human(settings, issue.id, issue.assignee_id, arguments["reason"]),
         {:ok, _} <- SymphonyElixir.Beads.Workbench.request(settings, issue.id, [%{
           "kind" => "review", "title" => "审查已发布的交付", "reason" => "交付已发布，请到远程仓库审查；合入后由 scheduler 核验并自动推进任务。",
           "review_url" => arguments["review_url"], "head_sha" => arguments["head_sha"]
         }], issue.assignee_id) do
      :ok
    end
  end

  defp checkpoint_handoff(issue, arguments) do
    intent = arguments["intent"] || if(arguments["review_url"], do: "ready_for_review", else: "blocked")

    with {:ok, record} <- RunJournal.read(issue.native_ref["run_directory"]),
         {:ok, _} <- RunJournal.checkpoint(record, %{"handoff_intent" => intent, "handoff_reason" => arguments["reason"], "checkpoint_head_sha" => arguments["head_sha"]}) do
      :ok
    end
  end

  defp publish_on_handoff(settings, issue, arguments) do
    if settings.provider["publish_on_handoff"] == true and arguments["intent"] != "blocked" and not Map.has_key?(arguments, "review_url") do
      with {:ok, delivery} <- Publication.publish(settings, issue) do
        {:ok, Map.merge(arguments, %{"review_url" => delivery.review_url, "head_sha" => delivery.head_sha})}
      end
    else
      {:ok, arguments}
    end
  end

  defp tool_result_payload(value) do
    text = Jason.encode!(value)
    %{"success" => true, "output" => text, "contentItems" => [%{"type" => "inputText", "text" => text}]}
  end

  @spec beads_dir(map()) :: String.t() | nil
  def beads_dir(settings), do: resolve(settings.provider["beads_dir"] || System.get_env("BEADS_DIR"))

  @spec journal_root(map()) :: String.t() | nil
  def journal_root(settings) do
    resolve(settings.provider["run_journal_dir"]) ||
      if is_binary(beads_dir(settings)), do: Path.join(Path.dirname(beads_dir(settings)), "symphony-runs")
  end

  @spec command(map(), [String.t()]) :: {:ok, term()} | {:error, term()}
  def command(settings, args) do
    executable = settings.provider["bin"] || "bd"
    directory = resolve(settings.provider["dir"]) || Path.dirname(beads_dir(settings))

    task = Task.async(fn -> run_command(executable, args, directory, settings) end)

    case Task.yield(task, settings.provider["timeout_ms"] || 15_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} ->
        decode_command(output, args)

      {:ok, {:error, message}} ->
        {:error, {:beads_command_failed, message}}

      {:ok, {_output, status}} ->
        {:error, {:beads_command_failed, List.first(args), status}}

      nil ->
        {:error, :beads_command_timeout}
    end
  rescue
    error in [ErlangError, ArgumentError] -> {:error, {:beads_command_failed, Exception.message(error)}}
  end

  defp decode_command(output, args) do
    case Jason.decode(output) do
      {:ok, value} -> {:ok, value}
      {:error, _} -> {:error, {:invalid_beads_json, List.first(args)}}
    end
  end

  defp run_command(executable, args, directory, settings) do
    System.cmd(executable, ["--actor", "symphony", "--sandbox" | args], cd: directory, env: [{"BEADS_DIR", beads_dir(settings)}], stderr_to_stdout: false)
  rescue
    error in [ErlangError, ArgumentError] -> {:error, Exception.message(error)}
  end

  @spec await_human(map(), String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def await_human(settings, id, owner, reason) do
    with {:ok, [current]} <- command(settings, ["show", id, "--json"]),
         true <- current["assignee"] == owner and current["status"] in ["in_progress", "blocked"] || {:error, :not_owned_by_symphony} do
      case command(settings, [
           "update",
           id,
           "--if-assignee",
           owner,
           "--if-status",
           current["status"],
           "--status",
           "blocked",
           "--add-label",
           "human",
           "--set-metadata",
           "symphony_gate=awaiting_human",
           "--append-notes",
           "Symphony delivery: " <> reason,
           "--json"
         ]) do
      {:ok, _} -> :ok
      error -> error
      end
    end
  end

  defp record_delivery(_settings, issue, %{"intent" => "blocked"}) do
    with {:ok, record} <- RunJournal.read(issue.native_ref["run_directory"]),
         true <- record["owner"] == issue.assignee_id || {:error, :not_owned_by_symphony},
         true <- is_nil(record["delivery"]) || {:error, :delivery_already_bound} do
      :ok
    end
  end

  defp record_delivery(settings, issue, %{"review_url" => url, "head_sha" => sha}) when is_binary(url) and is_binary(sha) do
    with :ok <- Acceptance.validate_review_scope(settings, url),
         true <- String.match?(sha, ~r/^[a-fA-F0-9]{40,64}$/) || {:error, :invalid_delivery_commit},
         {:ok, record} <- RunJournal.read(issue.native_ref["run_directory"]),
         true <- record["owner"] == issue.assignee_id || {:error, :delivery_owner_mismatch},
         :ok <- Validation.gate(record),
         :ok <- Validation.delivery_head(record, sha),
         {:ok, _} <- bind_delivery(record, url, sha) do
      :ok
    end
  end

  defp record_delivery(_settings, _issue, _arguments), do: {:error, :incomplete_delivery}

  defp bind_delivery(record, url, sha) do
    delivery = %{"review_url" => url, "head_sha" => sha, "attempt_id" => record["attempt_id"], "turn_id" => record["turn_id"]}
    RunJournal.checkpoint(record, %{"delivery" => delivery})
  end

  defp freeze_settings(settings) do
    provider =
      settings.provider
      |> Map.put("review_repository", resolve(settings.provider["review_repository"]))
      |> Map.put("beads_dir", beads_dir(settings))
      |> Map.put("run_journal_dir", journal_root(settings))
      |> Map.put("dir", resolve(settings.provider["dir"]) || Path.dirname(beads_dir(settings)))

    %{settings | provider: provider}
  end

  defp read_records(settings, args) do
    case command(settings, args) do
      {:ok, records} when is_list(records) ->
        if Enum.all?(records, &is_map/1), do: {:ok, records}, else: {:error, :invalid_beads_records}

      {:ok, _} ->
        {:error, :invalid_beads_records}

      error ->
        error
    end
  end

  @spec block_undelivered(map(), String.t(), map(), String.t()) :: :ok | {:error, term()}
  def block_undelivered(settings, id, record, reason) do
    with true <- is_nil(record["delivery"]) || {:error, :delivery_already_bound},
         {:ok, [issue]} <- read_records(settings, ["show", id, "--json"]),
         true <- (issue["status"] in ["in_progress", "blocked"] and issue["assignee"] == record["owner"]) || {:error, :not_owned_by_symphony},
         {:ok, _} <-
           command(settings, [
             "update",
             id,
             "--if-assignee",
             record["owner"],
             "--if-status",
             issue["status"],
             "--status",
             "blocked",
             "--remove-label",
             "human",
             "--set-metadata",
             "symphony_gate=blocked",
             "--append-notes",
             "Symphony blocker: " <> reason,
             "--json"
           ]),
         {:ok, _} <- RunJournal.checkpoint(record, %{"blocker_reason" => reason}) do
      SymphonyElixir.Beads.Workbench.capture(settings, id, reason)
    end
  end

  defp finish_delivery(settings, id, record, "blocked", reason), do: block_undelivered(settings, id, record, reason)

  defp finish_delivery(settings, id, record, "awaiting_human", _reason) do
    with {:ok, [issue]} <- read_records(settings, ["show", id, "--json"]) do
      if issue["status"] == "blocked" and issue["assignee"] == record["owner"] and "human" in (issue["labels"] || []) and
           get_in(issue, ["metadata", "symphony_gate"]) == "awaiting_human" do
        :ok
      else
        await_human(settings, id, record["owner"], "Delivery recorded; awaiting explicit acceptance")
      end
    end
  end

  defp claim(settings, issue, record) do
    expected = if record["thread_id"] || record["pre_turn_recovered"], do: record["owner"], else: ""

    case command(settings, ["update", issue.id, "--if-assignee", expected, "--if-status", issue.state, "--assignee", record["owner"], "--status", "in_progress", "--json"]) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp readiness(ready, blocked), do: %{ready: MapSet.new(ready, & &1["id"]), blocked: MapSet.new(blocked, & &1["id"])}

  defp normalize(raw, readiness) do
    labels = Enum.map(raw["labels"] || [], &String.downcase(String.trim(&1)))
    running = raw["status"] == "in_progress" and is_binary(raw["assignee"]) and String.starts_with?(raw["assignee"], "symphony-")

    %Issue{
      id: raw["id"],
      identifier: raw["id"],
      title: raw["title"],
      state: raw["status"],
      description:
        Enum.join(Enum.filter([raw["description"], section("Design", raw["design"]), section("Acceptance criteria", raw["acceptance_criteria"]), section("Notes", raw["notes"])], &is_binary/1), "\n\n"),
      priority: if(is_integer(raw["priority"]), do: raw["priority"] + 1),
      assignee_id: raw["assignee"],
      labels: labels,
      native_ref:
        raw
        |> Map.take(["issue_type", "acceptance_criteria", "external_ref", "metadata", "notes"])
        |> Map.put("dependency_blocked", MapSet.member?(readiness.blocked, raw["id"])),
      url: raw["external_ref"],
      dispatchable: (MapSet.member?(readiness.ready, raw["id"]) or running) and not MapSet.member?(readiness.blocked, raw["id"]) and "human" not in labels,
      created_at: timestamp(raw["created_at"]),
      updated_at: timestamp(raw["updated_at"])
    }
  end

  defp timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, time, _offset} -> time
      _ -> nil
    end
  end

  defp timestamp(_value), do: nil
  defp section(_name, nil), do: nil
  defp section(name, value), do: name <> ":\n" <> value
  defp resolve("$" <> variable), do: System.get_env(variable)
  defp resolve(value), do: value
  defp absolute_directory?(value), do: is_binary(value) and value != "" and Path.type(value) == :absolute

  defp tool_result({:error, reason}) do
    error = %{"code" => tool_error_code(reason), "detail" => inspect(reason)}
    output = Jason.encode!(%{"error" => error})
    %{"success" => false, "error" => error, "output" => output, "contentItems" => [%{"type" => "inputText", "text" => output}]}
  end

  defp tool_result(result) do
    output = inspect(result)
    %{"success" => result == :ok, "output" => output, "contentItems" => [%{"type" => "inputText", "text" => output}]}
  end

  defp tool_error_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp tool_error_code(reason) when is_tuple(reason) and tuple_size(reason) > 0, do: tool_error_code(elem(reason, 0))
  defp tool_error_code(_reason), do: "operation_failed"
end
