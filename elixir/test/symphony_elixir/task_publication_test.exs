defmodule SymphonyElixir.TaskPublicationTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.CommandCheck
  alias SymphonyElixir.{GitArtifact, GitArtifactFixture}
  alias SymphonyElixir.{NativeWork, RunJournal, TaskDecision, TaskPlan, TaskPublication, TaskWorkflow, WorkRef}
  alias SymphonyElixir.{TaskEvidence, TaskLifecycle}
  alias SymphonyElixir.TaskPlanPreflight

  defp contract(work, parent) do
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
      "deliverables" => [%{"id" => "output", "kind" => "report", "criteria" => ["result"]}]
    }

    Map.put(data, "contract_sha", TaskWorkflow.digest(data))
  end

  defp fixture(provider) do
    work = %{"provider" => provider, "host" => provider <> ".test", "repository_id" => "10", "kind" => "issue", "number" => 2}
    parent = %{work | "number" => 1}
    child_scope = contract(work, parent)
    root_scope = contract(parent, nil)
    member = %{"work" => work, "contract_sha" => child_scope["contract_sha"], "criteria" => ["result"], "budget_ms" => 100_000, "human_gate" => false}

    {:ok, plan} =
      TaskPlan.seal(%{
        "parent" => parent,
        "contract_sha" => root_scope["contract_sha"],
        "authorizer" => "1",
        "criteria" => ["result"],
        "members" => [member],
        "dependencies" => [],
        "integration" => work,
        "budget_ms" => 100_000
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

    state = start_supervised!({Agent, fn -> %{objects: objects, posts: [], mode: :success} end}, id: make_ref())

    request = fn ^provider, "GET", path, _, _ ->
      {:ok, %{status: 200, body: Agent.get(state, &Map.fetch!(&1.objects, path))}}
    end

    writer = fn ^provider, "POST", path, query, %{"body" => body}, _ ->
      assert query == %{}

      assert path == prefix <> "/issues/2" <> suffix
      Agent.get_and_update(state, &store_post(&1, path, body))
    end

    repository =
      Map.take(work, ~w(provider host repository_id))
      |> Map.merge(%{"path" => "team/repo", "api_url" => "https://" <> work["host"] <> if(provider == "github", do: "/api/v3", else: "/api/v4"), "credential" => "$UNUSED_PUBLICATION_FIXTURE"})

    policy = %{
      "engine_actor" => "99",
      "max_repairs" => 2,
      "max_retries" => 2,
      "checks" => %{"test" => %{"kind" => "command", "command" => "grep -qx expected result", "artifact" => "output", "timeout_ms" => 2_000}}
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
    payload = %{"work" => work, "contract_sha" => child_scope["contract_sha"], "inputs" => [], "artifacts" => [%{"id" => "output", "kind" => "report", "version" => "v1"}]}

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
