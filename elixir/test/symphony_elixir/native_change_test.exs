defmodule SymphonyElixir.NativeChangeTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.{GitArtifact, NativeWork, TaskDelivery}

  defp fixture(provider) do
    work = %{"provider" => provider, "host" => provider <> ".test", "repository_id" => "10", "kind" => if(provider == "github", do: "pr", else: "mr"), "number" => 7}
    url = "https://#{provider}.test/team/repo"
    head = String.duplicate("a", 40)
    final = String.duplicate("b", 40)

    repository =
      Map.take(work, ~w(provider host repository_id))
      |> Map.merge(%{"path" => "team/repo", "api_url" => "https://#{provider}.test/api/" <> if(provider == "github", do: "v3", else: "v4"), "credential" => "$UNUSED_CHANGE"})

    prefix = if provider == "github", do: "/repos/team/repo", else: "/projects/team%2Frepo"
    native = if provider == "github", do: %{"id" => 10, "full_name" => "team/repo", "html_url" => url}, else: %{"id" => 10, "path_with_namespace" => "team/repo", "web_url" => url}

    raw =
      if provider == "github" do
        %{
          "id" => 70,
          "number" => 7,
          "html_url" => url <> "/pull/7",
          "head" => %{"sha" => head, "ref" => "feature", "repo" => %{"id" => 10}},
          "base" => %{"ref" => "main", "repo" => %{"id" => 10}},
          "state" => "open",
          "merged" => false,
          "merged_at" => nil,
          "merge_commit_sha" => final
        }
      else
        %{
          "id" => 70,
          "iid" => 7,
          "web_url" => url <> "/-/merge_requests/7",
          "sha" => head,
          "source_branch" => "feature",
          "target_branch" => "main",
          "project_id" => 10,
          "source_project_id" => 10,
          "target_project_id" => 10,
          "state" => "opened",
          "merged_at" => nil,
          "merge_commit_sha" => final
        }
      end

    state = start_supervised!({Agent, fn -> raw end}, id: make_ref())
    path = prefix <> if(provider == "github", do: "/pulls/7", else: "/merge_requests/7")

    request = fn ^provider, "GET", requested, %{}, _ ->
      body =
        case requested do
          ^prefix -> native
          ^path -> Agent.get(state, & &1)
        end

      {:ok, %{status: 200, body: body}}
    end

    artifact = %{"id" => "output", "kind" => work["kind"], "version" => head, "source" => GitArtifact.source_ref(work, head), "target" => work, "target_branch" => "main"}
    opts = [repositories: [repository], request: request]
    %{work: work, state: state, raw: raw, head: head, final: final, artifact: artifact, path: path, opts: opts}
  end

  defp merge(f) do
    Agent.update(f.state, fn raw ->
      Map.merge(raw, %{"state" => if(f.work["provider"] == "github", do: "closed", else: "merged"), "merged" => true, "merged_at" => "2026-10-18T00:00:00Z"})
    end)
  end

  test "branch resolution binds the registered repository, exact encoded name and matching native commit reads" do
    for provider <- ["github", "gitlab"] do
      f = fixture(provider)
      prefix = if provider == "github", do: "/repos/team/repo/branches/", else: "/projects/team%2Frepo/repository/branches/"
      key = if provider == "github", do: "sha", else: "id"
      branch = "release/next"
      path = prefix <> "release%2Fnext"
      body = %{"name" => branch, "commit" => %{key => f.head}}
      reads = start_supervised!({Agent, fn -> [] end}, id: make_ref())

      request = fn p, method, target, query, settings ->
        Agent.update(reads, &(&1 ++ [target]))

        if target == path do
          {:ok, %{status: 200, body: body}}
        else
          f.opts[:request].(p, method, target, query, settings)
        end
      end

      assert {:ok, snapshot} = NativeWork.read_branch(f.work, branch, Keyword.put(f.opts, :request, request))
      assert snapshot["repository"] == Map.take(f.work, ~w(provider host repository_id))
      assert snapshot["branch"] == branch
      assert snapshot["revision"] == f.head
      assert snapshot["source"] == "branch:" <> SymphonyElixir.TaskWorkflow.digest(Map.delete(snapshot, "source"))
      assert Enum.count(Agent.get(reads, & &1), &(&1 == path)) == 2

      for invalid <- [nil, "", <<0>>] do
        assert {:error, :invalid_native_branch} = NativeWork.read_branch(f.work, invalid, f.opts)
      end

      assert {:error, :invalid_work_ref} = NativeWork.read_branch(%{}, branch, f.opts)
      assert {:error, :unregistered_plan_repository} = NativeWork.read_branch(%{f.work | "repository_id" => "99"}, branch, f.opts)

      invalid = [nil, %{}, %{body | "name" => "other"}, %{body | "commit" => %{key => "main"}}, %{body | "commit" => nil}]

      for malformed <- invalid do
        request = fn p, method, target, query, settings ->
          if target == path do
            {:ok, %{status: 200, body: malformed}}
          else
            f.opts[:request].(p, method, target, query, settings)
          end
        end

        assert {:error, :native_branch_incomplete} = NativeWork.read_branch(f.work, branch, Keyword.put(f.opts, :request, request))
      end

      Agent.update(reads, fn _ -> [] end)

      request = fn p, method, target, query, settings ->
        if target == path do
          revision =
            Agent.get_and_update(reads, fn list ->
              {if(list == [], do: f.head, else: f.final), [target | list]}
            end)

          {:ok, %{status: 200, body: put_in(body, ["commit", key], revision)}}
        else
          f.opts[:request].(p, method, target, query, settings)
        end
      end

      assert {:error, :native_branch_changed} = NativeWork.read_branch(f.work, branch, Keyword.put(f.opts, :request, request))
      Agent.update(reads, fn _ -> [] end)

      request = fn p, method, target, query, settings ->
        if target == path do
          Agent.update(reads, &[target | &1])
          {:ok, %{status: 200, body: body}}
        else
          {:ok, response} = f.opts[:request].(p, method, target, query, settings)

          if length(Agent.get(reads, & &1)) == 2,
            do: {:ok, %{response | body: Map.put(response.body, "id", 999)}},
            else: {:ok, response}
        end
      end

      result = NativeWork.read_branch(f.work, branch, Keyword.put(f.opts, :request, request))
      assert {:error, :native_repository_mismatch} = result
    end
  end

  test "native merge facts distinguish test SHAs, unmerged closure, transformed versions and verified final targets" do
    for provider <- ["github", "gitlab"] do
      f = fixture(provider)
      work = %{f.work | "kind" => "issue"}
      assert {:ok, snapshot} = NativeWork.read_change(f.work, f.opts)
      assert snapshot.facts["revision"] == nil
      assert {:ok, %{status: "awaiting_merge", receipt: nil}} = TaskDelivery.read(work, f.artifact, f.opts)
      Agent.update(f.state, &Map.put(&1, "state", "closed"))
      assert {:ok, %{status: "closed_unmerged"}} = TaskDelivery.read(work, f.artifact, f.opts)
      merge(f)
      assert {:ok, %{status: "verification_required", receipt: nil}} = TaskDelivery.read(work, f.artifact, f.opts)
      final = %{f.artifact | "version" => f.final, "source" => GitArtifact.source_ref(work, f.final)}
      assert {:ok, %{status: "delivered", receipt: receipt}} = TaskDelivery.read(work, final, f.opts)
      assert receipt["delivered_version"] == f.final
      assert receipt["head"] == f.head
      assert receipt["source"] == receipt["mapping"]
      assert {:error, :delivery_target_branch_changed} = TaskDelivery.read(work, Map.put(final, "target_branch", "other"), f.opts)

      if provider == "gitlab" do
        Agent.update(f.state, &(&1 |> Map.put("merge_commit_sha", nil) |> Map.put("squash_commit_sha", f.final)))
        assert {:ok, %{status: "delivered"}} = TaskDelivery.read(work, final, f.opts)
      end

      assert {:error, :expected_change} = NativeWork.read_change(work, f.opts)
      assert {:error, :invalid_work_ref} = NativeWork.read_change(%{}, f.opts)
      assert {:error, :delivery_target_unavailable} = TaskDelivery.read(work, Map.delete(final, "target"), f.opts)
      assert {:error, :delivery_source_mismatch} = TaskDelivery.read(work, Map.put(final, "source", "invented"), f.opts)
      changed = %{final | "version" => String.duplicate("c", 40), "source" => GitArtifact.source_ref(work, String.duplicate("c", 40))}
      assert {:error, :delivery_candidate_changed} = TaskDelivery.read(work, changed, f.opts)
    end
  end

  test "source forks are distinct from target repositories and incomplete native facts do not become delivery" do
    for provider <- ["github", "gitlab"] do
      f = fixture(provider)
      fork = if provider == "github", do: put_in(f.raw, ["head", "repo", "id"], 11), else: Map.put(f.raw, "source_project_id", 11)
      Agent.update(f.state, fn _ -> fork end)
      assert {:ok, snapshot} = NativeWork.read_change(f.work, f.opts)
      assert snapshot.facts["source_repository"]["repository_id"] == "11"
      assert {:error, :delivery_source_repository_mismatch} = TaskDelivery.read(f.work, f.artifact, f.opts)
      merge(f)
      final = %{f.artifact | "version" => f.final, "source" => GitArtifact.source_ref(f.work, f.final)}
      assert {:ok, %{status: "delivered"}} = TaskDelivery.read(f.work, final, f.opts)
      merged = Agent.get(f.state, & &1)

      for raw <- [nil, Map.put(merged, "id", nil), Map.put(merged, "merged_at", "not-a-time"), Map.put(merged, "merge_commit_sha", nil)] do
        Agent.update(f.state, fn _ -> raw end)
        assert {:error, :native_change_incomplete} = NativeWork.read_change(f.work, f.opts)
      end

      inconsistent = Map.merge(f.raw, %{"state" => "unknown", "merged" => nil})
      Agent.update(f.state, fn _ -> inconsistent end)
      assert {:error, :native_change_incomplete} = NativeWork.read_change(f.work, f.opts)
      missing_source = if provider == "github", do: put_in(f.raw, ["head", "repo", "id"], nil), else: Map.put(f.raw, "source_project_id", nil)
      Agent.update(f.state, fn _ -> missing_source end)
      assert {:error, :native_change_incomplete} = NativeWork.read_change(f.work, f.opts)

      if provider == "github" do
        for head <- [nil, "malformed", %{"repo" => "malformed"}] do
          Agent.update(f.state, fn _ -> Map.put(f.raw, "head", head) end)
          assert {:error, :native_change_incomplete} = NativeWork.read_change(f.work, f.opts)
        end
      end
    end
  end

  test "delivery reads fence concurrent target changes and native access errors" do
    f = fixture("github")

    request = fn provider, method, path, query, settings ->
      result = f.opts[:request].(provider, method, path, query, settings)
      if path == f.path, do: Agent.update(f.state, &put_in(&1["base"]["ref"], "changed"))
      result
    end

    opts = Keyword.put(f.opts, :request, request)
    assert {:error, :native_change_changed} = NativeWork.read_change(f.work, opts)
    bad = Keyword.put(f.opts, :request, fn _, _, _, _, _ -> {:error, :offline} end)
    assert {:error, :native_read_failed} = TaskDelivery.read_candidate(f.work, %{"artifacts" => [f.artifact]}, bad)
    denied = Keyword.put(f.opts, :request, fn _, _, _, _, _ -> {:ok, %{status: 403, body: %{}}} end)
    assert {:error, {:native_read_status, 403}} = NativeWork.read_change(f.work, denied)
  end
end
