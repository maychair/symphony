defmodule SymphonyElixir.Beads.Adapter do
  @moduledoc """
  Local Beads CLI adapter. Task routing uses `bd ready`; execution uses guarded
  claims and a separate durable journal. Only an explicit operator command accepts
  delivery. Agent tools can request human review but cannot merge or close tasks.
  """
  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Beads.{Acceptance, Publication, RunJournal, SourceIssue}
  alias SymphonyElixir.{Config, Tracker.Issue}

  @impl true
  def validate_config(settings) do
    cond do
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

    with true <- is_nil(opts[:worker_host]) || {:error, :beads_requires_local_executor},
         :ok <- source_ready(settings, issue),
         {:ok, record} <- RunJournal.admit(journal_root(settings), issue.id),
         true <- record["beads_dir"] in [nil, beads_dir(settings)] || {:error, :run_scope_mismatch},
         {:ok, record} <- RunJournal.checkpoint(record, %{"beads_dir" => beads_dir(settings), "provider_dir" => settings.provider["dir"]}),
         :ok <- claim(settings, issue, record),
         {:ok, record} <- RunJournal.checkpoint(record, %{"phase" => "claimed"}) do
      {:ok,
       %{
         issue
         | assignee_id: record["owner"],
           state: "in_progress",
           native_ref: (issue.native_ref || %{}) |> Map.put("beads_dir", beads_dir(settings)) |> Map.put("run_directory", record["directory"])
       }, opts |> Keyword.put(:run_record, record) |> Keyword.put(:tracker_settings, %{settings | provider: Map.put(settings.provider, "beads_dir", beads_dir(settings))})}
    end
  end

  @impl true
  def finish_run(issue, opts, result) do
    case opts[:run_record] do
      %{} = record ->
        settings = opts[:tracker_settings]
        # A bounded run or approval/error is delivery evidence, never acceptance.
        with :ok <- finish_delivery(settings, issue.id, record["owner"], result) do
          current = latest_record(record)

          RunJournal.complete(current, "awaiting_human")
        end

      _ ->
        :ok
    end
  end

  defp source_ready(settings, issue) do
    if settings.provider["remote_reconcile"] == true do
      case SourceIssue.read(settings, issue.native_ref["external_ref"] || "") do
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
        "name" => "beads_publish",
        "description" => "Publish only pre-authorized configured paths to a task-branch PR. Requires symphony:publish label. Never merges. Returns review_url/head_sha.",
        "inputSchema" => %{"type" => "object", "properties" => %{}, "additionalProperties" => false}
      },
      %{
        "name" => "beads_await_human",
        "description" => "Park this issue for explicit human review. Does not merge or close it.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{"reason" => %{"type" => "string"}, "review_url" => %{"type" => "string"}, "head_sha" => %{"type" => "string"}},
          "required" => ["reason"],
          "additionalProperties" => false
        }
      }
    ]
  end

  @impl true
  def execute_agent_tool("beads_await_human", %{"reason" => reason} = arguments, opts) when is_binary(reason) do
    issue = opts[:issue]
    settings = opts[:tracker_settings]

    result =
      with {:ok, [record]} <- command(settings, ["show", issue.id, "--json"]),
           true <- record["assignee"] == issue.assignee_id and is_binary(issue.assignee_id),
           {:ok, arguments} <- publish_on_handoff(settings, issue, arguments),
           :ok <- record_delivery(settings, issue, arguments) do
        await_human(settings, issue.id, record["assignee"], reason)
      else
        {:error, _} = error -> error
        _ -> {:error, :not_owned_by_symphony}
      end

    tool_result(result)
  end

  def execute_agent_tool("beads_publish", %{} = arguments, opts) when map_size(arguments) == 0 do
    case Publication.publish(opts[:tracker_settings], opts[:issue]) do
      {:ok, delivery} -> tool_result_payload(delivery)
      error -> tool_result(error)
    end
  end

  def execute_agent_tool(_tool, _arguments, _opts), do: tool_result({:error, :unsupported_tool})

  defp publish_on_handoff(settings, issue, arguments) do
    if settings.provider["publish_on_handoff"] == true and not Map.has_key?(arguments, "review_url") do
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
        case Jason.decode(output) do
          {:ok, value} -> {:ok, value}
          {:error, _} -> {:error, {:invalid_beads_json, List.first(args)}}
        end

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

  defp run_command(executable, args, directory, settings) do
    System.cmd(executable, ["--actor", "symphony", "--sandbox" | args], cd: directory, env: [{"BEADS_DIR", beads_dir(settings)}], stderr_to_stdout: false)
  rescue
    error in [ErlangError, ArgumentError] -> {:error, Exception.message(error)}
  end

  @spec await_human(map(), String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def await_human(settings, id, owner, reason) do
    case command(settings, [
           "update",
           id,
           "--if-assignee",
           owner,
           "--if-status",
           "in_progress",
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

  defp record_delivery(_settings, _issue, %{"review_url" => nil}), do: :ok

  defp record_delivery(settings, issue, %{"review_url" => url, "head_sha" => sha}) when is_binary(url) and is_binary(sha) do
    with :ok <- Acceptance.validate_review_scope(settings, url),
         true <- String.match?(sha, ~r/^[a-fA-F0-9]{40,64}$/) || {:error, :invalid_delivery_commit},
         {:ok, record} <- RunJournal.read(issue.native_ref["run_directory"]),
         true <- record["owner"] == issue.assignee_id || {:error, :delivery_owner_mismatch},
         {:ok, _} <- RunJournal.checkpoint(record, %{"delivery" => %{"review_url" => url, "head_sha" => sha, "attempt_id" => record["attempt_id"], "turn_id" => record["turn_id"]}}) do
      :ok
    end
  end

  defp record_delivery(_settings, _issue, arguments) do
    if Map.has_key?(arguments, "review_url") or Map.has_key?(arguments, "head_sha"), do: {:error, :incomplete_delivery}, else: :ok
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

  defp finish_delivery(settings, id, owner, result) do
    with {:ok, [issue]} <- read_records(settings, ["show", id, "--json"]) do
      if issue["status"] == "blocked" and issue["assignee"] == owner and "human" in (issue["labels"] || []) do
        :ok
      else
        await_human(settings, id, owner, inspect(result))
      end
    end
  end

  defp claim(settings, issue, record) do
    expected = if record["thread_id"], do: record["owner"], else: ""

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
      native_ref: Map.take(raw, ["issue_type", "acceptance_criteria", "external_ref", "metadata"]),
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

  defp tool_result(result) do
    output = inspect(result)
    %{"success" => result == :ok, "output" => output, "contentItems" => [%{"type" => "inputText", "text" => output}]}
  end
end
