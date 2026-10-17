defmodule SymphonyElixir.TaskReconcilerTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.{Execution, RunJournal, TaskDecision, TaskReconciler, TaskWorkflow}
  @ready_at "2026-10-16T00:00:01Z"

  setup do
    directory = Path.dirname(Workflow.workflow_file_path())

    File.write!(Workflow.workflow_file_path(), """
    ---
    tracker:
      kind: gitlab
      assignee: "1"
      provider:
        project_path: group/project
        api_key: fixture
        task_workflow: true
      required_labels: [symphony:ready]
      active_states: [opened]
      terminal_states: [closed]
    agent:
      goal_mode: true
      run_journal_dir: #{Jason.encode!(Path.join(directory, "runs"))}
    ---
    Execute {{ issue.url }}
    """)

    :ok = WorkflowStore.force_reload()
    url = "https://gitlab.test/group/project/-/issues/42"

    description = "Deliver the result\n\n" <> contract_block(development_contract())

    raw = %{
      "web_url" => url,
      "state" => "opened",
      "assignees" => [%{"id" => 1}],
      "labels" => ["symphony:ready", "type:development"],
      "description" => description
    }

    ready = label_event(11, "symphony:ready")

    state = %{
      raw: raw,
      notes: [candidate(description)],
      label_events: [ready],
      mr: %{},
      dependency: %{"state" => "opened"},
      calls: [],
      label_writes: [],
      fault: nil
    }

    {:ok, server} = Agent.start_link(fn -> state end)

    client = fn method, path, query, body, _ ->
      Agent.get_and_update(server, fn state ->
        state = %{state | calls: state.calls ++ [{method, path, query, body}]}

        cond do
          state.fault ->
            {state.fault, state}

          String.ends_with?(path, "/resource_label_events") ->
            events = Enum.slice(state.label_events, ((query["page"] || 1) - 1) * 100, 100)
            {{:ok, %{status: 200, body: events}}, state}

          String.ends_with?(path, "/notes") and method == "POST" ->
            notice = %{"id" => 1_000_000 + length(state.notes), "body" => body["body"], "updated_at" => DateTime.to_iso8601(DateTime.utc_now()), "author" => %{"id" => 1}}
            {{:ok, %{status: 201, body: notice}}, %{state | notes: state.notes ++ [notice]}}

          String.ends_with?(path, "/notes") ->
            notes = Enum.slice(state.notes, ((query["page"] || 1) - 1) * 100, 100)
            {{:ok, %{status: 200, body: notes}}, state}

          String.ends_with?(path, "/merge_requests/9") ->
            {{:ok, %{status: 200, body: state.mr}}, state}

          String.ends_with?(path, "/issues/7") ->
            {{:ok, %{status: 200, body: state.dependency}}, state}

          method == "PUT" and body["state_event"] == "close" ->
            raw = Map.put(state.raw, "state", "closed")
            {{:ok, %{status: 200, body: raw}}, %{state | raw: raw}}

          method == "PUT" ->
            removed = if body["remove_labels"], do: String.split(body["remove_labels"], ","), else: []
            added = if body["add_labels"], do: String.split(body["add_labels"], ","), else: []
            raw = Map.put(state.raw, "labels", Enum.uniq(state.raw["labels"] -- removed) ++ added)
            {{:ok, %{status: 200, body: raw}}, %{state | raw: raw, label_writes: state.label_writes ++ [body]}}

          true ->
            {{:ok, %{status: 200, body: state.raw}}, state}
        end
      end)
    end

    Application.put_env(:symphony_elixir, :task_workflow_client, client)
    on_exit(fn -> Application.delete_env(:symphony_elixir, :task_workflow_client) end)

    issue = %Issue{
      id: "42",
      identifier: "GL-42",
      title: "Result",
      state: "opened",
      url: url,
      labels: raw["labels"],
      assignee_id: "1",
      dispatchable: true
    }

    {:ok, server: server, issue: issue, contract: label_ref(11), client: client}
  end

  defp development_contract(extra \\ %{}) do
    Map.merge(
      %{
        "type" => "development",
        "criteria" => ["a", "b"],
        "acceptor" => "2",
        "reviewers" => ["3"],
        "acceptance_mode" => "separate",
        "deliverables" => [%{"id" => "code", "kind" => "mr"}]
      },
      extra
    )
  end

  defp contract_block(data) do
    "<!-- symphony-contract\n" <> Jason.encode!(Map.put(data, "contract_sha", TaskWorkflow.digest(data))) <> "\n-->"
  end

  defp candidate(description) do
    data = TaskReconciler.description_contract(description) |> Map.put("issue_version", TaskWorkflow.digest(description))
    body = "Review this agreement before applying ready.\n\n" <> TaskDecision.candidate_block(%{"action" => "authorize", "data" => data})
    reply(10_000, body, 1, "2026-10-16T00:00:00Z")
  end

  defp label_event(id, name, at \\ @ready_at, action \\ "add", actor \\ 1) do
    %{"id" => id, "action" => action, "label" => %{"name" => name}, "user" => %{"id" => actor}, "created_at" => at}
  end

  defp label_ref(id, at \\ @ready_at, actor \\ 1), do: "label:#{id}@#{actor}@#{at}"

  defp note(id, action, data, contract \\ nil, actor \\ 1) do
    body = "Decision\n\n<!-- symphony-workflow\n" <> Jason.encode!(%{"action" => action, "data" => data, "contract" => contract}) <> "\n-->"

    %{
      "id" => id,
      "body" => body,
      "author" => %{"id" => actor},
      "created_at" => DateTime.to_iso8601(DateTime.add(~U[2026-10-16 00:00:00Z], id)),
      "updated_at" => DateTime.to_iso8601(DateTime.add(~U[2026-10-16 00:00:00Z], id))
    }
  end

  defp append(server, note), do: Agent.update(server, &%{&1 | notes: &1.notes ++ [note]})

  # Engine notices are posted at the current time, so a comment that answers one
  # has to be later than that.
  defp reply(id, body, actor \\ 1, at \\ nil) do
    at = at || DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), 60))
    %{"id" => id, "body" => body, "author" => %{"id" => actor}, "created_at" => at, "updated_at" => at}
  end

  defp current(record), do: elem(RunJournal.read(record["directory"]), 1)

  defp write_lock_owner(record) do
    path = Path.join([record["directory"], "executor.lock", "executor-owner.json"])
    File.write!(path, Jason.encode!(Map.take(record, ["attempt_id", "host", "executor_os_pid"])))
  end

  test "pause, separately satisfied dependency and explicit resume survive unlabelled polling and restart", %{server: server, issue: issue, contract: contract} do
    assert TaskReconciler.enabled?()
    assert {:ok, _, opts} = Execution.prepare(issue, [])
    record = opts[:run_record]
    assert record["workflow"]["state"] == "running"
    append(server, note(2, "restrict", %{"kind" => "dependency", "restriction" => "dep", "condition" => %{"kind" => "issue", "number" => 7}}, contract))
    pause = %{note(3, "pause", %{}, contract) | "body" => "暂停任务"}
    append(server, pause)
    {:ok, record} = RunJournal.checkpoint(record, %{"thread_id" => "native", "thread_allocation_intent" => true, "native_stop_confirmed" => false})
    assert {:ok, record} = TaskReconciler.refresh(record, true)
    assert record["workflow"]["state"] == "waiting"
    # A pause blocks the task without the engine ever touching a human label.
    assert "symphony:ready" in Agent.get(server, & &1.raw["labels"])
    assert "symphony:blocked" in Agent.get(server, & &1.raw["labels"])
    assert record["workflow"]["charging"]
    {:ok, record} = RunJournal.checkpoint(record, %{"native_stop_confirmed" => true})
    refute record["workflow"]["charging"]
    :ok = Execution.finish(issue, opts, {:error, :scheduler_stop})
    Agent.update(server, &%{&1 | dependency: %{"state" => "closed"}})
    assert :ok = TaskReconciler.poll(MapSet.new())
    record = current(record)
    refute record["workflow"]["restrictions"]["dep"]
    assert record["workflow"]["state"] == "waiting"
    assert "symphony:blocked" in Agent.get(server, & &1.raw["labels"])
    append(server, %{note(4, "resume", %{}, contract) | "body" => "恢复执行"})
    assert :ok = TaskReconciler.poll(MapSet.new())
    assert "symphony:ready" in Agent.get(server, & &1.raw["labels"])
    refute "symphony:blocked" in Agent.get(server, & &1.raw["labels"])
    used = current(record)["workflow"]["used_ms"]
    assert {:ok, _, resumed} = Execution.prepare(issue, [])
    assert resumed[:run_record]["workflow"]["used_ms"] >= used
    assert resumed[:run_record]["thread_id"] == "native"
    assert :ok = TaskReconciler.poll(MapSet.new([issue.id]))
    before = File.read!(Path.join(record["directory"], "run.json"))
    assert :ok = TaskReconciler.poll(MapSet.new())
    assert File.read!(Path.join(record["directory"], "run.json")) == before
  end

  test "engine label writes stay inside the engine whitelist", %{server: server, issue: issue, contract: contract} do
    assert TaskReconciler.human_labels() == ["symphony:ready", "symphony:rework", "symphony:accept"]
    assert TaskReconciler.engine_labels() == ["symphony:running", "symphony:review", "symphony:blocked", "symphony:failed"]

    {:ok, _, opts} = Execution.prepare(issue, [])
    record = opts[:run_record]

    {:ok, record} = RunJournal.checkpoint(record, %{"thread_id" => "native", "thread_allocation_intent" => true})
    {:ok, record} = TaskReconciler.refresh(record, true)
    assert "symphony:running" in Agent.get(server, & &1.raw["labels"])

    append(server, %{note(3, "pause", %{}, contract) | "body" => "暂停任务"})
    {:ok, record} = TaskReconciler.refresh(record, true)
    assert "symphony:blocked" in Agent.get(server, & &1.raw["labels"])

    {:ok, record} = RunJournal.checkpoint(record, %{"native_stop_confirmed" => true})
    :ok = RunJournal.complete(record, "incident")
    :ok = TaskReconciler.poll(MapSet.new())
    assert "symphony:failed" in Agent.get(server, & &1.raw["labels"])

    writes = Agent.get(server, & &1.label_writes)
    assert length(writes) >= 3

    for body <- writes, {key, value} <- body, key in ["add_labels", "remove_labels"], label <- String.split(value, ",") do
      assert label in TaskReconciler.engine_labels()
    end

    assert Enum.all?(TaskReconciler.human_labels(), &(not String.contains?(inspect(writes), &1)))
  end

  test "ready binds a native candidate and never substitutes the current description" do
    description = "Deliver the result\n\n" <> contract_block(development_contract())
    published = candidate(description)
    [ready] = TaskDecision.label_events([label_event(11, "symphony:ready")], [published])
    assert ready["data"] == Map.put(TaskReconciler.description_contract(description), "issue_version", TaskWorkflow.digest(description))
    assert ready["binding"] == TaskReconciler.source_ref(published)
    assert ready["actor"] == "1"
    assert ready["ref"] == label_ref(11)
    assert TaskDecision.label_events([label_event(11, "symphony:ready")], []) == []
  end

  test "old ready cannot approve edited scope on first admission", %{server: server, issue: issue} do
    Agent.update(server, &put_in(&1.raw["description"], &1.raw["description"] <> "\nExtra requirement."))
    assert {:error, :task_workflow_waiting} = Execution.prepare(issue, [])
    refute Enum.any?(Agent.get(server, & &1.calls), fn {method, _, _, body} -> method == "PUT" and body["state_event"] == "close" end)
  end

  test "ready without its actual actor cannot borrow the assignee", %{server: server, issue: issue} do
    Agent.update(server, &%{&1 | label_events: [Map.delete(label_event(11, "symphony:ready"), "user")]})
    assert {:error, :task_workflow_waiting} = Execution.prepare(issue, [])
  end

  test "deleting or editing a candidate revokes its projection after journal reload", %{server: server, issue: issue} do
    {:ok, _, opts} = Execution.prepare(issue, [])
    record = opts[:run_record]
    published = Agent.get(server, & &1.notes)
    Agent.update(server, &%{&1 | notes: Enum.map(published, fn note -> Map.put(note, "updated_at", "2026-10-16T00:00:02Z") end)})
    {:ok, edited} = TaskReconciler.refresh(current(record), false)
    assert edited["workflow"]["restrictions"]["baseline"]
    assert edited["workflow"]["allowed_criteria"] == []
    Agent.update(server, &%{&1 | notes: []})
    {:ok, deleted} = TaskReconciler.refresh(current(record), false)
    assert deleted["workflow"]["restrictions"]["baseline"]
    assert deleted["workflow"]["allowed_criteria"] == []
  end

  test "unknown external routing removal, ownership loss and external closure cannot complete a task", %{server: server, issue: issue} do
    {:ok, _, opts} = Execution.prepare(issue, [])
    record = opts[:run_record]
    Agent.update(server, &%{&1 | raw: Map.merge(&1.raw, %{"labels" => ["type:development"], "assignees" => []})})
    {:ok, record} = TaskReconciler.refresh(record, true)
    assert record["workflow"]["restrictions"]["owner"]
    Agent.update(server, &%{&1 | raw: Map.merge(&1.raw, %{"assignees" => [%{"id" => 1}], "state" => "closed"})})
    {:ok, record} = TaskReconciler.refresh(record, false)
    assert record["workflow"]["state"] == "waiting"
    assert record["workflow"]["restrictions"]["external_routing"]
    assert record["workflow"]["restrictions"]["closure"]
    refute record["workflow"]["acceptance"]
    :ok = RunJournal.complete(record, "completed")
    assert {:error, :task_workflow_waiting} = Execution.prepare(issue, [])
    refute File.exists?(Path.join(record["directory"], "executor.lock"))
  end

  test "issue_version binds the whole description and editing it invalidates authorization", %{server: server, issue: issue} do
    description = Agent.get(server, & &1.raw["description"])
    {:ok, _, opts} = Execution.prepare(issue, [])
    record = opts[:run_record]
    assert record["workflow"]["contract"]["issue_version"] == TaskWorkflow.digest(description)

    # Editing the description changes its digest, so the recorded authorization
    # no longer matches the confirmed agreement and the engine raises the
    # baseline decision restriction until a new candidate receives explicit authorization.
    Agent.update(server, &put_in(&1.raw["description"], description <> "\n\nReworded scope."))
    {:ok, record} = TaskReconciler.refresh(record, false)
    assert record["workflow"]["restrictions"]["baseline"]
    assert record["workflow"]["state"] == "waiting"
  end

  test "an unexplained routing removal after handoff restricts an already started task", %{server: server, issue: issue} do
    {:ok, _, opts} = Execution.prepare(issue, [])
    record = opts[:run_record]
    flow = TaskWorkflow.handoff(record["workflow"], %{"kind" => "review"})
    {:ok, record} = RunJournal.checkpoint(record, %{"workflow" => flow, "native_stop_confirmed" => true, "thread_allocation_intent" => true, "thread_id" => "same"})
    :ok = RunJournal.complete(record, "completed")

    assert record["workflow"]["started"]
    Agent.update(server, &%{&1 | raw: Map.put(&1.raw, "labels", ["type:development"])})
    {:ok, record} = TaskReconciler.refresh(record, false)
    assert record["workflow"]["restrictions"]["external_routing"]
  end

  test "a never-routed task is not restricted just because the label was absent", %{server: server, issue: issue} do
    {:ok, _, opts} = Execution.prepare(issue, [])
    # A fresh record has not started, so an absent routing label is a legitimate
    # pre-authorization state rather than an unexplained removal.
    record = Map.take(opts[:run_record], ["attempt_id", "directory", "issue_id", "issue_url"])
    Agent.update(server, &%{&1 | raw: Map.put(&1.raw, "labels", ["type:development"])})
    {:ok, record} = TaskReconciler.refresh(record, false)
    refute (record["workflow"]["restrictions"] || %{})["external_routing"]
  end

  test "a verified intermediate merge restores routing, preserving task-level delivery and budget", %{server: server, issue: issue} do
    {:ok, _, opts} = Execution.prepare(issue, [])
    record = opts[:run_record]
    url = "https://gitlab.test/group/project/-/merge_requests/9"
    flow = TaskWorkflow.handoff(record["workflow"], %{"kind" => "review"}) |> Map.put("intermediate", %{"url" => url, "kind" => "mr", "version" => "v1"})
    {:ok, record} = RunJournal.checkpoint(record, %{"workflow" => flow, "native_stop_confirmed" => true, "thread_allocation_intent" => true, "thread_id" => "same"})
    :ok = RunJournal.complete(record, "completed")

    Agent.update(
      server,
      &%{&1 | raw: Map.put(&1.raw, "labels", ["symphony:ready", "type:development"]), mr: %{"web_url" => url, "sha" => "v1", "source_project_id" => 1, "target_project_id" => 1, "state" => "opened"}}
    )

    :ok = TaskReconciler.poll(MapSet.new())
    assert current(record)["workflow"]["state"] == "waiting"
    assert "symphony:review" in Agent.get(server, & &1.raw["labels"])
    Agent.update(server, &%{&1 | mr: Map.merge(&1.mr, %{"state" => "merged", "merged_at" => "2026-10-16T00:00:00Z"})})
    :ok = TaskReconciler.poll(MapSet.new())
    assert current(record)["workflow"]["state"] == "ready"
    assert "symphony:ready" in Agent.get(server, & &1.raw["labels"])
    refute "symphony:review" in Agent.get(server, & &1.raw["labels"])
    refute current(record)["workflow"]["acceptance"]
  end

  test "paginated decision reads, edited notes, malformed markers and stale observations remain conservative", %{server: server, issue: issue, contract: contract} do
    {:ok, _, opts} = Execution.prepare(issue, [])
    record = opts[:run_record]
    filler = for id <- 100..199, do: Map.put(note(id, "pause", %{}), "system", true)
    Agent.update(server, &%{&1 | notes: &1.notes ++ filler})
    append(server, %{note(200, "pause", %{}) | "body" => "<!-- symphony-workflow {bad} -->"})
    append(server, %{note(201, "pause", %{}) | "body" => "Ordinary review suggestion"})
    quoted = note(999, "pause", %{}, contract)
    quoted = %{quoted | "body" => "```html\n" <> quoted["body"] <> "\n```"}
    assert TaskReconciler.events([quoted], %{}, "1") == []
    assert {:ok, observation} = TaskReconciler.observe(record)
    assert length(observation.events) == 1
    stale = %{record | "attempt_id" => "other"}
    assert {:error, :stale_execution_observation} = TaskReconciler.apply_observation(stale, observation, false)
    append(server, note(202, "rework", %{"criteria" => ["a"], "changes" => []}, contract, 2))
    {:ok, record} = TaskReconciler.refresh(record, false)
    assert record["workflow"]["resume_requested"]
    # The contract lives in the description, so editing it invalidates the
    # recorded authorization until a new candidate receives explicit authorization.
    Agent.update(server, fn state -> %{state | raw: Map.put(state.raw, "description", "Edited agreement")} end)
    {:ok, record} = TaskReconciler.refresh(record, false)
    assert record["workflow"]["restrictions"]["baseline"]
    Agent.update(server, &%{&1 | fault: {:error, :offline}})
    assert {:error, {:task_facts_unavailable, _}} = TaskReconciler.refresh(record, false)
  end

  test "report manifests and final acceptance reference immutable current note versions", %{server: server, issue: issue} do
    Agent.update(server, fn state ->
      research = %{
        "type" => "research",
        "criteria" => ["answer"],
        "acceptor" => "2",
        "acceptance_mode" => "separate",
        "deliverables" => [%{"id" => "report", "kind" => "report"}]
      }

      raw =
        state.raw
        |> Map.put("labels", ["symphony:ready", "type:research"])
        |> Map.put("description", "Research the answer\n\n" <> contract_block(research))

      %{state | raw: raw, notes: [candidate(raw["description"])]}
    end)

    {:ok, _, opts} = Execution.prepare(%{issue | labels: ["symphony:ready", "type:research"]}, [])
    record = opts[:run_record]
    contract = record["workflow"]["contract"]["ref"]
    append(server, %{note(2, "report", %{}) | "body" => "The evidenced answer; uncertainty remains."})

    data = %{
      "contract" => contract,
      "items" => [%{"id" => "report", "kind" => "report", "url" => issue.url <> "#note_2", "version" => TaskWorkflow.digest("The evidenced answer; uncertainty remains."), "criteria" => ["answer"]}]
    }

    submission = note(3, "manifest", data, contract)
    append(server, submission)
    [event] = TaskReconciler.events([submission], %{}, "1")
    append(server, note(4, "accept", %{"manifest" => event["ref"]}, contract, 2))
    {:ok, record} = TaskReconciler.refresh(record, false)
    assert record["workflow"]["state"] == "review"
    Agent.update(server, &%{&1 | raw: Map.put(&1.raw, "state", "closed")})
    {:ok, record} = RunJournal.checkpoint(record, %{"native_stop_confirmed" => true})
    {:ok, record} = TaskReconciler.refresh(record, false)
    assert record["workflow"]["state"] == "ended"
    Agent.update(server, fn state -> %{state | notes: Enum.map(state.notes, fn note -> if note["id"] == 2, do: Map.put(note, "body", "Changed conclusion"), else: note end)} end)
    {:ok, record} = TaskReconciler.refresh(record, false)
    assert record["workflow"]["state"] == "waiting"
    refute record["workflow"]["acceptance"]
  end

  test "a manifest note and an accept label that arrive in one poll are accepted", %{server: server, issue: issue} do
    Agent.update(server, fn state ->
      research = %{
        "type" => "research",
        "criteria" => ["answer"],
        "acceptor" => "2",
        "acceptance_mode" => "separate",
        "deliverables" => [%{"id" => "report", "kind" => "report"}]
      }

      raw =
        state.raw
        |> Map.put("labels", ["symphony:ready", "type:research"])
        |> Map.put("description", "Research the answer\n\n" <> contract_block(research))

      %{state | raw: raw, notes: [candidate(raw["description"])]}
    end)

    {:ok, _, opts} = Execution.prepare(%{issue | labels: ["symphony:ready", "type:research"]}, [])
    record = opts[:run_record]
    contract = record["workflow"]["contract"]["ref"]
    append(server, %{note(2, "report", %{}) | "body" => "The evidenced answer."})

    item = %{"id" => "report", "kind" => "report", "url" => issue.url <> "#note_2", "version" => TaskWorkflow.digest("The evidenced answer."), "criteria" => ["answer"]}
    submission = note(7, "manifest", %{"contract" => contract, "items" => [item]}, contract)
    append(server, submission)
    # A human cannot accept a delivery that does not exist yet, so the accept
    # label is timestamped after the manifest note and must still reduce last.
    # With the chronological sort the note lands first regardless of its id.
    accept = label_event(3, "symphony:accept", "2026-10-16T00:00:08Z", "add", 2)
    Agent.update(server, &%{&1 | label_events: &1.label_events ++ [accept]})

    # Native note time proves which immutable manifest preceded the label;
    # binding happens before reduction, including on the first poll.
    {:ok, record} = TaskReconciler.refresh(record, false)
    assert record["workflow"]["acceptance"]["ref"] == "label:3@2@2026-10-16T00:00:08Z"
    assert record["workflow"]["acceptance"]["manifest"] == TaskReconciler.source_ref(submission)
  end

  test "failed native facts and label readbacks cannot grant admission or automatic recovery", context do
    %{issue: issue, contract: contract, server: server, client: client} = context
    {:ok, _, opts} = Execution.prepare(issue, [])
    record = opts[:run_record]
    offline = fn _, _, _, _, _ -> {:error, :offline} end
    Agent.update(server, &%{&1 | fault: {:error, :offline}})
    assert {:error, _} = TaskReconciler.admit(issue, record)
    Agent.update(server, &%{&1 | fault: nil})
    append(server, note(2, "pause", %{}, contract))

    fail_put = fn method, path, query, body, options ->
      case method do
        "PUT" -> offline.(method, path, query, body, options)
        _ -> client.(method, path, query, body, options)
      end
    end

    assert {:error, {:state_label_unconfirmed, _}} = TaskReconciler.refresh(record, true, client: fail_put)

    # A label write whose readback cannot be confirmed is not trusted either.
    {:ok, reads} = Agent.start_link(fn -> 0 end)

    fail_readback = fn method, path, query, body, options ->
      if method == "GET" and String.ends_with?(path, "/issues/42") do
        n = Agent.get_and_update(reads, &{&1, &1 + 1})
        if n == 0, do: client.(method, path, query, body, options), else: {:error, :offline}
      else
        client.(method, path, query, body, options)
      end
    end

    assert {:error, {:state_label_unconfirmed, _}} = TaskReconciler.refresh(record, true, client: fail_readback)
    {:ok, record} = TaskReconciler.refresh(current(record), true)
    {:ok, record} = RunJournal.checkpoint(record, %{"native_stop_confirmed" => true})
    append(server, note(3, "resume", %{"restrictions" => [hd(TaskReconciler.events([note(2, "pause", %{}, contract)], %{}, "1"))["ref"]]}, contract))
    assert {:error, {:state_label_unconfirmed, _}} = TaskReconciler.refresh(record, false, client: fail_put)
    # An invalid timestamp remains an unorderable, non-authorizing event.
    parsed = TaskReconciler.events([Map.put(note(4, "pause", %{}, contract), "updated_at", "invalid")], %{}, "1")
    assert hd(parsed)["at"] == 0
    File.write!(Path.join(record["directory"], "run.json"), Jason.encode!(Map.put(current(record), "directory", record["directory"] <> "/missing")))
    assert :ok = TaskReconciler.poll(MapSet.new())
  end

  test "unsupported delivery references and dependency read errors remain visible", %{issue: issue, contract: contract, server: server, client: client} do
    {:ok, _, opts} = Execution.prepare(issue, [])
    record = opts[:run_record]

    for url <- ["https://elsewhere.test/report", issue.url <> "#note_bad", "https://gitlab.test/group/project/-/merge_requests/not-a-number"] do
      data = %{"contract" => contract, "items" => [%{"id" => "code", "kind" => "mr", "url" => url, "version" => "v1", "criteria" => ["a", "b"]}]}
      manifest = note(20, "manifest", data, contract)
      Agent.update(server, &%{&1 | notes: [manifest]})
      assert {:ok, updated} = TaskReconciler.refresh(record, false)
      refute updated["workflow"]["manifest"]
    end

    Agent.update(server, &%{&1 | notes: []})
    append(server, note(21, "restrict", %{"kind" => "dependency", "condition" => %{"kind" => "mr", "number" => 9}}, contract))

    fail_dependency = fn method, path, query, body, options ->
      if String.ends_with?(path, "/merge_requests/9"), do: {:error, :offline}, else: client.(method, path, query, body, options)
    end

    assert {:error, _} = TaskReconciler.refresh(record, false, client: fail_dependency)

    bad_pages = fn method, path, query, body, options ->
      if String.ends_with?(path, "/notes"), do: {:ok, %{status: 503}}, else: client.(method, path, query, body, options)
    end

    assert {:error, _} = TaskReconciler.refresh(record, false, client: bad_pages)
    # A stranger cannot force reads of arbitrary delivery URLs.
    bad = note(22, "manifest", %{"items" => [%{"url" => "https://elsewhere.test/private"}]}, contract, 99)
    Agent.update(server, &%{&1 | notes: [bad]})
    assert {:ok, _} = TaskReconciler.refresh(record, false)
  end

  test "handoff intent preserves intermediate delivery and finalizes even when the provider later becomes unavailable", %{issue: issue, server: server, client: client} do
    {:ok, _, opts} = Execution.prepare(issue, [])
    record = opts[:run_record]
    delivery = %{"url" => "https://gitlab.test/group/project/-/merge_requests/9", "kind" => "mr", "version" => "v1"}
    {:ok, _} = RunJournal.checkpoint(record, %{"delivery" => delivery})
    arguments = %{"kind" => "review", "reason" => "Review this change.", "url" => delivery["url"], "continue_after" => "merged"}
    handoff_opts = [issue: issue, tracker_settings: Config.settings!().tracker, gitlab_client: client]
    assert Execution.handoff(arguments, handoff_opts)["success"]
    assert current(record)["workflow"]["intermediate"] == delivery
    {:ok, _} = RunJournal.checkpoint(current(record), %{"native_stop_confirmed" => true})
    Agent.update(server, &%{&1 | fault: {:error, :offline}})
    assert :ok = Execution.finish(issue, opts, :ok)
    assert current(record)["phase"] == "completed"
  end

  test "a controlled scope restart and a new pause never consume the transient retry allowance", %{issue: issue} do
    {:ok, _, opts} = Execution.prepare(issue, [])
    record = opts[:run_record]
    {:ok, _} = RunJournal.checkpoint(record, %{"control_restart" => true, "native_stop_confirmed" => true, "attempt_count" => 10})
    assert :ok = Execution.finish(issue, opts, {:error, {:native_goal_stopped, "blocked"}})
    assert current(record)["phase"] == "completed"
    assert current(record)["blocker_reason"] == nil
  end

  test "activation uses refreshed scope and remaining budget after slow hooks", %{issue: issue, contract: contract, server: server} do
    {:ok, _, opts} = Execution.prepare(issue, [])
    original = opts[:run_record]
    append(server, note(2, "restrict", %{"kind" => "dependency", "scope" => ["a"]}, contract))
    assert {:ok, current_opts} = Execution.activation_options(opts)
    assert original["workflow"]["allowed_criteria"] == ["a", "b"]
    assert current_opts[:run_record]["workflow"]["allowed_criteria"] == ["b"]
    assert current_opts[:deadline] <= opts[:deadline]
    assert {:error, :execution_budget_exhausted} = Execution.activation_options(Keyword.put(opts, :deadline, System.monotonic_time(:millisecond) - 1))
    stale = Keyword.put(opts, :run_record, Map.put(original, "attempt_id", "previous"))
    assert {:error, :execution_attempt_changed} = Execution.activation_options(stale)
    append(server, %{note(3, "pause", %{}, contract) | "body" => "Please pause this task."})
    assert {:error, :scheduler_stop} = Execution.activation_options(opts)
    assert TaskReconciler.intent(String.trim("请暂停这个任务。 ")) == %{"action" => "pause", "natural" => true}
    assert TaskReconciler.intent("Please resume this task.")["action"] == "resume"
    assert TaskReconciler.intent("Could you pause until we agree?")["action"] == "clarify"
  end

  test "authorized closure waits for native stop and verifies the close write", %{issue: issue, server: server, client: client} do
    research = %{
      "type" => "research",
      "criteria" => ["answer"],
      "acceptor" => "2",
      "acceptance_mode" => "separate",
      "close_on_conclusion" => true,
      "deliverables" => [%{"id" => "report", "kind" => "report"}]
    }

    Agent.update(server, fn state ->
      raw =
        state.raw
        |> Map.put("labels", ["symphony:ready", "type:research"])
        |> Map.put("description", "Deliver the result\n\n" <> contract_block(research))

      %{state | raw: raw, notes: [candidate(raw["description"])]}
    end)

    {:ok, _, opts} = Execution.prepare(issue, [])
    record = opts[:run_record]
    contract = record["workflow"]["contract"]["ref"]
    append(server, %{note(2, "report", %{}) | "body" => "Evidenced conclusion"})
    item = %{"id" => "report", "kind" => "report", "url" => issue.url <> "#note_2", "version" => TaskWorkflow.digest("Evidenced conclusion"), "criteria" => ["answer"]}
    submission = note(3, "manifest", %{"contract" => contract, "items" => [item]}, contract)
    append(server, submission)
    append(server, note(4, "accept", %{"manifest" => TaskReconciler.source_ref(submission)}, contract, 2))
    {:ok, record} = RunJournal.checkpoint(record, %{"native_stop_confirmed" => false, "thread_allocation_intent" => true})
    {:ok, record} = TaskReconciler.refresh(record, false)
    assert Agent.get(server, & &1.raw["state"]) == "opened"
    {:ok, record} = RunJournal.checkpoint(record, %{"native_stop_confirmed" => true})

    fail_close = fn method, path, query, body, options ->
      if body == %{"state_event" => "close"}, do: {:error, :offline}, else: client.(method, path, query, body, options)
    end

    assert {:error, {:issue_closure_unconfirmed, _}} = TaskReconciler.refresh(record, false, client: fail_close)
    {:ok, record} = TaskReconciler.refresh(current(record), false)
    assert record["closure_confirmed"]
    assert Agent.get(server, & &1.raw["state"]) == "closed"
    {:ok, record} = TaskReconciler.refresh(record, false)
    assert record["workflow"]["state"] == "ended"
    assert :ok = Execution.finish(issue, opts, {:error, {:native_goal_stopped, "blocked"}})
    refute current(record)["retry_count"]
  end

  test "legacy malformed artifacts fail closed and unknown native payloads do not grant completion", %{issue: issue, server: server} do
    {:ok, _, opts} = Execution.prepare(issue, [])
    record = opts[:run_record]

    for {kind, url} <- [{"mr", "https://elsewhere.invalid/report"}, {"report", issue.url <> "#note_bad"}] do
      bad = %{"ref" => "legacy", "items" => [%{"kind" => kind, "url" => url, "version" => "v1"}]}
      flow = Map.put(record["workflow"], "manifest", bad)
      {:ok, saved} = RunJournal.checkpoint(record, %{"workflow" => flow})
      assert {:error, _} = TaskReconciler.refresh(saved, false)
    end

    {:ok, record} = RunJournal.checkpoint(current(record), %{"workflow" => record["workflow"]})
    contract = record["workflow"]["contract"]["ref"]
    item = %{"id" => "code", "kind" => "mr", "url" => "https://gitlab.test/group/project/-/merge_requests/9", "version" => "v1", "criteria" => ["a", "b"], "checks" => true, "review" => true}
    append(server, note(5, "manifest", %{"contract" => contract, "items" => [item]}, contract))
    assert {:error, _} = TaskReconciler.refresh(record, false)
  end

  test "decision requests are posted once and an interrupted notice write recovers by native readback", context do
    %{issue: issue, contract: contract, server: server, client: client} = context
    {:ok, _, opts} = Execution.prepare(issue, [])
    record = opts[:run_record]
    append(server, note(5, "rework", %{"criteria" => ["new"], "changes" => ["scope"]}, contract, 2))
    {:ok, record} = TaskReconciler.refresh(record, false)
    count = Agent.get(server, &Enum.count(&1.calls, fn {method, _, _, _} -> method == "POST" end))
    assert count == 1
    assert record["waiting_notices"]
    {:ok, record} = TaskReconciler.refresh(record, false)
    assert Agent.get(server, &Enum.count(&1.calls, fn {method, _, _, _} -> method == "POST" end)) == count
    # Simulate a lost local save after a successful remote post.
    {:ok, record} = RunJournal.checkpoint(record, %{"waiting_notices" => %{}})
    {:ok, record} = TaskReconciler.refresh(record, false)
    assert Agent.get(server, &Enum.count(&1.calls, fn {method, _, _, _} -> method == "POST" end)) == count
    append(server, %{note(6, "pause", %{}, contract) | "body" => "Could you pause until we agree?"})

    fail_post = fn method, path, query, body, options ->
      if method == "POST", do: {:error, :offline}, else: client.(method, path, query, body, options)
    end

    assert {:error, {:waiting_notice_unconfirmed, _}} = TaskReconciler.refresh(record, false, client: fail_post)
    {:ok, record} = TaskReconciler.refresh(current(record), false)
    flow = put_in(record["workflow"], ["used_ms"], record["workflow"]["budget_ms"])
    {:ok, record} = RunJournal.checkpoint(record, %{"workflow" => flow})
    {:ok, record} = TaskReconciler.refresh(record, false)
    assert record["workflow"]["restrictions"]["budget"]
    assert Enum.any?(Agent.get(server, & &1.notes), &String.contains?(&1["body"], "累计执行预算已用完"))
  end

  test "repeated MR links retain every item's validation and review requirements", %{issue: issue, server: server} do
    agreement = %{
      "type" => "development",
      "criteria" => ["a", "b"],
      "acceptor" => "2",
      "reviewers" => ["3"],
      "acceptance_mode" => "separate",
      "deliverables" => [%{"id" => "first", "kind" => "mr"}, %{"id" => "second", "kind" => "mr"}]
    }

    # The description block is the confirmed agreement; the note authorization
    # must match it. Both items point at the same merged MR.
    description = "Deliver the result\n\n" <> contract_block(agreement)
    Agent.update(server, &put_in(&1.raw["description"], description))

    url = "https://gitlab.test/group/project/-/merge_requests/9"
    mr = %{"web_url" => url, "sha" => "v1", "source_project_id" => 1, "target_project_id" => 1, "state" => "merged", "merged_at" => "2026-10-16T00:00:00Z"}
    Agent.update(server, &%{&1 | notes: [candidate(description)], mr: mr})
    {:ok, _, opts} = Execution.prepare(issue, [])
    record = opts[:run_record]
    contract = record["workflow"]["contract"]["ref"]
    first = %{"id" => "first", "kind" => "mr", "url" => url, "version" => "v1", "criteria" => ["a"], "checks" => true, "review" => true}
    second = %{first | "id" => "second", "criteria" => ["b"], "checks" => false, "review" => false}
    submission = note(3, "manifest", %{"contract" => contract, "items" => [first, second]}, contract)
    append(server, submission)
    append(server, note(4, "accept", %{"manifest" => TaskReconciler.source_ref(submission)}, contract, 2))
    {:ok, record} = RunJournal.checkpoint(record, %{"native_stop_confirmed" => true})
    {:ok, record} = TaskReconciler.refresh(record, false)
    refute record["workflow"]["delivery_ready"]
    refute TaskWorkflow.valid_conclusion?(record["workflow"])
    assert Agent.get(server, & &1.raw["state"]) == "opened"

    # Requiring both checks and review on every item is the safeguard under test;
    # satisfying the second item lets delivery readiness succeed.
    satisfied = %{second | "checks" => true, "review" => true}
    append(server, note(5, "manifest", %{"contract" => contract, "items" => [first, satisfied]}, contract))
    {:ok, record} = TaskReconciler.refresh(record, false)
    assert record["workflow"]["delivery_ready"]
  end

  test "stopped-run polling recovers final MR publication and submits its manifest without a replacement executor", %{issue: issue, server: server, client: client} do
    {:ok, _, opts} = Execution.prepare(issue, [])
    record = opts[:run_record]
    url = "https://gitlab.test/group/project/-/merge_requests/9"

    mr = %{
      "iid" => 9,
      "web_url" => url,
      "sha" => "v1",
      "source_project_id" => 1,
      "target_project_id" => 1,
      "source_branch" => "task",
      "target_branch" => "main",
      "state" => "merged",
      "merged_at" => "2026-10-16T00:00:00Z",
      "squash" => true,
      "force_remove_source_branch" => true
    }

    Agent.update(server, &%{&1 | mr: mr})
    item = %{"id" => "code", "kind" => "mr", "url" => url, "version" => "v1", "criteria" => ["a", "b"], "checks" => true, "review" => true}
    manifest = %{"contract" => record["workflow"]["contract"]["ref"], "items" => [item]}
    invalid = %{"kind" => "review", "reason" => "Review", "manifest" => []}
    handoff_opts = [issue: issue, tracker_settings: Config.settings!().tracker, gitlab_client: client]
    refute Execution.handoff(invalid, handoff_opts)["success"]
    refute Execution.handoff(%{invalid | "manifest" => %{}}, handoff_opts)["success"]

    request = %{
      "schema_version" => 1,
      "attempt_id" => record["attempt_id"],
      "issue_url" => issue.url,
      "kind" => "review",
      "reason" => "Review the complete delivery.",
      "url" => url,
      "publication" => mr,
      "manifest" => manifest
    }

    File.write!(Path.join(record["directory"], "review-request-#{record["attempt_id"]}.json"), Jason.encode!(request))

    fail_release = fn method, path, query, body, options ->
      if method == "PUT", do: {:error, :offline}, else: client.(method, path, query, body, options)
    end

    delivery_opts = [tracker_settings: Config.settings!().tracker, gitlab_client: fail_release]
    assert {:error, _} = Execution.reconcile_delivery(issue, delivery_opts)
    filler = for id <- 100..199, do: Map.put(note(id, "ignored", %{}), "system", true)
    Agent.update(server, &%{&1 | notes: filler ++ &1.notes})
    # Simulate a lost receipt for the already posted notice, now beyond page one.
    {:ok, _} = RunJournal.checkpoint(current(record), %{"handoff_notice" => nil})
    {:ok, record} = RunJournal.checkpoint(current(record), %{"native_stop_confirmed" => true, "thread_id" => "original", "thread_allocation_intent" => true})
    :ok = RunJournal.complete(record, "completed")
    :ok = TaskReconciler.poll(MapSet.new())
    assert current(record)["handoff"]["manifest"] == manifest
    count = Agent.get(server, &Enum.count(&1.calls, fn {method, _, _, _} -> method == "POST" end))
    :ok = TaskReconciler.poll(MapSet.new())
    final = current(record)
    assert final["workflow"]["manifest"]["items"] == [item]
    assert final["workflow"]["state"] == "review"
    assert final["thread_id"] == "original"
    assert final["attempt_id"] == record["attempt_id"]
    assert Agent.get(server, &Enum.count(&1.calls, fn {method, _, _, _} -> method == "POST" end)) == count
    assert Execution.controlled_stop?(opts)
    refute Execution.controlled_stop?([])
  end

  test "a final report handoff states that no MR is expected and names the acceptance action", %{
    issue: issue,
    server: server,
    client: client
  } do
    contract =
      development_contract(%{
        "type" => "research",
        "criteria" => ["answer"],
        "deliverables" => [%{"id" => "report", "kind" => "report"}]
      })

    description = "Deliver the report\n\n" <> contract_block(contract)

    Agent.update(server, fn state ->
      raw =
        state.raw
        |> Map.put("description", description)
        |> Map.put("labels", ["symphony:ready", "type:research"])

      %{state | raw: raw, notes: [candidate(raw["description"])]}
    end)

    issue = %{issue | labels: ["symphony:ready", "type:research"]}
    {:ok, _, opts} = Execution.prepare(issue, [])
    record = opts[:run_record]

    manifest = %{
      "contract" => record["workflow"]["contract"]["ref"],
      "items" => [
        %{
          "id" => "report",
          "kind" => "report",
          "url" => issue.url <> "#note_2",
          "version" => TaskWorkflow.digest("Report body"),
          "criteria" => ["answer"]
        }
      ]
    }

    args = %{
      "kind" => "review",
      "reason" => "Review the complete report.",
      "manifest" => manifest
    }

    assert Execution.handoff(args,
             issue: issue,
             tracker_settings: Config.settings!().tracker,
             gitlab_client: client
           )["success"]

    body = Agent.get(server, &(&1.notes |> List.last() |> Map.fetch!("body")))
    assert body =~ "## 需要你做什么"
    assert body =~ "本任务没有 MR，这是报告型任务的预期交付"
    assert body =~ "添加 `symphony:accept`"
  end

  test "a mixed final handoff asks for the report and MR review together", %{
    issue: issue,
    server: server,
    client: client
  } do
    contract =
      development_contract(%{
        "type" => "mixed",
        "deliverables" => [
          %{"id" => "report", "kind" => "report"},
          %{"id" => "code", "kind" => "mr"}
        ]
      })

    description = "Deliver the report and change\n\n" <> contract_block(contract)
    url = "https://gitlab.test/group/project/-/issues/43"

    Agent.update(server, fn state ->
      raw =
        state.raw
        |> Map.put("description", description)
        |> Map.put("web_url", url)
        |> Map.put("labels", ["symphony:ready", "type:mixed"])

      %{state | raw: raw, notes: [candidate(raw["description"])]}
    end)

    issue = %{issue | id: "43", identifier: "GL-43", url: url, labels: ["symphony:ready", "type:mixed"]}
    {:ok, _, opts} = Execution.prepare(issue, [])
    record = opts[:run_record]

    manifest = %{
      "contract" => record["workflow"]["contract"]["ref"],
      "items" => [
        %{
          "id" => "report",
          "kind" => "report",
          "url" => url <> "#note_2",
          "version" => TaskWorkflow.digest("Report body"),
          "criteria" => ["a", "b"]
        },
        %{
          "id" => "code",
          "kind" => "mr",
          "url" => "https://gitlab.test/group/project/-/merge_requests/8",
          "version" => "v1",
          "criteria" => ["a", "b"],
          "checks" => true,
          "review" => true
        }
      ]
    }

    assert Execution.handoff(
             %{
               "kind" => "review",
               "reason" => "Review the complete mixed delivery.",
               "manifest" => manifest
             },
             issue: issue,
             tracker_settings: Config.settings!().tracker,
             gitlab_client: client
           )["success"]

    body = Agent.get(server, &(&1.notes |> List.last() |> Map.fetch!("body")))
    assert body =~ "打开上方报告和 MR"
    assert body =~ "添加 `symphony:accept`"
  end

  test "authorized recovery respects the cumulative failure count across successful handoffs", context do
    %{issue: issue, server: server, contract: contract, client: client} = context
    {:ok, _, opts} = Execution.prepare(issue, [])
    record = opts[:run_record]
    append(server, note(2, "rework", %{"criteria" => ["a"], "changes" => []}, contract, 2))
    {:ok, record} = RunJournal.checkpoint(record, %{"native_stop_confirmed" => true, "retry_count" => 1, "attempt_count" => 10, "executor_os_pid" => "99999999"})
    write_lock_owner(record)
    {:ok, record} = TaskReconciler.refresh(record, false)
    :ok = RunJournal.complete(record, "incident")
    assert Execution.resumable?(issue)
    {:ok, _, resumed} = Execution.prepare(issue, [])
    assert resumed[:run_record]["retry_count"] == 1
    assert resumed[:run_record]["attempt_count"] == 11
    # A rework already spent on an earlier handoff is still counted, so this
    # confirmed-stopped failure exhausts the single automatic rework.
    assert :ok = Execution.finish(issue, resumed, {:error, :fixture_failure})
    {:ok, record} = RunJournal.read(record["directory"])
    assert record["retry_count"] == 2 and record["phase"] == "incident"
    refute Execution.resumable?(issue)
    # Clearing an Incident needs a fresh human authorization, not a retry label.
    assert {:error, {:execution_requires_recovery, _}} = Execution.prepare(issue, gitlab_client: client)
  end

  test "waiting admission exits normally without allocating a native execution", %{issue: issue, server: server} do
    # Without an applied authorization label there is no agreement to admit.
    Agent.update(server, &%{&1 | notes: [], label_events: []})
    assert :ok = SymphonyElixir.AgentRunner.run(issue)
    {:ok, record} = RunJournal.read(RunJournal.directory(Execution.journal_root(), issue.id))
    assert record["workflow"]["state"] == "waiting"
    refute record["thread_id"]
    refute record["blocker_reason"]
    refute File.exists?(Path.join(record["directory"], "executor.lock"))
  end

  test "a decision handoff is answered by the owner's first later comment", %{issue: issue, server: server, client: client} do
    {:ok, _, opts} = Execution.prepare(issue, [])
    record = opts[:run_record]
    handoff_opts = [issue: issue, tracker_settings: Config.settings!().tracker, gitlab_client: client]
    assert Execution.handoff(%{"kind" => "decision", "reason" => "Which fixture should the replay use?"}, handoff_opts)["success"]

    # The question is an engine notice written with the same credentials as the
    # owner, so its marker is what keeps it from answering itself.
    question = Enum.find(Agent.get(server, & &1.notes), &(&1["body"] =~ "**decision**"))
    assert question["author"]["id"] == 1
    assert TaskReconciler.engine_notice?(question)

    {:ok, record} = RunJournal.checkpoint(current(record), %{"thread_id" => "native", "thread_allocation_intent" => true, "native_stop_confirmed" => true})
    {:ok, record} = TaskReconciler.refresh(record, false)
    {:ok, record} = TaskReconciler.refresh(record, false)
    assert record["workflow"]["state"] == "waiting"
    assert record["workflow"]["restrictions"]["handoff"]["kind"] == "decision"
    assert "symphony:blocked" in Agent.get(server, & &1.raw["labels"])

    append(server, reply(92, "I agree with that plan.", 3))
    {:ok, record} = TaskReconciler.refresh(record, false)
    assert record["workflow"]["state"] == "waiting"

    append(server, reply(93, "Use the replay fixture."))
    {:ok, record} = TaskReconciler.refresh(record, false)
    assert record["workflow"]["state"] == "ready"
    refute record["workflow"]["restrictions"]["handoff"]
    assert record["workflow"]["resume_requested"]
    assert record["workflow"]["allowed_criteria"] == ["a", "b"]
    refute "symphony:blocked" in Agent.get(server, & &1.raw["labels"])

    assert :ok = Execution.finish(issue, opts, {:error, {:native_goal_stopped, "blocked"}})
    assert {:ok, _, resumed} = Execution.prepare(issue, [])
    assert resumed[:run_record]["thread_id"] == "native"
  end

  test "an earlier owner comment and the engine notice never answer the question", %{issue: issue, server: server, client: client} do
    {:ok, _, opts} = Execution.prepare(issue, [])
    record = opts[:run_record]
    append(server, reply(70, "Nice progress so far.", 1, "2026-10-16T00:00:05Z"))
    handoff_opts = [issue: issue, tracker_settings: Config.settings!().tracker, gitlab_client: client]
    assert Execution.handoff(%{"kind" => "decision", "reason" => "Pick a fixture."}, handoff_opts)["success"]
    {:ok, record} = RunJournal.checkpoint(current(record), %{"thread_id" => "native", "thread_allocation_intent" => true, "native_stop_confirmed" => true})
    {:ok, record} = TaskReconciler.refresh(record, false)
    {:ok, record} = TaskReconciler.refresh(record, false)
    refute record["workflow"]["resume_requested"]
    assert record["workflow"]["state"] == "waiting"
    assert record["workflow"]["restrictions"]["handoff"]["kind"] == "decision"
  end

  test "a review handoff keeps waiting for an explicit human label", %{issue: issue, server: server, client: client} do
    {:ok, _, opts} = Execution.prepare(issue, [])
    record = opts[:run_record]
    handoff_opts = [issue: issue, tracker_settings: Config.settings!().tracker, gitlab_client: client]
    assert Execution.handoff(%{"kind" => "review", "reason" => "Review the delivery."}, handoff_opts)["success"]
    {:ok, record} = RunJournal.checkpoint(current(record), %{"thread_id" => "native", "thread_allocation_intent" => true, "native_stop_confirmed" => true})
    {:ok, record} = TaskReconciler.refresh(record, false)
    assert record["workflow"]["state"] == "waiting"
    assert "symphony:review" in Agent.get(server, & &1.raw["labels"])

    append(server, reply(94, "Looks good to me."))
    {:ok, record} = TaskReconciler.refresh(record, false)
    assert record["workflow"]["state"] == "waiting"
    assert record["workflow"]["restrictions"]["handoff"]["kind"] == "review"
    refute record["workflow"]["resume_requested"]
  end

  test "a reply that quotes the engine notice still answers the question", %{issue: issue, server: server, client: client} do
    {:ok, _, opts} = Execution.prepare(issue, [])
    record = opts[:run_record]
    handoff_opts = [issue: issue, tracker_settings: Config.settings!().tracker, gitlab_client: client]
    assert Execution.handoff(%{"kind" => "decision", "reason" => "Pick a fixture."}, handoff_opts)["success"]
    {:ok, record} = RunJournal.checkpoint(current(record), %{"thread_id" => "native", "thread_allocation_intent" => true, "native_stop_confirmed" => true})
    {:ok, record} = TaskReconciler.refresh(record, false)

    # Quoting the notice carries its marker into the reply, but the reply does not
    # end with it, so the owner still answers the question.
    quoted = Enum.find(Agent.get(server, & &1.notes), &TaskReconciler.engine_notice?/1)["body"]
    quote_only = Enum.map_join(String.split(quoted, "\n"), "\n", &("> " <> &1))
    append(server, reply(95, quote_only <> "\n\nUse the replay fixture."))

    {:ok, record} = TaskReconciler.refresh(record, false)
    assert record["workflow"]["state"] == "ready"
    refute record["workflow"]["restrictions"]["handoff"]
  end

  test "a standalone resume note answers a decision handoff", %{issue: issue, server: server, client: client} do
    {:ok, _, opts} = Execution.prepare(issue, [])
    record = opts[:run_record]
    handoff_opts = [issue: issue, tracker_settings: Config.settings!().tracker, gitlab_client: client]
    assert Execution.handoff(%{"kind" => "decision", "reason" => "Pick a fixture."}, handoff_opts)["success"]
    {:ok, record} = RunJournal.checkpoint(current(record), %{"thread_id" => "native", "thread_allocation_intent" => true, "native_stop_confirmed" => true})
    {:ok, record} = TaskReconciler.refresh(record, false)

    # A plain resume note says the same thing as an answer, so on its own it
    # must drop the decision that is waiting for the human.
    append(server, reply(96, "Please resume this task."))

    {:ok, record} = TaskReconciler.refresh(record, false)
    assert record["workflow"]["state"] == "ready"
    refute record["workflow"]["restrictions"]["handoff"]
    assert record["workflow"]["resume_requested"]
    refute "symphony:blocked" in Agent.get(server, & &1.raw["labels"])
  end

  test "only the sole assignee's later comment parses as the answer to a decision" do
    asked = "2026-10-16T00:00:01Z"
    answered = "2026-10-16T00:00:02Z"
    flow = %{"contract" => nil, "restrictions" => %{"handoff" => %{"kind" => "decision"}}}

    notes = [
      reply(1, "**Symphony 需要确认**\n\nPick a fixture.\n\n" <> TaskReconciler.engine_notice_marker(), 1, asked),
      reply(2, "Looks fine to me.", 9, answered),
      reply(3, "Use the replay fixture.", 1, answered)
    ]

    # The reducer also refuses a stranger's resume, so this pins the parse
    # itself: the engine notice and the other author produce no event.
    assert TaskReconciler.events(notes, flow, "1") |> Enum.map(& &1["id"]) == [3]
  end

  test "a decision with no visible question takes no comment as its answer" do
    flow = %{"contract" => nil, "restrictions" => %{"handoff" => %{"kind" => "decision"}}}
    notes = [reply(1, "Use the replay fixture.", 1, "2026-10-16T00:00:02Z")]

    assert TaskReconciler.events(notes, flow, "1") == []
  end

  test "a resume note written before the question does not release the decision", %{issue: issue, server: server, client: client} do
    {:ok, _, opts} = Execution.prepare(issue, [])
    record = opts[:run_record]
    append(server, reply(70, "Please resume this task.", 1, "2026-10-16T00:00:05Z"))

    handoff_opts = [issue: issue, tracker_settings: Config.settings!().tracker, gitlab_client: client]
    assert Execution.handoff(%{"kind" => "decision", "reason" => "Pick a fixture."}, handoff_opts)["success"]
    {:ok, record} = RunJournal.checkpoint(current(record), %{"thread_id" => "native", "thread_allocation_intent" => true, "native_stop_confirmed" => true})
    {:ok, record} = TaskReconciler.refresh(record, false)
    {:ok, record} = TaskReconciler.refresh(record, false)

    assert record["workflow"]["state"] == "waiting"
    assert record["workflow"]["restrictions"]["handoff"]["kind"] == "decision"
  end

  test "an answering resume also releases the pause it follows", %{issue: issue, server: server, client: client} do
    {:ok, _, opts} = Execution.prepare(issue, [])
    record = opts[:run_record]
    append(server, reply(50, "Please pause this task.", 1, "2026-10-16T00:00:02Z"))

    handoff_opts = [issue: issue, tracker_settings: Config.settings!().tracker, gitlab_client: client]
    assert Execution.handoff(%{"kind" => "decision", "reason" => "Pick a fixture."}, handoff_opts)["success"]
    {:ok, record} = RunJournal.checkpoint(current(record), %{"thread_id" => "native", "thread_allocation_intent" => true, "native_stop_confirmed" => true})
    {:ok, record} = TaskReconciler.refresh(record, false)
    assert record["workflow"]["state"] == "waiting"

    append(server, reply(96, "Please resume this task."))
    {:ok, record} = TaskReconciler.refresh(record, false)

    assert record["workflow"]["state"] == "ready"
    refute record["workflow"]["restrictions"]["handoff"]
    refute Enum.any?(record["workflow"]["restrictions"], fn {_, restriction} -> restriction["kind"] == "pause" end)
  end

  test "a plain text answer leaves the pause it follows in place", %{issue: issue, server: server, client: client} do
    {:ok, _, opts} = Execution.prepare(issue, [])
    record = opts[:run_record]
    append(server, reply(50, "Please pause this task.", 1, "2026-10-16T00:00:02Z"))

    handoff_opts = [issue: issue, tracker_settings: Config.settings!().tracker, gitlab_client: client]
    assert Execution.handoff(%{"kind" => "decision", "reason" => "Pick a fixture."}, handoff_opts)["success"]
    {:ok, record} = RunJournal.checkpoint(current(record), %{"thread_id" => "native", "thread_allocation_intent" => true, "native_stop_confirmed" => true})
    {:ok, record} = TaskReconciler.refresh(record, false)
    assert record["workflow"]["state"] == "waiting"

    # Answering is not resuming: the reply releases the question, while the
    # pause the owner asked for keeps the task waiting until it is released.
    append(server, reply(96, "Use the replay fixture."))
    {:ok, record} = TaskReconciler.refresh(record, false)

    assert record["workflow"]["state"] == "waiting"
    assert record["workflow"]["restrictions"]["handoff"] == nil
    assert Enum.any?(record["workflow"]["restrictions"], fn {_, restriction} -> restriction["kind"] == "pause" end)

    append(server, reply(97, "Please resume this task."))
    {:ok, record} = TaskReconciler.refresh(record, false)

    assert record["workflow"]["state"] == "ready"
    refute Enum.any?(record["workflow"]["restrictions"], fn {_, restriction} -> restriction["kind"] == "pause" end)
  end

  test "a comment in the question's own second answers only after the notice note", %{issue: issue, server: server, client: client} do
    {:ok, _, opts} = Execution.prepare(issue, [])
    record = opts[:run_record]
    handoff_opts = [issue: issue, tracker_settings: Config.settings!().tracker, gitlab_client: client]
    assert Execution.handoff(%{"kind" => "decision", "reason" => "Pick a fixture."}, handoff_opts)["success"]
    {:ok, record} = RunJournal.checkpoint(current(record), %{"thread_id" => "native", "thread_allocation_intent" => true, "native_stop_confirmed" => true})
    {:ok, record} = TaskReconciler.refresh(record, false)
    notice = Agent.get(server, & &1.notes) |> Enum.filter(&TaskReconciler.engine_notice?/1) |> List.last()

    # Notes carry second precision, so the note order decides inside that second.
    append(server, reply(notice["id"] - 1, "I agree with that plan.", 1, notice["updated_at"]))
    {:ok, record} = TaskReconciler.refresh(record, false)
    assert record["workflow"]["state"] == "waiting"

    append(server, reply(notice["id"] + 1, "Use the replay fixture.", 1, notice["updated_at"]))
    {:ok, record} = TaskReconciler.refresh(record, false)
    assert record["workflow"]["state"] == "ready"
    refute record["workflow"]["restrictions"]["handoff"]
  end

  test "an answer that quotes the notice underneath still answers the question", %{issue: issue, server: server, client: client} do
    {:ok, _, opts} = Execution.prepare(issue, [])
    record = opts[:run_record]
    handoff_opts = [issue: issue, tracker_settings: Config.settings!().tracker, gitlab_client: client]
    assert Execution.handoff(%{"kind" => "decision", "reason" => "Pick a fixture."}, handoff_opts)["success"]
    {:ok, record} = RunJournal.checkpoint(current(record), %{"thread_id" => "native", "thread_allocation_intent" => true, "native_stop_confirmed" => true})
    {:ok, record} = TaskReconciler.refresh(record, false)

    # Mail replies put the answer first and the quoted notice last.
    quoted = Enum.find(Agent.get(server, & &1.notes), &TaskReconciler.engine_notice?/1)["body"]
    append(server, reply(95, "Use the replay fixture.\n\n" <> Enum.map_join(String.split(quoted, "\n"), "\n", &("> " <> &1))))

    {:ok, record} = TaskReconciler.refresh(record, false)
    assert record["workflow"]["state"] == "ready"
    refute record["workflow"]["restrictions"]["handoff"]
  end
end
