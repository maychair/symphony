defmodule SymphonyElixir.TaskPlanPreflightTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.{NativeWork, TaskDecision, TaskPlan, TaskPlanPreflight, TaskWorkflow, WorkRef}
  alias SymphonyElixir.Tracker.Issue

  defp work(provider, repo, number),
    do: %{"provider" => provider, "host" => provider <> ".test", "repository_id" => repo, "kind" => "issue", "number" => number}

  defp repository(work, path) do
    Map.take(work, ~w(provider host repository_id))
    |> Map.merge(%{"path" => path, "api_url" => "https://#{work["host"]}/api/" <> if(work["provider"] == "github", do: "v3", else: "v4"), "credential" => "$PLAN_FIXTURE_TOKEN"})
  end

  defp scope(work, parent) do
    data = %{
      "schema_version" => 2,
      "work" => work,
      "parent" => parent,
      "goal" => "Deliver an observable result",
      "non_goals" => ["No extra scope"],
      "criteria" => ["result"],
      "criteria_details" => %{"result" => "The result reproduces the approved behavior"},
      "verification_checks" => %{"result" => ["review"]},
      "authorizer" => "1",
      "acceptance_mode" => if(is_nil(parent), do: "separate", else: "technical"),
      "acceptor" => if(is_nil(parent), do: "2", else: nil),
      "budget_ms" => 100,
      "deliverables" => [%{"id" => "output", "kind" => "report", "criteria" => ["result"]}]
    }

    Map.put(data, "contract_sha", TaskWorkflow.digest(data))
  end

  defp block(contract), do: "<!-- symphony-contract\n" <> Jason.encode!(contract) <> "\n-->"

  defp fixture do
    parent = work("github", "10", 1)
    child = work("gitlab", "20", 1)
    root_scope = scope(parent, nil)
    child_scope = scope(child, parent)
    member = %{"work" => child, "contract_sha" => child_scope["contract_sha"], "criteria" => ["result"], "budget_ms" => 100, "human_gate" => false}

    {:ok, plan} =
      TaskPlan.seal(%{
        "parent" => parent,
        "contract_sha" => root_scope["contract_sha"],
        "authorizer" => "1",
        "criteria" => ["result"],
        "members" => [member],
        "dependencies" => [],
        "integration" => child,
        "budget_ms" => 100
      })

    description = block(root_scope) <> "\n<!-- symphony-plan\n" <> Jason.encode!(plan) <> "\n-->"

    decision = %{
      "id" => 5,
      "body" => "Approved P1\n<!-- symphony-plan-decision " <> Jason.encode!(%{"action" => "authorize", "revision" => plan["revision"]}) <> " -->",
      "user" => %{"id" => 1},
      "created_at" => "2026-10-16T00:00:01Z",
      "updated_at" => "2026-10-16T00:00:01Z"
    }

    objects = %{
      {"github", "/repos/team/parent"} => %{"id" => 10, "full_name" => "team/parent", "html_url" => "https://github.test/team/parent"},
      {"github", "/repos/team/parent/issues/1"} => %{
        "id" => 1001,
        "number" => 1,
        "body" => description,
        "html_url" => "https://github.test/team/parent/issues/1",
        "state" => "open",
        "assignees" => [%{"id" => 1}]
      },
      {"github", "/repos/team/parent/issues/1/comments"} => [decision],
      {"gitlab", "/projects/team%2Fchild"} => %{"id" => 20, "path_with_namespace" => "team/child", "web_url" => "https://gitlab.test/team/child"},
      {"gitlab", "/projects/team%2Fchild/issues/1"} => %{
        "id" => 2001,
        "iid" => 1,
        "project_id" => 20,
        "description" => block(child_scope),
        "web_url" => "https://gitlab.test/team/child/-/issues/1",
        "state" => "opened",
        "assignees" => [%{"id" => 1}]
      },
      {"gitlab", "/projects/team%2Fchild/issues/1/notes"} => []
    }

    %{
      parent: parent,
      child: child,
      root_scope: root_scope,
      child_scope: child_scope,
      plan: plan,
      objects: objects,
      repositories: [repository(parent, "team/parent"), repository(child, "team/child")]
    }
  end

  defp options(fixture, rewrite \\ fn _, value -> value end) do
    request = fn provider, method, path, _query, settings ->
      assert method == "GET"
      assert settings.kind == provider
      {:ok, %{status: 200, body: rewrite.({provider, path}, Map.fetch!(fixture.objects, {provider, path}))}}
    end

    [repositories: fixture.repositories, roots: [fixture.parent], request: request]
  end

  test "one native approval resolves the whole cross-provider plan without an execution journal" do
    fixture = fixture()
    assert {:ok, result} = TaskPlanPreflight.inspect_plan(fixture.parent, options(fixture))
    assert result.authority["work"] == fixture.parent
    assert result.authority["revision"] == fixture.plan["revision"]
    assert result.members[WorkRef.key(fixture.child)].contract == fixture.child_scope
    [note] = result.parent.notes
    assert result.authority["source"] == TaskDecision.source_ref(note)

    issue = %Issue{id: "1", url: "https://github.test/team/parent/issues/1", description: fixture.objects[{"github", "/repos/team/parent/issues/1"}]["body"], native_ref: %{}, dispatchable: true}
    [projected] = TaskPlanPreflight.project([TaskPlan.project(issue)], options(fixture))
    assert projected.native_ref["plan_preflight"]["status"] == "approved"
    refute Issue.routable?(projected, [])
    [unclassified] = TaskPlanPreflight.project([issue], options(fixture))
    refute unclassified.dispatchable
    [copy] = TaskPlanPreflight.project([TaskPlan.project(%{issue | url: "https://github.test/team/parent/issues/2"})], options(fixture))
    assert copy.native_ref["plan_preflight"]["reason"] == "parent_projection_changed"
    [unconfigured] = TaskPlanPreflight.project([TaskPlan.project(issue)], Keyword.put(options(fixture), :roots, []))
    assert unconfigured.native_ref["plan_preflight"]["status"] == "unconfigured"
  end

  test "the execution registry follows native cross-provider membership and requires the member repository policy" do
    f = fixture()
    root = Path.join(System.tmp_dir!(), "configured-plan-#{System.unique_integer([:positive])}")
    policy = %{"engine_actor" => "99", "max_retries" => 2, "max_repairs" => 1, "checks" => %{"review" => %{"kind" => "review"}}}
    [parent, child] = f.repositories
    catalog = [parent, Map.put(child, "execution", %{"policy" => policy})]
    opts = options(f) |> Keyword.put(:journal_root, root) |> Keyword.put(:repositories, catalog)
    assert {:ok, configured} = SymphonyElixir.TaskExecutionConfig.prepare(f.parent, opts)
    assert Map.keys(configured.executions) == [WorkRef.key(f.child)]
    assert configured.executions[WorkRef.key(f.child)].policy == policy
    assert configured.plan.authority["work"] == f.parent
    refute File.exists?(root)

    invalid = Keyword.put(opts, :repositories, [Map.put(parent, "execution", %{"policy" => policy}), child])
    result = SymphonyElixir.TaskExecutionConfig.prepare(f.parent, invalid)
    assert {:error, {:member_execution_configuration, work, :missing_repository_execution_policy}} = result
    assert work == f.child
    refute File.exists?(root)
  end

  test "unregistered, duplicate and foreign endpoints fail before any HTTP call" do
    fixture = fixture()
    no_request = fn _, _, _, _, _ -> flunk("scope failure made an HTTP request") end
    assert {:error, :unregistered_plan_repository} = NativeWork.read(fixture.parent, repositories: [], request: no_request)
    assert {:error, :invalid_plan_repositories} = NativeWork.read(fixture.parent, repositories: nil, request: no_request)
    [repository | _] = fixture.repositories
    assert {:error, :ambiguous_plan_repository} = NativeWork.read(fixture.parent, repositories: [repository, repository], request: no_request)

    for altered <- [%{"api_url" => "https://foreign.test/api/v3"}, %{"credential" => "literal-secret"}, %{"path" => "team/../repo"}, %{"api_url" => "https://github.test/api/v3?token=x"}] do
      assert {:error, :invalid_plan_repository} = NativeWork.read(fixture.parent, repositories: [Map.merge(repository, altered)], request: no_request)
    end

    assert {:error, :invalid_work_ref} = NativeWork.read(%{}, repositories: [], request: no_request)
    assert {:error, :expected_issue} = NativeWork.read(%{fixture.parent | "kind" => "pr"}, repositories: [], request: no_request)
  end

  test "same-number foreign repositories, PRs and malformed payloads cannot become plan Issues" do
    fixture = fixture()

    for {key, replacement, error} <- [
          {{"github", "/repos/team/parent"}, %{"id" => 99}, :native_repository_mismatch},
          {{"github", "/repos/team/parent"}, [], :native_repository_mismatch},
          {{"github", "/repos/team/parent/issues/1"}, %{"pull_request" => %{}}, :native_issue_mismatch},
          {{"github", "/repos/team/parent/issues/1"}, [], :native_issue_mismatch},
          {{"github", "/repos/team/parent/issues/1"}, %{"html_url" => "https://github.test/foreign/repo/issues/1"}, :native_issue_mismatch},
          {{"github", "/repos/team/parent/issues/1/comments"}, %{}, :native_comments_invalid},
          {{"github", "/repos/team/parent/issues/1/comments"}, [nil], :native_comments_invalid}
        ] do
      rewrite = fn current, value -> if current == key, do: if(is_map(replacement) and is_map(value), do: Map.merge(value, replacement), else: replacement), else: value end
      assert {:error, ^error} = NativeWork.read(fixture.parent, options(fixture, rewrite))
    end
  end

  test "a changed child contract restricts the member instead of the whole plan" do
    fixture = fixture()
    key = {"gitlab", "/projects/team%2Fchild/issues/1"}
    data = fixture.child_scope |> Map.delete("contract_sha") |> Map.put("goal", "Expanded scope")
    edited = Map.put(data, "contract_sha", TaskWorkflow.digest(data))
    opts = options(fixture, fn current, value -> if current == key, do: Map.put(value, "description", block(edited)), else: value end)

    assert {:ok, %{members: members, restricted: restricted}} = TaskPlanPreflight.inspect_plan(fixture.parent, opts)
    assert members == %{}
    assert restricted == %{WorkRef.key(fixture.child) => %{work: fixture.child, reason: :member_contract_changed}}
  end

  test "an unavailable repository still prevents any partial plan result" do
    fixture = fixture()

    opts = options(fixture) |> Keyword.put(:repositories, [hd(fixture.repositories)])
    assert {:error, {:unregistered_plan_repository, _}} = TaskPlanPreflight.inspect_plan(fixture.parent, opts)
    [blocked] = TaskPlanPreflight.project([TaskPlan.project(%Issue{description: fixture.objects[{"github", "/repos/team/parent/issues/1"}]["body"]})], opts)
    assert blocked.native_ref["plan_preflight"] == %{"status" => "blocked", "reason" => "unregistered_plan_repository"}
  end

  test "edited, foreign and stale approvals cannot grant the plan" do
    fixture = fixture()

    for change <- [
          %{"user" => %{"id" => 99}},
          %{"updated_at" => "2026-10-16T00:00:03Z"},
          %{"body" => "<!-- symphony-plan-decision {\"action\":\"authorize\",\"revision\":\"old\"} -->"},
          %{"body" => "<!-- symphony-plan-decision broken -->"}
        ] do
      rewrite = fn
        {"github", "/repos/team/parent/issues/1/comments"}, [note] -> [Map.merge(note, change)]
        _, value -> value
      end

      assert {:error, _} = TaskPlanPreflight.inspect_plan(fixture.parent, options(fixture, rewrite))
    end
  end

  test "a native parent pause preserves the grant but projects a restriction instead of renewed approval" do
    f = fixture()
    path = {"github", "/repos/team/parent/issues/1/comments"}
    [approval] = f.objects[path]
    body = "<!-- symphony-plan-decision " <> Jason.encode!(%{"action" => "pause", "revision" => f.plan["revision"]}) <> " -->"
    pause = %{approval | "id" => 6, "body" => body, "created_at" => "2026-10-16T00:00:02Z", "updated_at" => "2026-10-16T00:00:02Z"}
    changed = put_in(f.objects[path], [approval, pause])
    assert {:ok, result} = TaskPlanPreflight.inspect_plan(f.parent, options(changed))
    assert result.authority["source"] == TaskDecision.source_ref(Map.put(approval, "author", approval["user"]))
    assert [%{"kind" => "pause"}] = result.controls.restrictions
    issue = TaskPlan.project(%Issue{url: result.parent.url, description: result.parent.description})
    [projected] = TaskPlanPreflight.project([issue], options(changed))
    assert projected.native_ref["plan_preflight"]["status"] == "restricted"
    assert projected.native_ref["plan_preflight"]["restrictions"] == ["pause"]
  end

  test "cross-repository credentials are collected for executor redaction" do
    fixture = fixture()
    assert NativeWork.secret_environment_names(%{provider: %{"plan_repositories" => fixture.repositories}}) == ["PLAN_FIXTURE_TOKEN"]
    settings = %SymphonyElixir.Config.Schema.Tracker{provider: %{"plan_repositories" => fixture.repositories}}
    assert NativeWork.secret_environment_names(settings) == ["PLAN_FIXTURE_TOKEN"]
    assert NativeWork.secret_environment_names(%{provider: %{}}) == []
    assert NativeWork.secret_environment_names(%{provider: %{"plan_repositories" => [%{"credential" => "$bad-name"}, %{}]}}) == []
  end

  test "comment pagination is complete and duplicate pages cannot substitute for missing history" do
    fixture = fixture()
    base_request = options(fixture)[:request]
    template = hd(fixture.objects[{"github", "/repos/team/parent/issues/1/comments"}])

    request = fn provider, method, path, query, settings ->
      if String.ends_with?(path, "/comments") do
        ids = if query["page"] == 1, do: 1..100, else: [101]
        {:ok, %{status: 200, body: Enum.map(ids, &Map.put(template, "id", &1))}}
      else
        base_request.(provider, method, path, query, settings)
      end
    end

    assert {:ok, result} = NativeWork.read(fixture.parent, Keyword.put(options(fixture), :request, request))
    assert length(result.notes) == 101
    duplicate = fn provider, method, path, query, settings -> request.(provider, method, path, Map.put(query, "page", 1), settings) end
    assert {:error, :native_comments_invalid} = NativeWork.read(fixture.parent, Keyword.put(options(fixture), :request, duplicate))
  end

  test "concurrent scope edits and native read failures produce no usable snapshot" do
    fixture = fixture()
    base_request = options(fixture)[:request]
    {:ok, calls} = Agent.start_link(fn -> 0 end)
    on_exit(fn -> if Process.alive?(calls), do: Agent.stop(calls) end)

    request = fn provider, method, path, query, settings ->
      result = base_request.(provider, method, path, query, settings)

      if path == "/repos/team/parent/issues/1" do
        count = Agent.get_and_update(calls, &{&1, &1 + 1})
        if count == 0, do: result, else: put_in(result, [Access.elem(1), :body, "body"], "Changed scope")
      else
        result
      end
    end

    assert {:error, :native_issue_changed} = NativeWork.read(fixture.parent, Keyword.put(options(fixture), :request, request))

    failures = [{:unavailable, :native_read_failed}, {{:ok, %{status: 403}}, {:native_read_status, 403}}]

    for {response, error} <- failures do
      request = fn _, _, _, _, _ -> response end
      opts = Keyword.put(options(fixture), :request, request)
      assert {:error, ^error} = NativeWork.read(fixture.parent, opts)
    end
  end

  test "a parent authorization edited while members are read invalidates the whole preflight" do
    fixture = fixture()
    base_request = options(fixture)[:request]
    {:ok, calls} = Agent.start_link(fn -> 0 end)
    on_exit(fn -> if Process.alive?(calls), do: Agent.stop(calls) end)

    request = fn provider, method, path, query, settings ->
      result = base_request.(provider, method, path, query, settings)

      if String.ends_with?(path, "/comments") do
        count = Agent.get_and_update(calls, &{&1, &1 + 1})
        if count == 0, do: result, else: put_in(result, [Access.elem(1), :body, Access.at(0), "body"], "Approval withdrawn")
      else
        result
      end
    end

    assert {:error, :parent_changed_during_preflight} = TaskPlanPreflight.inspect_plan(fixture.parent, Keyword.put(options(fixture), :request, request))
  end

  test "dependency edges must resolve to actual producer artifacts and their covered criteria" do
    fixture = fixture()
    integration = %{fixture.child | "number" => 2}
    integrated_scope = scope(integration, fixture.parent)
    root_data = fixture.root_scope |> Map.delete("contract_sha") |> Map.put("budget_ms", 200)
    root_scope = Map.put(root_data, "contract_sha", TaskWorkflow.digest(root_data))
    member = %{hd(fixture.plan["members"]) | "work" => integration, "contract_sha" => integrated_scope["contract_sha"]}
    plan = %{fixture.plan | "members" => fixture.plan["members"] ++ [member], "budget_ms" => 200, "contract_sha" => root_scope["contract_sha"], "integration" => integration}
    child_raw = fixture.objects[{"gitlab", "/projects/team%2Fchild/issues/1"}]
    integration_raw = %{child_raw | "iid" => 2, "description" => block(integrated_scope), "web_url" => "https://gitlab.test/team/child/-/issues/2"}
    objects = fixture.objects |> Map.put({"gitlab", "/projects/team%2Fchild/issues/2"}, integration_raw) |> Map.put({"gitlab", "/projects/team%2Fchild/issues/2/notes"}, [])

    for {artifact, criteria, valid} <- [{"output", ["result"], true}, {"missing", ["result"], false}, {"output", ["uncovered"], false}] do
      edge = %{"from" => fixture.child, "to" => integration, "artifact" => artifact, "stage" => "verified", "criteria" => criteria}
      {:ok, sealed} = TaskPlan.seal(%{plan | "dependencies" => [edge]})
      description = block(root_scope) <> "\n<!-- symphony-plan " <> Jason.encode!(sealed) <> " -->"
      objects = put_in(objects, [{"github", "/repos/team/parent/issues/1"}, "body"], description)

      objects =
        update_in(objects, [{"github", "/repos/team/parent/issues/1/comments"}], fn [note] ->
          [%{note | "body" => "<!-- symphony-plan-decision " <> Jason.encode!(%{"action" => "authorize", "revision" => sealed["revision"]}) <> " -->"}]
        end)

      result = TaskPlanPreflight.inspect_plan(fixture.parent, options(%{fixture | objects: objects}))

      if valid do
        assert {:ok, %{members: members}} = result
        assert map_size(members) == 2
      else
        assert result == {:error, :unresolved_dependency_artifact}
      end
    end
  end

  test "incomplete semantic scope cannot be approved by retaining a matching checksum" do
    fixture = fixture()
    child = fixture.child
    key = WorkRef.key(child)

    changes = [
      %{"acceptance_mode" => "automatic"},
      %{"criteria" => [], "criteria_details" => %{}},
      %{"deliverables" => []},
      %{"deliverables" => [%{"id" => "output"}]},
      %{"deliverables" => [%{"id" => "output", "kind" => "mr", "criteria" => ["result"]}]},
      %{"deliverables" => [%{"id" => "output", "kind" => "mr", "criteria" => ["result"], "target_branch" => " "}]},
      %{"criteria_details" => %{"result" => ""}},
      %{"non_goals" => nil}
    ]

    for change <- changes do
      data = fixture.child_scope |> Map.delete("contract_sha") |> Map.merge(change)
      contract = Map.put(data, "contract_sha", TaskWorkflow.digest(data))

      rewrite = fn
        {"gitlab", "/projects/team%2Fchild/issues/1"}, raw -> Map.put(raw, "description", block(contract))
        _, value -> value
      end

      assert {:ok, %{members: members, restricted: restricted}} = TaskPlanPreflight.inspect_plan(fixture.parent, options(fixture, rewrite))
      assert members == %{}
      assert %{^key => %{reason: :incomplete_sealed_scope, work: ^child}} = restricted
    end

    rewrite = fn
      {"gitlab", "/projects/team%2Fchild/issues/1"}, raw -> Map.put(raw, "assignees", [])
      _, value -> value
    end

    assert {:ok, %{members: members, restricted: restricted}} = TaskPlanPreflight.inspect_plan(fixture.parent, options(fixture, rewrite))
    assert members == %{}
    assert %{^key => %{reason: :incomplete_sealed_scope, work: ^child}} = restricted
  end

  test "a plan may omit its aggregate cap while every member still has a sealed finite allocation" do
    fixture = fixture()
    data = fixture.root_scope |> Map.delete("contract_sha") |> Map.put("budget_ms", nil)
    root = Map.put(data, "contract_sha", TaskWorkflow.digest(data))
    {:ok, plan} = TaskPlan.seal(%{fixture.plan | "contract_sha" => root["contract_sha"], "budget_ms" => nil})
    description = block(root) <> "\n<!-- symphony-plan " <> Jason.encode!(plan) <> " -->"

    rewrite = fn
      {"github", "/repos/team/parent/issues/1"}, raw ->
        Map.put(raw, "body", description)

      {"github", "/repos/team/parent/issues/1/comments"}, [note] ->
        [Map.put(note, "body", String.replace(note["body"], fixture.plan["revision"], plan["revision"]))]

      _, value ->
        value
    end

    assert {:ok, result} = TaskPlanPreflight.inspect_plan(fixture.parent, options(fixture, rewrite))
    assert result.plan["budget_ms"] == nil
    assert result.members[WorkRef.key(fixture.child)].contract["budget_ms"] == 100
  end

  test "native API endpoint and transport identities cannot redirect repository reads" do
    fixture = fixture()
    [repository | _] = fixture.repositories
    no_request = fn _, _, _, _, _ -> flunk("invalid endpoint reached HTTP") end

    for endpoint <- [nil, "/api/v3", "ftp://github.test:443/api/v3"] do
      repository = Map.put(repository, "api_url", endpoint)
      assert {:error, :invalid_plan_repository} = NativeWork.read(fixture.parent, repositories: [repository], request: no_request)
    end

    public = %{fixture.parent | "host" => "github.com"}
    public_repository = %{repository | "host" => "github.com", "api_url" => "https://api.github.com"}

    rewrite = fn _, value ->
      if is_map(value) and is_binary(value["html_url"]), do: Map.update!(value, "html_url", &String.replace(&1, "github.test", "github.com")), else: value
    end

    opts = options(fixture, rewrite) |> Keyword.put(:repositories, [public_repository])
    assert {:ok, %{work: ^public}} = NativeWork.read(public, opts)

    work = %{fixture.child | "host" => "gitlab.test:80"}
    repository = %{List.last(fixture.repositories) | "host" => work["host"], "api_url" => "http://gitlab.test/api/v4"}
    assert {:error, :invalid_plan_repository} = NativeWork.read(work, repositories: [repository], request: no_request)
    assert {:ok, _} = NativeWork.resolve(work, [Map.put(repository, "allow_insecure_http", true)])
  end

  test "missing native URLs and malformed final reads cannot produce identity evidence" do
    fixture = fixture()

    rewrite = fn
      {"github", "/repos/team/parent"}, raw -> Map.delete(raw, "html_url")
      _, value -> value
    end

    assert {:error, :native_repository_mismatch} = NativeWork.read(fixture.parent, options(fixture, rewrite))
    base = options(fixture)[:request]
    {:ok, calls} = Agent.start_link(fn -> 0 end)
    on_exit(fn -> if Process.alive?(calls), do: Agent.stop(calls) end)

    request = fn provider, method, path, query, settings ->
      if path == "/repos/team/parent/issues/1" and Agent.get_and_update(calls, &{&1, &1 + 1}) > 0 do
        {:ok, %{status: 200, body: []}}
      else
        base.(provider, method, path, query, settings)
      end
    end

    assert {:error, :native_issue_changed} = NativeWork.read(fixture.parent, Keyword.put(options(fixture), :request, request))
  end

  test "large comment history fails closed at the configured read bound" do
    fixture = fixture()
    base = options(fixture)[:request]
    note = %{"id" => 1, "body" => "Native note", "author" => %{"id" => 1}}

    request = fn provider, method, path, query, settings ->
      if String.ends_with?(path, "/notes") do
        start = (query["page"] - 1) * 100 + 1
        {:ok, %{status: 200, body: Enum.map(start..(start + 99), &Map.put(note, "id", &1))}}
      else
        base.(provider, method, path, query, settings)
      end
    end

    assert {:error, :native_comments_limit} = NativeWork.read(fixture.child, Keyword.put(options(fixture), :request, request))
  end

  test "unconfirmed or spoofed plan manifest facts do not project accepted in preflight" do
    fixture = fixture()

    manifest_payload = %{
      "schema_version" => 2,
      "plan_revision" => fixture.plan["revision"],
      "criteria" => fixture.plan["criteria"],
      "integration" => fixture.child,
      "members" => [%{"work" => fixture.child, "criteria" => ["result"], "status" => "completed"}]
    }

    manifest_without_rev = manifest_payload
    manifest_with_rev = Map.put(manifest_payload, "revision", TaskWorkflow.digest(manifest_without_rev))

    manifest_body =
      "<!-- symphony-plan-manifest " <>
        Jason.encode!(manifest_with_rev) <>
        " -->"

    manifest_note = %{
      "id" => 6,
      "body" => manifest_body,
      "user" => %{"id" => 1},
      "created_at" => "2026-10-16T00:00:02Z",
      "updated_at" => "2026-10-16T00:00:02Z"
    }

    rewrite = fn
      {"github", "/repos/team/parent/issues/1/comments"}, notes -> notes ++ [manifest_note]
      _, val -> val
    end

    issue = %Issue{
      id: "1",
      url: "https://github.test/team/parent/issues/1",
      description: fixture.objects[{"github", "/repos/team/parent/issues/1"}]["body"],
      native_ref: %{},
      dispatchable: true
    }

    opts = options(fixture, rewrite)
    [projected] = TaskPlanPreflight.project([TaskPlan.project(issue)], opts)
    assert projected.native_ref["plan_preflight"]["manifest"]["status"] == "unconfirmed"
  end

  test "inspect_plan/1 default options uses configured catalog and preflight projects non-plan issue" do
    fixture = fixture()
    # non-plan issue returns unchanged when requires_plan_lifecycle? is false (L44)
    non_plan = %Issue{
      id: "non-plan-1",
      kind: :task,
      url: "https://github.test/team/parent/issues/999",
      description: "Simple task without plan markers",
      native_ref: %{},
      dispatchable: true
    }

    assert [^non_plan] = TaskPlanPreflight.project([non_plan])

    # inspect_plan with 1 arg default opts (L85)
    # when repositories are omitted, Keyword.get_lazy reads Config.settings!().tracker.provider["plan_repositories"]
    assert {:error, _} = TaskPlanPreflight.inspect_plan(fixture.parent)
  end

  test "preflight projection covers blocked evidence with atom, tuple, and other reason labels, and transitive restrictions" do
    fixture = fixture()
    child_key = WorkRef.key(fixture.child)

    # Transitive dependency restriction (L141) and edges/2 fallback when edge source is restricted (L216)
    # Let's create a plan with dependencies: child -> child2
    child2 = work("gitlab", "20", 2)
    child2_scope = scope(child2, fixture.parent)

    child2_member = %{
      "work" => child2,
      "contract_sha" => child2_scope["contract_sha"],
      "criteria" => ["result"],
      "budget_ms" => 100,
      "human_gate" => false
    }

    root_data = fixture.root_scope |> Map.delete("contract_sha") |> Map.put("budget_ms", 200)
    root_scope_200 = Map.put(root_data, "contract_sha", TaskWorkflow.digest(root_data))

    {:ok, chained_plan} =
      TaskPlan.seal(%{
        "parent" => fixture.parent,
        "contract_sha" => root_scope_200["contract_sha"],
        "authorizer" => "1",
        "criteria" => ["result"],
        "members" => [hd(fixture.plan["members"]), child2_member],
        "dependencies" => [%{"from" => fixture.child, "to" => child2, "artifact" => "report", "stage" => "verified", "criteria" => ["result"]}],
        "integration" => child2,
        "budget_ms" => 200
      })

    chained_description = block(root_scope_200) <> "\n<!-- symphony-plan\n" <> Jason.encode!(chained_plan) <> "\n-->"

    # child is restricted (e.g. member_contract_changed), child2 depends on child
    data = fixture.child_scope |> Map.delete("contract_sha") |> Map.put("goal", "Drifted")
    edited_child = Map.put(data, "contract_sha", TaskWorkflow.digest(data))

    chained_decision = %{
      "id" => 5,
      "body" => "Approved P1\n<!-- symphony-plan-decision " <> Jason.encode!(%{"action" => "authorize", "revision" => chained_plan["revision"]}) <> " -->",
      "user" => %{"id" => 1},
      "created_at" => "2026-10-16T00:00:01Z",
      "updated_at" => "2026-10-16T00:00:01Z"
    }

    objects =
      fixture.objects
      |> Map.put({"github", "/repos/team/parent/issues/1/comments"}, [chained_decision])
      |> Map.put({"github", "/repos/team/parent/issues/1"}, %{
        "id" => 1001,
        "number" => 1,
        "body" => chained_description,
        "html_url" => "https://github.test/team/parent/issues/1",
        "state" => "open",
        "assignees" => [%{"id" => 1}]
      })
      |> Map.put({"gitlab", "/projects/team%2Fchild/issues/1"}, %{
        "id" => 2001,
        "iid" => 1,
        "project_id" => 20,
        "description" => block(edited_child),
        "web_url" => "https://gitlab.test/team/child/-/issues/1",
        "state" => "opened",
        "assignees" => [%{"id" => 1}]
      })
      |> Map.put({"gitlab", "/projects/team%2Fchild/issues/2"}, %{
        "id" => 2002,
        "iid" => 2,
        "project_id" => 20,
        "description" => block(child2_scope),
        "web_url" => "https://gitlab.test/team/child/-/issues/2",
        "state" => "opened",
        "assignees" => [%{"id" => 1}]
      })
      |> Map.put({"gitlab", "/projects/team%2Fchild/issues/2/notes"}, [])

    f_chained = %{fixture | objects: objects, plan: chained_plan}
    opts = options(f_chained)

    # inspect_plan restricts child, transitively child2 (L141), and edges/2 skips checking child (L216)
    assert {:ok, %{restricted: restricted}} = TaskPlanPreflight.inspect_plan(fixture.parent, opts)
    assert Map.has_key?(restricted, WorkRef.key(fixture.child))
    assert %{reason: {:dependency_restricted, ^child_key}} = restricted[WorkRef.key(child2)]

    # And project it via project/2
    chained_issue = %Issue{
      id: "1",
      url: "https://github.test/team/parent/issues/1",
      description: chained_description,
      native_ref: %{},
      dispatchable: true
    }

    [projected] = TaskPlanPreflight.project([TaskPlan.project(chained_issue)], opts)
    assert projected.native_ref["plan_preflight"]["status"] == "restricted"
    blocked_entries = projected.native_ref["plan_preflight"]["blocked"]
    assert Enum.any?(blocked_entries, &(&1["work"] == WorkRef.key(child2)))
  end
end
