defmodule SymphonyElixir.Execution do
  @moduledoc "Durable native execution for repository Issues, independent of task storage."
  alias SymphonyElixir.{Config, ExecutionBackend, RunJournal, Tracker}

  @spec enabled?() :: boolean()
  def enabled?, do: Config.settings!().agent.goal_mode

  @spec journal_root() :: Path.t()
  def journal_root do
    configured = Config.settings!().agent.run_journal_dir

    value =
      case configured do
        "$" <> name -> System.get_env(name)
        other -> other
      end

    value || System.get_env("SYMPHONY_RUN_JOURNAL_DIR") || Path.join(Config.settings!().workspace.root, ".runs")
  end

  @spec run_budget_ms(String.t()) :: pos_integer()
  def run_budget_ms(id) do
    agent = Config.settings!().agent

    case Map.get(agent.run_budget_ms_by_issue, id, agent.run_budget_ms) do
      value when is_integer(value) and value > 0 -> value
      _ -> agent.run_budget_ms
    end
  end

  @spec prepare(Tracker.Issue.t(), keyword()) :: {:ok, Tracker.Issue.t(), keyword()} | {:error, term()}
  def prepare(issue, opts) do
    if enabled?() do
      with :ok <- ExecutionBackend.check_record(journal_root(), issue.id),
           :ok <- consume_retry(issue, opts),
           :ok <- recover_stopped(issue),
           {:ok, record} <- RunJournal.admit(journal_root(), issue.id),
           {:ok, record} <-
             RunJournal.checkpoint(record, %{
               "issue_url" => issue.url,
               "issue_identifier" => issue.identifier,
               "backend" => ExecutionBackend.kind(),
               "recovery" => if(record["thread_id"], do: "resume existing native thread", else: nil),
               "handoff" => nil,
               "blocker_reason" => nil
             }) do
        {:ok, issue, Keyword.merge(opts, run_record: record, tracker_settings: Config.settings!().tracker)}
      end
    else
      {:ok, issue, opts}
    end
  end

  # A dead scheduler may release its lock, but resuming the recorded thread still
  # goes through AppServer's native idle/turn identity check. An unrecorded thread
  # allocation remains an incident instead of silently creating another executor.
  defp recover_stopped(issue) do
    directory = RunJournal.directory(journal_root(), issue.id)

    with {:ok, record} <- RunJournal.read(directory) do
      cond do
        is_nil(record) -> :ok
        record["issue_url"] != issue.url -> {:error, :execution_issue_identity_changed}
        resumable?(issue) -> release_for_resume(record)
        record["phase"] == "incident" -> {:error, {:execution_requires_recovery, record["blocker_reason"]}}
        RunJournal.executor_state(record) == :stopped and (is_binary(record["thread_id"]) or record["thread_allocation_intent"] != true) -> release_for_resume(record)
        record["phase"] == "completed" -> :ok
        true -> {:error, {:execution_requires_recovery, record["blocker_reason"] || record["phase"]}}
      end
    end
  end

  defp consume_retry(issue, opts) do
    if "symphony:retry" in issue.labels do
      remove_labels(Config.settings!().tracker, issue, ["symphony:retry"], opts)
    else
      :ok
    end
  end

  @spec handing_off?(String.t()) :: boolean()
  def handing_off?(id) do
    if enabled?() do
      case RunJournal.read(RunJournal.directory(journal_root(), id)) do
        {:ok, %{} = record} -> record["handoff_pending"] == true or is_map(record["handoff"])
        _ -> false
      end
    else
      false
    end
  end

  defp release_for_resume(record) do
    with {:ok, _} <- RunJournal.checkpoint(record, %{"phase" => "completed", "handoff" => nil, "blocker_reason" => nil}) do
      case File.rmdir(Path.join(record["directory"], "executor.lock")) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        error -> error
      end
    end
  end

  @spec finish(Tracker.Issue.t(), keyword(), term()) :: :ok | {:error, term()}
  def finish(_issue, opts, _result) when not is_list(opts), do: :ok

  def finish(issue, opts, result) do
    case opts[:run_record] do
      nil ->
        :ok

      initial ->
        with {:ok, record} <- RunJournal.read(initial["directory"]) do
          {phase, error} = final_phase(issue, record, result)

          with {:ok, updated} <- RunJournal.checkpoint(record, %{"blocker_reason" => error}),
               :ok <- RunJournal.complete(updated, phase) do
            :ok
          end
        end
    end
  end

  defp final_phase(_issue, record, {:error, :scheduler_stop}) do
    if record["native_stop_confirmed"] == true,
      do: {"completed", nil},
      else: {"incident", "Scheduler requested shutdown, but the native Goal could not be confirmed stopped."}
  end

  defp final_phase(issue, record, :ok) do
    if record["handoff"] do
      {"completed", nil}
    else
      case Tracker.fetch_issues_by_ids([issue.id]) do
        {:ok, [current]} ->
          if current.state in Config.settings!().tracker.terminal_states or
               not Tracker.Issue.routable?(current, Config.settings!().tracker.required_labels),
             do: {"completed", nil},
             else: {"incident", "Goal ended while the Issue still requests execution; inspect the result or add symphony:retry."}

        {:ok, []} ->
          {"completed", nil}

        {:error, reason} ->
          {"incident", "Cannot confirm the Issue after execution: #{inspect(reason)}"}
      end
    end
  end

  defp final_phase(_issue, record, result) do
    # Keep the existing scheduler retry loop for confirmed-stopped transient
    # failures. Two retries are enough before surfacing the actual incident.
    if (record["native_stop_confirmed"] == true or record["thread_allocation_intent"] != true) and (record["attempt_count"] || 0) < 3,
      do: {"completed", inspect(result)},
      else: {"incident", inspect(result)}
  end

  @spec worker_down(String.t(), term()) :: :ok | {:blocked, String.t()}
  def worker_down(id, reason) do
    if enabled?() do
      case RunJournal.read(RunJournal.directory(journal_root(), id)) do
        {:ok, %{"phase" => "incident"} = record} ->
          {:blocked, record["blocker_reason"] || inspect(reason)}

        {:ok, %{"phase" => phase} = record} when phase != "completed" ->
          message = "Execution interrupted at #{phase}: #{inspect(reason)}"
          finish_interrupted(record, message)

        _ ->
          :ok
      end
    else
      :ok
    end
  end

  defp finish_interrupted(record, message) do
    with {:ok, updated} <- RunJournal.checkpoint(record, %{"blocker_reason" => message}),
         :ok <- RunJournal.complete(updated, "incident") do
      {:blocked, message}
    else
      error -> {:blocked, "Cannot finalize interrupted execution: #{inspect(error)}"}
    end
  end

  @spec resumable?(Tracker.Issue.t()) :: boolean()
  def resumable?(issue) do
    if enabled?() and "symphony:retry" in issue.labels do
      case RunJournal.read(RunJournal.directory(journal_root(), issue.id)) do
        {:ok, %{"phase" => "incident"} = record} -> record["native_stop_confirmed"] == true or record["thread_allocation_intent"] != true
        _ -> false
      end
    else
      false
    end
  end

  @spec tool_specs() :: [map()]
  def tool_specs do
    if enabled?() do
      [
        %{
          "name" => "task_handoff",
          "description" => "Record a concrete review, decision or blocker on this repository Issue and release its routing label. Does not create a task, merge or close the Issue.",
          "inputSchema" => %{
            "type" => "object",
            "additionalProperties" => false,
            "required" => ["kind", "reason"],
            "properties" => %{
              "kind" => %{"type" => "string", "enum" => ["review", "decision", "blocked"]},
              "reason" => %{"type" => "string", "minLength" => 1},
              "url" => %{"type" => "string"}
            }
          }
        }
      ]
    else
      []
    end
  end

  @spec handoff(term(), keyword()) :: map()
  def handoff(arguments, opts) do
    result = do_handoff(arguments, opts)
    output = Jason.encode!(%{"result" => inspect(result)})
    %{"success" => match?({:ok, _}, result), "output" => output, "contentItems" => [%{"type" => "inputText", "text" => output}]}
  end

  defp do_handoff(%{"kind" => kind, "reason" => reason} = arguments, opts)
       when kind in ["review", "decision", "blocked"] and is_binary(reason) and byte_size(reason) > 0 do
    issue = Keyword.fetch!(opts, :issue)
    settings = Keyword.fetch!(opts, :tracker_settings)

    with {:ok, %{} = record} <- RunJournal.read(RunJournal.directory(journal_root(), issue.id)),
         true <- record["issue_url"] == issue.url,
         {:ok, pending} <- RunJournal.checkpoint(record, %{"handoff_pending" => true}) do
      case post_handoff(settings, issue, arguments, opts) do
        :ok ->
          with {:ok, updated} <- RunJournal.checkpoint(pending, %{"handoff_pending" => false, "handoff" => arguments}) do
            {:ok, Map.take(updated, ["issue_url", "handoff"])}
          end

        error ->
          RunJournal.checkpoint(pending, %{"handoff_pending" => false})
          {:error, error}
      end
    else
      error -> {:error, error}
    end
  end

  defp do_handoff(_, _), do: {:error, :invalid_handoff}

  defp post_handoff(%{kind: kind} = settings, issue, args, opts) when kind in ["github", "gitlab"] do
    {client, path} = client_path(settings, issue, opts)
    suffix = if kind == "github", do: "/comments", else: "/notes"

    with :ok <- response(client.("POST", path <> suffix, %{}, %{"body" => handoff_body(args)}, tracker_settings: settings)),
         :ok <- remove_labels(settings, issue, settings.required_labels ++ ["symphony:retry"], opts) do
      :ok
    end
  end

  defp post_handoff(_, _, _, _), do: {:error, :repository_tracker_required}

  defp remove_labels(%{kind: "github"} = settings, issue, labels, opts) do
    {client, path} = client_path(settings, issue, opts)

    Enum.reduce_while(labels, :ok, fn label, :ok ->
      case client.("DELETE", path <> "/labels/" <> URI.encode_www_form(label), %{}, nil, tracker_settings: settings) do
        {:ok, %{status: status}} when status in 200..299 or status == 404 -> {:cont, :ok}
        error -> {:halt, {:error, error}}
      end
    end)
  end

  defp remove_labels(%{kind: "gitlab"} = settings, issue, labels, opts) do
    {client, path} = client_path(settings, issue, opts)
    response(client.("PUT", path, %{}, %{"remove_labels" => Enum.join(labels, ",")}, tracker_settings: settings))
  end

  defp remove_labels(_, _, _, _), do: {:error, :repository_tracker_required}

  defp client_path(%{kind: "github"} = settings, issue, opts),
    do: {opts[:github_client] || (&SymphonyElixir.GitHub.Client.request/5), "/repos/#{settings.provider["repo"]}/issues/#{issue.id}"}

  defp client_path(%{kind: "gitlab"} = settings, issue, opts),
    do: {opts[:gitlab_client] || (&SymphonyElixir.GitLab.Client.request/5), "/projects/#{URI.encode_www_form(settings.provider["project_path"])}/issues/#{issue.id}"}

  defp handoff_body(args), do: "**#{args["kind"]}**\n\n#{args["reason"]}" <> if(args["url"], do: "\n\n#{args["url"]}", else: "")
  defp response({:ok, %{status: status}}) when status in 200..299, do: :ok
  defp response(error), do: {:error, error}
end
