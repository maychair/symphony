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
    flow = TaskWorkflow.handoff(record["workflow"], %{"kind" => "review"}) |> Map.put("intermediate", %{"url" => url, "kind" => "mr", "version" => "v1"})
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
      data = %{"contract" => contract, "items" => [%{"id" => "code", "kind" => "mr", "url" => url, "version" => "v1", "criteria" => ["a", "b"]}]}
      manifest = note(20, "manifest", data, contract)
      Agent.update(server, &%{&1 | notes: [hd(&1.notes), manifest]})
      assert {:ok, updated} = TaskReconciler.refresh(record, false)
      refute updated["workflow"]["manifest"]
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
    agreement = %{
      "issue_version" => TaskWorkflow.digest("Deliver the result"),
      "type" => "research",
      "criteria" => ["answer"],
      "acceptor" => "2",
      "acceptance_mode" => "separate",
      "close_on_conclusion" => true,
      "deliverables" => [%{"id" => "report", "kind" => "report"}]
    }

    Agent.update(server, &%{&1 | raw: Map.put(&1.raw, "labels", ["symphony:ready", "type:research"]), notes: [note(1, "authorize", agreement)]})
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
      "issue_version" => TaskWorkflow.digest("Deliver the result"),
      "type" => "development",
      "criteria" => ["a", "b"],
      "acceptor" => "2",
      "acceptance_mode" => "separate",
      "close_on_conclusion" => true,
      "deliverables" => [%{"id" => "first", "kind" => "mr"}, %{"id" => "second", "kind" => "mr"}]
    }

    url = "https://gitlab.test/group/project/-/merge_requests/9"
    mr = %{"web_url" => url, "sha" => "v1", "source_project_id" => 1, "target_project_id" => 1, "state" => "merged", "merged_at" => "2026-10-16T00:00:00Z"}
    Agent.update(server, &%{&1 | notes: [note(1, "authorize", agreement)], mr: mr})
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

  test "authorized recovery respects the cumulative failure count across successful handoffs", context do
    %{issue: issue, server: server, contract: contract, client: client} = context
    {:ok, _, opts} = Execution.prepare(issue, [])
    record = opts[:run_record]
    append(server, note(2, "rework", %{"criteria" => ["a"], "changes" => []}, contract, 2))
    {:ok, record} = RunJournal.checkpoint(record, %{"native_stop_confirmed" => true, "retry_count" => 1, "attempt_count" => 10})
    {:ok, record} = TaskReconciler.refresh(record, false)
    :ok = RunJournal.complete(record, "incident")
    assert Execution.resumable?(issue)
    {:ok, _, resumed} = Execution.prepare(issue, [])
    assert resumed[:run_record]["retry_count"] == 1
    assert resumed[:run_record]["attempt_count"] == 11
    # Successful review/rework attempts did not spend the two transient retries.
    assert :ok = Execution.finish(issue, resumed, {:error, :fixture_failure})
    {:ok, record} = RunJournal.read(record["directory"])
    assert record["retry_count"] == 2 and record["phase"] == "completed"
    {:ok, _, third} = Execution.prepare(issue, [])
    assert :ok = Execution.finish(issue, third, {:error, :fixture_failure})
    {:ok, record} = RunJournal.read(record["directory"])
    assert record["retry_count"] == 3 and record["phase"] == "incident"
    refute Execution.resumable?(issue)
    retry = %{issue | labels: issue.labels ++ ["symphony:retry"]}
    {:ok, _, explicit} = Execution.prepare(retry, gitlab_client: client)
    assert explicit[:run_record]["retry_count"] == 3
  end

  test "waiting admission exits normally without allocating a native execution", %{issue: issue, server: server} do
    Agent.update(server, &%{&1 | notes: []})
    assert :ok = SymphonyElixir.AgentRunner.run(issue)
    {:ok, record} = RunJournal.read(RunJournal.directory(Execution.journal_root(), issue.id))
    assert record["workflow"]["state"] == "waiting"
    refute record["thread_id"]
    refute record["blocker_reason"]
    refute File.exists?(Path.join(record["directory"], "executor.lock"))
  end
end
