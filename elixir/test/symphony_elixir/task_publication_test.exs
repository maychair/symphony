defmodule SymphonyElixir.TaskPublicationTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.{ArtifactStore, CommandCheck, ReportArtifact, TaskTools}
  alias SymphonyElixir.Codex.DynamicTool
  alias SymphonyElixir.{GitArtifact, GitArtifactFixture}
  alias SymphonyElixir.{NativeWork, RunJournal, TaskDecision, TaskPlan, TaskPublication, TaskWorkflow, WorkRef}
  alias SymphonyElixir.{TaskDelivery, TaskDependencies, TaskEvidence, TaskLifecycle}
  alias SymphonyElixir.TaskPlanPreflight

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

  defp report_fixture(provider, stages) do
    f = fixture(provider, stages, "report", %{"test" => %{"kind" => "review"}})
    body = "# Findings\n\nThe cited experiment supports the conclusion.\n\nLimit: only the approved input was examined.\n<!-- reader note -->"
    {:ok, report} = ReportArtifact.build(f.payload["work"], "output", body)
    %{f | payload: Map.put(f.payload, "artifacts", [report])} |> Map.put(:workspace, nil)
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
