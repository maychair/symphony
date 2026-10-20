defmodule SymphonyElixir.TaskPlanManifestTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Codex.DynamicTool

  alias SymphonyElixir.{
    ArtifactStore,
    ReportArtifact,
    RunJournal,
    Taskboard,
    TaskClosure,
    TaskDecision,
    TaskExecution,
    TaskExecutionConfig,
    TaskPlan,
    TaskPlanAssessment,
    TaskPlanExecution,
    TaskPlanManifest,
    TaskPlanPreflight,
    TaskTools,
    TaskWorkflow,
    WorkRef
  }

  alias SymphonyElixir.Tracker.Issue

  @criterion "C1"
  @decision_at "2026-10-18T00:00:30Z"
  @damaged_report_reasons [
    :artifact_publication_conflict,
    :invalid_artifact_file,
    :invalid_stored_report,
    :parent_manifest_incomplete
  ]

  # ---- pure, native-note fixtures -------------------------------------------

  defp work(number, provider) do
    %{
      "provider" => provider,
      "host" => provider <> ".test",
      "repository_id" => "10",
      "kind" => "issue",
      "number" => number
    }
  end

  defp contract(work, parent, criteria \\ [@criterion], budget \\ 100_000) do
    data = %{
      "schema_version" => 2,
      "work" => work,
      "parent" => parent,
      "goal" => "Deliver the approved result",
      "non_goals" => [],
      "criteria" => criteria,
      "criteria_details" => Map.new(criteria, &{&1, "Criterion " <> &1}),
      "verification_checks" => Map.new(criteria, &{&1, ["review"]}),
      "authorizer" => "1",
      "acceptance_mode" => if(parent, do: "technical", else: "separate"),
      "acceptor" => if(parent, do: nil, else: "2"),
      "budget_ms" => budget,
      "deliverables" => [%{"id" => "report", "kind" => "report", "criteria" => criteria}]
    }

    Map.put(data, "contract_sha", TaskWorkflow.digest(data))
  end

  defp block(name, value), do: "<!-- symphony-#{name} " <> Jason.encode!(value) <> " -->"

  defp note(id, author, body, at \\ "2026-10-18T00:00:00Z") do
    %{
      "id" => id,
      "body" => body,
      "author" => %{"id" => author},
      "user" => %{"id" => author},
      "created_at" => at,
      "updated_at" => at
    }
  end

  defp fixture(provider \\ "github") do
    parent = work(1, provider)
    member = work(2, provider)
    child = contract(member, parent)
    root = contract(parent, nil)

    item = %{
      "work" => member,
      "contract_sha" => child["contract_sha"],
      "criteria" => [@criterion],
      "budget_ms" => 100_000,
      "human_gate" => false
    }

    {:ok, plan} =
      TaskPlan.seal(%{
        "parent" => parent,
        "contract_sha" => root["contract_sha"],
        "authorizer" => "1",
        "criteria" => [@criterion],
        "members" => [item],
        "dependencies" => [],
        "integration" => member,
        "budget_ms" => 100_000
      })

    %{parent: parent, member: member, child: child, root: root, plan: plan}
  end

  defp manifest_block(value), do: "<!-- symphony-plan-manifest " <> Jason.encode!(value) <> " -->"

  defp candidate_block(value), do: "<!-- symphony-candidate " <> Jason.encode!(value) <> " -->"

  defp decision_block(value), do: "<!-- symphony-plan-acceptance " <> Jason.encode!(value) <> " -->"

  defp reseal(value, changes) do
    body = Map.merge(value, changes)
    Map.put(body, "revision", TaskWorkflow.digest(Map.delete(body, "revision")))
  end

  defp closed_projection(f) do
    flow = %{
      "candidate" => "candidate-digest",
      "verification" => "note:verification@1",
      "contract_sha" => f.child["contract_sha"],
      "plan_revision" => f.plan["revision"],
      "inputs" => []
    }

    closure = %{"status" => "confirmed", "native_state" => "closed", "source" => "issue:closed"}

    evidence = %{
      "candidate" => %{
        "digest" => "candidate-digest",
        "inputs" => [],
        "artifacts" => [%{"id" => "report", "kind" => "report", "version" => "v1", "source" => "issue:report"}]
      },
      "verification" => %{"source" => "note:verification@1"},
      "deliveries" => [%{"source" => "note:delivery@1"}]
    }

    %{WorkRef.key(f.member) => %{closeable: true, flow: flow, closure: closure, evidence: evidence}}
  end

  defp parent_with_notes(f, notes) do
    %{
      work: f.parent,
      description: block("contract", f.root) <> block("plan", f.plan),
      notes: notes,
      raw: %{"state" => "open"}
    }
  end

  defp manifest_entry(notes) do
    case TaskPlanManifest.manifests(%{notes: notes}) do
      [entry | _] -> {entry, notes}
      [] -> raise "no manifest entry"
    end
  end

  test "assemble seals a manifest only when every member has a confirmed native closure" do
    f = fixture()
    key = WorkRef.key(f.member)

    assert {:ok, manifest} = TaskPlanManifest.assemble(f.plan, closed_projection(f))
    assert manifest["schema_version"] == 2
    assert manifest["plan_revision"] == f.plan["revision"]
    assert manifest["revision"] == TaskWorkflow.digest(Map.delete(manifest, "revision"))

    assert [member] = manifest["members"]
    assert member["work"] == f.member
    assert member["status"] == "completed"
    assert member["criteria"] == [@criterion]
    assert member["contract_sha"] == f.child["contract_sha"]
    assert member["plan_revision"] == f.plan["revision"]
    assert member["candidate"] == "candidate-digest"
    assert member["verification"] == "note:verification@1"
    assert member["artifacts"] == [%{"id" => "report", "kind" => "report", "version" => "v1", "source" => "issue:report"}]
    assert member["deliveries"] == ["note:delivery@1"]
    assert member["inputs"] == []
    assert member["closure"] == "issue:closed"
    assert member["evidence"] == TaskWorkflow.digest(Map.drop(member, ["work", "criteria", "status", "evidence"]))

    drifted = put_in(closed_projection(f), [key, :evidence, "candidate", "digest"], "other-digest")
    assert {:incomplete, [^key]} = TaskPlanManifest.assemble(f.plan, drifted)

    no_artifacts = put_in(closed_projection(f), [key, :evidence, "candidate", "artifacts"], [])
    assert {:incomplete, [^key]} = TaskPlanManifest.assemble(f.plan, no_artifacts)

    unbound = put_in(closed_projection(f), [key, :closure, "source"], nil)
    assert {:incomplete, [^key]} = TaskPlanManifest.assemble(f.plan, unbound)

    assert {:incomplete, [^key]} = TaskPlanManifest.assemble(f.plan, %{})
    assert {:incomplete, [^key]} = TaskPlanManifest.assemble(f.plan, %{key => %{restricted: "member_contract_changed"}})
    assert {:incomplete, [^key]} = TaskPlanManifest.assemble(f.plan, %{key => %{closeable: false}})
  end

  test "manifests reads only unchanged, self-consistent manifest notes in native order" do
    f = fixture()
    {:ok, manifest} = TaskPlanManifest.assemble(f.plan, closed_projection(f))
    first = note(10, 1, manifest_block(manifest))
    second = note(11, 1, manifest_block(reseal(manifest, %{"integration" => f.parent})))
    edited = %{note(12, 1, manifest_block(manifest)) | "updated_at" => "2026-10-18T00:00:05Z"}
    tampered = note(13, 1, manifest_block(%{manifest | "revision" => String.duplicate("0", 64)}))
    system = Map.put(note(14, 1, manifest_block(manifest)), "system", true)
    unreadable = %{note(15, 1, manifest_block(manifest)) | "id" => "x"}
    malformed = note(16, 1, "<!-- symphony-plan-manifest {not json} -->")
    prose = note(17, 1, "just a comment")
    notes = [first, edited, tampered, system, unreadable, malformed, prose, second]

    assert [m1, m2] = TaskPlanManifest.manifests(%{notes: notes})
    assert m1["label"] == "M1"
    assert m1["payload"]["revision"] == manifest["revision"]
    assert m1["note_id"] == 10
    assert m1["source"] == TaskDecision.source_ref(first)
    assert m2["label"] == "M2"
    assert m2["note_id"] == 11

    assert TaskPlanManifest.manifests(%{notes: []}) == []
    assert %{"status" => "no_manifest"} = TaskPlanManifest.facts(%{notes: []}, f.plan)
  end

  test "decision resolves only the latest unchanged decision bound to the requested manifest" do
    f = fixture()
    {:ok, manifest} = TaskPlanManifest.assemble(f.plan, closed_projection(f))
    {entry, notes} = manifest_entry([note(10, 1, manifest_block(manifest))])

    accept = %{
      "action" => "accept",
      "manifest" => entry["source"],
      "revision" => entry["payload"]["revision"],
      "criteria" => []
    }

    accept_note = note(20, 2, decision_block(accept), @decision_at)
    parent = parent_with_notes(f, notes ++ [accept_note])

    assert %{"status" => "accepted", "revision" => revision, "label" => "M1"} = TaskPlanManifest.facts(parent, f.plan)
    assert revision == entry["payload"]["revision"]
    assert {:ok, %{"action" => "accept"}} = TaskPlanManifest.decision(parent, f.plan, entry)

    assert %{"status" => "awaiting_acceptance"} = TaskPlanManifest.facts(parent_with_notes(f, notes), f.plan)
    assert TaskPlanManifest.decision(parent, f.plan, nil) == {:ok, nil}
    assert {:ok, nil} = TaskPlanManifest.decision(parent_with_notes(f, notes), f.plan, entry)

    edited = %{accept_note | "updated_at" => "2026-10-18T00:00:11Z"}
    assert {:ok, nil} = TaskPlanManifest.decision(parent_with_notes(f, notes ++ [edited]), f.plan, entry)

    foreign = note(21, 9, decision_block(accept), @decision_at)
    assert {:ok, nil} = TaskPlanManifest.decision(parent_with_notes(f, notes ++ [foreign]), f.plan, entry)

    earlier = note(22, 2, decision_block(accept), "2026-10-17T23:59:59Z")
    assert {:ok, nil} = TaskPlanManifest.decision(parent_with_notes(f, notes ++ [earlier]), f.plan, entry)

    doubled = notes ++ [accept_note, note(23, 2, decision_block(accept), accept_note["created_at"])]
    assert {:error, :ambiguous_plan_decision} = TaskPlanManifest.decision(parent_with_notes(f, doubled), f.plan, entry)
    assert %{"status" => "unconfirmed"} = TaskPlanManifest.facts(parent_with_notes(f, doubled), f.plan)
  end

  test "a decision for one manifest never accepts another manifest of the same plan" do
    f = fixture()
    {:ok, m1_manifest} = TaskPlanManifest.assemble(f.plan, closed_projection(f))

    {:ok, plan2} = TaskPlan.seal(Map.put(f.plan, "budget_ms", 200_000))
    {:ok, m2_manifest} = TaskPlanManifest.assemble(plan2, closed_projection(%{f | plan: plan2}))

    notes = [note(10, 1, manifest_block(m1_manifest)), note(11, 1, manifest_block(m2_manifest))]
    [m1, m2] = TaskPlanManifest.manifests(%{notes: notes})

    accept = %{"action" => "accept", "manifest" => m1["source"], "revision" => m1["payload"]["revision"]}
    decision = note(20, 2, decision_block(accept), @decision_at)
    parent = parent_with_notes(f, notes ++ [decision])

    assert {:ok, %{"action" => "accept"}} = TaskPlanManifest.decision(parent, f.plan, m1)
    assert {:ok, nil} = TaskPlanManifest.decision(parent, plan2, m2)
    assert {:error, :manifest_plan_mismatch} = TaskPlanManifest.decision(parent, f.plan, m2)
    assert {:error, :manifest_plan_mismatch} = TaskPlanManifest.decision(parent, plan2, m1)
    assert %{"status" => "awaiting_acceptance", "label" => "M2"} = TaskPlanManifest.facts(parent, plan2)
  end

  test "decision binds an unchanged natural reply to the published candidate" do
    f = fixture()
    {:ok, manifest} = TaskPlanManifest.assemble(f.plan, closed_projection(f))
    candidate = %{"label" => "M1", "revision" => manifest["revision"], "authorizer" => "2", "data" => %{"acceptance_items" => [@criterion]}}
    published = note(10, 99, "验收清单 M1\n\n" <> manifest_block(manifest) <> "\n" <> candidate_block(candidate))
    {entry, _} = manifest_entry([published])

    accept = note(20, 2, "M1 验收通过", @decision_at)
    parent = parent_with_notes(f, [published, accept])
    assert {:ok, %{"action" => "accept", "criteria" => []}} = TaskPlanManifest.decision(parent, f.plan, entry)
    assert %{"status" => "accepted"} = TaskPlanManifest.facts(parent, f.plan)

    rework = note(21, 2, "验收项 C1 未满足，请修复", @decision_at)
    parent = parent_with_notes(f, [published, rework])
    assert {:ok, %{"action" => "rework", "criteria" => [@criterion]}} = TaskPlanManifest.decision(parent, f.plan, entry)
    assert %{"status" => "rework", "criteria" => [@criterion]} = TaskPlanManifest.facts(parent, f.plan)

    unknown_item = note(22, 2, "验收项 C9 未满足，请修复", @decision_at)
    assert {:ok, nil} = TaskPlanManifest.decision(parent_with_notes(f, [published, unknown_item]), f.plan, entry)

    foreign = note(23, 9, "M1 验收通过", @decision_at)
    assert {:ok, nil} = TaskPlanManifest.decision(parent_with_notes(f, [published, foreign]), f.plan, entry)
  end

  test "an unauthorized author and an ambiguous payload are ignored, not accepted" do
    f = fixture()
    {:ok, manifest} = TaskPlanManifest.assemble(f.plan, closed_projection(f))
    {entry, notes} = manifest_entry([note(10, 1, manifest_block(manifest))])

    bad = %{
      "action" => "accept",
      "manifest" => entry["source"],
      "revision" => entry["payload"]["revision"],
      "extra" => true
    }

    bad_note = note(20, 2, decision_block(bad), @decision_at)
    assert {:ok, nil} = TaskPlanManifest.decision(parent_with_notes(f, notes ++ [bad_note]), f.plan, entry)

    broken = note(21, 2, "<!-- symphony-plan-acceptance {broken} -->", @decision_at)
    assert {:ok, nil} = TaskPlanManifest.decision(parent_with_notes(f, notes ++ [broken]), f.plan, entry)

    unknown =
      note(
        22,
        2,
        decision_block(%{"action" => "erase", "manifest" => entry["source"], "revision" => entry["payload"]["revision"], "criteria" => []}),
        @decision_at
      )

    assert {:ok, nil} = TaskPlanManifest.decision(parent_with_notes(f, notes ++ [unknown]), f.plan, entry)
  end

  # ---- native, journal-backed fixture ---------------------------------------

  defp policy do
    %{
      "engine_actor" => "99",
      "max_retries" => 2,
      "max_repairs" => 2,
      "checks" => %{"review" => %{"kind" => "review"}}
    }
  end

  defp native_repo(work) do
    Map.take(work, ~w(provider host repository_id))
    |> Map.merge(%{
      "path" => "team/repo",
      "api_url" => "https://" <> work["host"] <> if(work["provider"] == "github", do: "/api/v3", else: "/api/v4"),
      "credential" => "$UNUSED_MANIFEST_FIXTURE",
      "execution" => %{"policy" => policy()}
    })
  end

  defp native_raw(provider, url, number, body) do
    base = %{"id" => number + 100, "state" => "open", "assignees" => [%{"id" => 1}]}

    if provider == "github" do
      Map.merge(base, %{"number" => number, "body" => body, "html_url" => url <> "/issues/#{number}"})
    else
      Map.merge(base, %{"iid" => number, "description" => body, "project_id" => 10, "web_url" => url <> "/-/issues/#{number}"})
    end
  end

  defp native_fixture(provider) do
    f = fixture(provider)
    prefix = if provider == "github", do: "/repos/team/repo", else: "/projects/team%2Frepo"
    suffix = if provider == "github", do: "/comments", else: "/notes"
    url = "https://" <> f.parent["host"] <> "/team/repo"

    approval = note(1, 1, block("plan-decision", %{"action" => "authorize", "revision" => f.plan["revision"]}))
    parent_body = block("contract", f.root) <> block("plan", f.plan)

    objects = %{
      prefix => repo_object(provider, url),
      "/user" => %{"id" => 99},
      (prefix <> "/issues/1") => native_raw(provider, url, 1, parent_body),
      (prefix <> "/issues/2") => native_raw(provider, url, 2, block("contract", f.child)),
      (prefix <> "/issues/1" <> suffix) => [approval],
      (prefix <> "/issues/2" <> suffix) => []
    }

    root = journal_root()
    state = start_supervised!({Agent, fn -> native_state(objects) end}, id: make_ref())
    opts = native_opts(provider, f.parent, state, root)

    f =
      Map.merge(f, %{
        opts: opts,
        root: root,
        state: state,
        prefix: prefix,
        suffix: suffix,
        provider: provider,
        parent_notes: prefix <> "/issues/1" <> suffix,
        member_notes: prefix <> "/issues/2" <> suffix,
        contracts: %{WorkRef.key(f.member) => f.child}
      })

    {:ok, record} = RunJournal.admit(root, WorkRef.key(f.member), execution_binding: developer_binding(f, f.member))
    {:ok, record} = RunJournal.checkpoint(record, %{"thread_id" => "developer"})

    Map.put(f, :record, record)
  end

  defp repo_object("github", url), do: %{"id" => 10, "full_name" => "team/repo", "html_url" => url}
  defp repo_object(_provider, url), do: %{"id" => 10, "path_with_namespace" => "team/repo", "web_url" => url}

  defp native_state(objects) do
    %{
      objects: objects,
      manifest_mode: :ok,
      reopen_mode: :ok,
      posts: %{},
      writes: [],
      drift: nil,
      note_reads: 0,
      close_note_reads: nil
    }
  end

  defp journal_root do
    token = System.pid() <> "-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    root = Path.join(System.tmp_dir!(), "plan-manifest-#{token}")
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp native_opts(provider, parent, state, root) do
    [
      repositories: [native_repo(parent)],
      request: native_request(provider, state),
      write_request: native_writer(provider, state),
      policy: policy(),
      journal_root: root
    ]
  end

  defp native_request(provider, state) do
    fn ^provider, "GET", path, _, _ -> {:ok, %{status: 200, body: read_native(state, path)}} end
  end

  defp native_writer(provider, state) do
    fn ^provider, method, path, _, body, _ -> Agent.get_and_update(state, &write_native(&1, method, path, body)) end
  end

  # Read one native object; an armed drift mutates the object on the Nth read of
  # that exact path so a concurrent edit can be injected between two reads.
  defp read_native(state, path) do
    Agent.get_and_update(state, fn current ->
      current =
        if String.contains?(path, "/issues/1/") and (String.ends_with?(path, "/comments") or String.ends_with?(path, "/notes")),
          do: %{current | note_reads: current.note_reads + 1},
          else: current

      if match?(%{"path" => ^path, "append_note" => _}, current.drift) do
        append_native_note(current, path)
      else
        read_native_drift(current, path)
      end
    end)
  end

  defp append_native_note(%{drift: %{"path" => path, "remaining" => remaining, "append_note" => added}} = current, path)
       when remaining <= 1 do
    notes = Map.fetch!(current.objects, path) ++ [added]
    {notes, %{current | objects: Map.put(current.objects, path, notes), drift: nil}}
  end

  defp append_native_note(%{drift: %{"path" => path, "remaining" => remaining, "append_note" => added}} = current, path) do
    {Map.fetch!(current.objects, path), %{current | drift: %{"path" => path, "remaining" => remaining - 1, "append_note" => added}}}
  end

  defp read_native_drift(current, path) do
    case current.drift do
      %{"path" => ^path, "remaining" => remaining, "remove_note_id" => note_id} when remaining <= 1 ->
        kept = Enum.reject(Map.fetch!(current.objects, path), &(&1["id"] == note_id))
        {kept, %{current | objects: Map.put(current.objects, path, kept), drift: nil}}

      %{"path" => ^path, "remaining" => remaining, "remove_note_id" => note_id} ->
        body = Map.fetch!(current.objects, path)
        {body, %{current | drift: %{"path" => path, "remaining" => remaining - 1, "remove_note_id" => note_id}}}

      %{"path" => ^path, "remaining" => remaining} when remaining <= 1 ->
        drifted = Map.put(Map.fetch!(current.objects, path), "updated_at", "2026-10-18T00:10:00Z")
        {drifted, %{current | objects: Map.put(current.objects, path, drifted), drift: nil}}

      %{"path" => ^path, "remaining" => remaining} ->
        body = Map.fetch!(current.objects, path)
        {body, %{current | drift: %{"path" => path, "remaining" => remaining - 1}}}

      _ ->
        {Map.fetch!(current.objects, path), current}
    end
  end

  defp arm_drift(f, path, reads) do
    Agent.update(f.state, &%{&1 | drift: %{"path" => path, "remaining" => reads}})
    f
  end

  defp arm_note_removal(f, reads, note_id) do
    Agent.update(f.state, &%{&1 | drift: %{"path" => f.parent_notes, "remaining" => reads, "remove_note_id" => note_id}, note_reads: 0})
    f
  end

  defp arm_note_append(f, reads, added) do
    Agent.update(f.state, &%{&1 | drift: %{"path" => f.parent_notes, "remaining" => reads, "append_note" => added}, note_reads: 0})
    f
  end

  defp developer_binding(f, member) do
    {:ok, preflight} = TaskPlanPreflight.inspect_plan(f.parent, f.opts)

    %{
      "work" => member,
      "role" => "developer",
      "plan_revision" => f.plan["revision"],
      "contract_sha" => contract_for(f, member)["contract_sha"],
      "authority" => preflight.authority,
      "inputs" => [],
      "candidate" => nil,
      "policy_sha" => TaskWorkflow.digest(policy())
    }
  end

  defp contract_for(f, member), do: Map.fetch!(f.contracts, WorkRef.key(member))

  defp native_comment(notes, body) do
    note(100 + length(notes), 99, body) |> Map.put("user", %{"id" => 99})
  end

  defp logged(state, kind) do
    %{state | writes: state.writes ++ [%{"kind" => kind}]}
  end

  defp bump(state, path), do: %{state | posts: Map.update(state.posts, path, 1, &(&1 + 1))}

  defp put_notes(state, path, notes), do: %{state | objects: Map.put(state.objects, path, notes)}

  defp write_native(state, "POST", path, %{"body" => body}) do
    parent = String.contains?(path, "/issues/1")
    kind = if parent, do: "manifest", else: "comment"
    state = logged(state, kind)
    notes = Map.fetch!(state.objects, path)

    cond do
      state.manifest_mode == :uncertain and parent ->
        {{:ok, %{status: 500, body: %{}}}, bump(state, path)}

      state.manifest_mode == :lost and parent ->
        comment = native_comment(notes, body)
        {{:error, :lost_response}, state |> bump(path) |> put_notes(path, notes ++ [comment])}

      true ->
        comment = native_comment(notes, body)
        {{:ok, %{status: 201, body: comment}}, state |> bump(path) |> put_notes(path, notes ++ [comment])}
    end
  end

  defp write_native(state, "PATCH", path, %{"state" => target}) do
    reopen = target in ["open", "opened"]
    apply_state_write(state, if(reopen, do: "reopen", else: "close"), path, target, reopen)
  end

  defp write_native(state, "PUT", path, %{"state_event" => event}) do
    reopen = event == "reopen"
    apply_state_write(state, if(reopen, do: "reopen", else: "close"), path, if(reopen, do: "open", else: "closed"), reopen)
  end

  defp apply_state_write(state, kind, path, target, reopen) do
    state = logged(state, kind)
    state = if kind == "close" and String.contains?(path, "/issues/1"), do: %{state | close_note_reads: state.note_reads}, else: state
    issue = Map.put(Map.fetch!(state.objects, path), "state", target)
    saved = %{state | objects: Map.put(state.objects, path, issue)}

    if reopen and state.reopen_mode == :lost do
      {{:error, :lost_response}, saved}
    else
      {{:ok, %{status: 200, body: issue}}, saved}
    end
  end

  defp current(f), do: elem(RunJournal.read(f.record["directory"]), 1)

  # Checkpoint the member journal the way production does: a checkpoint needs the
  # executor lock or a held reconciler fence, so acquire the fence around it.
  defp fenced_checkpoint(f, changes) do
    record = current(f)
    {:ok, _} = TaskClosure.with_fence(record, f.opts, fn -> RunJournal.checkpoint(record, changes) end)
    f
  end

  defp posts(f, path), do: Agent.get(f.state, &Map.get(&1.posts, path, 0))

  defp writes(f, kind) do
    Agent.get(f.state, fn state -> Enum.count(state.writes, &(&1["kind"] == kind)) end)
  end

  defp report_body(tag), do: "# Result\n\nThe approved result is reproducible.#{tag}"

  defp candidate_payload(f, tag) do
    {:ok, artifact} = ReportArtifact.build(f.member, "report", report_body(tag))
    %{"work" => f.member, "contract_sha" => f.child["contract_sha"], "inputs" => [], "artifacts" => [artifact]}
  end

  defp task_tools(f, record \\ nil) do
    record = record || current(f)
    now = System.system_time(:millisecond)
    flow = TaskWorkflow.new(100_000, now) |> TaskWorkflow.start(now) |> Map.merge(%{"schema_version" => 2, "repair_history" => %{}})
    {:ok, record} = RunJournal.checkpoint(record, %{"workflow" => flow, "native_stop_confirmed" => false})
    {:ok, tools} = TaskTools.bind(record, f.opts[:policy], f.opts)
    tools
  end

  defp tool(tools, name, arguments, opts \\ []) do
    result = DynamicTool.execute(name, arguments, tools, opts)
    {result["success"], Jason.decode!(result["output"])}
  end

  defp candidate_args(tag) do
    %{"artifacts" => [%{"id" => "report", "body" => report_body(tag)}], "summary" => "Candidate ready"}
  end

  defp verified(f, tag \\ "") do
    assert {true, _} = tool(task_tools(f), "task_candidate", candidate_args(tag))
    {:ok, stopped} = RunJournal.checkpoint(current(f), %{"native_stop_confirmed" => true})
    :ok = RunJournal.complete(stopped, "completed")
    binding = %{stopped["execution_binding"] | "role" => "verifier", "candidate" => TaskWorkflow.digest(candidate_payload(f, tag))}
    {:ok, verifier} = RunJournal.admit(Path.dirname(stopped["directory"]), stopped["issue_id"], execution_binding: binding)
    {:ok, verifier} = RunJournal.checkpoint(verifier, %{"thread_id" => "verifier" <> tag})
    tools = task_tools(f, verifier)

    assert {true, _} =
             tool(tools, "task_verification", %{
               "review_checks" => [%{"id" => "review", "result" => "passed", "rationale" => "Independent review passed"}],
               "findings" => [],
               "summary" => "Independent verification"
             })

    {:ok, done} = RunJournal.checkpoint(current(f), %{"native_stop_confirmed" => true})
    :ok = RunJournal.complete(done, "completed")
    f
  end

  defp configured(f) do
    {:ok, configured} = TaskExecutionConfig.prepare(f.parent, f.opts)
    configured
  end

  defp close_member(f) do
    configured = configured(f)
    member = configured.plan.members[WorkRef.key(f.member)]
    opts = Keyword.put(f.opts, :reobserve, fn -> TaskPlanAssessment.assess(f.parent, member, configured) end)
    {:ok, assessment} = TaskPlanAssessment.assess(f.parent, member, configured)
    {:ok, _} = TaskClosure.reconcile(assessment.record, assessment.flow, opts)
    f
  end

  defp append_parent_note(f, note) do
    path = f.parent_notes
    Agent.update(f.state, fn state -> %{state | objects: Map.update!(state.objects, path, &(&1 ++ [note]))} end)
    note
  end

  defp parent_note_count(f) do
    Agent.get(f.state, &length(Map.fetch!(&1.objects, f.parent_notes)))
  end

  defp rework_note(f, receipt) do
    payload = %{
      "action" => "rework",
      "manifest" => receipt["source"],
      "revision" => receipt["payload"]["revision"],
      "criteria" => [@criterion]
    }

    append_parent_note(f, note(1000 + parent_note_count(f), 2, decision_block(payload), @decision_at))
  end

  defp accept_note(f, receipt) do
    payload = %{"action" => "accept", "manifest" => receipt["source"], "revision" => receipt["payload"]["revision"]}
    append_parent_note(f, note(1000 + parent_note_count(f), 2, decision_block(payload), @decision_at))
  end

  defp manifest_for(f) do
    configured = configured(f)
    {:ok, manifest} = TaskPlanManifest.assemble(f.plan, TaskPlanExecution.projection_of(configured))
    {configured, manifest}
  end

  defp report_store_path(root, artifact) do
    name = "report-" <> String.replace_prefix(artifact["source"], "report:", "") <> ".json"
    Path.join([root, ".artifacts", name])
  end

  # ---- multi-member native fixture ------------------------------------------

  defp plan_fixture(provider, specs, deps, integration) do
    parent = work(1, provider)
    works = Map.new(specs, fn spec -> {spec.number, work(spec.number, provider)} end)
    criteria = specs |> Enum.flat_map(& &1.criteria) |> Enum.uniq()
    budget = 100_000 * length(specs)
    root_contract = contract(parent, nil, criteria, budget)

    contracts =
      Map.new(specs, fn spec -> {WorkRef.key(works[spec.number]), contract(works[spec.number], parent, spec.criteria)} end)

    root = %{parent: parent, criteria: criteria, root_contract: root_contract, integration: integration, budget: budget}
    plan = seal_plan(specs, deps, works, contracts, root)
    native = native_plan_objects(provider, parent, specs, works, contracts, root_contract, plan)
    f = Map.merge(native, %{parent: parent, plan: plan, works: works, contracts: contracts, provider: provider})

    records =
      Map.new(specs, fn spec ->
        member = works[spec.number]
        {WorkRef.key(member), seed_record(f, member, "developer-#{spec.number}")}
      end)

    Map.put(f, :records, records)
  end

  defp seal_plan(specs, deps, works, contracts, root) do
    %{parent: parent, criteria: criteria, root_contract: root_contract, integration: integration, budget: budget} = root

    members =
      Enum.map(specs, fn spec ->
        %{
          "work" => works[spec.number],
          "contract_sha" => contracts[WorkRef.key(works[spec.number])]["contract_sha"],
          "criteria" => spec.criteria,
          "budget_ms" => 100_000,
          "human_gate" => false
        }
      end)

    edges =
      Enum.map(deps, fn {from, to} ->
        %{"from" => works[from], "to" => works[to], "artifact" => "report", "stage" => "verified", "criteria" => spec(specs, from).criteria}
      end)

    {:ok, plan} =
      TaskPlan.seal(%{
        "parent" => parent,
        "contract_sha" => root_contract["contract_sha"],
        "authorizer" => "1",
        "criteria" => criteria,
        "members" => members,
        "dependencies" => edges,
        "integration" => works[integration],
        "budget_ms" => budget
      })

    plan
  end

  defp spec(specs, number), do: Enum.find(specs, &(&1.number == number))

  defp native_plan_objects(provider, parent, specs, works, contracts, root_contract, plan) do
    prefix = if provider == "github", do: "/repos/team/repo", else: "/projects/team%2Frepo"
    suffix = if provider == "github", do: "/comments", else: "/notes"
    url = "https://" <> parent["host"] <> "/team/repo"
    approval = note(1, 1, block("plan-decision", %{"action" => "authorize", "revision" => plan["revision"]}))

    base = %{
      prefix => repo_object(provider, url),
      "/user" => %{"id" => 99},
      (prefix <> "/issues/1") => native_raw(provider, url, 1, block("contract", root_contract) <> block("plan", plan)),
      (prefix <> "/issues/1" <> suffix) => [approval]
    }

    objects = Enum.reduce(specs, base, &put_plan_issue(&2, {provider, url, prefix, suffix, works, contracts}, &1))
    root = journal_root()
    state = start_supervised!({Agent, fn -> native_state(objects) end}, id: make_ref())

    %{
      state: state,
      root: root,
      prefix: prefix,
      suffix: suffix,
      parent_notes: prefix <> "/issues/1" <> suffix,
      opts: native_opts(provider, parent, state, root)
    }
  end

  defp put_plan_issue(acc, {provider, url, prefix, suffix, works, contracts}, s) do
    number = s.number
    body = block("contract", contracts[WorkRef.key(works[number])])

    acc
    |> Map.put(prefix <> "/issues/#{number}", native_raw(provider, url, number, body))
    |> Map.put(prefix <> "/issues/#{number}" <> suffix, [])
  end

  defp seed_record(f, member, thread) do
    {:ok, record} = RunJournal.admit(f.root, WorkRef.key(member), execution_binding: developer_binding(f, member))
    now = System.system_time(:millisecond)
    flow = TaskWorkflow.new(100_000, now) |> TaskWorkflow.start(now) |> Map.merge(%{"schema_version" => 2, "repair_history" => %{}})
    {:ok, record} = RunJournal.checkpoint(record, %{"thread_id" => thread, "workflow" => flow, "native_stop_confirmed" => false})
    # A seeded member stands in for a finished execution: release the admission
    # lock so a later rework fence can take it over exactly like a real reopen.
    :ok = RunJournal.release_lock(record)
    record
  end

  # A plan whose members have no journal-backed closure still needs the durable
  # publication intent that recover_rework requires; the ambiguity decision is
  # upstream of any manifest assembly, so the projection is not exercised here.
  defp confirm_manifest(f) do
    {:ok, manifest} = TaskPlanManifest.assemble(f.plan, hand_projection(f))
    receipt = append_parent_note(f, note(1000 + parent_note_count(f), 99, manifest_block(manifest)))
    source = TaskDecision.source_ref(receipt)
    directory = RunJournal.directory(f.root, WorkRef.key(f.plan["integration"]))
    {:ok, record} = RunJournal.read(directory)

    intent = %{"parent_manifest_intent" => %{"status" => "confirmed", "revision" => manifest["revision"], "source" => source}}
    # A checkpoint needs the member's executor lock or a held reconciler fence,
    # so write the durable intent the way production does: inside with_fence.
    {:ok, _} = TaskClosure.with_fence(record, f.opts, fn -> RunJournal.checkpoint(record, intent) end)
    {manifest, source}
  end

  defp hand_projection(f) do
    Map.new(f.plan["members"], fn member -> closed_member_projection(f, member["work"]) end)
  end

  defp closed_member_projection(f, member) do
    key = WorkRef.key(member)
    digest = "candidate-" <> String.slice(TaskWorkflow.digest(key), 0, 12)
    verification = "note:verification:" <> String.slice(TaskWorkflow.digest(key <> "v"), 0, 12)
    delivery = "note:delivery:" <> String.slice(TaskWorkflow.digest(key <> "d"), 0, 12)

    flow = %{
      "candidate" => digest,
      "verification" => verification,
      "contract_sha" => f.contracts[key]["contract_sha"],
      "plan_revision" => f.plan["revision"],
      "inputs" => []
    }

    artifact = %{"id" => "report", "kind" => "report", "version" => "v1", "source" => "issue:report"}
    candidate = %{"digest" => digest, "inputs" => [], "artifacts" => [artifact]}
    evidence = %{"candidate" => candidate, "verification" => %{"source" => verification}, "deliveries" => [%{"source" => delivery}]}
    closure = %{"status" => "confirmed", "native_state" => "closed", "source" => "issue:closed"}

    {key, %{closeable: true, flow: flow, closure: closure, evidence: evidence}}
  end

  defp native_state!(f, number, state) do
    path = f.prefix <> "/issues/#{number}"
    Agent.update(f.state, fn current -> %{current | objects: Map.update!(current.objects, path, &Map.put(&1, "state", state))} end)
    f
  end

  # Publish through the production path so the integration journal carries the
  # confirmed publication intent that rework recovery requires, then append the
  # parent's rework decision on top of that receipt.
  defp seed_rework(f, manifest) do
    {:ok, receipt} = TaskPlanManifest.publish(configured(f).plan.parent, f.plan, manifest, f.opts)
    rework_note(f, receipt)
    receipt
  end

  defp redeliver(f, thread) do
    {:ok, record} = RunJournal.admit(f.root, WorkRef.key(f.member), execution_binding: developer_binding(f, f.member))
    {:ok, _} = RunJournal.checkpoint(record, %{"thread_id" => thread})
    f |> verified("-" <> thread) |> close_member()
  end

  defp issue_state(f, number) do
    path = f.prefix <> "/issues/#{number}"
    Agent.get(f.state, & &1.objects) |> Map.fetch!(path) |> Map.fetch!("state")
  end

  defp set_member_state(f, state) do
    path = f.prefix <> "/issues/2"
    Agent.update(f.state, fn current -> %{current | objects: Map.update!(current.objects, path, &Map.put(&1, "state", state))} end)
    f
  end

  defp set_parent_state(f, state) do
    path = f.prefix <> "/issues/1"
    Agent.update(f.state, fn current -> %{current | objects: Map.update!(current.objects, path, &Map.put(&1, "state", state))} end)
    f
  end

  defp hold_member_lock(f) do
    lock = Path.join([f.record["directory"], "executor.lock", "executor-owner.json"])
    File.mkdir_p!(Path.dirname(lock))

    File.write!(lock, Jason.encode!(%{"attempt_id" => f.record["attempt_id"], "host" => f.record["host"], "executor_os_pid" => "0"}))
    f
  end

  # ---- native, journal-backed behaviour -------------------------------------

  test "advance publishes M1, waits for acceptance, then closes the parent across both providers" do
    for provider <- ["github", "gitlab"] do
      f = native_fixture(provider) |> verified() |> close_member()
      assert issue_state(f, 2) == "closed"

      assert {:ok, %{"status" => "awaiting_acceptance", "manifest" => receipt}} = TaskPlanManifest.advance(configured(f), f.opts)
      assert receipt["payload"]["plan_revision"] == f.plan["revision"]
      assert posts(f, f.parent_notes) == 1
      assert issue_state(f, 1) == "open"

      accept_note(f, receipt)
      assert {:ok, %{"status" => "confirmed"}} = TaskPlanManifest.advance(configured(f), f.opts)
      assert issue_state(f, 1) == "closed"
      assert {:ok, []} = TaskPlanExecution.discover(Keyword.merge(f.opts, roots: [f.parent], active_state: "Todo"))
      assert {:error, :parent_not_open} = TaskExecutionConfig.prepare(f.parent, f.opts)
      assert {:ok, projection} = TaskPlanExecution.projection(Keyword.merge(f.opts, roots: [f.parent], active_state: "Todo"))
      assert projection[WorkRef.key(f.member)].closeable
      assert {:ok, %{"revision" => revision}} = TaskPlanManifest.assemble(f.plan, projection)
      assert revision == receipt["payload"]["revision"]

      assert %{"status" => "confirmed", "manifest" => source, "revision" => ^revision, "acceptance" => acceptance, "members" => members} =
               current(f)["parent_close_intent"]

      assert source == receipt["source"]
      assert is_binary(acceptance)

      assert members[WorkRef.key(f.member)]["source"] ==
               String.trim_leading(projection[WorkRef.key(f.member)].closure["source"], "issue:")

      assert {:ok, detail} = completed_detail(f)
      assert detail.card.column == "Done"
      assert detail.execution.projection.status == "current"
      assert detail.execution.closeable

      parent_record = current(f)
      journal_path = Path.join(parent_record["directory"], "run.json")
      File.write!(journal_path, Jason.encode!(put_in(parent_record, ["parent_close_intent"], Map.delete(parent_record["parent_close_intent"], "members"))))
      assert {:ok, %{}} = TaskPlanExecution.projection(Keyword.merge(f.opts, roots: [f.parent], active_state: "Todo"))
      File.write!(journal_path, Jason.encode!(parent_record))

      File.write!(journal_path, Jason.encode!(Map.put(parent_record, "closure_confirmed", nil)))
      assert {:ok, %{}} = TaskPlanExecution.projection(Keyword.merge(f.opts, roots: [f.parent], active_state: "Todo"))
      File.write!(journal_path, Jason.encode!(parent_record))

      original = Agent.get(f.state, & &1.objects)

      Agent.update(f.state, fn state ->
        %{state | objects: Map.update!(state.objects, f.member_notes, &List.update_at(&1, -1, fn note -> Map.update!(note, "body", fn body -> body <> " edited" end) end))}
      end)

      assert {:ok, changed} = completed_detail(f)
      assert changed.card.column == "Human Review"
      assert changed.execution.projection.status == "stale"
      refute changed.execution.closeable
      Agent.update(f.state, &%{&1 | objects: original})

      Agent.update(f.state, fn state ->
        %{state | objects: Map.update!(state.objects, f.parent_notes, &Enum.drop(&1, -1))}
      end)

      assert {:ok, changed} = completed_detail(f)
      assert changed.execution.projection.status == "stale"
      refute changed.execution.closeable
    end
  end

  defp completed_detail(f) do
    provider = f.provider

    tracker = %{
      kind: provider,
      project_slug: "team/repo",
      active_states: ["open"],
      terminal_states: ["closed"],
      provider: %{
        "repo" => "team/repo",
        "project_path" => "team/repo",
        "api_url" => "https://" <> provider <> ".test/api/" <> if(provider == "github", do: "v3", else: "v4"),
        "token" => "fixture",
        "api_key" => "fixture",
        "plan_roots" => [f.parent],
        "plan_repositories" => f.opts[:repositories]
      }
    }

    issue_fun = fn _ ->
      raw = Agent.get(f.state, &Map.fetch!(&1.objects, f.prefix <> "/issues/2"))

      issue = %Issue{
        id: "2",
        identifier: if(provider == "github", do: "GH-2", else: "GL-2"),
        title: "Member",
        description: raw["body"] || raw["description"],
        url: raw["html_url"] || raw["web_url"],
        state: raw["state"],
        labels: ["symphony:todo"],
        native_ref: %{"number" => 2, "iid" => 2, "repo" => "team/repo", "project_path" => "team/repo", "repository_id" => "10", "project_id" => 10}
      }

      {:ok, [issue]}
    end

    request_fun = fn "GET", path, _query, nil, _settings ->
      {:ok, %{status: 200, body: Agent.get(f.state, &Map.get(&1.objects, path, []))}}
    end

    settings = %{tracker: tracker, taskboard: %{projects: [], enabled: true, control_token: nil, provider_token: nil}}

    opts =
      Keyword.merge(f.opts,
        settings: settings,
        roots: [f.parent],
        active_state: "Todo",
        issue_fun: issue_fun,
        request_fun: request_fun,
        runtime_snapshot_fun: fn -> %{} end
      )

    Taskboard.issue_detail(provider <> "-team-repo", if(provider == "github", do: "GH-2", else: "GL-2"), opts)
  end

  test "manual parent closure cannot produce a completed plan projection" do
    for provider <- ["github", "gitlab"] do
      f = native_fixture(provider) |> verified() |> close_member()
      parent_path = f.prefix <> "/issues/1"

      Agent.update(f.state, fn state ->
        %{state | objects: Map.update!(state.objects, parent_path, &Map.put(&1, "state", "closed"))}
      end)

      assert {:ok, %{}} = TaskPlanExecution.projection(Keyword.merge(f.opts, roots: [f.parent], active_state: "Todo"))
      assert {:ok, detail} = completed_detail(f)
      assert detail.execution.projection.status == "stale"
      refute detail.execution.closeable
    end
  end

  test "acceptance removed before the final parent snapshot cannot authorize close" do
    baseline = native_fixture("github") |> verified() |> close_member()
    assert {:ok, %{"manifest" => baseline_receipt}} = TaskPlanManifest.advance(configured(baseline), baseline.opts)
    accept_note(baseline, baseline_receipt)
    baseline_configured = configured(baseline)
    Agent.update(baseline.state, &%{&1 | note_reads: 0})
    assert {:ok, %{"status" => "confirmed"}} = TaskPlanManifest.advance(baseline_configured, baseline.opts)
    reads_before_close = Agent.get(baseline.state, & &1.close_note_reads)
    assert is_integer(reads_before_close) and reads_before_close > 1

    f = native_fixture("github") |> verified() |> close_member()
    assert {:ok, %{"manifest" => receipt}} = TaskPlanManifest.advance(configured(f), f.opts)
    acceptance = accept_note(f, receipt)
    configured = configured(f)
    arm_note_removal(f, reads_before_close - 1, acceptance["id"])

    assert {:error, :parent_changed_after_prepare} = TaskPlanManifest.advance(configured, f.opts)
    assert issue_state(f, 1) == "open"
    assert writes(f, "close") == 1
  end

  test "current acceptance distinguishes an exact manifest from a later native publication" do
    f = native_fixture("github") |> verified() |> close_member()
    assert {:ok, %{"manifest" => receipt}} = TaskPlanManifest.advance(configured(f), f.opts)
    accept_note(f, receipt)
    {:ok, parent} = SymphonyElixir.NativeWork.read(f.parent, f.opts)
    assert {:ok, decision} = TaskPlanManifest.decision(parent, f.plan, receipt)
    assert :ok = TaskPlanManifest.current_acceptance(parent, f.plan, receipt, decision)

    later_manifest = note(900, 99, block("plan-manifest", receipt["payload"]), @decision_at)
    Agent.update(f.state, &update_in(&1.objects[f.parent_notes], fn notes -> notes ++ [later_manifest] end))
    {:ok, changed} = SymphonyElixir.NativeWork.read(f.parent, f.opts)

    assert {:error, :parent_acceptance_changed} =
             TaskPlanManifest.current_acceptance(changed, f.plan, receipt, decision)
  end

  test "a native parent pause arriving after prepare blocks close across both providers" do
    for provider <- ["github", "gitlab"] do
      baseline = native_fixture(provider) |> verified() |> close_member()
      assert {:ok, %{"manifest" => baseline_receipt}} = TaskPlanManifest.advance(configured(baseline), baseline.opts)
      accept_note(baseline, baseline_receipt)
      Agent.update(baseline.state, &%{&1 | note_reads: 0})
      assert {:ok, %{"status" => "confirmed"}} = TaskPlanManifest.advance(configured(baseline), baseline.opts)
      reads_before_close = Agent.get(baseline.state, & &1.close_note_reads)
      assert reads_before_close > 1

      f = native_fixture(provider) |> verified() |> close_member()
      assert {:ok, %{"manifest" => receipt}} = TaskPlanManifest.advance(configured(f), f.opts)
      accept_note(f, receipt)
      prepared = configured(f)
      pause = note(900, 1, block("plan-decision", %{"action" => "pause", "revision" => f.plan["revision"]}), @decision_at)
      arm_note_append(f, reads_before_close - 3, pause)

      assert {:error, :parent_changed_after_prepare} = TaskPlanManifest.advance(prepared, f.opts)
      assert issue_state(f, 1) == "open"
      assert writes(f, "close") == 1
      assert current(f)["parent_close_intent"] == nil
    end
  end

  test "a native parent pause after the close write leaves the receipt inconsistent" do
    f = native_fixture("github") |> verified() |> close_member()
    assert {:ok, %{"manifest" => receipt}} = TaskPlanManifest.advance(configured(f), f.opts)
    accept_note(f, receipt)
    prepared = configured(f)
    write_request = f.opts[:write_request]
    parent_path = f.prefix <> "/issues/1"
    pause = note(900, 1, block("plan-decision", %{"action" => "pause", "revision" => f.plan["revision"]}), @decision_at)

    opts =
      Keyword.put(f.opts, :write_request, fn provider, method, path, headers, body, settings ->
        result = write_request.(provider, method, path, headers, body, settings)

        if method == "PATCH" and path == parent_path do
          Agent.update(f.state, fn state ->
            %{state | objects: Map.update!(state.objects, f.parent_notes, &(&1 ++ [pause]))}
          end)
        end

        result
      end)

    assert {:ok, %{"status" => "inconsistent"}} = TaskPlanManifest.advance(prepared, opts)
    assert issue_state(f, 1) == "closed"
    assert current(f)["parent_close_intent"]["status"] == "inconsistent"
  end

  test "publish recovers a lost write response by native readback instead of reposting" do
    f = native_fixture("github") |> verified() |> close_member()
    {configured, manifest} = manifest_for(f)
    Agent.update(f.state, &%{&1 | manifest_mode: :lost})

    assert {:ok, receipt} = TaskPlanManifest.publish(configured.plan.parent, f.plan, manifest, f.opts)
    assert receipt["payload"]["revision"] == manifest["revision"]
    assert {:ok, ^receipt} = TaskPlanManifest.publish(configured.plan.parent, f.plan, manifest, f.opts)
    assert posts(f, f.parent_notes) == 1
  end

  test "an uncertain manifest write whose readback is missing never reposts on the next round" do
    f = native_fixture("github") |> verified() |> close_member()
    {configured, manifest} = manifest_for(f)
    Agent.update(f.state, &%{&1 | manifest_mode: :uncertain})

    assert {:error, {:plan_manifest_unconfirmed, _}} = TaskPlanManifest.publish(configured.plan.parent, f.plan, manifest, f.opts)
    assert posts(f, f.parent_notes) == 1

    Agent.update(f.state, &%{&1 | manifest_mode: :ok})
    assert {:error, :plan_manifest_send_unconfirmed} = TaskPlanManifest.publish(configured.plan.parent, f.plan, manifest, f.opts)
    assert posts(f, f.parent_notes) == 1
  end

  test "publish pins every member report under the manifest owner before the native comment" do
    f = native_fixture("github") |> verified() |> close_member()
    {configured, manifest} = manifest_for(f)
    artifact = manifest["members"] |> hd() |> Map.fetch!("artifacts") |> hd()

    assert {:ok, before} = ArtifactStore.report_references(f.root <> "/.artifacts", f.member, artifact, f.opts)
    refute Enum.any?(before, &(&1["kind"] == "manifest"))

    assert {:ok, receipt} = TaskPlanManifest.publish(configured.plan.parent, f.plan, manifest, f.opts)
    assert receipt["payload"]["revision"] == manifest["revision"]

    assert {:ok, owners} = ArtifactStore.report_references(f.root <> "/.artifacts", f.member, artifact, f.opts)
    [manifest_owner] = Enum.filter(owners, &(&1["kind"] == "manifest"))
    assert manifest_owner["work"] == f.parent
    assert manifest_owner["revision"] == manifest["revision"]
  end

  test "a damaged retained report blocks publication while a removed one is re-derived before the comment" do
    f = native_fixture("github") |> verified() |> close_member()
    {configured, manifest} = manifest_for(f)
    artifact = manifest["members"] |> hd() |> Map.fetch!("artifacts") |> hd()
    path = report_store_path(f.root, artifact)

    # Retention never overwrites bytes that differ from the retained artifact, so
    # damaged bytes stop the manifest before any native comment is written.
    File.write!(path, "{not json}")
    assert {:error, reason} = TaskPlanManifest.publish(configured.plan.parent, f.plan, manifest, f.opts)
    assert reason in @damaged_report_reasons
    assert posts(f, f.parent_notes) == 0

    # The store is a materialization of the journal owner, so a removed report is
    # re-derived and re-pinned before the same manifest is published.
    File.rm!(path)
    assert {:ok, receipt} = TaskPlanManifest.publish(configured.plan.parent, f.plan, manifest, f.opts)
    assert receipt["payload"]["revision"] == manifest["revision"]
    assert File.exists?(path)
    assert posts(f, f.parent_notes) == 1
  end

  test "a rework decision reopens only the affected member once and is idempotent on the next round" do
    for provider <- ["github", "gitlab"] do
      f = native_fixture(provider) |> verified() |> close_member()
      assert issue_state(f, 2) == "closed"

      {_configured, manifest} = manifest_for(f)
      receipt = seed_rework(f, manifest)

      assert {:ok, %{"status" => "rework", "members" => [member]}} = TaskPlanManifest.advance(configured(f), f.opts)
      assert member["work"] == f.member
      assert member["status"] == "reopened"
      assert member["criteria"] == [@criterion]
      assert member["manifest"] == receipt["source"]
      assert issue_state(f, 2) == "open"
      assert writes(f, "reopen") == 1
      assert posts(f, f.parent_notes) == 1

      assert %{"status" => "confirmed"} = current(f)["rework"]
      assert %{"status" => "confirmed", "source" => source} = current(f)["parent_manifest_intent"]
      assert source == receipt["source"]

      assert {:ok, %{"status" => "rework", "members" => [again]}} = TaskPlanManifest.advance(configured(f), f.opts)
      assert again["status"] == "already_open"
      assert writes(f, "reopen") == 1
    end
  end

  test "a lost reopen response is recovered by readback and never re-sent" do
    f = native_fixture("github") |> verified() |> close_member()
    {_configured, manifest} = manifest_for(f)
    receipt = seed_rework(f, manifest)
    Agent.update(f.state, &%{&1 | reopen_mode: :lost})

    assert {:ok, %{"status" => "rework", "members" => [member]}} = TaskPlanManifest.advance(configured(f), f.opts)
    assert member["status"] == "reopened"
    assert member["manifest"] == receipt["source"]
    assert issue_state(f, 2) == "open"
    assert writes(f, "reopen") == 1

    Agent.update(f.state, &%{&1 | reopen_mode: :ok})
    assert {:ok, %{"members" => [again]}} = TaskPlanManifest.advance(configured(f), f.opts)
    assert again["status"] == "already_open"
    assert writes(f, "reopen") == 1
  end

  test "a rework reopen that was never sent retries the same decision without a duplicate write" do
    f = native_fixture("github") |> verified() |> close_member()
    {_configured, manifest} = manifest_for(f)
    _receipt = seed_rework(f, manifest)

    configured = configured(f)
    # The Issue is edited between the rework snapshot and the pre-write read-back,
    # so NativeWork.reopen refuses to send and reports :not_sent instead of writing.
    f = arm_drift(f, f.prefix <> "/issues/2", 5)

    assert {:error, {:member_rework_not_sent, :native_snapshot_changed}} = TaskPlanManifest.advance(configured, f.opts)
    assert issue_state(f, 2) == "closed"
    assert writes(f, "reopen") == 0
    assert current(f)["rework"]["status"] == "prepared"

    assert {:ok, %{"status" => "rework", "members" => [member]}} = TaskPlanManifest.advance(configured, f.opts)
    assert member["status"] == "reopened"
    assert issue_state(f, 2) == "open"
    assert writes(f, "reopen") == 1
    assert current(f)["rework"]["status"] == "confirmed"
  end

  test "a held member fence blocks rework without writing to the native Issue" do
    f = native_fixture("github") |> verified() |> close_member()
    {_configured, manifest} = manifest_for(f)
    _entry = seed_rework(f, manifest)
    hold_member_lock(f)

    assert {:error, :member_closure_executor_locked} = TaskPlanManifest.advance(configured(f), f.opts)
    assert issue_state(f, 2) == "closed"
    assert writes(f, "reopen") == 0
  end

  test "a rework decision inside an in-flight parent close cannot reopen the member" do
    f = native_fixture("github") |> verified() |> close_member()
    {_configured, manifest} = manifest_for(f)
    receipt = seed_rework(f, manifest)

    record = current(f)
    intent = %{"parent_close_intent" => %{"status" => "sending", "manifest" => receipt["source"]}}
    {:ok, _} = TaskClosure.with_fence(record, f.opts, fn -> RunJournal.checkpoint(record, intent) end)

    assert {:error, :parent_rework_after_acceptance} = TaskPlanManifest.advance(configured(f), f.opts)
    assert issue_state(f, 2) == "closed"
    assert writes(f, "reopen") == 0
  end

  test "rework never reopens a member whose workflow budget is spent" do
    f = native_fixture("github") |> verified() |> close_member()
    {_configured, manifest} = manifest_for(f)
    _receipt = seed_rework(f, manifest)

    record = current(f)
    spent = Map.merge(record["workflow"], %{"used_ms" => record["workflow"]["budget_ms"]})
    {:ok, _} = TaskClosure.with_fence(record, f.opts, fn -> RunJournal.checkpoint(record, %{"workflow" => spent}) end)

    assert {:error, :member_rework_budget_exhausted} = TaskPlanManifest.advance(configured(f), f.opts)
    assert issue_state(f, 2) == "closed"
    assert writes(f, "reopen") == 0
  end

  test "a reworked member is redelivered, reverified and reclosed before M2 acceptance" do
    f = native_fixture("github") |> verified() |> close_member()
    {_configured, manifest1} = manifest_for(f)
    receipt1 = seed_rework(f, manifest1)

    assert {:ok, %{"status" => "rework"}} = TaskPlanManifest.advance(configured(f), f.opts)
    assert issue_state(f, 2) == "open"

    assert {:ok, observed} = TaskExecution.observe(f.parent, f.member, configured(f).executions, f.opts)
    assert observed.flow["dispatchable"]
    assert observed.flow["action"] == "implement"
    assert {:ok, admitted} = TaskExecution.admit(f.parent, f.member, configured(f).executions, f.opts)
    assert admitted.flow["action"] == "implement"
    {:ok, _} = RunJournal.checkpoint(admitted.record, %{"thread_id" => "developer-2"})

    f = f |> verified("-developer-2") |> close_member()
    assert issue_state(f, 2) == "closed"

    assert {:ok, %{"status" => "awaiting_acceptance", "manifest" => receipt2}} = TaskPlanManifest.advance(configured(f), f.opts)
    assert receipt2["label"] == "M2"
    assert receipt2["payload"]["revision"] != receipt1["payload"]["revision"]

    accept_note(f, receipt2)
    assert {:ok, %{"status" => "confirmed"}} = TaskPlanManifest.advance(configured(f), f.opts)
    assert issue_state(f, 1) == "closed"
  end

  test "facts/3 trusts only a manifest backed by a durable publication receipt" do
    f = native_fixture("github") |> verified() |> close_member()
    {_configured, manifest} = manifest_for(f)

    append_parent_note(f, note(1000 + parent_note_count(f), 99, manifest_block(manifest), "2026-10-18T00:00:00Z"))
    parent = configured(f).plan.parent

    # A native manifest note alone is unconfirmed, even though the loose reader sees it.
    assert %{"status" => "unconfirmed", "label" => "M1", "source" => source} = TaskPlanManifest.facts(parent, f.plan, f.opts)
    assert source == TaskPlanManifest.manifests(parent) |> List.last() |> Map.fetch!("source")
    assert %{"status" => "awaiting_acceptance"} = TaskPlanManifest.facts(parent, f.plan)

    # A missing publication journal is never treated as a publication.
    orphan = Keyword.put(f.opts, :journal_root, Path.join(System.tmp_dir!(), "absent-#{System.unique_integer([:positive])}"))
    assert %{"status" => "unconfirmed"} = TaskPlanManifest.facts(parent, f.plan, orphan)

    # Publishing writes the durable receipt that promotes the same note.
    assert {:ok, receipt} = TaskPlanManifest.publish(parent, f.plan, manifest, f.opts)
    assert receipt["source"] == source
    assert %{"status" => "awaiting_acceptance", "label" => "M1"} = TaskPlanManifest.facts(configured(f).plan.parent, f.plan, f.opts)
  end

  test "accept(M1) never closes the parent once the member evidence changes to M2" do
    f = native_fixture("github") |> verified() |> close_member()
    {_configured, manifest1} = manifest_for(f)
    assert {:ok, %{"status" => "awaiting_acceptance", "manifest" => receipt1}} = TaskPlanManifest.advance(configured(f), f.opts)

    accept_note(f, receipt1)
    assert issue_state(f, 1) == "open"

    # The member is redone after M1 was accepted, so the accepted evidence no longer holds.
    f = f |> set_member_state("open") |> redeliver("developer-2")
    assert issue_state(f, 2) == "closed"

    assert {:ok, %{"status" => "awaiting_acceptance", "manifest" => receipt2}} = TaskPlanManifest.advance(configured(f), f.opts)
    assert receipt2["label"] == "M2"
    assert receipt2["payload"]["revision"] != receipt1["payload"]["revision"]
    assert receipt2["payload"]["members"] != receipt1["payload"]["members"]
    assert issue_state(f, 1) == "open"
    assert manifest1["revision"] == receipt1["payload"]["revision"]
  end

  test "a criterion that maps to two independent members clarifies instead of reopening either" do
    specs = [%{number: 2, criteria: [@criterion]}, %{number: 3, criteria: [@criterion]}, %{number: 4, criteria: ["C2"]}]
    f = plan_fixture("github", specs, [{2, 4}, {3, 4}], 4)
    f = Enum.reduce([2, 3, 4], f, fn number, acc -> native_state!(acc, number, "closed") end)

    {manifest, source} = confirm_manifest(f)
    rework_note(f, %{"source" => source, "payload" => manifest})

    assert {:ok, %{"status" => "clarification", "criteria" => [@criterion]}} = TaskPlanManifest.advance(configured(f), f.opts)
    assert writes(f, "reopen") == 0
    assert posts(f, f.parent_notes) == 0
    assert Enum.map([2, 3, 4], &issue_state(f, &1)) == ["closed", "closed", "closed"]
  end

  test "a single rework root reopens every dependent member through the plan graph" do
    specs = [%{number: 2, criteria: [@criterion]}, %{number: 3, criteria: ["C2"]}]
    f = plan_fixture("github", specs, [{2, 3}], 3)
    f = f |> native_state!(2, "closed") |> native_state!(3, "closed")

    {manifest, source} = confirm_manifest(f)
    rework_note(f, %{"source" => source, "payload" => manifest})

    assert {:ok, %{"status" => "rework", "members" => members}} = TaskPlanManifest.advance(configured(f), f.opts)
    assert Enum.sort(Enum.map(members, & &1["work"]["number"])) == [2, 3]
    assert Enum.all?(members, &(&1["status"] == "reopened"))
    assert writes(f, "reopen") == 2
    assert issue_state(f, 2) == "open"
    assert issue_state(f, 3) == "open"
  end

  test "publish refuses a plan whose integration member journal cannot be read" do
    f = native_fixture("github") |> verified() |> close_member()
    {_configured, manifest} = manifest_for(f)

    assert {:error, :parent_manifest_member_unavailable} =
             TaskPlanManifest.publish(f.parent, f.plan, manifest, Keyword.put(f.opts, :journal_root, journal_root()))

    broken = journal_root()
    directory = RunJournal.directory(broken, WorkRef.key(f.plan["integration"]))
    File.mkdir_p!(directory)
    File.write!(Path.join(directory, "run.json"), "[]")

    assert {:error, :invalid_run_journal} =
             TaskPlanManifest.publish(f.parent, f.plan, manifest, Keyword.put(f.opts, :journal_root, broken))

    assert posts(f, f.parent_notes) == 0
  end

  test "manifest retention pins exact reports and refuses missing report or unavailable Git bytes" do
    f = native_fixture("github") |> verified() |> close_member()
    {_configured, manifest} = manifest_for(f)
    assert :ok = TaskPlanManifest.retain_manifest(current(f), f.plan, manifest, f.opts)

    artifact = manifest["members"] |> hd() |> Map.fetch!("artifacts") |> hd()
    File.rm!(report_store_path(f.root, artifact))
    assert {:error, _} = TaskPlanManifest.retain_manifest(current(f), f.plan, manifest, f.opts)

    git_member = manifest["members"] |> hd() |> Map.put("artifacts", [%{"kind" => "pr", "version" => String.duplicate("a", 40)}])
    git_manifest = %{manifest | "members" => [git_member]}
    request = f.opts[:request]

    opts =
      Keyword.put(f.opts, :request, fn provider, method, path, headers, settings ->
        if String.contains?(path, "/git/commits/") do
          {:error, :not_found}
        else
          request.(provider, method, path, headers, settings)
        end
      end)

    assert {:error, _} = TaskPlanManifest.retain_manifest(current(f), f.plan, git_manifest, opts)
  end

  test "publish refuses to comment when the native actor no longer matches the policy" do
    f = native_fixture("github") |> verified() |> close_member()
    {configured, manifest} = manifest_for(f)
    Agent.update(f.state, &put_notes(&1, "/user", %{"id" => 42}))

    assert {:error, {:plan_manifest_not_published, :native_publication_actor_mismatch}} =
             TaskPlanManifest.publish(configured.plan.parent, f.plan, manifest, f.opts)

    assert posts(f, f.parent_notes) == 0
    assert %{"status" => "prepared"} = current(f)["parent_manifest_intent"]

    Agent.update(f.state, &put_notes(&1, "/user", %{"id" => 99}))
    assert {:ok, receipt} = TaskPlanManifest.publish(configured.plan.parent, f.plan, manifest, f.opts)
    assert receipt["payload"]["revision"] == manifest["revision"]
    assert posts(f, f.parent_notes) == 1
  end

  test "publish rejects a manifest that native facts attribute to another author" do
    f = native_fixture("github") |> verified() |> close_member()
    {configured, manifest} = manifest_for(f)
    append_parent_note(f, note(200, 7, manifest_block(manifest)))

    assert {:error, :plan_manifest_publication_conflict} =
             TaskPlanManifest.publish(configured.plan.parent, f.plan, manifest, f.opts)

    assert posts(f, f.parent_notes) == 0
  end

  test "publish refuses a manifest superseded by newer member evidence" do
    f = native_fixture("github") |> verified() |> close_member()
    {_configured, manifest} = manifest_for(f)

    f = f |> set_member_state("open") |> redeliver("developer-2")
    assert {:ok, %{"revision" => revision}} = TaskPlanManifest.assemble(f.plan, TaskPlanExecution.projection_of(configured(f)))
    refute revision == manifest["revision"]

    assert {:error, :parent_manifest_superseded} = TaskPlanManifest.publish(f.parent, f.plan, manifest, f.opts)
    assert posts(f, f.parent_notes) == 0
  end

  test "publish refuses to reuse a receipt when a divergent intent is still sending" do
    f = native_fixture("github") |> verified() |> close_member()
    {configured, manifest} = manifest_for(f)
    assert {:ok, _receipt} = TaskPlanManifest.publish(configured.plan.parent, f.plan, manifest, f.opts)

    fenced_checkpoint(f, %{"parent_manifest_intent" => %{"status" => "sending", "revision" => "other"}})

    assert {:error, :prior_plan_manifest_unconfirmed} =
             TaskPlanManifest.publish(configured.plan.parent, f.plan, manifest, f.opts)

    assert posts(f, f.parent_notes) == 1
  end

  test "publish refuses to reuse a receipt whose native source changed" do
    f = native_fixture("github") |> verified() |> close_member()
    {configured, manifest} = manifest_for(f)
    assert {:ok, receipt} = TaskPlanManifest.publish(configured.plan.parent, f.plan, manifest, f.opts)

    notes = Agent.get(f.state, &Map.fetch!(&1.objects, f.parent_notes))
    renamed = Enum.map(notes, fn item -> if item["id"] == receipt["note_id"], do: Map.put(item, "id", 500), else: item end)
    Agent.update(f.state, &put_notes(&1, f.parent_notes, renamed))

    assert {:error, :plan_manifest_source_changed} =
             TaskPlanManifest.publish(configured.plan.parent, f.plan, manifest, f.opts)

    assert posts(f, f.parent_notes) == 1
  end

  test "facts/3 reports a divergent durable intent as unconfirmed" do
    f = native_fixture("github") |> verified() |> close_member()
    {configured, manifest} = manifest_for(f)
    assert {:ok, _receipt} = TaskPlanManifest.publish(configured.plan.parent, f.plan, manifest, f.opts)

    intent = current(f)["parent_manifest_intent"]
    fenced_checkpoint(f, %{"parent_manifest_intent" => %{intent | "revision" => "other"}})

    assert %{"status" => "unconfirmed", "revision" => revision} =
             TaskPlanManifest.facts(configured(f).plan.parent, f.plan, f.opts)

    assert revision == manifest["revision"]
  end

  test "a prepared reopen whose Issue is already open is confirmed without another write" do
    f = native_fixture("github") |> verified() |> close_member()
    {_configured, manifest} = manifest_for(f)
    _receipt = seed_rework(f, manifest)

    configured = configured(f)
    f = arm_drift(f, f.prefix <> "/issues/2", 5)
    assert {:error, {:member_rework_not_sent, :native_snapshot_changed}} = TaskPlanManifest.advance(configured, f.opts)
    assert current(f)["rework"]["status"] == "prepared"

    f = set_member_state(f, "open")

    assert {:ok, %{"status" => "rework", "members" => [member]}} = TaskPlanManifest.advance(configured, f.opts)
    assert member["status"] == "already_open"
    assert writes(f, "reopen") == 0
    assert current(f)["rework"]["status"] == "confirmed"
  end

  test "a rework intent left sending is confirmed by readback without a second write" do
    f = native_fixture("github") |> verified() |> close_member()
    {_configured, manifest} = manifest_for(f)
    receipt = seed_rework(f, manifest)

    assert {:ok, %{"status" => "rework", "members" => [first]}} = TaskPlanManifest.advance(configured(f), f.opts)
    assert first["status"] == "reopened"
    assert writes(f, "reopen") == 1

    marker = current(f)["rework"]
    fenced_checkpoint(f, %{"rework" => Map.put(marker, "status", "sending")})

    assert {:ok, %{"status" => "rework", "members" => [again]}} = TaskPlanManifest.advance(configured(f), f.opts)
    assert again["status"] == "reopened"
    assert again["manifest"] == receipt["source"]
    assert writes(f, "reopen") == 1
    assert current(f)["rework"]["status"] == "confirmed"
  end

  test "a rework of an Issue in an unknown native state writes nothing" do
    f = native_fixture("github") |> verified() |> close_member()
    {_configured, manifest} = manifest_for(f)
    _receipt = seed_rework(f, manifest)
    f = set_member_state(f, "locked")

    assert {:error, :member_rework_state_unknown} = TaskPlanManifest.advance(configured(f), f.opts)
    assert writes(f, "reopen") == 0
    assert posts(f, f.parent_notes) == 1
  end

  test "a rework intent with an unexpected status is refused instead of reopening" do
    f = native_fixture("github") |> verified() |> close_member()
    {_configured, manifest} = manifest_for(f)
    _receipt = seed_rework(f, manifest)

    assert {:ok, %{"status" => "rework", "members" => [_first]}} = TaskPlanManifest.advance(configured(f), f.opts)
    assert issue_state(f, 2) == "open"

    marker = current(f)["rework"]
    fenced_checkpoint(f, %{"rework" => Map.put(marker, "status", "other")})

    assert {:error, :member_rework_intent_invalid} = TaskPlanManifest.advance(configured(f), f.opts)
    assert writes(f, "reopen") == 1
  end

  test "decision rejects a manifest payload that is not a planned member list" do
    f = fixture()
    {:ok, manifest} = TaskPlanManifest.assemble(f.plan, closed_projection(f))
    {entry, _} = manifest_entry([note(10, 1, manifest_block(manifest))])

    assert {:error, :manifest_plan_mismatch} = TaskPlanManifest.decision(parent_with_notes(f, []), f.plan, %{})

    broken = %{entry | "payload" => Map.put(entry["payload"], "members", "not-a-list")}
    assert {:error, :manifest_plan_mismatch} = TaskPlanManifest.decision(parent_with_notes(f, []), f.plan, broken)
  end

  test "decision falls back to the plan authorizer when the parent has no separate acceptor" do
    f = fixture()
    {:ok, manifest} = TaskPlanManifest.assemble(f.plan, closed_projection(f))
    {entry, notes} = manifest_entry([note(10, 99, manifest_block(manifest))])

    accept = %{"action" => "accept", "manifest" => entry["source"], "revision" => entry["payload"]["revision"]}
    root = f.root |> Map.put("acceptance_mode", "technical") |> Map.put("acceptor", nil)
    description = block("contract", root) <> block("plan", f.plan)
    parent_notes = notes ++ [note(20, 1, decision_block(accept), @decision_at)]
    parent = %{parent_with_notes(f, parent_notes) | :description => description}

    assert {:ok, %{"action" => "accept"}} = TaskPlanManifest.decision(parent, f.plan, entry)
  end

  test "recover_closed refuses a close receipt when the member journal is unreadable" do
    f = native_fixture("github") |> verified() |> close_member()
    f = native_state!(f, 1, "closed")
    directory = RunJournal.directory(f.root, WorkRef.key(f.plan["integration"]))
    File.write!(Path.join(directory, "run.json"), "[]")

    assert {:error, :invalid_run_journal} = TaskPlanManifest.recover_closed(f.parent, f.opts)
  end

  test "advance refuses an ambiguous native rework decision instead of reopening" do
    f = native_fixture("github") |> verified() |> close_member()
    {_configured, manifest} = manifest_for(f)
    receipt = seed_rework(f, manifest)
    rework_note(f, receipt)

    assert {:error, :ambiguous_plan_decision} = TaskPlanManifest.advance(configured(f), f.opts)
    assert writes(f, "reopen") == 0
    assert issue_state(f, 2) == "closed"
  end

  test "a rework decision already on the parent settles the fresh publication into rework" do
    f = native_fixture("github") |> verified() |> close_member()
    {_configured, manifest} = manifest_for(f)
    assert {:ok, receipt} = TaskPlanManifest.publish(configured(f).plan.parent, f.plan, manifest, f.opts)

    # Dropping the durable receipt forces a re-publication of the same manifest, so
    # a rework decision already present is settled after that publication.
    fenced_checkpoint(f, %{"parent_manifest_intent" => nil})
    rework_note(f, receipt)

    assert {:ok, %{"status" => "rework", "members" => [member]}} = TaskPlanManifest.advance(configured(f), f.opts)
    assert member["status"] == "reopened"
    assert writes(f, "reopen") == 1
  end

  test "an accepted manifest recovers a durable close intent instead of closing twice" do
    f = native_fixture("github") |> verified() |> close_member()
    {_configured, manifest} = manifest_for(f)
    assert {:ok, receipt} = TaskPlanManifest.publish(configured(f).plan.parent, f.plan, manifest, f.opts)
    accept = accept_note(f, receipt)
    acceptance = TaskDecision.source_ref(accept)

    intent = %{
      "status" => "inconsistent",
      "manifest" => receipt["source"],
      "revision" => receipt["payload"]["revision"],
      "acceptance" => acceptance
    }

    fenced_checkpoint(f, %{"parent_close_intent" => intent})
    assert {:error, :parent_close_unconfirmed} = TaskPlanManifest.advance(configured(f), f.opts)
    f = set_parent_state(f, "closed")
    before = writes(f, "close")

    assert {:ok, %{"status" => "inconsistent", "manifest" => source}} = TaskPlanManifest.recover_closed(f.parent, f.opts)
    assert source == receipt["source"]
    assert posts(f, f.parent_notes) == 1
    assert writes(f, "close") == before
  end

  test "a parent close that was definitely not sent keeps a prepared retry intent" do
    f = native_fixture("github") |> verified() |> close_member()
    assert {:ok, %{"manifest" => receipt}} = TaskPlanManifest.advance(configured(f), f.opts)
    accept_note(f, receipt)

    request = f.opts[:request]
    parent_path = f.prefix <> "/issues/1"

    opts =
      Keyword.put(f.opts, :request, fn provider, method, path, headers, settings ->
        if method == "GET" and path == parent_path and get_in(current(f), ["parent_close_intent", "status"]) == "sending",
          do: {:error, :offline},
          else: request.(provider, method, path, headers, settings)
      end)

    assert {:error, {:parent_close_not_sent, :native_read_failed}} = TaskPlanManifest.advance(configured(f), opts)
    assert current(f)["parent_close_intent"]["status"] == "prepared"
    assert issue_state(f, 1) == "open"
  end

  test "parent close recovery marks native read failures inconsistent" do
    for failed <- [:member, :parent] do
      f = native_fixture("github") |> verified() |> close_member()
      assert {:ok, %{"manifest" => receipt}} = TaskPlanManifest.advance(configured(f), f.opts)
      accept_note(f, receipt)
      assert {:ok, %{"status" => "confirmed"}} = TaskPlanManifest.advance(configured(f), f.opts)
      assert issue_state(f, 1) == "closed"

      parent_path = f.prefix <> "/issues/1"
      member_path = f.prefix <> "/issues/2"
      request = f.opts[:request]
      counter = start_supervised!({Agent, fn -> 0 end}, id: make_ref())

      opts =
        Keyword.put(f.opts, :request, fn provider, method, path, headers, settings ->
          count =
            if method == "GET" and path == parent_path,
              do: Agent.get_and_update(counter, fn n -> {n + 1, n + 1} end),
              else: 0

          if (failed == :member and method == "GET" and path == member_path) or
               (failed == :parent and method == "GET" and path == parent_path and count == 5),
             do: {:error, :offline},
             else: request.(provider, method, path, headers, settings)
        end)

      assert {:ok, %{"status" => "inconsistent"}} = TaskPlanManifest.recover_closed(f.parent, opts)
      assert current(f)["parent_close_intent"]["status"] == "inconsistent"
    end
  end

  test "rework source loss after preflight prevents native reopening on both providers" do
    for provider <- ["github", "gitlab"], change <- [:delete, :edit] do
      f = native_fixture(provider) |> verified() |> close_member()
      {_, manifest} = manifest_for(f)
      seed_rework(f, manifest)
      prepared = configured(f)

      Agent.update(f.state, fn state ->
        update_in(state.objects[f.parent_notes], fn notes ->
          if change == :delete, do: Enum.drop(notes, -1), else: List.update_at(notes, -1, &Map.put(&1, "updated_at", "2026-10-18T00:01:00Z"))
        end)
      end)

      assert {:error, :member_rework_authority_changed} = TaskPlanManifest.advance(prepared, f.opts)
      assert issue_state(f, 2) == "closed"
      assert writes(f, "reopen") == 0
    end
  end

  test "rework authority is read again after the final native member check" do
    f = native_fixture("github") |> verified() |> close_member()
    {_, manifest} = manifest_for(f)
    seed_rework(f, manifest)
    prepared = configured(f)
    request = f.opts[:request]

    opts =
      Keyword.put(f.opts, :request, fn provider, method, path, query, settings ->
        if path == f.prefix <> "/issues/2" and get_in(current(f), ["rework", "status"]) == "sending" do
          Agent.update(f.state, fn state -> update_in(state.objects[f.parent_notes], &Enum.reject(&1, fn note -> String.contains?(note["body"], "symphony-plan-acceptance") end)) end)
        end

        request.(provider, method, path, query, settings)
      end)

    result = TaskPlanManifest.advance(prepared, opts)
    assert {:error, {:member_rework_not_sent, :member_rework_authority_changed}} = result
    assert issue_state(f, 2) == "closed"
    assert writes(f, "reopen") == 0
  end

  test "ordinary parent and member discussion preserves accepted completion" do
    for provider <- ["github", "gitlab"] do
      f = native_fixture(provider) |> verified() |> close_member()
      {:ok, %{"manifest" => receipt}} = TaskPlanManifest.advance(configured(f), f.opts)
      accept_note(f, receipt)
      assert {:ok, %{"status" => "confirmed"}} = TaskPlanManifest.advance(configured(f), f.opts)

      for actor <- [1, 2, 3] do
        append_parent_note(f, note(9000 + actor, actor, "已收到成果，谢谢。", "2026-10-18T00:01:00Z"))
      end

      Agent.update(f.state, fn state -> update_in(state.objects[f.member_notes], &(&1 ++ [note(9999, 3, "Progress link added.", "2026-10-18T00:01:00Z")])) end)
      assert {:ok, %{"status" => "confirmed"}} = TaskPlanManifest.recover_closed(f.parent, f.opts)
      assert {:ok, detail} = completed_detail(f)
      assert detail.card.column == "Done"
      assert detail.execution.projection.status == "current"
      assert detail.execution.closeable
      # A real decision still invalidates the current completion proof.
      append_parent_note(f, note(10_001, 1, block("plan-decision", %{"action" => "pause", "revision" => f.plan["revision"]}), "2026-10-18T00:02:00Z"))
      assert {:ok, changed} = completed_detail(f)
      refute changed.execution.closeable
      assert {:ok, %{"status" => "inconsistent"}} = TaskPlanManifest.recover_closed(f.parent, f.opts)
    end
  end

  test "ordinary discussion after an answered question preserves completion" do
    for provider <- ["github", "gitlab"] do
      f = native_fixture(provider)
      question = %{"label" => "Q1", "revision" => f.plan["revision"], "authorizer" => "1", "data" => %{"work" => f.member}}
      append_parent_note(f, note(8001, 99, candidate_block(question), "2026-10-18T00:00:01Z"))
      append_parent_note(f, note(8002, 1, "Q1：采用方案 B", "2026-10-18T00:00:02Z"))
      f = f |> verified() |> close_member()
      {:ok, %{"manifest" => manifest}} = TaskPlanManifest.advance(configured(f), f.opts)
      accept_note(f, manifest)
      assert {:ok, %{"status" => "confirmed"}} = TaskPlanManifest.advance(configured(f), f.opts)

      for actor <- [1, 2, 3] do
        append_parent_note(f, note(9000 + actor, actor, "已收到成果，谢谢。", "2026-10-18T00:01:00Z"))
      end

      assert {:ok, %{"status" => "confirmed"}} = TaskPlanManifest.recover_closed(f.parent, f.opts)
      assert {:ok, detail} = completed_detail(f)
      assert detail.card.column == "Done"
      assert detail.execution.projection.status == "current"
    end
  end

  test "old completion receipts retain exact source checks rather than inventing migration evidence" do
    f = native_fixture("github") |> verified() |> close_member()
    {:ok, %{"manifest" => manifest}} = TaskPlanManifest.advance(configured(f), f.opts)
    accept_note(f, manifest)
    {:ok, %{"status" => "confirmed"}} = TaskPlanManifest.advance(configured(f), f.opts)
    intent = current(f)["parent_close_intent"] |> Map.delete("parent_evidence")
    intent = Map.update!(intent, "members", &Map.new(&1, fn {key, member} -> {key, Map.delete(member, "evidence")} end))
    fenced_checkpoint(f, %{"parent_close_intent" => intent})
    assert {:ok, _} = TaskExecutionConfig.prepare(f.parent, Keyword.put(f.opts, :completed_plan_read, true))
    assert {:ok, %{"status" => "confirmed"}} = TaskPlanManifest.recover_closed(f.parent, f.opts)
    baseline = current(f)["parent_close_intent"]

    for field <- ~w(source parent_description parent_notes) do
      bad = Map.put(baseline, field, if(field == "parent_notes", do: [], else: "changed"))
      fenced_checkpoint(f, %{"parent_close_intent" => bad})
      assert {:error, _} = TaskExecutionConfig.prepare(f.parent, Keyword.put(f.opts, :completed_plan_read, true))
    end

    fenced_checkpoint(f, %{"parent_close_intent" => baseline})
    append_parent_note(f, note(9000, 3, "Ordinary discussion", "2026-10-18T00:01:00Z"))
    assert {:ok, %{"status" => "inconsistent"}} = TaskPlanManifest.recover_closed(f.parent, f.opts)
  end
end
