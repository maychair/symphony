defmodule SymphonyElixir.ExecutionBindingTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.{ExecutionBinding, RunJournal, TaskWorkflow}

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-role-#{System.pid()}-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  defp fixture_binding(role \\ "developer") do
    work = %{"provider" => "github", "host" => "github.test", "repository_id" => "1", "kind" => "issue", "number" => 2}
    revision = TaskWorkflow.digest("approved plan")

    %{
      "work" => work,
      "role" => role,
      "plan_revision" => revision,
      "contract_sha" => TaskWorkflow.digest("scope"),
      "policy_sha" => TaskWorkflow.digest("execution policy"),
      "authority" => %{"work" => %{work | "number" => 1}, "source" => "note:5@" <> TaskWorkflow.digest("approval"), "actor" => "1", "revision" => revision},
      "inputs" => [],
      "candidate" => if(role == "verifier", do: TaskWorkflow.digest("candidate"))
    }
  end

  defp stop(record, thread) do
    {:ok, record} = RunJournal.checkpoint(record, %{"thread_id" => thread, "turn_id" => thread <> "-turn", "thread_allocation_intent" => true, "native_stop_confirmed" => true})
    assert :ok = RunJournal.complete(record, "completed")
    record
  end

  test "developer, verifier and repair use separate generations without resetting consumed budget", %{root: root} do
    {:ok, developer} = RunJournal.admit(root, "2", execution_binding: fixture_binding())
    flow = TaskWorkflow.new(10_000, System.system_time(:millisecond)) |> Map.put("used_ms", 4_000)
    {:ok, developer} = RunJournal.checkpoint(developer, %{"workflow" => flow, "retry_count" => 1, "repair_count" => 2, "task_observation_error" => ":observation_timeout"})
    developer = stop(developer, "developer-thread")

    {:ok, verifier} = RunJournal.admit(root, "2", execution_binding: fixture_binding("verifier"))
    assert verifier["execution_generation"] == 2
    assert verifier["attempt_id"] != developer["attempt_id"]
    assert verifier["thread_id"] == nil
    assert verifier["turn_id"] == nil
    assert verifier["workflow"]["used_ms"] == 4_000
    assert verifier["retry_count"] == 1 and verifier["repair_count"] == 2
    assert [receipt] = verifier["execution_history"]
    assert receipt["thread_id"] == "developer-thread"
    assert receipt["native_stop_confirmed"]
    assert receipt["task_observation_error"] == ":observation_timeout"
    refute verifier["task_observation_error"]
    assert receipt["execution_binding"]["role"] == "developer"

    before = File.read!(Path.join(verifier["directory"], "run.json"))
    assert {:error, :native_thread_reused_across_generations} = RunJournal.checkpoint(verifier, %{"thread_id" => "developer-thread"})
    assert File.read!(Path.join(verifier["directory"], "run.json")) == before
    verifier = stop(verifier, "verifier-thread")
    {:ok, repair} = RunJournal.admit(root, "2", execution_binding: fixture_binding())
    assert repair["execution_generation"] == 3
    assert repair["workflow"]["used_ms"] == 4_000
    assert repair["thread_id"] == nil
    assert Enum.map(repair["execution_history"], & &1["thread_id"]) == ["developer-thread", "verifier-thread"]
    assert verifier["execution_binding"]["candidate"] == TaskWorkflow.digest("candidate")
  end

  test "retrying the same binding resumes its native thread, including after reordering fixed inputs", %{root: root} do
    base = fixture_binding()
    a = %{"work" => %{base["work"] | "number" => 3}, "artifact" => "a", "version" => "sha-a", "verification" => "receipt-a"}
    b = %{a | "artifact" => "b", "version" => "sha-b", "verification" => "receipt-b"}
    first = %{base | "inputs" => [a, b]}
    {:ok, record} = RunJournal.admit(root, "2", execution_binding: first)
    record = stop(record, "same-thread")
    {:ok, resumed} = RunJournal.admit(root, "2", execution_binding: %{first | "inputs" => [b, a]})
    assert resumed["execution_generation"] == 1
    assert resumed["thread_id"] == "same-thread"
    assert resumed["execution_binding_sha"] == record["execution_binding_sha"]
    assert resumed["execution_history"] == []
    assert {:error, :bound_native_thread_changed} = RunJournal.checkpoint(resumed, %{"thread_id" => "replacement"})
    assert {:error, :invalid_bound_native_thread} = RunJournal.checkpoint(resumed, %{"thread_id" => nil})
    assert {:ok, _} = RunJournal.checkpoint(resumed, %{"thread_id" => "same-thread"})
  end

  test "changed inputs cannot replace a live, unconfirmed or unrecorded native allocation", %{root: root} do
    for {thread, confirmed} <- [{"live", false}, {nil, false}, {nil, true}] do
      id = inspect({thread, confirmed})
      {:ok, record} = RunJournal.admit(root, id, execution_binding: fixture_binding())
      fields = %{"thread_allocation_intent" => true, "native_stop_confirmed" => confirmed}
      fields = if thread, do: Map.put(fields, "thread_id", thread), else: fields
      {:ok, record} = RunJournal.checkpoint(record, fields)
      assert :ok = RunJournal.complete(record, "completed")
      before = File.read!(Path.join(record["directory"], "run.json"))
      assert {:error, _} = RunJournal.admit(root, id, execution_binding: fixture_binding("verifier"))
      assert File.read!(Path.join(record["directory"], "run.json")) == before
      refute File.exists?(Path.join(record["directory"], "executor.lock"))
    end
  end

  test "a bound execution cannot lose its authority reference or change repository identity", %{root: root} do
    base = fixture_binding()
    {:ok, record} = RunJournal.admit(root, "2", execution_binding: base)
    assert :ok = RunJournal.complete(record, "completed")
    assert {:error, :execution_binding_required} = RunJournal.admit(root, "2")
    foreign = put_in(base, ["work", "repository_id"], "2")
    assert {:error, :execution_work_changed} = RunJournal.admit(root, "2", execution_binding: foreign)
    assert {:ok, _} = RunJournal.admit(root, "2", execution_binding: base)
  end

  test "legacy sessions need explicit migration even when their stop is confirmed", %{root: root} do
    {:ok, legacy} = RunJournal.admit(root, "2")
    legacy = stop(legacy, "legacy")
    assert {:error, :unbound_execution_requires_migration} = RunJournal.admit(root, "2", execution_binding: fixture_binding())
    assert {:ok, current} = RunJournal.read(legacy["directory"])
    assert current["thread_id"] == "legacy"
    refute current["execution_binding"]
  end

  test "malformed and ambiguous bindings fail before admission changes durable state", %{root: root} do
    base = fixture_binding()
    input = %{"work" => base["work"], "artifact" => "a", "version" => "v", "verification" => "proof"}

    invalid = [
      nil,
      %{},
      %{base | "role" => "human"},
      %{base | "candidate" => "unverified"},
      put_in(base, ["authority", "revision"], "stale"),
      %{base | "inputs" => nil},
      %{base | "inputs" => [false]},
      %{base | "inputs" => [input, input]},
      put_in(base, ["work", "number"], 0)
    ]

    for value <- invalid do
      assert {:error, :invalid_execution_binding} = ExecutionBinding.normalize(value)
    end

    assert {:error, :invalid_execution_binding} = RunJournal.admit(root, "2", execution_binding: %{})
    assert {:ok, nil} = RunJournal.read(RunJournal.directory(root, "2"))
  end

  test "parallel role admission still grants a single owner", %{root: root} do
    results = 1..8 |> Task.async_stream(fn _ -> RunJournal.admit(root, "2", execution_binding: fixture_binding()) end) |> Enum.map(fn {:ok, result} -> result end)
    assert length(Enum.filter(results, &match?({:ok, _}, &1))) == 1
    assert length(Enum.filter(results, &match?({:error, {:run_admission_blocked, _, :eexist}}, &1))) == 7
  end

  test "late callbacks and stale snapshots cannot overwrite a newer native identity or verifier generation", %{root: root} do
    {:ok, developer} = RunJournal.admit(root, "2", execution_binding: fixture_binding())
    {:ok, current} = RunJournal.checkpoint(developer, %{"thread_id" => "developer"})
    assert {:error, :stale_or_unowned_execution_checkpoint} = RunJournal.checkpoint(developer, %{"thread_id" => "late"})
    changes = %{"execution_binding" => fixture_binding("verifier")}
    assert {:error, :execution_binding_changed_outside_admission} = RunJournal.checkpoint(current, changes)
    current = stop(current, "developer")
    assert {:error, :stale_or_unowned_execution_checkpoint} = RunJournal.checkpoint(current, %{"goal_status" => "complete"})
    {:ok, verifier} = RunJournal.admit(root, "2", execution_binding: fixture_binding("verifier"))
    before = File.read!(Path.join(verifier["directory"], "run.json"))
    assert {:error, :stale_or_unowned_execution_checkpoint} = RunJournal.complete(current, "completed")
    assert File.read!(Path.join(verifier["directory"], "run.json")) == before
    assert File.exists?(Path.join(verifier["directory"], "executor.lock"))
    unbound = Map.drop(developer, ~w(execution_binding execution_binding_sha execution_generation execution_history))
    assert {:error, :execution_binding_required} = RunJournal.checkpoint(unbound, %{"phase" => "completed"})
    assert File.read!(Path.join(verifier["directory"], "run.json")) == before
  end

  test "stopped-record reconciliation needs its own live lock and current journal revision", %{root: root} do
    {:ok, record} = RunJournal.admit(root, "2", execution_binding: fixture_binding())
    _ = stop(record, "developer")
    {:ok, record} = RunJournal.read(record["directory"])
    assert {:error, :stale_or_unowned_execution_checkpoint} = RunJournal.checkpoint(record, %{"native_stop_confirmed" => true})
    lock = Path.join(record["directory"], "executor.lock")
    File.mkdir!(lock)
    File.write!(Path.join(lock, "reconcile-owner"), System.pid())
    assert {:ok, saved} = RunJournal.checkpoint(record, %{"native_stop_confirmed" => true})
    assert saved["journal_version"] == record["journal_version"] + 1
    assert {:error, :stale_or_unowned_execution_checkpoint} = RunJournal.checkpoint(record, %{"phase" => "completed"})
    File.write!(Path.join(lock, "reconcile-owner"), "another-owner")
    assert {:error, :stale_or_unowned_execution_checkpoint} = RunJournal.checkpoint(saved, %{"phase" => "completed"})
  end

  test "competing callbacks commit one journal revision and cannot lose the winner's native identity", %{root: root} do
    {:ok, record} = RunJournal.admit(root, "2", execution_binding: fixture_binding())

    results =
      1..8
      |> Task.async_stream(fn index -> RunJournal.checkpoint(record, %{"thread_id" => "thread-#{index}"}) end)
      |> Enum.map(fn {:ok, result} -> result end)

    assert [{:ok, winner}] = Enum.filter(results, &match?({:ok, _}, &1))
    assert length(Enum.filter(results, &match?({:error, :stale_or_unowned_execution_checkpoint}, &1))) == 7
    assert {:ok, current} = RunJournal.read(record["directory"])
    assert current["thread_id"] == winner["thread_id"]
    assert current["journal_version"] == record["journal_version"] + 1
  end

  test "damaged or missing execution binding history cannot create fresh authority on recovery", %{root: root} do
    {:ok, developer} = RunJournal.admit(root, "2", execution_binding: fixture_binding())
    _ = stop(developer, "developer")
    {:ok, verifier} = RunJournal.admit(root, "2", execution_binding: fixture_binding("verifier"))
    _ = stop(verifier, "verifier")
    {:ok, original} = RunJournal.read(verifier["directory"])

    mutations = [
      Map.delete(original, "execution_binding"),
      %{original | "execution_binding_sha" => "changed"},
      %{original | "execution_generation" => 1},
      %{original | "execution_history" => nil},
      %{original | "execution_history" => [false]},
      %{original | "thread_id" => 123, "thread_allocation_intent" => false},
      %{original | "native_stop_confirmed" => "yes"},
      put_in(original, ["execution_history", Access.at(0), "native_stop_confirmed"], false)
    ]

    path = Path.join(verifier["directory"], "run.json")

    for damaged <- mutations do
      File.write!(path, Jason.encode!(damaged))
      assert {:error, :execution_binding_required} = RunJournal.admit(root, "2")
      assert {:error, :invalid_persisted_execution_binding} = RunJournal.admit(root, "2", execution_binding: fixture_binding())
      assert {:ok, ^damaged} = RunJournal.read(verifier["directory"])
    end

    File.write!(path, Jason.encode!(original))
    assert {:ok, _} = RunJournal.admit(root, "2", execution_binding: fixture_binding())
  end

  test "an unreadable journal cannot be replaced from an older unbound snapshot", %{root: root} do
    {:ok, record} = RunJournal.admit(root, "2")
    path = Path.join(record["directory"], "run.json")
    File.write!(path, "{interrupted checkpoint")
    assert {:error, %Jason.DecodeError{}} = RunJournal.checkpoint(record, %{"phase" => "completed"})
    assert File.read!(path) == "{interrupted checkpoint"
  end
end
