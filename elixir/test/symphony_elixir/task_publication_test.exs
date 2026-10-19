defmodule SymphonyElixir.TaskPublicationTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.{ArtifactStore, CommandCheck, ReportArtifact, TaskTools}
  alias SymphonyElixir.Codex.DynamicTool
  alias SymphonyElixir.{GitArtifact, GitArtifactFixture}
  alias SymphonyElixir.{NativeWork, RunJournal, TaskDecision, TaskDelivery, TaskDependencies}
  alias SymphonyElixir.{TaskEvidence, TaskExecution, TaskExecutionConfig, TaskLifecycle}
  alias SymphonyElixir.{TaskPlan, TaskPlanManifest, TaskPlanPreflight, TaskPublication}
  alias SymphonyElixir.{TaskWorkflow, TaskWorkspace, WorkRef}

  defp contract(work, parent, kind \\ "report") do
    data = %{
      "schema_version" => 2,
      "work" => work,
      "parent" => parent,
      "goal" => "Deliver the approved result",
      "non_goals" => [],
      "criteria" => ["result"],
      "criteria_details" => %{"result" => "Reproducible output"},
      "verification_checks" => %{"result" => ["test"]},
      "authorizer" => "1",
      "acceptance_mode" => if(parent, do: "technical", else: "separate"),
      "acceptor" => if(parent, do: nil, else: "2"),
      "budget_ms" => 100_000,
      "deliverables" => [%{"id" => "output", "kind" => kind, "criteria" => ["result"]}]
    }

    data = if kind in ["pr", "mr"], do: Map.update!(data, "deliverables", &Enum.map(&1, fn output -> Map.put(output, "target_branch", "main") end)), else: data
    Map.put(data, "contract_sha", TaskWorkflow.digest(data))
  end

  defp fixture(provider, stages \\ [], kind \\ "report", checks \\ nil) do
    work = %{"provider" => provider, "host" => provider <> ".test", "repository_id" => "10", "kind" => "issue", "number" => 2}
    parent = %{work | "number" => 1}
    child_scope = contract(work, parent, kind)
    root_scope = contract(parent, nil) |> Map.delete("contract_sha") |> Map.put("budget_ms", 100_000 * (1 + length(stages)))
    root_scope = Map.put(root_scope, "contract_sha", TaskWorkflow.digest(root_scope))
    member = %{"work" => work, "contract_sha" => child_scope["contract_sha"], "criteria" => ["result"], "budget_ms" => 100_000, "human_gate" => false}

    extra =
      Enum.with_index(stages, 3)
      |> Enum.map(fn {_, number} ->
        child = %{work | "number" => number}
        %{member | "work" => child, "contract_sha" => contract(child, parent, kind)["contract_sha"]}
      end)

    edges =
      Enum.with_index(stages, 3)
      |> Enum.map(fn {stage, number} ->
        %{"from" => %{work | "number" => number - 1}, "to" => %{work | "number" => number}, "artifact" => "output", "criteria" => ["result"], "stage" => stage}
      end)

    {:ok, plan} =
      TaskPlan.seal(%{
        "parent" => parent,
        "contract_sha" => root_scope["contract_sha"],
        "authorizer" => "1",
        "criteria" => ["result"],
        "members" => [member | extra],
        "dependencies" => edges,
        "integration" => %{work | "number" => 2 + length(stages)},
        "budget_ms" => root_scope["budget_ms"]
      })

    approval = note(1, 1, "<!-- symphony-plan-decision " <> Jason.encode!(%{"action" => "authorize", "revision" => plan["revision"]}) <> " -->")
    parent_body = block(root_scope) <> "\n<!-- symphony-plan " <> Jason.encode!(plan) <> " -->"
    prefix = if provider == "github", do: "/repos/team/repo", else: "/projects/team%2Frepo"
    suffix = if provider == "github", do: "/comments", else: "/notes"
    url = "https://" <> work["host"] <> "/team/repo"

    repo = if provider == "github", do: %{"id" => 10, "full_name" => "team/repo", "html_url" => url}, else: %{"id" => 10, "path_with_namespace" => "team/repo", "web_url" => url}

    raw = fn number, body ->
      base = %{"id" => number + 100, "state" => "open", "assignees" => [%{"id" => 1}]}

      if provider == "github",
        do: Map.merge(base, %{"number" => number, "body" => body, "html_url" => url <> "/issues/#{number}"}),
        else: Map.merge(base, %{"iid" => number, "description" => body, "project_id" => 10, "web_url" => url <> "/-/issues/#{number}"})
    end

    objects = %{
      prefix => repo,
      "/user" => %{"id" => 99},
      (prefix <> "/issues/1") => raw.(1, parent_body),
      (prefix <> "/issues/2") => raw.(2, block(child_scope)),
      (prefix <> "/issues/1" <> suffix) => [approval],
      (prefix <> "/issues/2" <> suffix) => []
    }

    objects =
      Enum.reduce(extra, objects, fn member, objects ->
        child = member["work"]
        path = prefix <> "/issues/#{child["number"]}"
        objects |> Map.put(path, raw.(child["number"], block(contract(child, parent, kind)))) |> Map.put(path <> suffix, [])
      end)

    state = start_supervised!({Agent, fn -> %{objects: objects, posts: [], mode: :success} end}, id: make_ref())

    request = fn ^provider, "GET", path, _, _ ->
      {:ok, %{status: 200, body: Agent.get(state, &Map.fetch!(&1.objects, path))}}
    end

    writer = fn ^provider, "POST", path, query, %{"body" => body}, _ ->
      assert query == %{}

      assert path in Enum.map(2..(2 + length(stages)), &(prefix <> "/issues/#{&1}" <> suffix))
      Agent.get_and_update(state, &store_post(&1, path, body))
    end

    repository =
      Map.take(work, ~w(provider host repository_id))
      |> Map.merge(%{"path" => "team/repo", "api_url" => "https://" <> work["host"] <> if(provider == "github", do: "/api/v3", else: "/api/v4"), "credential" => "$UNUSED_PUBLICATION_FIXTURE"})

    policy = %{
      "engine_actor" => "99",
      "max_repairs" => 2,
      "max_retries" => 2,
      "checks" => checks || %{"test" => %{"kind" => "command", "command" => "grep -x expected result", "artifact" => "output", "timeout_ms" => 2_000}}
    }

    opts = [repositories: [repository], request: request, write_request: writer, policy: policy]
    {:ok, preflight} = TaskPlanPreflight.inspect_plan(parent, opts)

    binding = %{
      "work" => work,
      "role" => "developer",
      "plan_revision" => plan["revision"],
      "contract_sha" => child_scope["contract_sha"],
      "authority" => preflight.authority,
      "inputs" => [],
      "candidate" => nil,
      "policy_sha" => TaskWorkflow.digest(policy)
    }

    root = Path.join(System.tmp_dir!(), "publication-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, record} = RunJournal.admit(root, WorkRef.key(work), execution_binding: binding)
    {:ok, record} = RunJournal.checkpoint(record, %{"thread_id" => "developer"})
    payload = %{"work" => work, "contract_sha" => child_scope["contract_sha"], "inputs" => [], "artifacts" => [%{"id" => "output", "kind" => kind, "version" => "v1"}]}

    %{
      record: record,
      payload: payload,
      opts: opts,
      state: state,
      notes: prefix <> "/issues/2" <> suffix,
      parent_notes: prefix <> "/issues/1" <> suffix,
      child: prefix <> "/issues/2",
      parent: parent
    }
  end

  defp store_post(current, path, body) do
    notes = current.objects[path]
    new_note = note(100 + length(notes), 99, body)
    objects = if current.mode == :missing, do: current.objects, else: Map.put(current.objects, path, notes ++ [new_note])
    result = if current.mode == :success, do: {:ok, %{status: 201, body: new_note}}, else: {:error, :lost_response}
    {result, %{current | objects: objects, posts: current.posts ++ [body]}}
  end

  defp block(scope), do: "<!-- symphony-contract " <> Jason.encode!(scope) <> " -->"

  defp note(id, actor, body),
    do: %{"id" => id, "body" => body, "author" => %{"id" => actor}, "user" => %{"id" => actor}, "created_at" => "2026-10-17T00:00:00Z", "updated_at" => "2026-10-17T00:00:00Z"}

  defp current(fixture), do: elem(RunJournal.read(fixture.record["directory"]), 1)
  defp publish(fixture, record \\ nil), do: TaskPublication.publish(record || fixture.record, "candidate", fixture.payload, "Candidate ready for verification", fixture.opts)
  defp posts(fixture), do: Agent.get(fixture.state, & &1.posts)

  defp git_artifact(fixture) do
    provider = fixture.payload["work"]["provider"]
    source = Path.join(fixture.record["directory"], "fixture-source")
    workspace = Path.join(fixture.record["directory"], "fixture-developer")
    git = GitArtifactFixture.create(source, provider)
    GitArtifactFixture.git(source, ["worktree", "add", "--detach", workspace, git.revision])
    prefix = String.replace_suffix(fixture.child, "/issues/2", "")
    objects = Map.new(git.objects, fn {path, value} -> {prefix <> path, value} end)
    Agent.update(fixture.state, &%{&1 | objects: Map.merge(&1.objects, objects)})
    artifact = hd(fixture.payload["artifacts"]) |> Map.merge(%{"version" => git.revision, "source" => GitArtifact.source_ref(fixture.payload["work"], git.revision)})
    Map.merge(fixture, %{payload: Map.put(fixture.payload, "artifacts", [artifact]), git: git, workspace: workspace})
  end

  defp evidence(fixture, record, policy \\ nil) do
    {:ok, plan} = TaskPlanPreflight.inspect_plan(fixture.parent, fixture.opts)
    TaskEvidence.read_member(plan, fixture.payload["work"], record, policy || fixture.opts[:policy], fixture.opts)
  end

  defp control(fixture, scope, action, id, extra \\ %{}) do
    binding = fixture.record["execution_binding"]
    payload = %{"action" => action, "revision" => binding["plan_revision"]}
    payload = if scope == :member, do: Map.put(payload, "contract_sha", binding["contract_sha"]), else: payload
    marker = if scope == :member, do: "task", else: "plan"
    body = "<!-- symphony-#{marker}-decision " <> Jason.encode!(Map.merge(payload, extra)) <> " -->"
    {:ok, base, _} = DateTime.from_iso8601("2026-10-17T00:00:00Z")
    time = DateTime.add(base, id) |> DateTime.to_iso8601()
    note(id, 1, body) |> Map.merge(%{"created_at" => time, "updated_at" => time})
  end

  defp task_tools(fixture, record \\ nil) do
    record = record || current(fixture)
    now = System.system_time(:millisecond)
    flow = TaskWorkflow.new(100_000, now) |> TaskWorkflow.start(now) |> Map.merge(%{"schema_version" => 2, "repair_history" => %{}})
    {:ok, record} = RunJournal.checkpoint(record, %{"workflow" => flow, "native_stop_confirmed" => false})
    {:ok, tools} = TaskTools.bind(record, fixture.opts[:policy], fixture.opts)
    tools
  end

  defp tool(tools, name, arguments, opts \\ []) do
    result = DynamicTool.execute(name, arguments, tools, opts)
    {result["success"], Jason.decode!(result["output"])}
  end

  defp candidate_args(fixture),
    do: %{
      "artifacts" => Enum.map(fixture.payload["artifacts"], fn artifact -> Map.take(artifact, if(Map.has_key?(artifact, "body"), do: ~w(id body), else: ~w(id version target))) end),
      "summary" => "Fixed candidate ready"
    }

  defp verifier_tools(fixture, developer) do
    {:ok, stopped} = RunJournal.checkpoint(developer, %{"native_stop_confirmed" => true})
    :ok = RunJournal.complete(stopped, "completed")
    binding = %{stopped["execution_binding"] | "role" => "verifier", "candidate" => TaskWorkflow.digest(fixture.payload)}
    {:ok, verifier} = RunJournal.admit(Path.dirname(stopped["directory"]), stopped["issue_id"], execution_binding: binding)
    {:ok, verifier} = RunJournal.checkpoint(verifier, %{"thread_id" => "tool-verifier-#{verifier["execution_generation"]}", "workspace" => fixture.workspace})
    task_tools(fixture, verifier)
  end

  defp verified_tools(f) do
    assert {true, _} = tool(task_tools(f), "task_candidate", candidate_args(f))
    verifier = verifier_tools(f, current(f))
    assert {true, %{"data" => %{"exit_code" => 0}}} = tool(verifier, "task_check", %{"check_id" => "test"})
    assert {true, _} = tool(verifier, "task_verification", %{"review_checks" => [], "findings" => [], "summary" => "Verified fixed output"})
    f
  end

  defp verified_report(f) do
    {:ok, developer, _} = TaskPublication.publish(current(f), "candidate", f.payload, "Candidate report", f.opts)
    {:ok, stopped} = RunJournal.checkpoint(developer, %{"native_stop_confirmed" => true})
    :ok = RunJournal.complete(stopped, "completed")
    binding = %{stopped["execution_binding"] | "role" => "verifier", "candidate" => TaskWorkflow.digest(f.payload)}
    {:ok, verifier} = RunJournal.admit(Path.dirname(stopped["directory"]), stopped["issue_id"], execution_binding: binding)
    {:ok, verifier} = RunJournal.checkpoint(verifier, %{"thread_id" => "report-verifier-#{verifier["execution_generation"]}"})

    verdict = %{
      "candidate" => TaskWorkflow.digest(f.payload),
      "inputs" => f.payload["inputs"],
      "policy_sha" => TaskWorkflow.digest(f.opts[:policy]),
      "checks" => [%{"id" => "test", "candidate" => TaskWorkflow.digest(f.payload), "result" => "passed", "rationale" => "Independent report review"}],
      "findings" => []
    }

    {:ok, verifier, _} = TaskPublication.publish(verifier, "verification", verdict, "Verified report", f.opts)
    {:ok, stopped} = RunJournal.checkpoint(verifier, %{"native_stop_confirmed" => true})
    :ok = RunJournal.complete(stopped, "completed")
    f
  end

  defp report_consumer(f, input) do
    work = %{f.payload["work"] | "number" => 3}
    binding = %{f.record["execution_binding"] | "work" => work, "contract_sha" => contract(work, f.parent)["contract_sha"], "inputs" => [input]}
    {:ok, record} = RunJournal.admit(Path.dirname(f.record["directory"]), WorkRef.key(work), execution_binding: binding)
    {:ok, record} = RunJournal.checkpoint(record, %{"thread_id" => "report-consumer"})
    {:ok, report} = ReportArtifact.build(work, "output", "Consumer report")
    payload = %{"work" => work, "contract_sha" => binding["contract_sha"], "inputs" => [input], "artifacts" => [report]}
    child = String.replace(f.child, "/issues/2", "/issues/3")
    notes = String.replace(f.notes, "/issues/2", "/issues/3")
    %{f | record: record, payload: payload, child: child, notes: notes}
  end

  defp revised_report(f, body) do
    previous = current(f)
    binding = %{previous["execution_binding"] | "role" => "developer", "candidate" => TaskWorkflow.digest(f.payload)}
    {:ok, record} = RunJournal.admit(Path.dirname(previous["directory"]), previous["issue_id"], execution_binding: binding)
    {:ok, record} = RunJournal.checkpoint(record, %{"thread_id" => "report-revision"})
    {:ok, report} = ReportArtifact.build(f.payload["work"], "output", body)
    %{f | record: record, payload: Map.put(f.payload, "artifacts", [report])} |> verified_report()
  end

  defp confirmed_rework(f, superseded) do
    {:ok, preflight} = TaskPlanPreflight.inspect_plan(f.parent, f.opts)
    plan = preflight.plan

    body = %{
      "schema_version" => 2,
      "plan_revision" => plan["revision"],
      "criteria" => plan["criteria"],
      "integration" => plan["integration"],
      "members" => Enum.map(plan["members"], &Map.take(&1, ["work"]))
    }

    manifest = Map.put(body, "revision", TaskWorkflow.digest(body))
    manifest_note = note(710, 99, "<!-- symphony-plan-manifest " <> Jason.encode!(manifest) <> " -->")
    [entry] = TaskPlanManifest.manifests(%{notes: [manifest_note]})
    decision = %{"action" => "rework", "manifest" => entry["source"], "revision" => manifest["revision"], "criteria" => ["result"]}
    decision_note = note(711, 2, "<!-- symphony-plan-acceptance " <> Jason.encode!(decision) <> " -->")
    decision_note = Map.merge(decision_note, %{"created_at" => "2026-10-17T00:00:01Z", "updated_at" => "2026-10-17T00:00:01Z"})
    Agent.update(f.state, &update_in(&1.objects[f.parent_notes], fn notes -> notes ++ [manifest_note, decision_note] end))

    %{
      "status" => "confirmed",
      "source" => "issue:reopened",
      "parent_source" => TaskDecision.source_ref(decision_note),
      "manifest" => entry["source"],
      "criteria" => ["result"],
      "superseded" => superseded
    }
  end

  defp persist_report_flow(observation) do
    record = observation.record
    {:ok, locked} = RunJournal.admit(Path.dirname(record["directory"]), record["issue_id"], execution_binding: record["execution_binding"])
    {:ok, updated} = RunJournal.checkpoint(locked, %{"workflow" => observation.flow})
    :ok = RunJournal.complete(updated, "completed")
  end

  defp report_fixture(provider, stages) do
    f = fixture(provider, stages, "report", %{"test" => %{"kind" => "review"}})
    body = "# Findings\n\nThe cited experiment supports the conclusion.\n\nLimit: only the approved input was examined.\n<!-- reader note -->"
    {:ok, report} = ReportArtifact.build(f.payload["work"], "output", body)
    %{f | payload: Map.put(f.payload, "artifacts", [report])} |> Map.put(:workspace, nil)
  end

  defp fresh_execution(f) do
    File.rm_rf!(f.record["directory"])
    f
  end

  defp native_tools(f, record, thread) do
    {:ok, record} = RunJournal.checkpoint(record, %{"thread_id" => thread, "thread_allocation_intent" => true, "native_stop_confirmed" => false})
    {:ok, tools} = TaskTools.bind(record, f.opts[:policy], f.opts)
    {record, tools}
  end

  test "native evidence derives and admits developer then independent verifier, retaining budget and stop fences" do
    for provider <- ["github", "gitlab"] do
      f = report_fixture(provider, []) |> fresh_execution()
      registry = executions([f])
      work = f.payload["work"]
      assert {:ok, initial} = TaskExecution.observe(f.parent, work, registry, f.opts)
      assert initial.flow["next_binding"]["role"] == "developer"
      refute initial.flow["started"]
      refute File.exists?(Path.join(f.record["directory"], "run.json"))
      assert {:ok, admitted} = TaskExecution.admit(f.parent, work, registry, f.opts)
      assert admitted.flow["charging"]
      assert admitted.record["execution_generation"] == 1
      assert {:error, {:run_admission_blocked, _, :eexist}} = TaskExecution.admit(f.parent, work, registry, f.opts)
      {developer, tools} = native_tools(f, admitted.record, "native-developer")
      assert {true, _} = tool(tools, "task_candidate", candidate_args(f))
      assert {:ok, next} = TaskExecution.refresh(developer, registry, Keyword.put(f.opts, :active, true))
      assert next.flow["next_binding"]["role"] == "verifier"
      assert next.flow["stop_required"]
      refute next.flow["dispatchable"]
      assert {:waiting, uncertain} = TaskExecution.admit(f.parent, work, registry, f.opts)
      assert uncertain.flow["restrictions"]["native_stop"]
      {:ok, stopped} = RunJournal.checkpoint(next.record, %{"native_stop_confirmed" => true})
      :ok = RunJournal.complete(stopped, "completed")
      assert {:ok, verifying} = TaskExecution.admit(f.parent, work, registry, f.opts)
      assert verifying.record["execution_generation"] == 2
      assert verifying.flow["used_ms"] >= next.flow["used_ms"]
      assert verifying.record["execution_binding"]["candidate"] == TaskWorkflow.digest(f.payload)
      assert verifying.record["execution_binding"]["role"] == "verifier"
      assert {:error, :native_thread_reused_across_generations} = RunJournal.checkpoint(verifying.record, %{"thread_id" => "native-developer"})
      assert {:error, :execution_attempt_changed} = TaskExecution.refresh(developer, registry, f.opts)
      assert {false, _} = tool(tools, "task_candidate", candidate_args(f))
      {verifier, review_tools} = native_tools(f, verifying.record, "native-verifier")
      review = %{"id" => "test", "result" => "passed", "rationale" => "Checked the exact report and its cited evidence against every approved criterion."}
      assert {true, _} = tool(review_tools, "task_verification", %{"review_checks" => [review], "findings" => [], "summary" => "Verified"})
      assert {:ok, pending_stop} = TaskExecution.refresh(verifier, registry, Keyword.put(f.opts, :active, true))
      assert pending_stop.flow["stop_required"]
      refute pending_stop.flow["closeable"]
      {:ok, stopped} = RunJournal.checkpoint(pending_stop.record, %{"native_stop_confirmed" => true})
      assert {:ok, completed} = TaskExecution.refresh(stopped, registry, f.opts)
      assert completed.flow["closeable"]
      refute completed.flow["charging"]
      :ok = RunJournal.complete(completed.record, "completed")
      assert {:waiting, observation} = TaskExecution.admit(f.parent, work, registry, f.opts)
      assert observation.flow["outcome"] == "delivered"
      assert length(posts(f)) == 2
      assert Agent.get(f.state, & &1.objects[f.child]["state"]) == "open"
    end
  end

  test "a pause observed before the first execution remains binding if its native comment disappears" do
    f = report_fixture("github", []) |> fresh_execution()
    pause = control(f, :parent, "pause", 20)
    Agent.update(f.state, &update_in(&1.objects[f.parent_notes], fn notes -> notes ++ [pause] end))
    assert {:waiting, waiting} = TaskExecution.admit(f.parent, f.payload["work"], executions([f]), f.opts)
    refute waiting.flow["started"]
    Agent.update(f.state, &put_in(&1.objects[f.parent_notes], [hd(&1.objects[f.parent_notes])]))
    result = TaskExecution.admit(f.parent, f.payload["work"], executions([f]), f.opts)
    assert {:error, :control_source_unconfirmed} = result
    source = hd(Map.values(current(f)["control_receipts"]))
    resume = control(f, :parent, "resume", 21, %{"restriction" => source})
    Agent.update(f.state, &update_in(&1.objects[f.parent_notes], fn notes -> notes ++ [pause, resume] end))
    assert {:ok, admitted} = TaskExecution.admit(f.parent, f.payload["work"], executions([f]), f.opts)
    assert admitted.record["execution_generation"] == 1
    assert admitted.record["execution_binding"]["role"] == "developer"
  end

  test "admission rechecks pause after locking and retains it without starting or leaving a stale lock" do
    f = report_fixture("gitlab", []) |> fresh_execution()
    registry = executions([f])
    work = f.payload["work"]
    pause = control(f, :parent, "pause", 20)

    request = fn provider, method, path, query, settings ->
      if File.exists?(Path.join(f.record["directory"], "executor.lock")) do
        Agent.update(f.state, &put_in(&1.objects[f.parent_notes], [hd(&1.objects[f.parent_notes]), pause]))
      end

      f.opts[:request].(provider, method, path, query, settings)
    end

    opts = Keyword.put(f.opts, :request, request)
    assert {:error, :lifecycle_start_not_admitted} = TaskExecution.admit(f.parent, work, registry, opts)
    record = current(f)
    refute record["thread_id"]
    refute record["workflow"]["started"]
    assert record["workflow"]["used_ms"] == 0
    refute File.exists?(Path.join(record["directory"], "executor.lock"))
    assert {:waiting, _} = TaskExecution.admit(f.parent, work, registry, f.opts)
    Agent.update(f.state, &put_in(&1.objects[f.parent_notes], [hd(&1.objects[f.parent_notes])]))
    assert {:error, :control_source_unconfirmed} = TaskExecution.admit(f.parent, work, registry, f.opts)
  end

  test "admission refuses missing configuration, foreign journals, unknown allocation and changing source evidence" do
    f = report_fixture("github", []) |> fresh_execution()
    work = f.payload["work"]
    registry = executions([f])
    key = WorkRef.key(work)
    assert {:error, :incomplete_plan_execution_configuration} = TaskExecution.observe(f.parent, work, nil, f.opts)
    assert {:error, :incomplete_plan_execution_configuration} = TaskExecution.observe(f.parent, work, %{}, f.opts)
    invalid = put_in(registry, [key, :directory], "/tmp/foreign")
    assert {:error, :incomplete_plan_execution_configuration} = TaskExecution.observe(f.parent, work, invalid, f.opts)
    assert {:error, :invalid_work_ref} = TaskExecution.observe(f.parent, %{}, registry, f.opts)
    foreign_work = %{work | "number" => 99}
    assert {:error, :member_execution_unavailable} = TaskExecution.observe(f.parent, foreign_work, registry, f.opts)
    assert {:ok, admitted} = TaskExecution.admit(f.parent, work, registry, f.opts)
    {:ok, unknown} = RunJournal.checkpoint(admitted.record, %{"thread_allocation_intent" => true})
    assert {:waiting, _} = TaskExecution.admit(f.parent, work, registry, f.opts)
    assert {:error, :invalid_execution_binding} = TaskExecution.refresh(%{}, registry, f.opts)
    assert {:error, :control_source_unconfirmed} = TaskExecution.refresh(Map.put(unknown, "control_receipts", %{"foreign" => "missing"}), registry, f.opts)
    path = Path.join(f.record["directory"], "run.json")
    File.write!(path, Jason.encode!(%{unknown | "issue_id" => "foreign"}))
    assert {:error, :member_execution_identity_changed} = TaskExecution.observe(f.parent, work, registry, f.opts)
    File.write!(path, Jason.encode!(Map.put(unknown, "execution_binding", "malformed")))
    assert {:error, :member_execution_identity_changed} = TaskExecution.observe(f.parent, work, registry, f.opts)

    for json <- ["[]", "null", "42", Jason.encode!("invalid record")] do
      File.write!(path, json)
      assert {:error, :invalid_run_journal} = TaskExecution.observe(f.parent, work, registry, f.opts)
      assert {:error, :invalid_run_journal} = TaskExecution.admit(f.parent, work, registry, f.opts)
    end

    File.write!(path, "{")
    assert {:error, %Jason.DecodeError{}} = TaskExecution.observe(f.parent, work, registry, f.opts)
    File.write!(path, Jason.encode!(unknown))
    counter = start_supervised!({Agent, fn -> 0 end}, id: make_ref())

    request = fn provider, method, target, query, settings ->
      result = f.opts[:request].(provider, method, target, query, settings)

      if target == f.child do
        count = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
        if count == 3, do: File.write!(path, Jason.encode!(Map.put(unknown, "retry_count", 1)))
      end

      result
    end

    assert {:error, :execution_evidence_changed_during_read} = TaskExecution.observe(f.parent, work, registry, Keyword.put(f.opts, :request, request))
  end

  test "member admission resolves whole-plan configuration and pins independently verified upstream inputs" do
    f = fixture("github", ["verified"]) |> git_artifact()
    {:ok, plan} = TaskPlanPreflight.inspect_plan(f.parent, f.opts)

    registry =
      Map.new(plan.members, fn {key, _} ->
        {key, %{directory: RunJournal.directory(Path.dirname(f.record["directory"]), key), policy: f.opts[:policy]}}
      end)

    consumer = %{f.payload["work"] | "number" => 3}
    assert {:error, :incomplete_plan_execution_configuration} = TaskExecution.admit(f.parent, consumer, executions([f]), f.opts)
    assert {:error, :dependency_not_verified} = TaskExecution.admit(f.parent, consumer, registry, f.opts)
    refute File.exists?(registry[WorkRef.key(consumer)].directory)
    f = verified_tools(f)
    assert {:ok, admitted} = TaskExecution.admit(f.parent, consumer, registry, f.opts)
    [input] = admitted.record["execution_binding"]["inputs"]
    assert input["work"] == f.payload["work"]
    assert input["version"] == f.git.revision
    assert input["verification"] == hd(admitted.evidence["dependencies"])["verification"]
    assert admitted.flow["dispatchable"]
    assert {:ok, again} = TaskExecution.observe(f.parent, consumer, registry, f.opts)
    assert again.flow["inputs"] == [input]
  end

  test "confirmed dependent rework selects current upstream evidence instead of its stale binding" do
    f = fixture("github", ["verified"]) |> git_artifact() |> verified_tools()
    {:ok, upstream} = dependencies(f, 3, nil, [f])
    [input] = inputs(upstream)
    stale = Map.put(input, "version", String.duplicate("0", 40))
    dependent = consumer(f, 3, [stale], [f])
    work = dependent.payload["work"]
    registry = executions([f, dependent])

    assert {:error, :pinned_input_unconfirmed} = TaskExecution.observe(f.parent, work, registry, f.opts)

    marker = confirmed_rework(f, ["candidate", "verification"])

    {:ok, stopped} = RunJournal.checkpoint(current(dependent), %{"rework" => marker, "native_stop_confirmed" => true})
    :ok = RunJournal.complete(stopped, "completed")
    {:ok, updated} = TaskPlanPreflight.inspect_plan(f.parent, f.opts)
    assert TaskLifecycle.authorized_rework?(updated, work, current(dependent))
    assert {:ok, observation} = TaskExecution.observe(f.parent, work, registry, f.opts)
    assert observation.flow["inputs"] == [input]
    assert observation.flow["dispatchable"]
  end

  test "a newly approved explicit upstream selection replaces a stale dependent pin" do
    f = fixture("github", ["verified"]) |> git_artifact() |> verified_tools()
    {:ok, upstream} = dependencies(f, 3, nil, [f])
    [input] = inputs(upstream)
    stale = Map.put(input, "version", String.duplicate("0", 40))
    dependent = consumer(f, 3, [stale], [f])
    work = dependent.payload["work"]
    registry = executions([f, dependent])

    assert {:error, :pinned_input_unconfirmed} = TaskExecution.observe(f.parent, work, registry, f.opts)
    repin(f, 3, f.git.revision)
    {:ok, stopped} = RunJournal.checkpoint(current(dependent), %{"native_stop_confirmed" => true})
    :ok = RunJournal.complete(stopped, "completed")

    assert {:ok, observation} = TaskExecution.observe(f.parent, work, registry, f.opts)
    assert observation.flow["inputs"] == [input]
  end

  test "an approved replacement restarts a previously completed dependent report" do
    f = report_fixture("github", ["verified"]) |> verified_report()
    {:ok, upstream} = dependencies(f, 3, nil, [f])
    [input] = inputs(upstream)
    dependent = report_consumer(f, input) |> verified_report()
    work = dependent.payload["work"]
    registry = executions([f, dependent])
    assert {:ok, prior} = TaskExecution.observe(f.parent, work, registry, f.opts)
    assert prior.flow["phase"] == "completed"
    persist_report_flow(prior)

    revised = revised_report(f, "Upstream replacement")
    assert {:ok, unchanged} = TaskExecution.observe(f.parent, work, registry, f.opts)
    assert unchanged.flow["phase"] == "completed"
    assert unchanged.flow["inputs"] == [input]

    [artifact] = revised.payload["artifacts"]
    repin(revised, 3, artifact["version"])
    assert {:ok, ready} = TaskExecution.observe(f.parent, work, registry, f.opts)
    assert ready.flow["dispatchable"]
    assert ready.flow["action"] == "implement"
    assert ready.flow["inputs"] != [input]
    assert {:ok, admitted} = TaskExecution.admit(f.parent, work, registry, f.opts)
    assert admitted.record["execution_binding"]["inputs"] == ready.flow["inputs"]
  end

  test "rework repins once and then retains the admitted inputs during ordinary polling" do
    f = report_fixture("github", ["verified"]) |> verified_report()
    {:ok, upstream} = dependencies(f, 3, nil, [f])
    [input] = inputs(upstream)
    dependent = report_consumer(f, input) |> verified_report()
    work = dependent.payload["work"]
    registry = executions([f, dependent])
    assert {:ok, prior} = TaskExecution.observe(f.parent, work, registry, f.opts)
    assert prior.flow["phase"] == "completed"
    persist_report_flow(prior)

    superseded =
      current(dependent)["publications"]
      |> Map.values()
      |> Enum.map(&get_in(&1, ["receipt", "source"]))
      |> Enum.reject(&is_nil/1)

    marker = confirmed_rework(f, superseded)
    completed = current(dependent)
    {:ok, locked} = RunJournal.admit(Path.dirname(completed["directory"]), completed["issue_id"], execution_binding: completed["execution_binding"])
    {:ok, marked} = RunJournal.checkpoint(locked, %{"rework" => marker})
    :ok = RunJournal.complete(marked, "completed")
    assert {:ok, admitted} = TaskExecution.admit(f.parent, work, registry, f.opts)
    assert admitted.record["execution_binding"]["inputs"] == [input]
    assert admitted.flow["rework_source"] == marker["parent_source"]

    revised_report(f, "A later upstream candidate")
    assert {:ok, ordinary} = TaskExecution.observe(f.parent, work, registry, f.opts)
    assert ordinary.flow["inputs"] == [input]
    assert ordinary.record["execution_binding"]["inputs"] == [input]

    {:ok, active} = RunJournal.checkpoint(ordinary.record, %{"thread_id" => "reworked-dependent", "native_stop_confirmed" => false})
    assert {:ok, running} = TaskExecution.observe_running(active, registry, f.opts)
    assert running.flow["inputs"] == [input]
    refute running.flow["stop_required"]
  end

  test "an explicit edge selection resolves only the approved upstream version and refuses any newer one" do
    f = fixture("github", ["verified"]) |> git_artifact() |> verified_tools()

    pinned = repin(f, 3, f.git.revision)
    assert {:ok, facts} = dependencies(pinned, 3, nil, [pinned])
    [proof] = facts.dependencies
    assert proof["version"] == f.git.revision
    assert {:ok, ^facts} = dependencies(pinned, 3, inputs(facts), [pinned])

    repinned = repin(f, 3, String.duplicate("b", 40))
    assert {:error, :dependency_selection_unconfirmed} = dependencies(repinned, 3, nil, [repinned])
    assert {:error, :dependency_selection_unconfirmed} = dependencies(repinned, 3, inputs(facts), [repinned])

    # An explicitly unpinned edge still consumes the current verified upstream,
    # so the refusal above comes from the declared selection, not from refusing
    # every explicit selection. A consumer that already recorded b1 keeps it
    # rather than being silently re-pointed (§9.2).
    unpinned = repin(f, 3, nil)
    assert {:ok, ^facts} = dependencies(unpinned, 3, inputs(facts), [unpinned])
    assert {:ok, current} = dependencies(unpinned, 3, nil, [unpinned])
    assert hd(current.dependencies)["version"] == f.git.revision
  end

  test "a re-authorized selection change invalidates only the repinned consumer grant" do
    f = fixture("github", ["verified"]) |> git_artifact() |> verified_tools()
    {:ok, original} = TaskPlanPreflight.inspect_plan(f.parent, f.opts)
    consumer = %{f.payload["work"] | "number" => 3}
    assert {:ok, facts} = dependencies(f, 3, nil, [f])

    producer = binding_for(original, f.payload["work"], [])
    claimed = binding_for(original, consumer, inputs(facts))
    assert TaskPlan.compatible_binding?(original.plan, original.authority, claimed, consumer, original.parent.notes)

    changed = repin(f, 3, String.duplicate("c", 40))
    {:ok, repinned} = TaskPlanPreflight.inspect_plan(changed.parent, changed.opts)
    assert repinned.plan["schema_version"] == 2

    assert TaskPlan.compatible_binding?(repinned.plan, repinned.authority, producer, f.payload["work"], repinned.parent.notes)
    refute TaskPlan.compatible_binding?(repinned.plan, repinned.authority, claimed, consumer, repinned.parent.notes)
  end

  test "a selection change only takes effect under a fresh authorization" do
    f = fixture("github", ["verified"]) |> git_artifact() |> verified_tools()
    {:ok, original} = TaskPlanPreflight.inspect_plan(f.parent, f.opts)

    repinned = author_plan(f, 3, f.git.revision)
    refute repinned["revision"] == original.plan["revision"]
    assert {:error, :plan_decision_revision_mismatch} = TaskPlanPreflight.inspect_plan(f.parent, f.opts)

    assert authorize_plan(f, repinned["revision"]) == f
    assert {:ok, authorized} = TaskPlanPreflight.inspect_plan(f.parent, f.opts)
    assert authorized.plan["revision"] == repinned["revision"]
  end

  test "native unavailability at the final fence or after lock acquisition never starts an executor" do
    f = report_fixture("github", []) |> fresh_execution()
    registry = executions([f])
    work = f.payload["work"]
    parent_path = String.replace_suffix(f.parent_notes, "/comments", "")
    reads = start_supervised!({Agent, fn -> 0 end}, id: make_ref())

    request = fn provider, method, target, query, settings ->
      count = if target == parent_path, do: Agent.get_and_update(reads, &{&1 + 1, &1 + 1}), else: 0
      # The final preflight follows the initial plan and member evidence reads.
      if count == 11 do
        {:error, :temporarily_unavailable}
      else
        f.opts[:request].(provider, method, target, query, settings)
      end
    end

    result = TaskExecution.observe(f.parent, work, registry, Keyword.put(f.opts, :request, request))
    assert {:error, :native_read_failed} = result
    refute File.exists?(f.record["directory"])

    request = fn provider, method, target, query, settings ->
      if File.exists?(Path.join(f.record["directory"], "executor.lock")),
        do: {:error, :temporarily_unavailable},
        else: f.opts[:request].(provider, method, target, query, settings)
    end

    result = TaskExecution.admit(f.parent, work, registry, Keyword.put(f.opts, :request, request))
    assert {:error, :native_read_failed} = result
    refute current(f)["thread_id"]
    refute current(f)["workflow"]
    refute File.exists?(Path.join(f.record["directory"], "executor.lock"))
    assert {:ok, admitted} = TaskExecution.admit(f.parent, work, registry, f.opts)
    assert admitted.record["attempt_count"] == 2
    assert admitted.record["execution_generation"] == 1
    assert admitted.flow["started"]
    assert admitted.flow["budget_ms"] == 100_000
  end

  test "provider exceptions before and after admission locking leave no native allocation or stranded owner" do
    for provider <- ["github", "gitlab"], failure <- [:raise, :throw, :exit], locked <- [false, true] do
      f = report_fixture(provider, []) |> fresh_execution()
      registry = executions([f])
      work = f.payload["work"]
      lock = Path.join(f.record["directory"], "executor.lock")

      request = fn p, method, target, query, settings ->
        if File.exists?(lock) == locked,
          do: admission_provider_failure(failure),
          else: f.opts[:request].(p, method, target, query, settings)
      end

      assert {:error, {:admission_observation_failed, _, _}} =
               TaskExecution.admit(f.parent, work, registry, Keyword.put(f.opts, :request, request))

      refute File.exists?(lock)

      if locked do
        assert current(f)["phase"] == "completed"
        refute current(f)["thread_id"]
        refute current(f)["workflow"]
      else
        refute File.exists?(f.record["directory"])
      end

      assert {:ok, resumed} = TaskExecution.admit(f.parent, work, registry, f.opts)
      assert resumed.record["attempt_count"] == if(locked, do: 2, else: 1)
      assert resumed.record["execution_generation"] == 1
      assert resumed.flow["repair_count"] == 0
      assert (resumed.record["retry_count"] || 0) == 0
      assert resumed.flow["budget_ms"] == 100_000
      assert Agent.get(f.state, & &1.posts) == []
    end
  end

  defp admission_provider_failure(:raise), do: raise("admission provider unavailable")
  defp admission_provider_failure(:throw), do: throw(:admission_provider_unavailable)
  defp admission_provider_failure(:exit), do: exit(:admission_provider_unavailable)

  test "provider exceptions after ownership changes preserve the replacement execution lock" do
    f = report_fixture("github", []) |> fresh_execution()
    lock = Path.join(f.record["directory"], "executor.lock")

    request = fn provider, method, target, query, settings ->
      if File.exists?(lock) do
        path = Path.join(f.record["directory"], "run.json")
        File.write!(path, Jason.encode!(Map.put(current(f), "attempt_id", "replacement-owner")))
        raise "provider failed after ownership changed"
      end

      f.opts[:request].(provider, method, target, query, settings)
    end

    opts = Keyword.put(f.opts, :request, request)
    assert {:error, :execution_admission_recovery_required} = TaskExecution.admit(f.parent, f.payload["work"], executions([f]), opts)
    assert current(f)["attempt_id"] == "replacement-owner"
    assert current(f)["phase"] == "admitted"
    assert File.exists?(lock)
    refute current(f)["thread_id"]
  end

  test "admission never releases a replacement attempt when ownership changes during native readback" do
    f = report_fixture("github", []) |> fresh_execution()
    changed = start_supervised!({Agent, fn -> false end}, id: make_ref())

    request = fn provider, method, target, query, settings ->
      if File.exists?(Path.join(f.record["directory"], "executor.lock")) and not Agent.get(changed, & &1) do
        Agent.update(changed, fn _ -> true end)
        path = Path.join(f.record["directory"], "run.json")
        File.write!(path, Jason.encode!(Map.put(current(f), "attempt_id", "replacement-owner")))
      end

      f.opts[:request].(provider, method, target, query, settings)
    end

    opts = Keyword.put(f.opts, :request, request)
    result = TaskExecution.admit(f.parent, f.payload["work"], executions([f]), opts)
    assert {:error, :execution_admission_recovery_required} = result
    assert current(f)["attempt_id"] == "replacement-owner"
    assert File.exists?(Path.join(f.record["directory"], "executor.lock"))
    refute current(f)["thread_id"]
  end

  defp workspace_options(f), do: Keyword.put(f.opts, :workspace_root, Path.join(Path.dirname(f.record["directory"]), "workspaces"))

  defp configured_options(f, config \\ %{}) do
    execution = Map.merge(%{"policy" => f.opts[:policy]}, config)
    repositories = Enum.map(f.opts[:repositories], &Map.put(&1, "execution", execution))
    workspace_options(f) |> Keyword.put(:repositories, repositories) |> Keyword.put(:journal_root, Path.dirname(f.record["directory"]))
  end

  test "host configuration resolves every sealed member without allocating journals or accepting scope from configuration" do
    f = report_fixture("github", ["verified"]) |> fresh_execution()
    opts = configured_options(f)
    assert {:ok, configured} = TaskExecutionConfig.prepare(f.parent, opts)
    assert configured.plan.plan["parent"] == f.parent
    assert map_size(configured.executions) == 2
    assert configured.executions[WorkRef.key(f.payload["work"])] == executions([f])[WorkRef.key(f.payload["work"])]
    refute File.exists?(f.record["directory"])

    for {_key, entry} <- configured.executions do
      assert entry.policy == f.opts[:policy]
      refute File.exists?(entry.directory)
    end

    assert {:ok, admitted} = TaskExecution.admit(f.parent, f.payload["work"], configured.executions, configured.opts)
    assert admitted.record["execution_binding"]["policy_sha"] == TaskWorkflow.digest(f.opts[:policy])
    assert Agent.get(f.state, & &1.posts) == []
  end

  test "incomplete host policy and unsafe journal roots fail before allocation" do
    f = report_fixture("gitlab", []) |> fresh_execution()
    opts = configured_options(f)

    for root <- [nil, "relative", "/", Path.dirname(f.record["directory"]) <> "/../escaped"] do
      assert {:error, :invalid_plan_journal_root} = TaskExecutionConfig.prepare(f.parent, Keyword.put(opts, :journal_root, root))
    end

    assert {:error, {:member_execution_configuration, _, :missing_repository_execution_policy}} =
             TaskExecutionConfig.prepare(f.parent, Keyword.put(opts, :repositories, f.opts[:repositories]))

    for policy <- [nil, Map.delete(f.opts[:policy], "max_retries"), Map.put(f.opts[:policy], "checks", %{})] do
      assert {:error, {:member_execution_configuration, _, :incomplete_verification_policy}} =
               TaskExecutionConfig.prepare(f.parent, configured_options(f, %{"policy" => policy}))
    end

    assert {:error, {:member_execution_configuration, _, :workspace_source_ambiguous}} =
             TaskExecutionConfig.prepare(f.parent, configured_options(f, %{"workspace_artifact" => "missing"}))

    failed = Keyword.put(opts, :request, fn _, _, _, _, _ -> raise "native unavailable" end)
    assert {:error, {:execution_configuration_failed, :error, _}} = TaskExecutionConfig.prepare(f.parent, failed)
    refute File.exists?(f.record["directory"])
  end

  test "configured code sources pin a native branch and preserve the developer base and edits when that branch advances" do
    for provider <- ["github", "gitlab"] do
      kind = if provider == "github", do: "pr", else: "mr"
      f = fixture(provider, [], kind) |> fresh_execution()
      root = Path.dirname(f.record["directory"])
      git = GitArtifactFixture.create(Path.join(root, "source"), provider)
      prefix = if provider == "github", do: "/repos/team/repo", else: "/projects/team%2Frepo"
      branch_path = prefix <> if(provider == "github", do: "/branches/main", else: "/repository/branches/main")
      key = if provider == "github", do: "sha", else: "id"
      native = Map.new(git.objects, fn {path, body} -> {prefix <> path, body} end)
      native = Map.put(native, branch_path, %{"name" => "main", "commit" => %{key => git.revision}})
      Agent.update(f.state, &update_in(&1.objects, fn objects -> Map.merge(objects, native) end))
      opts = configured_options(f, %{"repository" => git.path, "workspace_artifact" => "output"})
      assert {:ok, configured} = TaskExecutionConfig.prepare(f.parent, opts)
      entry = configured.executions[WorkRef.key(f.payload["work"])]
      assert entry.base_revision == git.revision
      assert entry.base_source["branch"] == "main"
      assert {:ok, admitted} = TaskExecution.admit(f.parent, f.payload["work"], configured.executions, configured.opts)
      digest = TaskWorkflow.digest(%{"binding" => admitted.record["execution_binding"], "generation" => admitted.record["execution_generation"]})
      partial_manifest = Path.join([opts[:workspace_root], "task-" <> digest, "manifest.json"])

      request = fn p, method, target, query, settings ->
        if File.exists?(partial_manifest), do: {:error, :offline}, else: opts[:request].(p, method, target, query, settings)
      end

      assert {:error, :native_read_failed} = TaskWorkspace.prepare(admitted.record, configured.executions, Keyword.put(configured.opts, :request, request))
      partial = current(f)
      assert partial["task_source"]["revision"] == git.revision
      refute partial["task_workspace"]
      assert {:error, :bound_workspace_changed} = RunJournal.checkpoint(partial, %{"task_source" => nil})
      assert {:error, :role_workspace_changed} = TaskWorkspace.validate(Map.put(partial, "task_source", nil))
      assert {:error, :role_workspace_changed} = TaskWorkspace.validate(put_in(partial, ["task_source", "generation"], 999))
      Agent.update(f.state, &put_in(&1.objects[branch_path]["commit"][key], String.duplicate("a", 40)))
      assert {:ok, after_failure} = TaskExecutionConfig.prepare(f.parent, opts)
      assert {:ok, prepared} = TaskWorkspace.prepare(partial, after_failure.executions, after_failure.opts)
      # Journals written before source intents already have a complete bound manifest.
      legacy = Map.delete(prepared, "task_source")
      File.write!(Path.join(prepared["directory"], "run.json"), Jason.encode!(legacy))
      assert {:ok, prepared} = TaskWorkspace.prepare(legacy, after_failure.executions, after_failure.opts)
      assert prepared["task_source"]["revision"] == git.revision
      manifest = Path.join(prepared["task_workspace"]["directory"], "manifest.json") |> File.read!() |> Jason.decode!()
      assert manifest["source"]["base_source"] == entry.base_source
      File.write!(Path.join(prepared["workspace"], "result"), "work in progress\n")
      Agent.update(f.state, &put_in(&1.objects[branch_path]["commit"][key], String.duplicate("b", 40)))
      assert {:ok, refreshed} = TaskExecutionConfig.prepare(f.parent, opts)
      assert refreshed.executions[WorkRef.key(f.payload["work"])].base_revision != entry.base_revision
      assert {:ok, resumed} = TaskWorkspace.prepare(prepared, refreshed.executions, refreshed.opts)
      assert resumed["task_workspace"] == prepared["task_workspace"]
      assert File.read!(Path.join(resumed["workspace"], "result")) == "work in progress\n"
      assert GitArtifactFixture.git(git.path, ["status", "--porcelain"]) == ""

      for repository <- ["relative", "$UNSET_SOURCE_#{System.unique_integer([:positive])}"] do
        invalid = configured_options(f, %{"repository" => repository})
        result = TaskExecutionConfig.prepare(f.parent, invalid)
        assert {:error, {:member_execution_configuration, _, :workspace_repository_unavailable}} = result
      end

      invalid = configured_options(f, %{"repository" => git.path, "workspace_artifact" => "other"})
      result = TaskExecutionConfig.prepare(f.parent, invalid)
      assert {:error, {:member_execution_configuration, _, :workspace_source_ambiguous}} = result
    end
  end

  test "owned partial workspace preparation resumes but foreign directories and changed receipts block" do
    f = report_fixture("github", []) |> fresh_execution()
    registry = executions([f])
    opts = workspace_options(f)
    assert {:ok, admitted} = TaskExecution.admit(f.parent, f.payload["work"], registry, opts)
    record = admitted.record
    digest = TaskWorkflow.digest(%{"binding" => record["execution_binding"], "generation" => record["execution_generation"]})
    root = Path.join(opts[:workspace_root], "task-" <> digest)
    File.mkdir_p!(root)
    File.write!(Path.join(root, "foreign"), "preserve this directory")
    assert {:error, :workspace_path_occupied} = TaskWorkspace.prepare(record, registry, opts)
    assert File.read!(Path.join(root, "foreign")) == "preserve this directory"
    File.rename!(root, root <> "-foreign")
    assert {:error, :invalid_role_workspace_root} = TaskWorkspace.prepare(record, registry, Keyword.put(opts, :workspace_root, "relative"))

    manifest = Path.join(root, "manifest.json")

    request = fn provider, method, target, query, settings ->
      if File.exists?(manifest), do: {:error, :offline}, else: f.opts[:request].(provider, method, target, query, settings)
    end

    assert {:error, :native_read_failed} = TaskWorkspace.prepare(record, registry, Keyword.put(opts, :request, request))
    assert File.exists?(manifest)
    refute current(f)["task_workspace"]
    assert {:ok, prepared} = TaskWorkspace.prepare(current(f), registry, opts)
    assert :ok = TaskWorkspace.validate(prepared)
    assert {:ok, resumed} = TaskWorkspace.prepare(prepared, registry, opts)
    assert resumed["task_workspace"] == prepared["task_workspace"]
    File.rmdir!(Path.join(root, "inputs"))
    assert {:error, :role_workspace_changed} = TaskWorkspace.validate(prepared)
    File.mkdir!(Path.join(root, "inputs"))
    assert {:error, :role_workspace_changed} = TaskWorkspace.validate(Map.put(prepared, "task_workspace", nil))
    assert {:error, :role_workspace_changed} = TaskWorkspace.validate(put_in(prepared, ["task_workspace", "directory"], nil))
    altered = put_in(prepared, ["task_workspace", "owner_sha"], String.duplicate("0", 64))
    assert {:error, :role_workspace_changed} = TaskWorkspace.validate(altered)
    File.ln_s!("/missing-git", Path.join(prepared["workspace"], ".git"))
    assert {:error, :role_workspace_changed} = TaskWorkspace.validate(prepared)
    File.rm!(Path.join(prepared["workspace"], ".git"))
    Agent.update(f.state, &put_in(&1.objects[f.parent_notes], &1.objects[f.parent_notes] ++ [control(f, :plan, "pause", 70)]))
    assert {:error, :workspace_execution_not_ready} = TaskWorkspace.prepare(prepared, registry, opts)
  end

  test "Git source requires a local exact native revision and refuses borrowed worktree administration" do
    f = fixture("github", [], "pr") |> fresh_execution() |> git_artifact()
    work = f.payload["work"]
    registry = executions([f])
    opts = workspace_options(f)
    assert {:ok, admitted} = TaskExecution.admit(f.parent, work, registry, opts)
    assert {:error, :workspace_revision_unavailable} = TaskWorkspace.prepare(admitted.record, registry, opts)
    registry = update_in(registry, [WorkRef.key(work)], &Map.put(&1, :base_revision, f.git.revision))
    assert {:error, :workspace_repository_unavailable} = TaskWorkspace.prepare(admitted.record, registry, opts)
    registry = update_in(registry, [WorkRef.key(work)], &Map.put(&1, :repository, f.git.path))
    readonly = opts[:workspace_root] <> "-readonly"
    File.mkdir_p!(readonly)
    File.chmod!(readonly, 0o555)

    try do
      assert {:error, :eacces} = TaskWorkspace.prepare(admitted.record, registry, Keyword.put(opts, :workspace_root, readonly))
    after
      File.chmod!(readonly, 0o755)
    end

    digest = TaskWorkflow.digest(%{"binding" => admitted.record["execution_binding"], "generation" => admitted.record["execution_generation"]})
    root = Path.join(opts[:workspace_root], "task-" <> digest)
    manifest = Path.join(root, "manifest.json")

    request = fn provider, method, target, query, settings ->
      if File.exists?(manifest), do: {:error, :offline}, else: f.opts[:request].(provider, method, target, query, settings)
    end

    assert {:error, :native_read_failed} = TaskWorkspace.prepare(admitted.record, registry, Keyword.put(opts, :request, request))
    source = Path.join(root, "source")
    File.rename!(source, source <> "-moved")
    File.write!(source, "occupied source")
    assert {:error, :workspace_path_occupied} = TaskWorkspace.prepare(current(f), registry, opts)
    File.rm!(source)
    File.rename!(source <> "-moved", source)
    File.rm!(manifest)
    File.chmod!(root, 0o555)

    try do
      assert {:error, :eacces} = TaskWorkspace.prepare(current(f), registry, opts)
    after
      File.chmod!(root, 0o755)
    end

    File.rename!(f.git.path, f.git.path <> "-offline")

    try do
      assert {:error, :git_workspace_unavailable} = TaskWorkspace.prepare(current(f), registry, opts)
    after
      File.rename!(f.git.path <> "-offline", f.git.path)
    end

    assert {:ok, prepared} = TaskWorkspace.prepare(current(f), registry, opts)
    {:ok, owners} = ArtifactStore.references(Path.join(Path.dirname(f.record["directory"]), ".artifacts"), work, f.git.revision, opts)
    assert Enum.any?(owners, &(&1["kind"] == "execution"))
    git_file = Path.join(prepared["workspace"], ".git")
    original = File.read!(git_file)
    File.write!(git_file, File.read!(Path.join(f.workspace, ".git")))
    assert {:error, :role_workspace_changed} = TaskWorkspace.validate(prepared)
    File.write!(git_file, original)
    assert :ok = TaskWorkspace.validate(prepared)
    assert {:error, :workspace_specification_changed} = TaskWorkspace.prepare(prepared, registry, Keyword.put(opts, :workspace_root, opts[:workspace_root] <> "-changed"))
    registry = update_in(registry, [WorkRef.key(work)], &Map.delete(&1, :base_revision))
    assert {:ok, resumed} = TaskWorkspace.prepare(prepared, registry, opts)
    assert resumed["task_workspace"] == prepared["task_workspace"]
  end

  test "generation worktrees preserve developer edits and give the verifier exact candidate bytes in a separate directory" do
    command = """
    python3 - <<'PY'
    import json, os, pathlib
    manifest = pathlib.Path(os.environ['SYMPHONY_TASK_MANIFEST'])
    data = json.loads(manifest.read_text())
    package = next(p for p in data['packages'] if p['reference']['category'] == 'candidate')
    source = manifest.parent / package['path'] / 'result'
    assert source.read_text() == 'expected\\n'
    assert pathlib.Path(os.environ['SYMPHONY_TASK_INPUTS']).is_dir()
    assert source.is_relative_to(os.environ['SYMPHONY_TASK_CANDIDATES'])
    try:
        source.write_text('changed')
    except PermissionError:
        print('fixed input readable; write denied')
    else:
        raise AssertionError('input write was allowed')
    PY
    """

    checks = %{
      "test" => %{"kind" => "command", "command" => command, "artifact" => "output", "timeout_ms" => 2_000},
      "race" => %{"kind" => "command", "command" => "touch ready; while [ ! -f release ]; do sleep 0.01; done", "artifact" => "output", "timeout_ms" => 5_000}
    }

    f = fixture("github", [], "report", checks) |> fresh_execution() |> git_artifact()
    work = f.payload["work"]
    registry = update_in(executions([f]), [WorkRef.key(work)], &Map.merge(&1, %{repository: f.git.path, base_revision: f.git.revision}))
    opts = workspace_options(f)
    assert {:ok, admitted} = TaskExecution.admit(f.parent, work, registry, opts)
    assert {:ok, developer} = TaskWorkspace.prepare(admitted.record, registry, opts)
    assert developer["workspace"] != f.git.path
    assert File.read!(Path.join(developer["workspace"], "result")) == "expected\n"
    assert File.regular?(Path.join(developer["workspace"], ".git"))
    File.write!(Path.join(developer["workspace"], "result"), "uncommitted developer edits\n")
    assert {:ok, resumed} = TaskWorkspace.prepare(developer, registry, opts)
    assert resumed["workspace"] == developer["workspace"]
    assert File.read!(Path.join(resumed["workspace"], "result")) == "uncommitted developer edits\n"
    assert File.read!(Path.join(f.git.path, "result")) == "expected\n"
    assert {:error, :bound_workspace_changed} = RunJournal.checkpoint(resumed, %{"workspace" => f.git.path})
    {developer, tools} = native_tools(f, resumed, "workspace-developer")
    assert {true, _} = tool(tools, "task_candidate", candidate_args(f))
    assert {:ok, next} = TaskExecution.refresh(developer, registry, Keyword.put(opts, :active, true))
    {:ok, stopped} = RunJournal.checkpoint(next.record, %{"native_stop_confirmed" => true})
    :ok = RunJournal.complete(stopped, "completed")
    assert {:ok, verifying} = TaskExecution.admit(f.parent, work, registry, opts)
    refute verifying.record["task_workspace"]
    refute verifying.record["task_source"]
    assert List.last(verifying.record["execution_history"])["task_source"] == developer["task_source"]
    refute verifying.record["workspace"]
    assert {:ok, verifier} = TaskWorkspace.prepare(verifying.record, registry, opts)
    refute verifier["task_source"]
    assert verifier["workspace"] != developer["workspace"]
    assert File.read!(Path.join(verifier["workspace"], "result")) == "expected\n"
    assert :ok = TaskWorkspace.validate(verifier)
    assert File.exists?(TaskWorkspace.environment(verifier)["SYMPHONY_TASK_MANIFEST"])
    {verifier, verifier_tools} = native_tools(f, verifier, "workspace-verifier")
    assert {true, %{"data" => checked}} = tool(verifier_tools, "task_check", %{"check_id" => "test"})
    assert checked["exit_code"] == 0
    assert checked["snapshot_valid"]
    assert checked["output"] =~ "fixed input readable; write denied"
    assert :ok = TaskWorkspace.validate(verifier)
    record = current(f)
    task = Task.async(fn -> CommandCheck.run(record, verifying.evidence["candidate"], "race", f.opts[:policy]) end)
    check_workspace = await_check_workspace(f, "race")
    manifest = TaskWorkspace.environment(verifier)["SYMPHONY_TASK_MANIFEST"] |> File.read!() |> Jason.decode!()
    [package] = manifest["packages"]
    input = Path.join([verifier["task_workspace"]["directory"], package["path"], "result"])
    File.chmod!(input, 0o644)
    File.write!(input, "changed during check")
    File.write!(Path.join(check_workspace, "release"), "")
    assert {:ok, _, receipt} = Task.await(task, 10_000)
    assert receipt["exit_code"] == 0
    refute receipt["snapshot_valid"]
    assert receipt["native_stop_confirmed"]
    File.write!(input, "expected\n")
    File.chmod!(input, 0o444)
    File.write!(Path.join(verifier["workspace"], "result"), "tampered reviewer tree")
    assert {:error, :role_workspace_changed} = TaskWorkspace.validate(verifier)
    assert {:error, :invalid_task_tool_binding} = TaskTools.bind(verifier, f.opts[:policy], opts)
    assert File.read!(Path.join(developer["workspace"], "result")) == "uncommitted developer edits\n"
  end

  defp await_check_workspace(f, check, remaining \\ 500) do
    entry = Enum.find_value(current(f)["check_runs"] || %{}, fn {_, entry} -> if entry["spec"]["check"] == check, do: entry end)
    path = if entry, do: entry["spec"]["workspace"]

    cond do
      path && File.exists?(Path.join(path, "ready")) ->
        path

      remaining > 0 ->
        Process.sleep(10)
        await_check_workspace(f, check, remaining - 1)

      true ->
        flunk("supervised check did not reach the input-read barrier")
    end
  end

  test "report dependency bytes are materialized without Git and input corruption blocks role tools" do
    f = report_fixture("gitlab", ["verified"])
    assert {true, _} = tool(task_tools(f), "task_candidate", candidate_args(f))
    verifier = verifier_tools(f, current(f))
    check = %{"id" => "test", "result" => "passed", "rationale" => "Checked report evidence and limitations against the approved criterion."}
    assert {true, _} = tool(verifier, "task_verification", %{"review_checks" => [check], "findings" => [], "summary" => "Verified"})
    {:ok, plan} = TaskPlanPreflight.inspect_plan(f.parent, f.opts)

    registry =
      Map.new(plan.members, fn {key, _} ->
        {key, %{directory: RunJournal.directory(Path.dirname(f.record["directory"]), key), policy: f.opts[:policy]}}
      end)

    consumer = %{f.payload["work"] | "number" => 3}
    opts = workspace_options(f)
    assert {:ok, admitted} = TaskExecution.admit(f.parent, consumer, registry, opts)
    binding = admitted.record["execution_binding"]
    owner = %{"kind" => "execution", "work" => consumer, "revision" => TaskWorkflow.digest(%{"binding" => binding, "generation" => admitted.record["execution_generation"]})}
    report = hd(f.payload["artifacts"])
    reference = String.replace_prefix(report["source"], "report:", "report-") <> "." <> TaskWorkflow.digest(owner) <> ".ref"
    reference = Path.join([Path.dirname(f.record["directory"]), ".artifacts", reference])
    File.write!(reference, "conflicting execution retention receipt")
    assert {:error, :artifact_publication_conflict} = TaskWorkspace.prepare(admitted.record, registry, opts)
    File.rm!(reference)
    root = Path.join(opts[:workspace_root], "task-" <> owner["revision"])

    request = fn provider, method, target, query, settings ->
      if File.exists?(Path.join(root, "manifest.json")), do: {:error, :offline}, else: f.opts[:request].(provider, method, target, query, settings)
    end

    assert {:error, :native_read_failed} = TaskWorkspace.prepare(admitted.record, registry, Keyword.put(opts, :request, request))
    manifest = Jason.decode!(File.read!(Path.join(root, "manifest.json")))
    [package] = manifest["packages"]
    path = Path.join([root, package["path"], "report.md"])
    File.chmod!(path, 0o644)
    File.write!(path, "corrupt partial input")
    assert {:error, :artifact_files_changed} = TaskWorkspace.prepare(admitted.record, registry, opts)
    assert File.read!(path) == "corrupt partial input"
    File.write!(path, report["body"])
    File.chmod!(path, 0o444)
    assert {:ok, record} = TaskWorkspace.prepare(admitted.record, registry, opts)
    refute File.exists?(Path.join(record["workspace"], ".git"))
    assert File.read!(path) == hd(f.payload["artifacts"])["body"]
    assert package["reference"]["verification"] == hd(record["execution_binding"]["inputs"])["verification"]
    assert :ok = TaskWorkspace.validate(record)
    File.rmdir!(record["workspace"])
    assert {:error, :role_workspace_changed} = TaskWorkspace.validate(record)
    File.mkdir!(record["workspace"])
    {:ok, record} = RunJournal.checkpoint(record, %{"thread_id" => "report-consumer", "native_stop_confirmed" => false})
    assert {:ok, tools} = TaskTools.bind(record, f.opts[:policy], Keyword.put(opts, :dependency_executions, registry))
    assert {true, %{"data" => %{"workspace" => environment}}} = tool(tools, "task_context", %{})
    assert environment["SYMPHONY_TASK_INPUTS"] == Path.join(root, "inputs")
    File.chmod!(path, 0o644)
    File.write!(path, "changed input")
    assert {:error, :role_workspace_changed} = TaskWorkspace.validate(record)
    assert {false, %{"error" => ":role_workspace_changed"}} = tool(tools, "task_context", %{})
    assert {:error, :role_workspace_changed} = TaskWorkspace.prepare(record, registry, opts)
  end

  test "native Markdown reports publish visibly and unlock verified delivery only after independent review" do
    for provider <- ["github", "gitlab"], stage <- ["verified", "delivered", "published"] do
      f = report_fixture(provider, [stage])
      developer = task_tools(f)
      assert {true, %{"data" => receipt}} = tool(developer, "task_candidate", candidate_args(f))
      [body] = posts(f)
      assert body =~ hd(f.payload["artifacts"])["body"]
      assert body =~ "### Report"
      assert {:ok, facts} = evidence(f, current(f))
      assert facts.candidate["artifacts"] == f.payload["artifacts"]
      assert hd(facts.artifacts).files |> hd() |> Map.fetch!("content") == hd(f.payload["artifacts"])["body"]
      refute File.exists?(Path.join(f.record["directory"], ".git"))
      assert {:error, :dependency_not_verified} = dependencies(f, 3, nil, [f])
      assert {true, %{"data" => %{"delivery" => [%{"status" => "delivered", "receipt" => delivery}]}}} = tool(developer, "task_context", %{})
      assert delivery["source"] == receipt["source"]
      verifier = verifier_tools(f, current(f))

      review = %{
        "review_checks" => [%{"id" => "test", "result" => "passed", "rationale" => "Checked cited evidence, scope and stated limitations against the approved criteria."}],
        "findings" => [],
        "summary" => "Report independently verified"
      }

      assert {true, _} = tool(verifier, "task_verification", review)
      assert {:ok, dependencies} = dependencies(f, 3, nil, [f])
      [proof] = dependencies.dependencies
      assert proof["stage"] == stage
      assert proof["version"] == hd(f.payload["artifacts"])["version"]
      root = Path.join(Path.dirname(f.record["directory"]), ".artifacts")
      assert {:ok, owners} = ArtifactStore.report_references(root, f.payload["work"], hd(f.payload["artifacts"]), f.opts)
      assert Enum.any?(owners, &(&1["kind"] == "dependency" and &1["work"]["number"] == 3))
      Agent.update(f.state, &update_in(&1.objects[f.notes], fn [candidate, verification] -> [%{candidate | "body" => candidate["body"] <> "edited"}, verification] end))
      assert {:error, _} = dependencies(f, 3, inputs(dependencies), [f])
    end
  end

  test "report publication recovers a lost response and rejects mismatched bodies or native command injection" do
    f = report_fixture("gitlab", [])
    tools = task_tools(f)
    bad = candidate_args(f) |> Map.put("artifacts", [%{"id" => "output", "body" => "Report\n/close"}])
    assert {false, %{"error" => ":invalid_report_artifact"}} = tool(tools, "task_candidate", bad)
    Agent.update(f.state, &%{&1 | mode: :lost})
    assert {true, %{"data" => receipt}} = tool(tools, "task_candidate", candidate_args(f))
    assert {true, %{"data" => ^receipt}} = tool(tools, "task_candidate", candidate_args(f))
    assert length(posts(f)) == 1
    forged = Map.update!(f.payload, "artifacts", &Enum.map(&1, fn artifact -> Map.put(artifact, "body", "Changed without updating version") end))
    assert {:error, :invalid_publication_context} = TaskPublication.publish(current(f), "candidate", forged, "Changed", f.opts)
    oversized_summary = String.duplicate("x", 64_001)
    oversized_result = TaskPublication.publish(current(f), "candidate", f.payload, oversized_summary, f.opts)
    assert {:error, :publication_body_too_large} = oversized_result
    invalid_payload = Map.put(f.payload, "artifacts", [nil])
    assert {:error, :invalid_publication_context} = TaskPublication.publish(current(f), "candidate", invalid_payload, "Invalid", f.opts)
    assert {:ok, evidence} = evidence(f, current(f))
    artifact = hd(f.payload["artifacts"])
    opts = f.opts |> Keyword.put(:candidate, evidence.candidate) |> Keyword.put(:runtime, current(f))
    assert {:ok, delivery} = TaskDelivery.read(f.payload["work"], artifact, opts)
    assert TaskDelivery.current?(delivery.snapshot, opts)
    invalid = Keyword.put(opts, :candidate, Map.put(evidence.candidate, "digest", "invented"))
    assert {:error, :report_delivery_unconfirmed} = TaskDelivery.read(f.payload["work"], artifact, invalid)
    missing = Keyword.put(opts, :runtime, %{})
    assert {:error, :unrecorded_native_result} = TaskDelivery.read(f.payload["work"], artifact, missing)
    offline = Keyword.put(opts, :request, fn _, _, _, _, _ -> {:error, :offline} end)
    refute TaskDelivery.current?(delivery.snapshot, offline)
    Agent.update(f.state, &put_in(&1.objects[f.notes], []))
    refute TaskDelivery.current?(delivery.snapshot, opts)
    assert {:error, :report_delivery_unconfirmed} = TaskDelivery.read(f.payload["work"], artifact, opts)
  end

  defp executions(fixtures), do: Map.new(fixtures, &{WorkRef.key(&1.payload["work"]), %{directory: &1.record["directory"], policy: &1.opts[:policy]}})

  defp dependencies(f, number, inputs, fixtures, opts \\ nil) do
    opts = opts || f.opts
    {:ok, plan} = TaskPlanPreflight.inspect_plan(f.parent, opts)
    TaskDependencies.read(plan, %{f.payload["work"] | "number" => number}, inputs, executions(fixtures), opts)
  end

  defp inputs(facts), do: Enum.map(facts.dependencies, &Map.take(&1, ~w(work artifact version verification)))

  defp consumer(f, number, inputs, producers) do
    work = %{f.payload["work"] | "number" => number}
    binding = %{f.record["execution_binding"] | "work" => work, "contract_sha" => contract(work, f.parent, hd(f.payload["artifacts"])["kind"])["contract_sha"], "inputs" => inputs}
    {:ok, record} = RunJournal.admit(Path.dirname(f.record["directory"]), WorkRef.key(work), execution_binding: binding)
    {:ok, record} = RunJournal.checkpoint(record, %{"thread_id" => "developer-#{number}"})
    payload = Map.take(binding, ~w(work contract_sha inputs)) |> Map.put("artifacts", Enum.map(f.payload["artifacts"], &Map.put(&1, "source", GitArtifact.source_ref(work, f.git.revision))))

    %{
      f
      | record: record,
        payload: payload,
        opts: Keyword.put(f.opts, :dependency_executions, executions(producers)),
        child: String.replace(f.child, "/issues/2", "/issues/#{number}"),
        notes: String.replace(f.notes, "/issues/2", "/issues/#{number}")
    }
  end

  # Re-author the parent plan with an explicit per-edge upstream selection. The
  # changed selection participates in the revision, so it needs a later
  # authorization while the earlier approval keeps untouched grants
  # native-verifiable (§12 scenario 5).
  defp author_plan(f, number, version) do
    {:ok, preflight} = TaskPlanPreflight.inspect_plan(f.parent, f.opts)
    parent_path = parent_path(f)
    issue = Agent.get(f.state, &Map.fetch!(&1.objects, parent_path))

    draft =
      preflight.plan
      |> Map.drop(["schema_version", "revision"])
      |> Map.update!("dependencies", fn edges -> Enum.map(edges, &selected_edge(&1, number, version)) end)

    {:ok, repinned} = TaskPlan.seal(draft)
    body = Regex.replace(~r/<!--\s*symphony-plan\s+\{.*?\}\s*-->/s, issue["body"], fn _ -> plan_block(repinned) end)
    Agent.update(f.state, &put_in(&1.objects[parent_path]["body"], body))
    repinned
  end

  defp repin(f, number, version) do
    authorize_plan(f, author_plan(f, number, version)["revision"])
  end

  defp authorize_plan(f, revision) do
    Agent.update(f.state, fn state ->
      notes = state.objects[f.parent_notes] ++ [reauthorization(revision)]
      %{state | objects: Map.put(state.objects, f.parent_notes, notes)}
    end)

    f
  end

  defp parent_path(f), do: String.replace_suffix(f.child, "/issues/2", "") <> "/issues/1"

  defp selected_edge(%{"to" => %{"number" => to}} = edge, number, version) when to == number,
    do: Map.put(edge, "selects", version)

  defp selected_edge(edge, _number, _version), do: edge

  defp plan_block(plan), do: "<!-- symphony-plan " <> Jason.encode!(plan) <> " -->"

  defp reauthorization(revision) do
    body = "<!-- symphony-plan-decision " <> Jason.encode!(%{"action" => "authorize", "revision" => revision}) <> " -->"
    id = 900 + System.unique_integer([:positive, :monotonic])
    at = DateTime.add(~U[2026-10-17T00:00:00Z], id, :second) |> DateTime.to_iso8601()
    note(id, 1, body) |> Map.merge(%{"created_at" => at, "updated_at" => at})
  end

  defp binding_for(preflight, work, inputs) do
    %{
      "work" => work,
      "contract_sha" => preflight.members[WorkRef.key(work)].contract["contract_sha"],
      "authority" => preflight.authority,
      "plan_revision" => preflight.plan["revision"],
      "inputs" => inputs
    }
  end

  defp change_target(f) do
    work = f.payload["work"]
    artifact = hd(f.payload["artifacts"])
    target = %{work | "kind" => artifact["kind"], "number" => 7}
    prefix = String.replace_suffix(f.child, "/issues/2", "")
    path = prefix <> if(work["provider"] == "github", do: "/pulls/7", else: "/merge_requests/7")
    url = "https://" <> work["host"] <> "/team/repo"

    raw =
      if work["provider"] == "github" do
        %{
          "id" => 700,
          "number" => 7,
          "html_url" => url <> "/pull/7",
          "head" => %{"sha" => f.git.revision, "ref" => "feature", "repo" => %{"id" => 10}},
          "base" => %{"ref" => "main", "repo" => %{"id" => 10}},
          "state" => "open",
          "merged" => false,
          "merged_at" => nil
        }
      else
        %{
          "id" => 700,
          "iid" => 7,
          "web_url" => url <> "/-/merge_requests/7",
          "sha" => f.git.revision,
          "source_branch" => "feature",
          "target_branch" => "main",
          "project_id" => 10,
          "source_project_id" => 10,
          "target_project_id" => 10,
          "state" => "opened",
          "merged_at" => nil
        }
      end

    Agent.update(f.state, &put_in(&1.objects[path], raw))
    %{f | payload: Map.put(f.payload, "artifacts", [Map.merge(artifact, %{"target" => target, "target_branch" => "main"})])} |> Map.put(:change_path, path)
  end

  defp merged_candidate(f) do
    git = GitArtifactFixture.create(Path.join(f.record["directory"], "merged-source"), f.payload["work"]["provider"], %{"result" => "expected\n", "merged" => "target branch content\n"})
    prefix = String.replace_suffix(f.child, "/issues/2", "")
    objects = Map.new(git.objects, fn {path, value} -> {prefix <> path, value} end)
    Agent.update(f.state, &%{&1 | objects: Map.merge(&1.objects, objects)})

    Agent.update(
      f.state,
      &update_in(&1.objects[f.change_path], fn raw ->
        Map.merge(raw, %{
          "state" => if(f.payload["work"]["provider"] == "github", do: "closed", else: "merged"),
          "merged" => true,
          "merged_at" => "2026-10-18T00:00:00Z",
          "merge_commit_sha" => git.revision
        })
      end)
    )

    workspace = Path.join(f.record["directory"], "merged-worktree")
    GitArtifactFixture.git(git.path, ["worktree", "add", "--detach", workspace, git.revision])
    artifacts = Enum.map(f.payload["artifacts"], &Map.merge(&1, %{"version" => git.revision, "source" => GitArtifact.source_ref(f.payload["work"], git.revision)}))
    %{f | payload: Map.put(f.payload, "artifacts", artifacts), git: git, workspace: workspace}
  end

  test "merged dependencies require verification of the actual delivered commit and recheck native delivery" do
    for {provider, kind} <- [{"github", "pr"}, {"gitlab", "mr"}] do
      f = fixture(provider, ["delivered"], kind) |> git_artifact() |> change_target() |> verified_tools()
      assert {:error, :dependency_delivery_unconfirmed} = dependencies(f, 3, nil, [f])
      final = merged_candidate(f)
      assert {:error, :dependency_delivery_verification_required} = dependencies(f, 3, nil, [f])
      assert {true, %{"data" => %{"delivery" => [%{"status" => "verification_required"}]}}} = tool(task_tools(f), "task_context", %{})
      {:ok, stopped} = RunJournal.checkpoint(current(f), %{"native_stop_confirmed" => true})
      :ok = RunJournal.complete(stopped, "completed")
      binding = %{stopped["execution_binding"] | "role" => "developer"}
      {:ok, record} = RunJournal.admit(Path.dirname(stopped["directory"]), stopped["issue_id"], execution_binding: binding)
      {:ok, record} = RunJournal.checkpoint(record, %{"thread_id" => "delivery-developer"})
      final = %{final | record: record} |> verified_tools()
      assert {:ok, facts} = dependencies(final, 3, nil, [final])
      [proof] = facts.dependencies
      assert proof["stage"] == "delivered"
      assert proof["version"] == final.git.revision
      refute proof["version"] == f.git.revision
      assert proof["delivery"] in facts.sources
      assert {:ok, observations} = TaskDelivery.read_candidate(final.payload["work"], final.payload, final.opts)
      assert hd(observations).receipt["head"] == f.git.revision

      # A final-state change after the first native delivery read blocks the assembled proof.
      counter = start_supervised!({Agent, fn -> 0 end}, id: make_ref())

      request = fn p, method, path, query, settings ->
        result = final.opts[:request].(p, method, path, query, settings)

        if path == final.change_path do
          count = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
          if count == 2, do: Agent.update(final.state, &put_in(&1.objects[path]["merge_commit_sha"], String.duplicate("c", 40)))
        end

        result
      end

      assert {:error, :dependency_changed_during_read} = dependencies(final, 3, inputs(facts), [final], Keyword.put(final.opts, :request, request))
      assert {:error, :delivery_candidate_changed} = dependencies(final, 3, inputs(facts), [final])
    end
  end

  test "a verified merged change is not release publication evidence" do
    f = fixture("github", ["published"], "pr") |> git_artifact() |> change_target() |> merged_candidate() |> verified_tools()
    assert {:ok, [observation]} = TaskDelivery.read_candidate(f.payload["work"], f.payload, f.opts)
    assert observation.status == "delivered"
    assert {:error, :dependency_delivery_evidence_unavailable} = dependencies(f, 3, nil, [f])
  end

  test "candidate tools require native targets only for PR/MR outputs and do not publish target assertions blindly" do
    f = fixture("github", [], "pr") |> git_artifact()
    tools = task_tools(f)
    assert {false, %{"error" => ":candidate_delivery_target_invalid"}} = tool(tools, "task_candidate", candidate_args(f))
    f = change_target(f)
    Agent.update(f.state, &put_in(&1.objects[f.change_path]["head"]["sha"], String.duplicate("c", 40)))
    assert {false, %{"error" => ":delivery_candidate_changed"}} = tool(tools, "task_candidate", candidate_args(f))
    assert posts(f) == []
    report = fixture("github") |> git_artifact()
    args = candidate_args(report) |> Map.update!("artifacts", &Enum.map(&1, fn item -> Map.put(item, "target", hd(f.payload["artifacts"])["target"]) end))
    assert {false, %{"error" => ":candidate_delivery_target_invalid"}} = tool(task_tools(report), "task_candidate", args)
  end

  test "native verified dependencies are transitive, retained and consumed by role tools on both providers" do
    for provider <- ["github", "gitlab"] do
      f = fixture(provider, ["verified", "verified"]) |> git_artifact()
      assert {:error, :dependency_not_verified} = dependencies(f, 3, nil, [f])
      f = verified_tools(f)
      assert {:ok, facts} = dependencies(f, 3, nil, [f])
      assert [%{"stage" => "verified", "version" => revision}] = facts.dependencies
      assert revision == f.git.revision
      assert {:ok, ^facts} = dependencies(f, 3, inputs(facts), [f])
      root = Path.join(Path.dirname(f.record["directory"]), ".artifacts")
      assert {:ok, owners} = ArtifactStore.references(root, f.payload["work"], revision, f.opts)
      assert Enum.any?(owners, &(&1["kind"] == "dependency" and &1["work"]["number"] == 3))

      second = consumer(f, 3, inputs(facts), [f]) |> verified_tools()
      assert {:ok, downstream} = dependencies(f, 4, nil, [f, second])
      assert hd(downstream.dependencies)["work"] == second.payload["work"]
      third = consumer(f, 4, inputs(downstream), [f, second])
      tools = task_tools(third)
      assert {true, %{"data" => %{"dependencies" => proofs}}} = tool(tools, "task_context", %{})
      assert proofs == downstream.dependencies

      # A missing upstream publication blocks effects even when the intermediate result is intact.
      Agent.update(f.state, &put_in(&1.objects[f.notes], []))
      before = posts(f)
      assert {false, _} = tool(tools, "task_candidate", candidate_args(third))
      assert posts(f) == before
      assert {:error, :pinned_input_unconfirmed} = dependencies(f, 4, inputs(downstream), [f, second])
    end
  end

  test "dependency observation refuses missing journals, mismatched inputs and delivery-stage shortcuts" do
    f = fixture("github", ["verified"]) |> git_artifact() |> verified_tools()
    assert {:error, :dependency_execution_unavailable} = dependencies(f, 3, nil, [])
    assert {:error, :dependency_inputs_do_not_match_plan} = dependencies(f, 3, [], [f])
    assert {:error, :dependency_inputs_do_not_match_plan} = dependencies(f, 3, "invalid", [f])
    assert {:error, :not_plan_member} = dependencies(f, 42, nil, [f])
    {:ok, facts} = dependencies(f, 3, nil, [f])
    [input] = inputs(facts)
    assert {:error, :pinned_input_unconfirmed} = dependencies(f, 3, [Map.put(input, "version", String.duplicate("0", 40))], [f])
    assert {:error, :pinned_input_unconfirmed} = dependencies(f, 3, [Map.put(input, "verification", "missing")], [f])
    changed_policy = Keyword.put(f.opts, :policy, Map.put(f.opts[:policy], "max_repairs", 1))
    assert {:error, :pinned_input_unconfirmed} = dependencies(f, 3, [input], [%{f | opts: changed_policy}])

    {:ok, plan} = TaskPlanPreflight.inspect_plan(f.parent, f.opts)
    invalid = put_in(plan.plan["revision"], "invalid")
    assert {:error, :plan_revision_changed} = TaskDependencies.read(invalid, f.payload["work"], nil, executions([f]), f.opts)
    root = Path.join(Path.dirname(f.record["directory"]), ".artifacts")
    reference = Path.wildcard(Path.join(root, "*.ref")) |> Enum.find(&(Jason.decode!(File.read!(&1))["owner"]["kind"] == "dependency"))
    File.write!(reference, "damaged consumer ownership")
    assert {:error, :artifact_publication_conflict} = dependencies(f, 3, [input], [f])

    for stage <- ["delivered", "published"] do
      staged = fixture("gitlab", [stage]) |> git_artifact() |> verified_tools()
      Agent.update(staged.state, &put_in(&1.objects[staged.child]["state"], "closed"))
      assert {:error, :dependency_delivery_evidence_unavailable} = dependencies(staged, 3, nil, [staged])
    end
  end

  test "new candidates do not silently replace a pinned valid input" do
    f = fixture("github", ["verified"]) |> git_artifact() |> verified_tools()
    {:ok, facts} = dependencies(f, 3, nil, [f])
    original = inputs(facts)
    {:ok, stopped} = RunJournal.checkpoint(current(f), %{"native_stop_confirmed" => true})
    :ok = RunJournal.complete(stopped, "completed")
    binding = %{stopped["execution_binding"] | "role" => "developer"}
    {:ok, record} = RunJournal.admit(Path.dirname(stopped["directory"]), stopped["issue_id"], execution_binding: binding)
    {:ok, record} = RunJournal.checkpoint(record, %{"thread_id" => "next-developer"})
    changed = put_in(f.payload["artifacts"], Enum.map(f.payload["artifacts"], &Map.put(&1, "version", String.duplicate("a", 40))))
    # An unverified new candidate has no usable bytes; the older pinned input remains independently provable.
    {:ok, _, _} = TaskPublication.publish(record, "candidate", changed.payload, "New candidate", f.opts)
    assert {:ok, ^facts} = dependencies(f, 3, original, [f])
    assert {:error, _} = dependencies(f, 3, nil, [f])
    Agent.update(f.state, &update_in(&1.objects[f.notes], fn [_candidate, verification, newer] -> [verification, newer] end))
    assert {:error, :current_result_unconfirmed} = dependencies(f, 3, original, [f])
  end

  test "a newer verification of the same candidate invalidates the old pinned verdict" do
    f = fixture("github", ["verified"]) |> git_artifact() |> verified_tools()
    {:ok, facts} = dependencies(f, 3, nil, [f])
    original = inputs(facts)
    {:ok, stopped} = RunJournal.checkpoint(current(f), %{"native_stop_confirmed" => true})
    :ok = RunJournal.complete(stopped, "completed")
    binding = %{stopped["execution_binding"] | "role" => "developer"}
    {:ok, developer} = RunJournal.admit(Path.dirname(stopped["directory"]), stopped["issue_id"], execution_binding: binding)
    {:ok, developer} = RunJournal.checkpoint(developer, %{"thread_id" => "recheck-developer", "native_stop_confirmed" => true})
    :ok = RunJournal.complete(developer, "completed")
    {:ok, verifier} = RunJournal.admit(Path.dirname(stopped["directory"]), stopped["issue_id"], execution_binding: stopped["execution_binding"])
    {:ok, verifier} = RunJournal.checkpoint(verifier, %{"thread_id" => "recheck-verifier", "workspace" => f.workspace})
    tools = task_tools(f, verifier)
    assert {true, _} = tool(tools, "task_check", %{"check_id" => "test"})

    finding = %{
      "id" => "F1",
      "criterion" => "result",
      "status" => "unknown",
      "required" => true,
      "rationale" => "Contradictory source needs resolution",
      "problem_sha" => TaskWorkflow.digest("problem"),
      "repair_basis_sha" => TaskWorkflow.digest("basis"),
      "evidence" => [hd(f.payload["artifacts"])["source"]]
    }

    assert {true, _} = tool(tools, "task_verification", %{"review_checks" => [], "findings" => [finding], "summary" => "Unresolved evidence"})
    assert {:error, :pinned_input_unconfirmed} = dependencies(f, 3, original, [f])
    assert {:error, :dependency_not_verified} = dependencies(f, 3, nil, [f])
  end

  test "dependency evidence is fenced against native and journal changes during the read" do
    for mutation <- [:parent, :consumer, :journal, :journal_missing, :native_error] do
      f = fixture("github", ["verified"]) |> git_artifact() |> verified_tools()
      root = Path.join(Path.dirname(f.record["directory"]), ".artifacts")
      original = f.opts[:request]

      request = fn provider, method, path, query, settings ->
        {:ok, owners} = ArtifactStore.references(root, f.payload["work"], f.git.revision, f.opts)
        pinned = Enum.any?(owners, &(&1["kind"] == "dependency"))
        trigger = pinned and path == String.replace_suffix(f.parent_notes, "/comments", "") and not Agent.get(f.state, &Map.get(&1, :dependency_mutated, false))

        if trigger do
          Agent.update(f.state, &Map.put(&1, :dependency_mutated, true))

          case mutation do
            :parent -> Agent.update(f.state, &put_in(&1.objects[f.parent_notes], &1.objects[f.parent_notes] ++ [control(f, :parent, "pause", 50)]))
            :consumer -> Agent.update(f.state, &put_in(&1.objects[String.replace(f.notes, "/issues/2", "/issues/3")], [note(50, 1, "Consumer changed")]))
            :journal -> assert {:ok, _} = RunJournal.checkpoint(current(f), %{"phase" => "changed"})
            :journal_missing -> File.rm!(Path.join(f.record["directory"], "run.json"))
            :native_error -> :ok
          end
        end

        if trigger and mutation == :native_error do
          {:error, :offline}
        else
          original.(provider, method, path, query, settings)
        end
      end

      assert {:error, _} = dependencies(f, 3, nil, [f], Keyword.put(f.opts, :request, request))
    end
  end

  test "role tools publish retained candidates and actual command results through both native providers" do
    for provider <- ["github", "gitlab"] do
      f = fixture(provider) |> git_artifact()
      developer = task_tools(f)
      assert Enum.map(developer.tool_specs, & &1["name"]) == ["task_context", "task_candidate"]
      assert developer.agent_environment == %{}
      assert "UNUSED_PUBLICATION_FIXTURE" in developer.secret_environment_names
      assert {true, %{"data" => %{"candidate" => nil, "contract" => contract}}} = tool(developer, "task_context", "{}")
      assert contract["work"] == f.payload["work"]
      assert {true, %{"data" => receipt}} = tool(developer, "task_candidate", candidate_args(f))
      assert receipt["work"] == f.payload["work"]
      assert {true, %{"data" => ^receipt}} = tool(developer, "task_candidate", candidate_args(f))
      assert length(posts(f)) == 1
      assert {true, %{"data" => %{"candidate" => candidate}}} = tool(developer, "task_context", %{})
      assert candidate["artifacts"] == f.payload["artifacts"]
      verifier = verifier_tools(f, current(f))
      assert Enum.map(verifier.tool_specs, & &1["name"]) == ["task_context", "task_check", "task_verification"]
      args = %{"review_checks" => [], "findings" => [], "summary" => "Independent check complete"}
      assert {false, %{"error" => ":command_check_not_completed"}} = tool(verifier, "task_verification", args)
      assert {false, %{"error" => ":unassigned_verification_check"}} = tool(verifier, "task_check", %{"check_id" => "foreign"})

      assert {true, %{"data" => %{"exit_code" => 0, "output_sha" => sha, "output" => "expected\n", "output_encoding" => "utf8", "output_truncated" => false}}} =
               tool(verifier, "task_check", %{"check_id" => "test"})

      assert {true, %{"data" => %{"output_sha" => ^sha}}} = tool(verifier, "task_check", %{"check_id" => "test"})
      assert {true, %{"data" => verified}} = tool(verifier, "task_verification", args)
      assert {true, %{"data" => ^verified}} = tool(verifier, "task_verification", args)
      assert length(posts(f)) == 2
      assert {:ok, facts} = evidence(f, current(f))
      assert facts.verification["source"] == verified["source"]
      assert hd(facts.verification["checks"])["output_sha"] == sha
      assert {false, %{"error" => ":task_execution_no_longer_owned"}} = tool(developer, "task_context", %{})
    end
  end

  test "bound task sessions reject policy substitution, copied callers, scope overrides and unsupported tools" do
    f = fixture("github") |> git_artifact()
    developer = task_tools(f)
    assert {:error, :invalid_task_tool_binding} = TaskTools.bind(current(f), %{}, f.opts)
    assert {:error, :invalid_task_tool_binding} = TaskTools.bind(%{}, nil, f.opts)
    missing_policy = [run_record: current(f), dynamic_tool_binding: %{}]
    options = [run_record: current(f), execution_policy: f.opts[:policy], task_native_options: f.opts]
    assert {:error, :invalid_task_tool_binding} = DynamicTool.bind_session(missing_policy)
    assert {:ok, bound} = DynamicTool.bind_session(options)
    assert Map.has_key?(bound, :task_execution)
    foreign = Task.async(fn -> tool(developer, "task_context", %{}) end)
    assert {false, %{"error" => ":task_tool_owner_mismatch"}} = Task.await(foreign)
    assert {false, %{"error" => ":task_tool_owner_mismatch"}} = tool(developer, "task_context", %{}, issue: %{id: "foreign"})
    assert {true, _} = tool(developer, "task_context", %{}, issue: %{id: f.record["issue_id"]})

    for {name, args} <- [
          {"task_check", %{"check_id" => "test"}},
          {"task_handoff", %{}},
          {"github_api", %{}},
          {"task_candidate", Map.put(candidate_args(f), "work", %{})},
          {"task_context", %{"policy" => %{}}}
        ] do
      assert {false, %{"error" => ":invalid_task_tool_call"}} = tool(developer, name, args)
    end

    for args <- ["invalid json", "[]", nil, []] do
      assert {false, %{"error" => ":invalid_task_tool_arguments"}} = tool(developer, "task_context", args)
    end

    for artifacts <- [[], [nil], [%{"id" => "foreign", "version" => f.git.revision}], [%{"id" => "output", "version" => f.git.revision, "source" => "invented"}]] do
      assert {false, %{"error" => ":candidate_outputs_do_not_match_contract"}} =
               tool(developer, "task_candidate", Map.put(candidate_args(f), "artifacts", artifacts))
    end

    assert posts(f) == []
    {:ok, _} = RunJournal.checkpoint(current(f), %{"native_stop_confirmed" => true})
    assert {false, %{"error" => ":task_execution_no_longer_owned"}} = tool(developer, "task_context", %{})
  end

  test "task tools retain native pause receipts, respect budgets and reject changed parent identity" do
    f = fixture("gitlab") |> git_artifact()
    tools = task_tools(f)
    original = Agent.get(f.state, & &1.objects[f.parent_notes])
    pause = control(f, :parent, "pause", 10)
    Agent.update(f.state, &put_in(&1.objects[f.parent_notes], original ++ [pause]))
    assert {false, %{"error" => ":task_execution_controlled"}} = tool(tools, "task_candidate", candidate_args(f))
    assert {true, %{"data" => %{"controls" => [%{"kind" => "pause"}]}}} = tool(tools, "task_context", %{})
    assert map_size(current(f)["control_receipts"]) == 1
    Agent.update(f.state, &put_in(&1.objects[f.parent_notes], original))
    assert {false, %{"error" => ":control_source_unconfirmed"}} = tool(tools, "task_context", %{})
    source = hd(Map.values(current(f)["control_receipts"]))
    resume = control(f, :parent, "resume", 11, %{"restriction" => source})
    Agent.update(f.state, &put_in(&1.objects[f.parent_notes], original ++ [pause, resume]))
    record = current(f)
    {:ok, _} = RunJournal.checkpoint(record, %{"workflow" => Map.put(record["workflow"], "used_ms", 100_000)})
    assert {false, %{"error" => ":task_execution_controlled"}} = tool(tools, "task_candidate", candidate_args(f))
    assert posts(f) == []
    record = current(f)
    {:ok, _} = RunJournal.checkpoint(record, %{"workflow" => Map.delete(record["workflow"], "budget_ms")})
    assert {false, %{"error" => ":task_execution_controlled"}} = tool(tools, "task_candidate", candidate_args(f))
    parent_path = String.replace_suffix(f.parent_notes, "/notes", "")
    Agent.update(f.state, &put_in(&1.objects[parent_path]["state"], "closed"))
    assert {false, %{"error" => ":parent_not_open"}} = tool(tools, "task_context", %{})
  end

  test "a verifier can submit only configured review checks and cannot replace a generation result" do
    f = fixture("github") |> git_artifact()
    policy = Map.put(f.opts[:policy], "checks", %{"test" => %{"kind" => "review"}})
    binding = Map.put(f.record["execution_binding"], "policy_sha", TaskWorkflow.digest(policy))
    {:ok, stopped} = RunJournal.checkpoint(f.record, %{"native_stop_confirmed" => true})
    :ok = RunJournal.complete(stopped, "completed")
    {:ok, developer} = RunJournal.admit(Path.dirname(stopped["directory"]), stopped["issue_id"], execution_binding: binding)
    {:ok, developer} = RunJournal.checkpoint(developer, %{"thread_id" => "review-developer"})
    f = %{f | opts: Keyword.put(f.opts, :policy, policy)}
    tools = task_tools(f, developer)
    assert {true, _} = tool(tools, "task_candidate", candidate_args(f))
    verifier = verifier_tools(f, current(f))

    args = %{
      "review_checks" => [%{"id" => "test", "result" => "passed", "rationale" => "Checked the fixed source against result criterion"}],
      "findings" => [],
      "summary" => "Independent source review"
    }

    for checks <- [[], [nil], [%{"id" => "test", "result" => "passed", "rationale" => "okay", "exit_code" => 0}]] do
      assert {false, %{"error" => ":review_checks_do_not_match_policy"}} = tool(verifier, "task_verification", %{args | "review_checks" => checks})
    end

    assert {false, %{"error" => ":invalid_verification_findings"}} = tool(verifier, "task_verification", %{args | "findings" => [%{"id" => "unsupported"}]})
    assert {true, _} = tool(verifier, "task_verification", args)
    changed = put_in(args["review_checks"], [%{"id" => "test", "result" => "failed", "rationale" => "Changed opinion"}])
    assert {false, %{"error" => ":execution_result_already_submitted"}} = tool(verifier, "task_verification", changed)
    assert length(posts(f)) == 2
  end

  test "a pause first observed during candidate retrieval stops host checks and survives source disappearance" do
    f = fixture("gitlab") |> git_artifact()
    developer = task_tools(f)
    assert {true, _} = tool(developer, "task_candidate", candidate_args(f))
    _verifier = verifier_tools(f, current(f))
    original = Agent.get(f.state, & &1.objects[f.parent_notes])
    request = f.opts[:request]
    Process.put(:task_tools_parent_reads, 0)

    wrapped = fn provider, method, path, query, settings ->
      if path == f.parent_notes do
        count = Process.get(:task_tools_parent_reads) + 1
        Process.put(:task_tools_parent_reads, count)
        if count == 3, do: Agent.update(f.state, &put_in(&1.objects[f.parent_notes], original ++ [control(f, :parent, "pause", 10)]))
      end

      request.(provider, method, path, query, settings)
    end

    opts = Keyword.put(f.opts, :request, wrapped)
    {:ok, tools} = TaskTools.bind(current(f), f.opts[:policy], opts)
    assert {false, %{"error" => ":task_execution_controlled"}} = tool(tools, "task_check", %{"check_id" => "test"})
    assert map_size(current(f)["control_receipts"]) == 1
    assert current(f)["check_runs"] in [nil, %{}]
    Agent.update(f.state, &put_in(&1.objects[f.parent_notes], original))
    assert {false, %{"error" => ":control_source_unconfirmed"}} = tool(tools, "task_check", %{"check_id" => "test"})
  end

  test "changed candidate and closed member facts cannot be used by an older bound role" do
    f = fixture("github") |> git_artifact()
    tools = task_tools(f)
    assert {true, _} = tool(tools, "task_candidate", candidate_args(f))
    {:ok, developer} = RunJournal.checkpoint(current(f), %{"native_stop_confirmed" => true})
    :ok = RunJournal.complete(developer, "completed")
    binding = %{developer["execution_binding"] | "role" => "verifier", "candidate" => TaskWorkflow.digest("different candidate")}
    {:ok, record} = RunJournal.admit(Path.dirname(developer["directory"]), developer["issue_id"], execution_binding: binding)
    {:ok, record} = RunJournal.checkpoint(record, %{"thread_id" => "stale-candidate-verifier"})
    verifier = task_tools(f, record)
    assert {false, %{"error" => ":task_candidate_changed"}} = tool(verifier, "task_check", %{"check_id" => "test"})
    notes = Agent.get(f.state, & &1.objects[f.notes])
    Agent.update(f.state, &put_in(&1.objects[f.notes], Enum.map(notes, fn note -> Map.update!(note, "body", fn body -> body <> "edited" end) end)))
    assert {false, %{"error" => ":unrecorded_native_result"}} = tool(verifier, "task_check", %{"check_id" => "test"})
    Agent.update(f.state, &put_in(&1.objects[f.notes], notes))
    Agent.update(f.state, &put_in(&1.objects[f.child]["state"], "closed"))
    assert {false, %{"error" => ":task_tool_scope_changed"}} = tool(verifier, "task_context", %{})
    assert length(posts(f)) == 1
  end

  test "parent and child pauses fence native writes and persist source memory before returning a blocked result" do
    for provider <- ["github", "gitlab"], scope <- [:parent, :member] do
      f = fixture(provider)
      path = if scope == :parent, do: f.parent_notes, else: f.notes
      original = Agent.get(f.state, & &1.objects[path])
      pause = control(f, scope, "pause", 10)
      Agent.update(f.state, &put_in(&1.objects[path], original ++ [pause]))
      assert {:error, :publication_controlled} = publish(f)
      persisted = current(f)
      assert map_size(persisted["control_receipts"]) == 1
      assert posts(f) == []

      Agent.update(f.state, &put_in(&1.objects[path], original))
      assert {:error, :control_source_unconfirmed} = publish(f, persisted)
      assert posts(f) == []

      source = hd(Map.values(persisted["control_receipts"]))
      resume = control(f, scope, "resume", 11, %{"restriction" => source})
      Agent.update(f.state, &put_in(&1.objects[path], original ++ [pause, resume]))
      assert {:ok, saved, _} = publish(f, current(f))
      assert map_size(saved["control_receipts"]) == 2
      assert length(posts(f)) == 1

      Agent.update(f.state, &update_in(&1.objects[path], fn notes -> Enum.reject(notes, fn note -> note["id"] == 11 end) end))
      changed = update_in(f.payload["artifacts"], fn [artifact] -> [Map.put(artifact, "version", "v2")] end)
      assert {:error, :control_source_unconfirmed} = publish(changed, saved)
      assert length(posts(f)) == 1
    end
  end

  test "native evidence includes current controls without discarding an already published candidate" do
    f = fixture("github") |> git_artifact()
    assert {:ok, saved, _} = publish(f)
    Agent.update(f.state, &update_in(&1.objects[f.parent_notes], fn notes -> notes ++ [control(f, :parent, "pause", 10)] end))
    assert {:ok, facts} = evidence(f, saved)
    assert facts.candidate
    assert [%{"kind" => "pause", "source" => source}] = facts.controls.restrictions
    assert source in facts.sources
    assert map_size(facts.controls.receipts) == 1
    {:ok, plan} = TaskPlanPreflight.inspect_plan(f.parent, f.opts)

    resolved = %{
      "sources" => facts.sources,
      "restrictions" => facts.controls.restrictions,
      "releases" => facts.controls.releases,
      "control_receipts" => facts.controls.receipts,
      "candidate" => facts.candidate,
      "verification" => nil,
      "dependencies" => [],
      "deliveries" => [],
      "acceptance" => nil,
      "active" => true
    }

    context = %{plan: plan, work: f.payload["work"], runtime: saved, policy: f.opts[:policy], evidence: resolved}
    assert {:ok, flow} = TaskLifecycle.assess(context, 0)
    assert flow["stop_required"]
    assert flow["execution"] == "stopping"
    refute flow["dispatchable"]
    {:ok, saved} = RunJournal.checkpoint(saved, %{"workflow" => flow})
    Agent.update(f.state, &update_in(&1.objects[f.parent_notes], fn [approval, _pause] -> [approval] end))
    assert {:error, :control_source_unconfirmed} = evidence(f, saved)
  end

  test "both providers publish only to the owning Issue, read back the exact actor and reuse one receipt" do
    for provider <- ["github", "gitlab"] do
      fixture = fixture(provider)
      assert {:ok, saved, receipt} = publish(fixture)
      assert length(posts(fixture)) == 1
      [native] = Agent.get(fixture.state, & &1.objects[fixture.notes])
      assert receipt["source"] == TaskDecision.source_ref(native)
      assert receipt["work"] == fixture.record["execution_binding"]["work"]
      assert {:ok, _saved, ^receipt} = publish(fixture, saved)
      assert length(posts(fixture)) == 1
      assert {:error, :stale_or_unowned_execution_checkpoint} = publish(fixture)
      assert length(posts(fixture)) == 1
    end
  end

  test "a lost write response recovers the native receipt without another POST" do
    fixture = fixture("gitlab")
    Agent.update(fixture.state, &%{&1 | mode: :lost})
    assert {:ok, saved, receipt} = publish(fixture)
    assert {:ok, _, ^receipt} = publish(fixture, saved)
    assert length(posts(fixture)) == 1
  end

  test "changing only presentation text cannot create another intent for the same execution evidence" do
    fixture = fixture("github")
    {:ok, saved, _} = publish(fixture)

    assert {:error, :publication_intent_changed} =
             TaskPublication.publish(saved, "candidate", fixture.payload, "Reworded explanation", fixture.opts)

    assert length(posts(fixture)) == 1
  end

  test "an uncertain absent comment remains fenced after restart and recovers when it becomes visible" do
    fixture = fixture("github")
    Agent.update(fixture.state, &%{&1 | mode: :missing})
    assert {:error, :publication_readback_unconfirmed} = publish(fixture)
    saved = current(fixture)
    assert :ok = RunJournal.complete(saved, "completed")
    assert {:ok, resumed} = RunJournal.admit(Path.dirname(saved["directory"]), saved["issue_id"], execution_binding: saved["execution_binding"])
    assert {:error, :publication_readback_unconfirmed} = publish(fixture, resumed)
    assert length(posts(fixture)) == 1
    [body] = posts(fixture)
    Agent.update(fixture.state, &put_in(&1, [:objects, fixture.notes], [note(100, 99, body)]))
    assert {:ok, recovered} = TaskPublication.recover(current(fixture), fixture.opts)
    assert {:ok, _, _} = publish(fixture, recovered)
    assert length(posts(fixture)) == 1
  end

  test "foreign author, edited body, edited timestamp and duplicate IDs cannot become publication receipts" do
    for change <- [:actor, :body, :time, :duplicate, :missing] do
      fixture = fixture("gitlab")
      assert {:ok, saved, _} = publish(fixture)

      Agent.update(fixture.state, fn data ->
        [native] = data.objects[fixture.notes]

        notes =
          case change do
            :actor -> [put_in(native["author"]["id"], 1)]
            :body -> [Map.update!(native, "body", &(&1 <> "\nEdited"))]
            :time -> [Map.put(native, "updated_at", "2026-10-17T00:00:01Z")]
            :duplicate -> [native, Map.put(native, "id", 101)]
            :missing -> []
          end

        put_in(data, [:objects, fixture.notes], notes)
      end)

      assert {:error, :publication_readback_unconfirmed} = publish(fixture, saved)
      assert length(posts(fixture)) == 1
    end
  end

  test "changed approval and a closed member prevent publication before POST" do
    for target <- [:approval, :child] do
      fixture = fixture("github")

      Agent.update(fixture.state, fn data ->
        if target == :approval,
          do: put_in(data, [:objects, fixture.parent_notes], []),
          else: put_in(data, [:objects, fixture.child, "state"], "closed")
      end)

      assert {:error, _} = publish(fixture)
      assert posts(fixture) == []
    end
  end

  test "the configured credential must resolve to the expected publisher, even if it could write" do
    fixture = fixture("gitlab")
    Agent.update(fixture.state, &put_in(&1, [:objects, "/user", "id"], 7))
    assert {:error, {:publication_not_sent, :native_publication_actor_mismatch}} = publish(fixture)
    assert posts(fixture) == []
    Agent.update(fixture.state, &put_in(&1, [:objects, "/user", "id"], 99))
    assert {:ok, _, _} = publish(fixture, current(fixture))
    assert length(posts(fixture)) == 1
  end

  test "role, thread, candidate and policy are fixed before any provider operation" do
    fixture = fixture("github")

    for {kind, payload, record, opts} <- [
          {"verification", fixture.payload, fixture.record, fixture.opts},
          {"candidate", Map.put(fixture.payload, "inputs", ["foreign"]), fixture.record, fixture.opts},
          {"candidate", fixture.payload, Map.delete(fixture.record, "thread_id"), fixture.opts},
          {"candidate", fixture.payload, fixture.record, Keyword.put(fixture.opts, :policy, %{})}
        ] do
      assert {:error, :invalid_publication_context} = TaskPublication.publish(record, kind, payload, "Result", opts)
    end

    assert posts(fixture) == []
  end

  test "comment write fencing includes note edits even when the Issue's version is unchanged" do
    fixture = fixture("github")
    work = fixture.record["execution_binding"]["work"]
    {:ok, snapshot} = NativeWork.read(work, fixture.opts)
    Agent.update(fixture.state, &put_in(&1, [:objects, fixture.notes], [note(100, 1, "Pause")]))
    assert {:not_sent, :native_snapshot_changed} = NativeWork.comment(snapshot, "Result", "99", fixture.opts)
    assert posts(fixture) == []
    assert {:not_sent, :invalid_native_publication} = NativeWork.comment(snapshot, "", "99", fixture.opts)
    assert {:not_sent, :invalid_native_publication} = NativeWork.comment(snapshot, "", "99")
  end

  test "default provider writers do not fall back to unrelated credentials" do
    for provider <- ["github", "gitlab"] do
      fixture = fixture(provider)
      missing = "SYMPHONY_MISSING_PUBLICATION_#{System.unique_integer([:positive])}"
      refute System.get_env(missing)
      repositories = Enum.map(fixture.opts[:repositories], &Map.put(&1, "credential", "$" <> missing))
      opts = fixture.opts |> Keyword.delete(:write_request) |> Keyword.put(:repositories, repositories)
      {:ok, snapshot} = NativeWork.read(fixture.record["execution_binding"]["work"], opts)
      assert {:uncertain, :native_write_failed} = NativeWork.comment(snapshot, "Result", "99", opts)
      assert posts(fixture) == []
    end
  end

  test "GitLab Issue evidence cannot execute quick actions through comment text" do
    fixture = fixture("gitlab")
    work = fixture.record["execution_binding"]["work"]
    {:ok, snapshot} = NativeWork.read(work, fixture.opts)
    body = "Result\n/close"
    assert {:not_sent, :native_comment_action_not_allowed} = NativeWork.comment(snapshot, body, "99", fixture.opts)
    assert {:error, :invalid_publication_context} = TaskPublication.publish(fixture.record, "candidate", fixture.payload, body, fixture.opts)
    assert posts(fixture) == []
    refute NativeWork.comment_body?("unknown", body)
  end

  test "a verifier publication stays bound to its separate journal generation and fixed candidate" do
    fixture = fixture("github")
    {:ok, developer, _} = publish(fixture)
    {:ok, developer} = RunJournal.checkpoint(developer, %{"native_stop_confirmed" => true})
    :ok = RunJournal.complete(developer, "completed")
    binding = %{developer["execution_binding"] | "role" => "verifier", "candidate" => TaskWorkflow.digest(fixture.payload)}
    {:ok, verifier} = RunJournal.admit(Path.dirname(developer["directory"]), developer["issue_id"], execution_binding: binding)
    {:ok, verifier} = RunJournal.checkpoint(verifier, %{"thread_id" => "verifier"})
    payload = Map.take(binding, ~w(candidate inputs policy_sha)) |> Map.merge(%{"checks" => [], "findings" => []})
    forged = Map.put(payload, "checks", [%{"id" => "test", "exit_code" => 0, "output_sha" => TaskWorkflow.digest("asserted")}])
    assert {:error, :invalid_publication_context} = TaskPublication.publish(verifier, "verification", forged, "Claimed success", fixture.opts)
    assert {:ok, _, receipt} = TaskPublication.publish(verifier, "verification", payload, "Verification report", fixture.opts)
    assert receipt["work"] == binding["work"]
    assert length(posts(fixture)) == 2
    refute Enum.at(posts(fixture), 0) == Enum.at(posts(fixture), 1)
  end

  test "a real isolated command receipt is published as evidence by the independent verifier generation" do
    fixture = fixture("gitlab") |> git_artifact()
    payload = fixture.payload
    {:ok, developer, _} = TaskPublication.publish(fixture.record, "candidate", payload, "Fixed report", fixture.opts)
    {:ok, developer} = RunJournal.checkpoint(developer, %{"native_stop_confirmed" => true})
    :ok = RunJournal.complete(developer, "completed")
    candidate = Map.put(payload, "digest", TaskWorkflow.digest(payload))
    binding = %{developer["execution_binding"] | "role" => "verifier", "candidate" => candidate["digest"]}
    {:ok, verifier} = RunJournal.admit(Path.dirname(developer["directory"]), developer["issue_id"], execution_binding: binding)
    now = System.system_time(:millisecond)
    flow = TaskWorkflow.new(10_000, now) |> TaskWorkflow.start(now) |> Map.merge(%{"schema_version" => 2, "repair_history" => %{}})
    {:ok, verifier} = RunJournal.checkpoint(verifier, %{"thread_id" => "independent-verifier", "workspace" => fixture.workspace, "workflow" => flow})
    assert {:ok, checked, receipt} = CommandCheck.run(verifier, candidate, "test", fixture.opts[:policy])
    assert receipt["exit_code"] == 0
    check = receipt |> Map.take(~w(candidate command exit_code output_sha reason snapshot_valid)) |> Map.put("id", "test")
    report = Map.take(binding, ~w(candidate inputs policy_sha)) |> Map.merge(%{"checks" => [check], "findings" => []})
    assert {:ok, saved, published} = TaskPublication.publish(checked, "verification", report, "Fixed report verified", fixture.opts)
    assert published["work"] == binding["work"]
    assert length(posts(fixture)) == 2
    assert List.last(posts(fixture)) =~ receipt["output_sha"]

    assert {:ok, facts} = evidence(fixture, saved)
    assert facts.candidate["digest"] == candidate["digest"]
    assert facts.verification["source"] == published["source"]
    assert hd(facts.artifacts).files |> hd() |> Map.fetch!("content") == "expected\n"
    {:ok, plan} = TaskPlanPreflight.inspect_plan(fixture.parent, fixture.opts)

    resolved = %{
      "candidate" => facts.candidate,
      "verification" => facts.verification,
      "sources" => facts.sources,
      "restrictions" => [],
      "releases" => [],
      "deliveries" => [],
      "dependencies" => [],
      "acceptance" => nil,
      "active" => false
    }

    context = %{plan: plan, work: fixture.payload["work"], runtime: Map.put(saved, "native_stop_confirmed", true), evidence: resolved, policy: fixture.opts[:policy]}
    assert {:ok, assessment} = TaskLifecycle.assess(context, System.system_time(:millisecond))
    assert assessment["action"] == "deliver"
    assert assessment["dispatchable"]
    refute assessment["closeable"]

    changed_policy = Map.put(fixture.opts[:policy], "max_repairs", 3)
    assert {:ok, %{verification: nil, candidate: %{}}} = evidence(fixture, saved, changed_policy)
    output = Path.join([saved["directory"], "checks", receipt["id"], "output"])
    File.write!(output, "tampered")
    assert {:error, :command_evidence_not_attested} = evidence(fixture, saved)
  end

  test "native candidate retrieval works for both providers and absent evidence remains absent" do
    for provider <- ["github", "gitlab"] do
      fixture = fixture(provider) |> git_artifact()
      assert {:ok, %{candidate: nil, verification: nil}} = evidence(fixture, fixture.record)
      {:ok, saved, receipt} = publish(fixture)
      assert {:ok, facts} = evidence(fixture, saved)
      assert facts.candidate["source"] == receipt["source"]
      assert hd(facts.artifacts).receipt["source"] in facts.sources
      assert {:error, :result_execution_unconfirmed} = evidence(fixture, Map.put(saved, "thread_id", "not-the-publisher"))
      assert {:error, :unrecorded_native_result} = evidence(fixture, Map.delete(saved, "publications"))
      assert {:error, :invalid_publication_journal} = evidence(fixture, Map.put(saved, "publications", []))
      Agent.update(fixture.state, &put_in(&1.objects[fixture.notes], []))
      assert {:error, :current_result_unconfirmed} = evidence(fixture, saved)
    end
  end

  test "retained candidate bytes survive source cleanup but never bypass fresh native publication evidence" do
    fixture = fixture("github") |> git_artifact()
    {:ok, saved, _} = publish(fixture)
    assert {:ok, original} = evidence(fixture, saved)
    File.rm_rf!(fixture.git.path)
    File.rm_rf!(fixture.workspace)
    Agent.update(fixture.state, &%{&1 | objects: Map.reject(&1.objects, fn {path, _} -> String.contains?(path, "/git/") end)})
    assert {:ok, recovered} = evidence(fixture, saved)
    assert recovered.artifacts == original.artifacts
    assert recovered.candidate == original.candidate
    root = Path.join(Path.dirname(saved["directory"]), ".artifacts")
    assert {:ok, [owner]} = ArtifactStore.references(root, fixture.payload["work"], fixture.git.revision, fixture.opts)
    assert owner["revision"] == original.candidate["digest"]
    Agent.update(fixture.state, &put_in(&1.objects[fixture.notes], []))
    assert {:error, :current_result_unconfirmed} = evidence(fixture, saved)
  end

  test "evidence selection cannot silently choose between conflicting results from one generation" do
    fixture = fixture("github") |> git_artifact()
    {:ok, saved, _} = publish(fixture)
    changed = Map.update!(fixture.payload, "artifacts", &Enum.map(&1, fn artifact -> Map.put(artifact, "id", "conflicting") end))
    {:ok, saved, _} = TaskPublication.publish(saved, "candidate", changed, "Conflicting candidate", fixture.opts)
    assert {:error, :ambiguous_execution_result} = evidence(fixture, saved)
  end

  test "newer execution results replace historical ones but losing the newest source never falls back" do
    fixture = fixture("github") |> git_artifact()
    {:ok, original, _} = publish(fixture)
    {:ok, original} = RunJournal.checkpoint(original, %{"native_stop_confirmed" => true})
    :ok = RunJournal.complete(original, "completed")
    binding = Map.put(original["execution_binding"], "candidate", TaskWorkflow.digest(fixture.payload))
    {:ok, next} = RunJournal.admit(Path.dirname(original["directory"]), original["issue_id"], execution_binding: binding)
    {:ok, next} = RunJournal.checkpoint(next, %{"thread_id" => "next-developer"})
    {:ok, saved, receipt} = publish(fixture, next)
    assert {:ok, facts} = evidence(fixture, saved)
    assert facts.candidate["execution"]["thread_id"] == "next-developer"
    assert facts.candidate["source"] == receipt["source"]
    Agent.update(fixture.state, &update_in(&1.objects[fixture.notes], fn [old, _new] -> [old] end))
    assert {:error, :current_result_unconfirmed} = evidence(fixture, saved)
  end

  test "a native write not yet reconciled cannot become current evidence merely because the comment exists" do
    fixture = fixture("github") |> git_artifact()
    {:ok, saved, receipt} = publish(fixture)
    entry = saved["publications"][receipt["id"]] |> Map.put("status", "sending") |> Map.delete("receipt")
    uncertain = Map.put(saved, "publications", %{receipt["id"] => entry})
    assert {:error, :current_result_unconfirmed} = evidence(fixture, uncertain)
  end

  test "a native publication edit during artifact retrieval invalidates the complete observation" do
    fixture = fixture("github") |> git_artifact()
    {:ok, saved, _} = publish(fixture)
    {:ok, plan} = TaskPlanPreflight.inspect_plan(fixture.parent, fixture.opts)
    original = fixture.opts[:request]

    racing = fn provider, method, path, query, settings ->
      result = original.(provider, method, path, query, settings)

      if String.contains?(path, "/git/blobs/") do
        Agent.update(fixture.state, &update_in(&1.objects[fixture.notes], fn [note] -> [Map.put(note, "body", note["body"] <> "\nChanged during retrieval")] end))
      end

      result
    end

    opts = Keyword.put(fixture.opts, :request, racing)
    assert {:error, :member_evidence_scope_changed} = TaskEvidence.read_member(plan, fixture.payload["work"], saved, fixture.opts[:policy], opts)
  end

  test "a new parent pause during artifact retrieval invalidates the result before it can authorize work" do
    f = fixture("github") |> git_artifact()
    {:ok, saved, _} = publish(f)
    {:ok, plan} = TaskPlanPreflight.inspect_plan(f.parent, f.opts)
    original = f.opts[:request]

    racing = fn provider, method, path, query, settings ->
      result = original.(provider, method, path, query, settings)

      if String.contains?(path, "/git/blobs/") do
        Agent.update(f.state, &update_in(&1.objects[f.parent_notes], fn notes -> Enum.uniq_by(notes ++ [control(f, :parent, "pause", 10)], fn note -> note["id"] end) end))
      end

      result
    end

    assert {:error, :member_evidence_scope_changed} =
             TaskEvidence.read_member(plan, f.payload["work"], saved, f.opts[:policy], Keyword.put(f.opts, :request, racing))
  end

  test "a malformed journal envelope cannot invent an execution generation" do
    fixture = fixture("github") |> git_artifact()
    {:ok, saved, receipt} = publish(fixture)
    entry = saved["publications"][receipt["id"]]
    [json] = Regex.run(~r/<!-- symphony-evidence (\{[^\n]*\}) -->/, entry["body"], capture: :all_but_first)
    envelope = Jason.decode!(json) |> Map.put("generation", "invented")
    id = TaskWorkflow.digest(Map.drop(envelope, ~w(id summary)))
    envelope = Map.put(envelope, "id", id)
    body = envelope["summary"] <> "\n\n<!-- symphony-evidence " <> TaskWorkflow.canonical_json(envelope) <> " -->\n<!-- symphony-engine-notice -->"
    entry = entry |> Map.merge(%{"id" => id, "body" => body, "status" => "prepared"}) |> Map.delete("receipt")
    assert {:error, :invalid_publication_journal} = evidence(fixture, Map.put(saved, "publications", %{id => entry}))
  end

  test "unretrievable sources and changed native scope cannot be treated as current candidates" do
    for artifact <- [%{"id" => "output", "kind" => "report", "version" => "v1"}, %{"id" => "output", "kind" => "report", "version" => "v1", "source" => "asserted"}] do
      fixture = fixture("github")
      {:ok, saved, _} = TaskPublication.publish(fixture.record, "candidate", Map.put(fixture.payload, "artifacts", [artifact]), "Unavailable", fixture.opts)
      assert {:error, :artifact_source_mismatch} = evidence(fixture, saved)
    end

    fixture = fixture("github") |> git_artifact()
    {:ok, saved, _} = publish(fixture)
    {:ok, plan} = TaskPlanPreflight.inspect_plan(fixture.parent, fixture.opts)
    Agent.update(fixture.state, &update_in(&1.objects[fixture.child]["body"], fn body -> body <> "\nChanged" end))
    assert {:error, :member_evidence_scope_changed} = TaskEvidence.read_member(plan, fixture.payload["work"], saved, fixture.opts[:policy], fixture.opts)
    Agent.update(fixture.state, &update_in(&1.objects[fixture.notes], fn [note] -> [Map.put(note, "body", note["body"] <> "\nEdited")] end))
    assert {:error, :unrecorded_native_result} = evidence(fixture, saved)
  end

  test "damaged intents fail before attempting recovery or allowing a new publication" do
    fixture = fixture("github")
    {:ok, saved, _} = publish(fixture)
    [{id, entry}] = Map.to_list(saved["publications"])

    for entries <- [
          [],
          %{id => nil},
          %{id => Map.put(entry, "body", "corrupt")},
          %{id => Map.put(entry, "status", "unknown")},
          %{id => Map.put(entry, "work", fixture.parent)},
          %{id => Map.delete(entry, "receipt")},
          %{"other" => entry}
        ] do
      assert {:error, :invalid_publication_journal} = TaskPublication.recover(Map.put(saved, "publications", entries), fixture.opts)
    end

    assert {:error, :invalid_publication_context} =
             TaskPublication.publish(saved, "candidate", fixture.payload, "<!-- symphony-plan-decision -->", fixture.opts)

    assert {:error, :invalid_publication_context} = TaskPublication.publish(saved, "candidate", fixture.payload, "Result")
    assert {:ok, _} = TaskPublication.recover(fixture.record)

    assert length(posts(fixture)) == 1
  end

  test "status-only write success is insufficient, and transport rejection leaves uncertainty" do
    for response <- [{:ok, %{status: 201}}, {:ok, %{status: 503}}] do
      fixture = fixture("gitlab")
      writer = fn _, _, _, _, _, _ -> response end
      opts = Keyword.put(fixture.opts, :write_request, writer)

      assert {:error, :publication_readback_unconfirmed} =
               TaskPublication.publish(fixture.record, "candidate", fixture.payload, "Result", opts)

      assert {:error, :publication_readback_unconfirmed} = TaskPublication.recover(current(fixture), opts)
    end
  end

  test "a crash after the provider write retains a recoverable sending intent" do
    fixture = fixture("gitlab")
    writer = fixture.opts[:write_request]

    crashing = fn a, b, c, d, e, f ->
      writer.(a, b, c, d, e, f)
      raise "fixture disconnected after write"
    end

    assert_raise RuntimeError, "fixture disconnected after write", fn ->
      TaskPublication.publish(fixture.record, "candidate", fixture.payload, "Result", Keyword.put(fixture.opts, :write_request, crashing))
    end

    assert {:ok, recovered} = TaskPublication.recover(current(fixture), fixture.opts)
    [entry] = Map.values(recovered["publications"])
    assert entry["status"] == "published"
    assert length(posts(fixture)) == 1
  end

  test "a concurrent recovery can confirm the first POST but cannot send a duplicate or accept a stale callback" do
    fixture = fixture("github")
    caller = self()
    writer = fixture.opts[:write_request]

    waiting = fn a, b, c, d, e, f ->
      result = writer.(a, b, c, d, e, f)
      send(caller, {:remote_written, self()})

      receive do
        :respond -> result
      end
    end

    publishing =
      Task.async(fn ->
        TaskPublication.publish(fixture.record, "candidate", fixture.payload, "Result", Keyword.put(fixture.opts, :write_request, waiting))
      end)

    assert_receive {:remote_written, worker}
    assert {:ok, recovered} = TaskPublication.recover(current(fixture), fixture.opts)
    send(worker, :respond)
    assert {:error, :stale_or_unowned_execution_checkpoint} = Task.await(publishing)
    assert {:ok, _, _} = TaskPublication.publish(recovered, "candidate", fixture.payload, "Result", fixture.opts)
    assert length(posts(fixture)) == 1
  end
end
