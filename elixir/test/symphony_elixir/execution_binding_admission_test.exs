defmodule SymphonyElixir.ExecutionBindingAdmissionTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.{RunJournal, TaskExecution, TaskPlan, TaskWorkflow, WorkRef}

  test "a published P1 and natural authorizer reply admit a developer with verifiable authority" do
    work = %{"provider" => "github", "host" => "github.test", "repository_id" => "10", "kind" => "issue", "number" => 2}
    parent = %{work | "number" => 1}
    child = contract(work, parent)
    root = contract(parent, nil)

    {:ok, plan} =
      TaskPlan.seal(%{
        "parent" => parent,
        "contract_sha" => root["contract_sha"],
        "authorizer" => "1",
        "criteria" => ["result"],
        "members" => [%{"work" => work, "contract_sha" => child["contract_sha"], "criteria" => ["result"], "budget_ms" => 100_000, "human_gate" => false}],
        "dependencies" => [],
        "integration" => work,
        "budget_ms" => 100_000
      })

    candidate = %{"label" => "P1", "revision" => plan["revision"], "authorizer" => "1", "data" => %{}}
    published = note(5, 99, "计划 P1\n<!-- symphony-candidate " <> Jason.encode!(candidate) <> " -->", "2026-10-18T00:00:00Z")
    reply = note(6, 1, "按 P1 执行", "2026-10-18T00:00:01Z")
    base = "/repos/team/repo"
    url = "https://github.test/team/repo"

    objects = %{
      base => %{"id" => 10, "full_name" => "team/repo", "html_url" => url},
      "/user" => %{"id" => 99},
      (base <> "/issues/1") => issue(1, url, block(root) <> "\n<!-- symphony-plan " <> Jason.encode!(plan) <> " -->"),
      (base <> "/issues/2") => issue(2, url, block(child)),
      (base <> "/issues/1/comments") => [published, reply],
      (base <> "/issues/2/comments") => []
    }

    request = fn "github", "GET", path, _, _ -> {:ok, %{status: 200, body: Map.fetch!(objects, path)}} end

    repository = %{
      "provider" => "github",
      "host" => "github.test",
      "repository_id" => "10",
      "path" => "team/repo",
      "api_url" => "https://github.test/api/v3",
      "credential" => "$UNUSED_BINDING_FIXTURE"
    }

    policy = %{"engine_actor" => "99", "max_repairs" => 2, "max_retries" => 2, "checks" => %{"test" => %{"kind" => "review"}}}
    opts = [repositories: [repository], request: request, policy: policy]
    journal_root = Path.join(System.tmp_dir!(), "natural-admission-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(journal_root) end)
    directory = RunJournal.directory(journal_root, WorkRef.key(work))
    executions = %{WorkRef.key(work) => %{directory: directory, policy: policy}}

    assert {:ok, admitted} = TaskExecution.admit(parent, work, executions, opts)
    assert admitted.flow["started"]
    assert admitted.record["execution_generation"] == 1
    assert %{"candidate_source" => source, "candidate_digest" => digest, "label" => "P1"} = admitted.record["execution_binding"]["authority"]
    assert source == SymphonyElixir.TaskDecision.source_ref(published)
    assert digest == TaskWorkflow.digest(candidate)
    assert admitted.record["execution_binding"]["authority"] == admitted.plan.authority
  end

  defp contract(work, parent) do
    scope = %{
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

    Map.put(scope, "contract_sha", TaskWorkflow.digest(scope))
  end

  defp block(scope), do: "<!-- symphony-contract " <> Jason.encode!(scope) <> " -->"

  defp issue(number, url, body) do
    %{"id" => number + 100, "number" => number, "body" => body, "state" => "open", "assignees" => [%{"id" => 1}], "html_url" => url <> "/issues/#{number}"}
  end

  defp note(id, actor, body, at) do
    %{"id" => id, "body" => body, "author" => %{"id" => actor}, "user" => %{"id" => actor}, "created_at" => at, "updated_at" => at}
  end
end
