defmodule SymphonyElixir.MailReview.Listener do
  @moduledoc """
  Scheduler-owned mail port and durable MR review execution journal.
  The existing MR is the work item; the journal owns execution identities and receipts.
  Uncertain execution or publication stays fenced across restarts.
  """
  use GenServer
  alias SymphonyElixir.{Config, Tracker.Issue}
  alias SymphonyElixir.MailReview.{GitLab, Policy}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]) |> Keyword.put_new(:name, __MODULE__))

  @spec health() :: map()
  def health, do: GenServer.call(__MODULE__, :health)

  @spec issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def issues, do: GenServer.call(__MODULE__, :issues, 120_000)

  @spec begin_run(String.t()) :: {:ok, map(), map()} | {:error, term()}
  def begin_run(id), do: GenServer.call(__MODULE__, {:begin, id}, 60_000)

  @spec checkpoint(String.t(), map()) :: :ok
  def checkpoint(id, changes), do: GenServer.call(__MODULE__, {:checkpoint, id, changes}, 60_000)

  @spec submit(String.t(), map()) :: :ok | {:error, term()}
  def submit(id, arguments), do: GenServer.call(__MODULE__, {:submit, id, arguments}, 120_000)

  @spec ingest(map()) :: :ok | {:error, term()}
  def ingest(event), do: GenServer.call(__MODULE__, {:ingest, event}, 120_000)

  @spec request_review(String.t(), pos_integer()) :: :ok | {:error, term()}
  def request_review(project, iid), do: GenServer.call(__MODULE__, {:request_review, project, iid}, 120_000)

  @impl true
  def init(opts) do
    Process.send_after(self(), :configure, 100)

    state = %{
      config: nil,
      port: nil,
      buffer: "",
      health: :disabled,
      restarts: 0,
      records: %{},
      seen: [],
      last_event_at: nil,
      error: nil,
      initial_config: opts[:config]
    }

    {:ok, state}
  end

  @impl true
  def handle_call(message, from, state) do
    bypass = message == :health or match?({:checkpoint, _, _}, message) or is_nil(state.config)

    if bypass or current_config?(state),
      do: handle_request(message, from, state),
      else: {:reply, {:error, :mail_review_configuration_changed_restart_required}, suspend(state)}
  end

  defp handle_request(:health, _from, state) do
    {:reply,
     Map.take(state, [:health, :restarts, :last_event_at, :error])
     |> Map.put(:mail_delivery, :live_only_no_replay)
     |> Map.put(
       :fenced_runs,
       Enum.filter(Map.values(state.records), &(&1["phase"] in ["running", "publishing", "failed", "fenced"]))
       |> Enum.map(&Map.take(&1, ["id", "phase", "error", "thread_id", "turn_id"]))
     ), state}
  end

  defp handle_request(:issues, _from, %{config: nil} = state), do: {:reply, {:ok, []}, state}

  defp handle_request(:issues, _from, state) do
    state = reconcile(state)
    issues = Enum.map(state.records, fn {_key, record} -> issue(record) end)
    {:reply, {:ok, issues}, state}
  end

  defp handle_request({:request_review, project, iid}, _from, state) do
    if state.config && is_binary(project) && is_integer(iid) && iid > 0 && Map.has_key?(state.config["projects"], project) do
      case candidate(state, {:ok, project, iid}) do
        {:ok, next} -> {:reply, :ok, next}
        {:error, reason} -> {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, :invalid_review_scope}, state}
    end
  end

  defp handle_request({:ingest, event}, _from, state) do
    case ingest_event(state, event) do
      {:ok, next} -> {:reply, :ok, next}
      {:error, reason} -> {:reply, {:error, reason}, %{state | error: inspect(reason)}}
    end
  end

  defp handle_request({:checkpoint, id, changes}, _from, state) do
    record = Map.fetch!(state.records, record_key(id))

    if record["phase"] == "completed" and changes["phase"] == "failed" do
      {:reply, :ok, state}
    else
      next = put_record(state, Map.merge(record, changes))
      {:reply, :ok, next}
    end
  end

  defp handle_request({:begin, id}, _from, state) do
    case Map.get(state.records, record_key(id)) do
      %{"phase" => "queued"} = record ->
        record = Map.put(record, "phase", "running")
        next = put_record(state, record)
        {:reply, {:ok, record, state.config}, next}

      _ ->
        {:reply, {:error, :review_execution_fenced}, state}
    end
  end

  defp handle_request({:submit, id, arguments}, _from, state) do
    case publish(state, id, arguments) do
      {:ok, next} -> {:reply, :ok, next}
      {:error, reason, next} -> {:reply, {:error, reason}, next}
    end
  end

  @impl true
  def handle_info(:configure, state) do
    settings = initial_settings(state.initial_config)

    case settings do
      {:ok, %{tracker: %{provider: %{"mail_review" => %{"enabled" => true} = config}}}} ->
        case load(state, config) do
          {:ok, next} ->
            Process.send_after(self(), :check_config, 1_000)
            {:noreply, open_watch(recover(next))}

          {:error, reason} ->
            {:noreply, %{state | health: :failed, error: inspect(reason)}}
        end

      _ ->
        Process.send_after(self(), :configure, 1_000)
        {:noreply, state}
    end
  end

  def handle_info(:restart_watch, state), do: {:noreply, if(current_config?(state), do: open_watch(state), else: suspend(state))}

  def handle_info(:check_config, state) do
    Process.send_after(self(), :check_config, 1_000)
    {:noreply, if(current_config?(state), do: state, else: suspend(state))}
  end

  def handle_info({port, {:data, data}}, %{port: port} = state) do
    if current_config?(state) do
      consume_data(port, data, state)
    else
      {:noreply, suspend(state)}
    end
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    {:noreply, failed_watch(%{state | port: nil, buffer: ""}, {:mail_exit, code})}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp consume_data(port, data, state) do
    # SDK stderr can contain access_key/ticket URLs. Never log or persist lines.
    buffer = state.buffer <> data

    if byte_size(buffer) > 2_097_152 do
      close_watch(port)
      {:noreply, failed_watch(%{state | port: nil, buffer: ""}, :mail_line_too_large)}
    else
      parts = String.split(buffer, "\n")
      {tail, lines} = List.pop_at(parts, -1)
      next = Enum.reduce(lines, %{state | buffer: tail}, &consume_line/2)
      {:noreply, next}
    end
  end

  @impl true
  def terminate(_reason, %{port: port}) when is_port(port), do: close_watch(port)
  def terminate(_reason, _state), do: :ok

  defp initial_settings(nil), do: Config.settings()
  defp initial_settings(config), do: {:ok, %{tracker: %{provider: %{"mail_review" => config}}}}

  defp current_config?(%{initial_config: config}) when is_map(config), do: true

  defp current_config?(state) do
    with :ok <- Config.validate!(),
         {:ok, %{tracker: %{provider: %{"mail_review" => %{"enabled" => true} = config}}}} <- Config.settings() do
      SymphonyElixir.MailReview.resolve(config) == state.config
    else
      _ -> false
    end
  end

  defp close_watch(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> System.cmd("kill", ["-TERM", Integer.to_string(pid)], stderr_to_stdout: true)
      _ -> :ok
    end

    Port.close(port)
  rescue
    _ -> :ok
  end

  defp suspend(state) do
    if is_port(state.port), do: close_watch(state.port)
    %{state | port: nil, health: :failed, error: "Configuration changed or invalid; restart required", buffer: ""}
  end

  defp recover(state) do
    Enum.reduce(state.records, state, fn {_id, record}, current ->
      if record["phase"] in ["running", "publishing", "failed"] do
        put_record(current, record |> Map.put("previous_phase", record["phase"]) |> Map.put("phase", "fenced"))
      else
        current
      end
    end)
  end

  defp load(state, raw_config) do
    config = SymphonyElixir.MailReview.resolve(raw_config)
    path = Path.join(config["state_dir"], "mail-review.json")

    with :ok <- File.mkdir_p(config["state_dir"]) do
      case File.read(path) do
        {:ok, content} ->
          restore(state, config, content)

        {:error, :enoent} ->
          {:ok, %{state | config: config}}

        error ->
          error
      end
    end
  end

  defp restore(state, config, content) do
    with {:ok, data} <- Jason.decode(content),
         true <- is_map(data["records"]) and scope(data["scope"] || %{}) == scope(config) do
      {:ok, %{state | config: config, records: data["records"], seen: data["seen"] || []}}
    else
      _ -> {:error, :invalid_review_journal}
    end
  end

  defp open_watch(state) do
    executable = System.find_executable(state.config["lark_bin"] || "lark-cli")

    if executable do
      port = Port.open({:spawn_executable, executable}, [:binary, :exit_status, :stderr_to_stdout, args: ["mail", "+watch", "--msg-format", "event", "--format", "json", "--as", "user"]])
      %{state | port: port, health: :starting, error: nil}
    else
      failed_watch(state, :lark_executable_missing)
    end
  rescue
    _ -> failed_watch(state, :mail_watch_start_failed)
  end

  defp failed_watch(state, reason) do
    count = state.restarts + 1

    if count <= (state.config["restart_limit"] || 5) do
      Process.send_after(self(), :restart_watch, state.config["restart_delay_ms"] || 10_000)
      %{state | health: :restarting, restarts: count, error: inspect(reason)}
    else
      %{state | health: :failed, restarts: count, error: inspect(reason)}
    end
  end

  defp consume_line("Connected. Waiting for mail events... (Ctrl+C to stop)", state), do: %{state | health: :listening}

  defp consume_line(line, state) do
    case Jason.decode(line) do
      {:ok, %{"ok" => true, "data" => %{"event" => %{"message_id" => _}}} = event} ->
        case ingest_event(state, event) do
          {:ok, next} -> %{next | health: :listening, last_event_at: DateTime.to_iso8601(DateTime.utc_now())}
          {:error, reason} -> %{state | error: inspect(reason)}
        end

      _ ->
        state
    end
  end

  defp ingest_event(%{config: nil}, _event), do: {:error, :listener_disabled}

  defp ingest_event(state, %{"ok" => true, "data" => %{"event" => %{"message_id" => id}}})
       when is_binary(id) and byte_size(id) in 1..512 do
    if id in state.seen do
      {:ok, state}
    else
      with {:ok, body} <-
             GitLab.command(
               state.config["lark_bin"] || "lark-cli",
               ["mail", "+message", "--message-id", id, "--as", "user", "--format", "json"]
             ),
           {:ok, %{"ok" => true, "data" => mail}} <- Jason.decode(body),
           {:ok, next} <- candidate(state, Policy.candidate(mail, state.config)) do
        next = %{next | seen: Enum.take([id | next.seen], 10_000)}
        {:ok, persist(next)}
      else
        {:error, reason} -> {:error, reason}
        _ -> {:error, :invalid_mail_response}
      end
    end
  end

  defp ingest_event(_state, _event), do: {:error, :invalid_mail_event}

  defp candidate(state, :ignore), do: {:ok, state}

  defp candidate(state, {:ok, project, iid}) do
    path = GitLab.mr_path(project, iid)

    with {:ok, mr} <- GitLab.request(state.config, "GET", path),
         true <- Policy.requested_reviewer?(mr, state.config["username"]),
         true <- valid_mr?(mr, project, iid, state.config) do
      previous = state.records |> Map.values() |> Enum.filter(&(&1["project"] == project and &1["iid"] == iid))
      if previous == [], do: queue(state, project, iid, mr, 1), else: {:ok, state}
    else
      false -> {:ok, state}
      error -> error
    end
  end

  defp valid_mr?(mr, project, iid, config) do
    mr["iid"] == iid and is_integer(get_in(mr, ["author", "id"])) and
      Enum.all?([mr["sha"], get_in(mr, ["diff_refs", "base_sha"])], &valid_sha?/1) and
      valid_mr_url?(mr["web_url"], project, iid, config)
  end

  defp valid_sha?(sha), do: is_binary(sha) and Regex.match?(~r/^[a-f0-9]{40,64}$/, sha)

  defp valid_mr_url?(url, project, iid, config) do
    uri = URI.parse(url || "")

    uri.scheme in ["http", "https"] and uri.host == config["host"] and
      uri.path == "/#{project}/-/merge_requests/#{iid}" and
      is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment)
  end

  defp queue(state, project, iid, mr, round) do
    id = :crypto.hash(:sha256, "#{project}!#{iid}:#{round}") |> Base.encode16(case: :lower)

    record = %{
      "id" => id,
      "project" => project,
      "iid" => iid,
      "round" => round,
      "head" => mr["sha"],
      "base" => mr["diff_refs"]["base_sha"],
      "author_id" => mr["author"]["id"],
      "url" => mr["web_url"],
      "findings" => [],
      "phase" => "queued"
    }

    {:ok, put_record(state, record)}
  end

  defp reconcile(state) do
    state.records
    |> Map.values()
    |> Enum.filter(&(&1["phase"] == "completed" and &1["findings"] != []))
    |> Enum.reduce(state, fn record, current ->
      newer = Enum.any?(current.records, fn {_id, r} -> r["project"] == record["project"] and r["iid"] == record["iid"] and r["round"] > record["round"] end)

      if newer, do: current, else: reconcile_record(current, record)
    end)
  end

  defp reconcile_record(state, record) do
    path = GitLab.mr_path(record["project"], record["iid"])

    with {:ok, mr} <- GitLab.request(state.config, "GET", path),
         true <- valid_mr?(mr, record["project"], record["iid"], state.config),
         true <- Policy.requested_reviewer?(mr, state.config["username"]),
         {:ok, discussions} <- GitLab.discussions(state.config, path),
         true <- Policy.answered?(record["findings"], discussions, record["author_id"]),
         {:ok, next} <- queue(state, record["project"], record["iid"], mr, record["round"] + 1) do
      next
    else
      _ -> state
    end
  end

  defp issue(record) do
    %Issue{
      id: "mail-review:" <> record["id"],
      identifier: "review-#{String.slice(record["id"], 0, 16)}",
      title: "Review #{record["project"]}!#{record["iid"]}",
      description: Jason.encode!(Map.take(record, ["project", "iid", "head", "base", "round"])),
      state: if(record["phase"] in ["queued", "running"], do: hd(SymphonyElixir.Config.settings!().tracker.active_states), else: "closed"),
      native_ref: Map.put(record, "execution_kind", "mail_review"),
      labels: SymphonyElixir.Config.settings!().tracker.required_labels,
      dispatchable: record["phase"] in ["queued", "running"],
      url: record["url"]
    }
  end

  defp publish(state, id, %{"findings" => findings}) when is_list(findings) and length(findings) <= 50 do
    record = state.records[record_key(id)]

    if publishable?(record, findings) do
      record = Map.put_new(record, "submission", findings) |> Map.put("phase", "publishing")
      state = put_record(state, record)
      path = GitLab.mr_path(record["project"], record["iid"])

      with true <- record["submission"] == findings || {:error, :changed_submission},
           {:ok, mr} <- GitLab.request(state.config, "GET", path),
           true <- same_review?(mr, record, state.config) || {:error, :mr_head_changed},
           {:ok, user} <- GitLab.request(state.config, "GET", "user"),
           true <- user["username"] == state.config["username"] || {:error, :gitlab_identity_mismatch},
           {:ok, discussions} <- GitLab.discussions(state.config, path),
           {:ok, receipts} <- post_findings(state.config, path, record, discussions) do
        {:ok, put_record(state, record |> Map.put("phase", "completed") |> Map.put("receipts", receipts) |> Map.put("findings", if(findings == [], do: [], else: receipts)))}
      else
        {:error, reason} ->
          next = put_record(state, record |> Map.put("phase", "fenced") |> Map.put("error", inspect(reason)))
          {:error, reason, next}
      end
    else
      {:error, :invalid_review_submission, state}
    end
  end

  defp publish(state, _id, _arguments), do: {:error, :invalid_review_submission, state}

  defp publishable?(nil, _findings), do: false

  defp publishable?(record, findings) do
    record["phase"] in ["running", "publishing"] and Enum.all?(findings, &valid_finding?/1)
  end

  defp valid_finding?(finding) do
    is_binary(finding) and byte_size(finding) in 1..16_384 and
      Regex.match?(~r/[\x{4e00}-\x{9fff}]/u, finding) and not String.contains?(finding, "<!-- symphony-review:")
  end

  defp post_findings(config, path, record, discussions) do
    entries = if record["submission"] == [], do: ["本轮评审未发现有充分证据支持的问题。评审范围：`#{record["base"]}` → `#{record["head"]}`。"], else: record["submission"]

    entries
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {body, index}, {:ok, receipts} ->
      marker = Policy.marker(record["id"], index)
      existing = Enum.find(discussions, &owned_note(&1["notes"] || [], marker, config))
      result = if existing, do: {:ok, existing}, else: post_at_head(config, path, record, body <> "\n\n" <> marker)
      collect_receipt(result, marker, config, receipts)
    end)
  end

  defp owned_note(notes, marker, config) do
    Enum.find(
      notes,
      &(String.contains?(&1["body"] || "", marker) and
          get_in(&1, ["author", "username"]) == config["username"])
    )
  end

  defp collect_receipt({:ok, %{"id" => discussion_id, "notes" => notes}}, marker, config, receipts) do
    case owned_note(notes, marker, config) do
      %{"id" => id} when is_integer(id) ->
        {:cont, {:ok, receipts ++ [%{"discussion_id" => discussion_id, "note_id" => id}]}}

      _ ->
        {:halt, {:error, :invalid_owned_note_receipt}}
    end
  end

  defp collect_receipt({:error, reason}, _marker, _config, _receipts), do: {:halt, {:error, reason}}
  defp collect_receipt(_result, _marker, _config, _receipts), do: {:halt, {:error, :invalid_discussion_receipt}}

  defp same_review?(mr, record, config) do
    mr["sha"] == record["head"] and Policy.requested_reviewer?(mr, config["username"])
  end

  defp post_at_head(config, path, record, body) do
    with {:ok, mr} <- GitLab.request(config, "GET", path),
         true <- same_review?(mr, record, config) || {:error, :mr_head_or_reviewer_changed} do
      GitLab.request(config, "POST", path <> "/discussions", %{"body" => body})
    end
  end

  defp record_key("mail-review:" <> key), do: key
  defp record_key(key), do: key

  defp put_record(state, record), do: persist(%{state | records: Map.put(state.records, record["id"], record)})
  defp scope(config), do: Map.take(config, ["host", "username", "projects"])

  defp persist(state) do
    path = Path.join(state.config["state_dir"], "mail-review.json")
    File.write!(path <> ".pending", Jason.encode!(%{"scope" => scope(state.config), "records" => state.records, "seen" => state.seen}), [:sync])
    File.rename!(path <> ".pending", path)
    state
  end
end
