defmodule SymphonyElixir.TaskDeliveryPublicationTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.{ArtifactStore, GitArtifact, GitArtifactFixture, RunJournal}
  alias SymphonyElixir.Codex.DynamicTool
  alias SymphonyElixir.{TaskDecision, TaskDelivery, TaskDependencies, TaskEvidence, TaskPlan}
  alias SymphonyElixir.{TaskPlanPreflight, TaskPublicationDelivery, TaskTools, TaskWorkflow, WorkRef}

  defp contract(work, parent, kind) do
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

  defp fixture(provider, stages, kind) do
    work = %{"provider" => provider, "host" => provider <> ".test", "repository_id" => "10", "kind" => "issue", "number" => 2}
    parent = %{work | "number" => 1}
    child_scope = contract(work, parent, kind)
    root_scope = contract(parent, nil, kind) |> Map.delete("contract_sha") |> Map.put("budget_ms", 100_000 * (1 + length(stages)))
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

    repo =
      if provider == "github",
        do: %{"id" => 10, "full_name" => "team/repo", "html_url" => url},
        else: %{"id" => 10, "path_with_namespace" => "team/repo", "web_url" => url}

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
      {:ok, %{status: 200, body: Map.fetch!(Agent.get(state, & &1.objects), path)}}
    end

    writer = fn ^provider, "POST", path, %{}, %{"body" => body}, _ ->
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
      "checks" => %{"test" => %{"kind" => "command", "command" => "grep -x expected result", "artifact" => "output", "timeout_ms" => 2_000}}
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

    root = Path.join(System.tmp_dir!(), "publication-delivery-#{System.unique_integer([:positive])}")
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
      parent: parent,
      kind: kind
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

  defp note(id, actor, body) do
    %{
      "id" => id,
      "body" => body,
      "author" => %{"id" => actor},
      "user" => %{"id" => actor},
      "created_at" => "2026-10-17T00:00:00Z",
      "updated_at" => "2026-10-17T00:00:00Z"
    }
  end

  defp current(fixture), do: elem(RunJournal.read(fixture.record["directory"]), 1)
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

  defp evidence(fixture, record) do
    {:ok, plan} = TaskPlanPreflight.inspect_plan(fixture.parent, fixture.opts)
    TaskEvidence.read_member(plan, fixture.payload["work"], record, fixture.opts[:policy], fixture.opts)
  end

  defp change_target(fixture) do
    provider = fixture.payload["work"]["provider"]
    url = "https://" <> fixture.payload["work"]["host"] <> "/team/repo"

    target = %{
      "provider" => provider,
      "host" => fixture.payload["work"]["host"],
      "repository_id" => "10",
      "kind" => if(provider == "github", do: "pr", else: "mr"),
      "number" => 7
    }

    prefix = String.replace_suffix(fixture.child, "/issues/2", "")
    path = prefix <> if(provider == "github", do: "/pulls/7", else: "/merge_requests/7")

    raw =
      if provider == "github" do
        %{
          "id" => 700,
          "number" => 7,
          "html_url" => url <> "/pull/7",
          "head" => %{"sha" => fixture.git.revision, "ref" => "feature", "repo" => %{"id" => 10}},
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
          "sha" => fixture.git.revision,
          "source_branch" => "feature",
          "target_branch" => "main",
          "project_id" => 10,
          "source_project_id" => 10,
          "target_project_id" => 10,
          "state" => "opened",
          "merged_at" => nil
        }
      end

    Agent.update(fixture.state, fn state -> Map.put(state, :objects, Map.put(state.objects, path, raw)) end)
    artifact = hd(fixture.payload["artifacts"]) |> Map.merge(%{"target" => target, "target_branch" => "main"})
    fixture |> Map.put(:payload, Map.put(fixture.payload, "artifacts", [artifact])) |> Map.put(:change_path, path)
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

  defp candidate_args(fixture) do
    artifacts = Enum.map(fixture.payload["artifacts"], &Map.take(&1, ~w(id version target)))
    %{"artifacts" => artifacts, "summary" => "Fixed publication ready"}
  end

  defp verifier_tools(fixture, developer) do
    {:ok, stopped} = RunJournal.checkpoint(developer, %{"native_stop_confirmed" => true})
    :ok = RunJournal.complete(stopped, "completed")
    binding = %{stopped["execution_binding"] | "role" => "verifier", "candidate" => TaskWorkflow.digest(fixture.payload)}
    {:ok, verifier} = RunJournal.admit(Path.dirname(stopped["directory"]), stopped["issue_id"], execution_binding: binding)
    {:ok, verifier} = RunJournal.checkpoint(verifier, %{"thread_id" => "tool-verifier-#{verifier["execution_generation"]}", "workspace" => fixture.workspace})
    task_tools(fixture, verifier)
  end

  defp verified(f) do
    assert {true, _} = tool(task_tools(f), "task_candidate", candidate_args(f))
    verifier = verifier_tools(f, current(f))
    assert {true, %{"data" => %{"exit_code" => 0}}} = tool(verifier, "task_check", %{"check_id" => "test"})
    assert {true, _} = tool(verifier, "task_verification", %{"review_checks" => [], "findings" => [], "summary" => "Verified fixed output"})
    f
  end

  defp executions(fixtures), do: Map.new(fixtures, &{WorkRef.key(&1.payload["work"]), %{directory: &1.record["directory"], policy: &1.opts[:policy]}})

  defp dependencies(f, number, inputs, fixtures, opts \\ nil) do
    opts = opts || f.opts
    {:ok, plan} = TaskPlanPreflight.inspect_plan(f.parent, opts)
    TaskDependencies.read(plan, %{f.payload["work"] | "number" => number}, inputs, executions(fixtures), opts)
  end

  defp inputs(facts), do: Enum.map(facts.dependencies, &Map.take(&1, ~w(work artifact version verification)))

  defp delivery_opts(f) do
    {:ok, evidence} = evidence(f, current(f))
    f.opts |> Keyword.put(:candidate, evidence.candidate) |> Keyword.put(:runtime, current(f))
  end

  test "an approved publication delivers to its native target and unlocks a published dependency" do
    for provider <- ["github", "gitlab"] do
      f = fixture(provider, ["published"], "publication") |> git_artifact() |> verified()
      work = f.payload["work"]
      [artifact] = f.payload["artifacts"]
      assert artifact["kind"] == "publication"
      assert artifact["source"] == GitArtifact.source_ref(work, artifact["version"])

      assert {:ok, facts} = dependencies(f, 3, nil, [f])
      [proof] = facts.dependencies
      assert proof["stage"] == "published"
      assert proof["version"] == f.git.revision
      assert proof["retrieval"] == artifact["source"]
      assert proof["delivery"] in facts.sources
      assert {:ok, ^facts} = dependencies(f, 3, inputs(facts), [f])

      {:ok, evidence} = evidence(f, current(f))
      opts = f.opts |> Keyword.put(:candidate, evidence.candidate) |> Keyword.put(:runtime, current(f))
      assert {:ok, delivery} = TaskDelivery.read(work, artifact, opts)
      assert delivery.status == "delivered"
      assert delivery.receipt["version"] == artifact["version"]
      assert delivery.receipt["candidate"] == evidence.candidate["digest"]
      assert delivery.receipt["target"] == work
      assert delivery.receipt["publication"] == TaskPublicationDelivery.source_ref(work, artifact)

      native = Agent.get(f.state, & &1.objects) |> Map.fetch!(f.notes) |> Enum.find(&(&1["id"] == delivery.receipt["note_id"]))
      assert native["body"] =~ artifact["version"]
      assert delivery.receipt["author"] == to_string(get_in(native, ["author", "id"]))
      assert delivery.receipt["content"] == TaskWorkflow.digest(native["body"])
      assert delivery.receipt["source"] == TaskDecision.source_ref(native)
      assert TaskDelivery.current?(delivery.snapshot, opts)

      assert {:ok, [observation]} = TaskDelivery.read_candidate(work, evidence.candidate, Keyword.put(f.opts, :runtime, current(f)))
      assert observation.status == "delivered"
    end
  end

  test "publication delivery reads the native receipt back and refuses ambiguity, drift and lost reads" do
    f = fixture("gitlab", [], "publication") |> git_artifact()
    Agent.update(f.state, &%{&1 | mode: :lost})
    tools = task_tools(f)
    assert {true, %{"data" => receipt}} = tool(tools, "task_candidate", candidate_args(f))
    assert {true, %{"data" => ^receipt}} = tool(tools, "task_candidate", candidate_args(f))
    assert length(posts(f)) == 1

    [artifact] = f.payload["artifacts"]
    opts = delivery_opts(f)
    assert {:ok, delivery} = TaskDelivery.read(f.payload["work"], artifact, opts)
    assert TaskDelivery.current?(delivery.snapshot, opts)

    duplicate = Map.fetch!(Agent.get(f.state, & &1.objects), f.notes) |> hd()
    Agent.update(f.state, fn state -> Map.put(state, :objects, Map.update!(state.objects, f.notes, &(&1 ++ [%{duplicate | "id" => duplicate["id"] + 1}]))) end)
    assert {:error, :publication_delivery_unconfirmed} = TaskDelivery.read(f.payload["work"], artifact, opts)
    Agent.update(f.state, fn state -> Map.put(state, :objects, Map.update!(state.objects, f.notes, &Enum.drop(&1, -1))) end)

    Agent.update(f.state, fn state ->
      edited = Map.update!(state.objects, f.notes, fn [head | tail] -> [%{head | "body" => head["body"] <> "edited"} | tail] end)
      Map.put(state, :objects, edited)
    end)

    refute TaskDelivery.current?(delivery.snapshot, opts)
    assert {:error, :unrecorded_native_result} = TaskDelivery.read(f.payload["work"], artifact, opts)

    Agent.update(f.state, fn state -> Map.put(state, :objects, Map.put(state.objects, f.notes, [])) end)
    assert {:error, :publication_delivery_unconfirmed} = TaskDelivery.read(f.payload["work"], artifact, opts)

    offline = Keyword.put(opts, :request, fn _, _, _, _, _ -> {:error, :offline} end)
    assert {:error, :native_read_failed} = TaskDelivery.read(f.payload["work"], artifact, offline)
    refute TaskDelivery.current?(delivery.snapshot, offline)
  end

  test "publication delivery refuses a bare candidate, foreign versions, sources and native targets" do
    f = fixture("github", [], "publication") |> git_artifact() |> verified()
    work = f.payload["work"]
    [artifact] = f.payload["artifacts"]
    opts = delivery_opts(f)

    assert {:ok, %{status: "publication_unconfirmed", receipt: nil, snapshot: nil}} =
             TaskDelivery.read(work, artifact, Keyword.put(f.opts, :candidate, f.payload))

    assert {:error, :invalid_publication_artifact} = TaskDelivery.read(work, Map.delete(artifact, "version"), opts)
    assert {:error, :publication_source_mismatch} = TaskDelivery.read(work, Map.put(artifact, "source", GitArtifact.source_ref(work, String.duplicate("a", 40))), opts)
    assert {:error, :publication_target_unavailable} = TaskDelivery.read(work, Map.put(artifact, "target", %{work | "number" => 9}), opts)
    assert {:error, :publication_target_unavailable} = TaskDelivery.read(work, Map.put(artifact, "target", "issue:9"), opts)

    changed = Keyword.put(opts, :candidate, Map.put(opts[:candidate], "digest", String.duplicate("0", 64)))
    assert {:error, :publication_delivery_unconfirmed} = TaskDelivery.read(work, artifact, changed)
    assert {:error, :unrecorded_native_result} = TaskDelivery.read(work, artifact, Keyword.put(opts, :runtime, %{}))
  end

  test "a published edge still refuses change artifacts instead of relaxing their target and version rules" do
    for provider <- ["github", "gitlab"] do
      kind = if provider == "github", do: "pr", else: "mr"
      f = fixture(provider, ["published"], kind) |> git_artifact() |> change_target() |> verified()
      work = f.payload["work"]
      [artifact] = f.payload["artifacts"]
      assert artifact["kind"] in ["pr", "mr"]
      assert TaskDelivery.target?(work, artifact)
      assert {:error, :dependency_delivery_evidence_unavailable} = dependencies(f, 3, nil, [f])
    end
  end

  test "a publication that drifts while the dependency is read fails instead of passing silently" do
    clean = fixture("github", ["published"], "publication") |> git_artifact() |> verified()
    assert {:ok, facts} = dependencies(clean, 3, nil, [clean])
    assert [%{"stage" => "published"}] = facts.dependencies

    drifted = fixture("github", ["published"], "publication") |> git_artifact() |> verified()
    root = Path.join(Path.dirname(drifted.record["directory"]), ".artifacts")
    original = drifted.opts[:request]

    request = fn provider, method, path, query, settings ->
      {:ok, owners} = ArtifactStore.references(root, drifted.payload["work"], drifted.git.revision, drifted.opts)
      pinned = Enum.any?(owners, &(&1["kind"] == "dependency"))
      trigger = pinned and path == String.replace_suffix(drifted.parent_notes, "/comments", "") and not Agent.get(drifted.state, &Map.get(&1, :mutated, false))

      if trigger do
        Agent.update(drifted.state, fn state ->
          notes = Map.fetch!(state.objects, drifted.notes)
          [candidate | rest] = notes
          state |> Map.put(:objects, Map.put(state.objects, drifted.notes, [%{candidate | "body" => candidate["body"] <> "edited"} | rest])) |> Map.put(:mutated, true)
        end)
      end

      original.(provider, method, path, query, settings)
    end

    assert {:error, :dependency_changed_during_read} = dependencies(drifted, 3, nil, [drifted], Keyword.put(drifted.opts, :request, request))
  end
end
