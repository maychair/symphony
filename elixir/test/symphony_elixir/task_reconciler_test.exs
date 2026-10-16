defmodule SymphonyElixir.TaskReconcilerTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.{Execution, RunJournal, TaskReconciler, TaskWorkflow}

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
    raw = %{"web_url" => url, "state" => "opened", "assignees" => [%{"id" => 1}], "labels" => ["symphony:ready", "type:development"], "description" => "Deliver the result"}

    agreement = %{
      "issue_version" => TaskWorkflow.digest(raw["description"]),
      "type" => "development",
      "criteria" => ["a", "b"],
      "acceptor" => "2",
      "reviewers" => ["3"],
      "acceptance_mode" => "separate",
      "deliverables" => [%{"id" => "code", "kind" => "mr"}]
    }

    note = note(1, "authorize", agreement)
    [event] = TaskReconciler.events([note], %{}, "1")
    state = %{raw: raw, notes: [note], mr: %{}, dependency: %{"state" => "opened"}, calls: [], fault: nil}
    {:ok, server} = Agent.start_link(fn -> state end)

    client = fn method, path, query, body, _ ->
      Agent.get_and_update(server, fn state ->
        state = %{state | calls: state.calls ++ [{method, path, query, body}]}

        cond do
          state.fault ->
            {state.fault, state}

          String.ends_with?(path, "/notes") ->
            notes = Enum.slice(state.notes, ((query["page"] || 1) - 1) * 100, 100)
            {{:ok, %{status: 200, body: notes}}, state}

          String.ends_with?(path, "/merge_requests/9") ->
            {{:ok, %{status: 200, body: state.mr}}, state}

          String.ends_with?(path, "/issues/7") ->
            {{:ok, %{status: 200, body: state.dependency}}, state}

          method == "PUT" ->
            labels = state.raw["labels"]
            labels = if body["remove_labels"], do: labels -- String.split(body["remove_labels"], ","), else: Enum.uniq(labels ++ String.split(body["add_labels"], ","))
            raw = Map.put(state.raw, "labels", labels)
            {{:ok, %{status: 200, body: raw}}, %{state | raw: raw}}

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

    {:ok, server: server, issue: issue, contract: event["ref"], client: client}
  end

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
  defp current(record), do: elem(RunJournal.read(record["directory"]), 1)

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
    refute "symphony:ready" in Agent.get(server, & &1.raw["labels"])
    assert record["workflow"]["charging"]
    {:ok, record} = RunJournal.checkpoint(record, %{"native_stop_confirmed" => true})
    refute record["workflow"]["charging"]
    :ok = Execution.finish(issue, opts, {:error, :scheduler_stop})
    Agent.update(server, &%{&1 | dependency: %{"state" => "closed"}})
    assert :ok = TaskReconciler.poll(MapSet.new())
    record = current(record)
    refute record["workflow"]["restrictions"]["dep"]
    assert record["workflow"]["state"] == "waiting"
    refute "symphony:ready" in Agent.get(server, & &1.raw["labels"])
    append(server, %{note(4, "resume", %{}, contract) | "body" => "恢复执行"})
    assert :ok = TaskReconciler.poll(MapSet.new())
    assert "symphony:ready" in Agent.get(server, & &1.raw["labels"])
    used = current(record)["workflow"]["used_ms"]
    assert {:ok, _, resumed} = Execution.prepare(issue, [])
    assert resumed[:run_record]["workflow"]["used_ms"] >= used
    assert resumed[:run_record]["thread_id"] == "native"
    assert :ok = TaskReconciler.poll(MapSet.new([issue.id]))
    before = File.read!(Path.join(record["directory"], "run.json"))
    assert :ok = TaskReconciler.poll(MapSet.new())
    assert File.read!(Path.join(record["directory"], "run.json")) == before
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

  test "a verified intermediate merge restores routing, preserving task-level delivery and budget", %{server: server, issue: issue} do
    {:ok, _, opts} = Execution.prepare(issue, [])
    record = opts[:run_record]
    url = "https://gitlab.test/group/project/-/merge_requests/9"
    flow = TaskWorkflow.handoff(record["workflow"], %{"kind" => "review"}) |> Map.put("intermediate", %{"url" => url, "version" => "v1"})
    {:ok, record} = RunJournal.checkpoint(record, %{"workflow" => flow, "native_stop_confirmed" => true, "thread_allocation_intent" => true, "thread_id" => "same"})
    :ok = RunJournal.complete(record, "completed")
    Agent.update(server, &%{&1 | raw: Map.put(&1.raw, "labels", ["type:development"]), mr: %{"web_url" => url, "sha" => "v1", "source_project_id" => 1, "target_project_id" => 1, "state" => "opened"}})
    :ok = TaskReconciler.poll(MapSet.new())
    assert current(record)["workflow"]["state"] == "waiting"
    Agent.update(server, &%{&1 | mr: Map.merge(&1.mr, %{"state" => "merged", "merged_at" => "2026-10-16T00:00:00Z"})})
    :ok = TaskReconciler.poll(MapSet.new())
    assert current(record)["workflow"]["state"] == "ready"
    assert "symphony:ready" in Agent.get(server, & &1.raw["labels"])
    refute current(record)["workflow"]["acceptance"]
  end

  test "paginated decision reads, edited notes, malformed markers and stale observations remain conservative", %{server: server, issue: issue, contract: contract} do
    {:ok, _, opts} = Execution.prepare(issue, [])
    record = opts[:run_record]
    filler = for id <- 100..199, do: Map.put(note(id, "pause", %{}), "system", true)
    Agent.update(server, &%{&1 | notes: &1.notes ++ filler})
    append(server, %{note(200, "pause", %{}) | "body" => "<!-- symphony-workflow {bad} -->"})
    append(server, %{note(201, "pause", %{}) | "body" => "Ordinary review suggestion"})
    assert {:ok, observation} = TaskReconciler.observe(record)
    assert length(observation.events) == 1
    stale = %{record | "attempt_id" => "other"}
    assert {:error, :stale_execution_observation} = TaskReconciler.apply_observation(stale, observation, false)
    append(server, note(202, "rework", %{"criteria" => ["a"], "changes" => []}, contract, 2))
    {:ok, record} = TaskReconciler.refresh(record, false)
    assert record["workflow"]["resume_requested"]
    Agent.update(server, fn state -> %{state | notes: Enum.map(state.notes, fn note -> if note["id"] == 1, do: Map.put(note, "body", "Edited agreement"), else: note end)} end)
    {:ok, record} = TaskReconciler.refresh(record, false)
    assert record["workflow"]["restrictions"]["baseline"]
    Agent.update(server, &%{&1 | fault: {:error, :offline}})
    assert {:error, {:task_facts_unavailable, _}} = TaskReconciler.refresh(record, false)
  end

  test "report manifests and final acceptance reference immutable current note versions", %{server: server, issue: issue} do
    Agent.update(server, fn state ->
      raw = Map.put(state.raw, "labels", ["symphony:ready", "type:research"])

      agreement = %{
        "issue_version" => TaskWorkflow.digest(raw["description"]),
        "type" => "research",
        "criteria" => ["answer"],
        "acceptor" => "2",
        "acceptance_mode" => "separate",
        "deliverables" => [%{"id" => "report", "kind" => "report"}]
      }

      %{state | raw: raw, notes: [note(1, "authorize", agreement)]}
    end)

    {:ok, _, opts} = Execution.prepare(%{issue | labels: ["symphony:ready", "type:research"]}, [])
    record = opts[:run_record]
    contract = record["workflow"]["contract"]["ref"]
    append(server, %{note(2, "report", %{}) | "body" => "The evidenced answer; uncertainty remains."})

    data = %{
      "contract" => contract,
      "items" => [%{"id" => "report", "url" => issue.url <> "#note_2", "version" => TaskWorkflow.digest("The evidenced answer; uncertainty remains."), "criteria" => ["answer"]}]
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

    assert {:error, {:routing_release_unconfirmed, _}} = TaskReconciler.refresh(record, true, client: fail_put)
    {:ok, record} = TaskReconciler.refresh(current(record), true)
    {:ok, record} = RunJournal.checkpoint(record, %{"native_stop_confirmed" => true})
    append(server, note(3, "resume", %{"restrictions" => [hd(TaskReconciler.events([note(2, "pause", %{}, contract)], %{}, "1"))["ref"]]}, contract))
    assert {:error, {:routing_restore_unconfirmed, _}} = TaskReconciler.refresh(record, false, client: fail_put)
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
      data = %{"contract" => contract, "items" => [%{"id" => "code", "url" => url, "version" => "v1", "criteria" => ["a", "b"]}]}
      manifest = note(20, "manifest", data, contract)
      Agent.update(server, &%{&1 | notes: [hd(&1.notes), manifest]})
      assert {:error, _} = TaskReconciler.refresh(record, false)
    end

    Agent.update(server, &%{&1 | notes: [hd(&1.notes)]})
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
    Agent.update(server, &%{&1 | notes: [hd(&1.notes), bad]})
    assert {:ok, _} = TaskReconciler.refresh(record, false)
  end

  test "handoff intent preserves intermediate delivery and finalizes even when the provider later becomes unavailable", %{issue: issue, server: server, client: client} do
    {:ok, _, opts} = Execution.prepare(issue, [])
    record = opts[:run_record]
    delivery = %{"url" => "https://gitlab.test/group/project/-/merge_requests/9", "version" => "v1"}
    {:ok, _} = RunJournal.checkpoint(record, %{"delivery" => delivery})
    arguments = %{"kind" => "review", "reason" => "Review this intermediate change.", "url" => delivery["url"], "continue_after" => "merged"}
    assert Execution.handoff(arguments, issue: issue, tracker_settings: Config.settings!().tracker, gitlab_client: client)["success"]
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
end
