defmodule SymphonyElixir.CommandCheckTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.{CommandCheck, ExecutionBinding, RunJournal, TaskWorkflow}

  defp git(path, args) do
    {output, 0} = System.cmd("git", ["-C", path | args], stderr_to_stdout: true)
    String.trim(output)
  end

  defp fixture(command, timeout \\ 2_000, overrides \\ %{}) do
    root = Path.join(System.tmp_dir!(), "command-check-#{System.unique_integer([:positive])}")
    primary = Path.join(root, "source")
    workspace = Path.join(root, "developer")
    File.mkdir_p!(primary)
    on_exit(fn -> File.rm_rf!(root) end)
    git(primary, ["init", "-q"])
    File.write!(Path.join(primary, "input"), "approved\n")
    git(primary, ["add", "input"])
    git(primary, ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.test", "commit", "-qm", "Fixture"])
    revision = git(primary, ["rev-parse", "HEAD"])
    git(primary, ["worktree", "add", "--detach", workspace, revision])
    # The fixed candidate must not inherit later dirty developer changes.
    File.write!(Path.join(workspace, "input"), "unsubmitted\n")
    work = %{"provider" => "github", "host" => "github.test", "repository_id" => "1", "kind" => "issue", "number" => 2}
    plan = TaskWorkflow.digest("plan")
    scope = TaskWorkflow.digest("scope")
    command = if is_function(command, 1), do: command.(root), else: command
    overrides = if is_function(overrides, 1), do: overrides.(root), else: overrides
    check_policy = Map.merge(%{"kind" => "command", "command" => command, "artifact" => "source", "timeout_ms" => timeout}, overrides)
    policy = %{"engine_actor" => "99", "checks" => %{"test" => check_policy, "other" => check_policy, "review" => %{"kind" => "review"}}}
    payload = %{"work" => work, "contract_sha" => scope, "inputs" => [], "artifacts" => [%{"id" => "source", "kind" => "code", "version" => revision}]}
    candidate = Map.put(payload, "digest", TaskWorkflow.digest(payload))

    binding = %{
      "work" => work,
      "role" => "verifier",
      "candidate" => candidate["digest"],
      "contract_sha" => scope,
      "plan_revision" => plan,
      "policy_sha" => TaskWorkflow.digest(policy),
      "inputs" => [],
      "authority" => %{"work" => %{work | "number" => 1}, "actor" => "1", "source" => "native-approval", "revision" => plan}
    }

    {:ok, record} = RunJournal.admit(Path.join(root, "runs"), "2", execution_binding: binding)
    now = System.system_time(:millisecond)
    flow = TaskWorkflow.new(10_000, now) |> TaskWorkflow.start(now) |> Map.put("schema_version", 2)
    {:ok, record} = RunJournal.checkpoint(record, %{"thread_id" => "verifier", "workspace" => workspace, "workflow" => flow, "native_stop_confirmed" => true})
    %{root: root, primary: primary, workspace: workspace, candidate: candidate, policy: policy, record: record}
  end

  defp run(context, record \\ nil), do: CommandCheck.run(record || context.record, context.candidate, "test", context.policy)
  defp current(context), do: elem(RunJournal.read(context.record["directory"]), 1)
  defp check_dir(record, id), do: Path.join([record["directory"], "checks", id])
  defp check(receipt), do: receipt |> Map.take(~w(candidate command exit_code output_sha reason snapshot_valid)) |> Map.put("id", "test")

  test "a real command checks the fixed commit in another worktree and preserves actual output and exit status" do
    context = fixture("cat input; printf 'stderr\\n' >&2; exit 7")
    assert {:ok, saved, receipt} = run(context)
    assert receipt["exit_code"] == 7
    assert receipt["reason"] == "completed"
    assert receipt["snapshot_valid"]
    assert receipt["native_stop_confirmed"]
    assert File.read!(Path.join(context.workspace, "input")) == "unsubmitted\n"
    assert File.read!(Path.join(context.primary, "input")) == "approved\n"
    output = File.read!(Path.join(check_dir(saved, receipt["id"]), "output"))
    assert output == "approved\nstderr\n"
    assert {:ok, %{"output" => ^output, "output_encoding" => "utf8", "output_truncated" => false}} = CommandCheck.output(saved, receipt["id"])
    assert receipt["output_sha"] == Base.encode16(:crypto.hash(:sha256, output), case: :lower)
    assert :ok = CommandCheck.attest(saved, %{"checks" => [check(receipt)]}, context.policy)
    assert :ok = CommandCheck.attest(saved, %{"checks" => [check(receipt), %{"id" => "review"}]}, context.policy)
    assert {:ok, _, ^receipt} = run(context, saved)
    assert {:error, :stale_or_unowned_execution_checkpoint} = run(context)
  end

  test "binary command output is explicitly encoded rather than corrupting the tool response" do
    context = fixture(~S|printf '\377'|)
    {:ok, saved, receipt} = run(context)
    assert {:ok, %{"output" => "/w==", "output_encoding" => "base64", "output_truncated" => false}} = CommandCheck.output(saved, receipt["id"])
  end

  test "actual command evidence cannot be replaced by success booleans, different exits or edited logs" do
    context = fixture("echo failing; exit 1")
    {:ok, saved, receipt} = run(context)

    for altered <- [nil, %{"id" => "unknown"}, Map.put(check(receipt), "exit_code", 0), Map.put(check(receipt), "output_sha", "claimed")] do
      assert {:error, :command_evidence_not_attested} = CommandCheck.attest(saved, %{"checks" => [altered]}, context.policy)
    end

    assert {:error, :command_evidence_not_attested} = CommandCheck.attest(saved, %{"checks" => nil}, context.policy)
    File.write!(Path.join(check_dir(saved, receipt["id"]), "output"), "changed")
    assert {:error, :check_output_unconfirmed} = CommandCheck.output(saved, receipt["id"])
    assert {:error, :check_output_unconfirmed} = CommandCheck.output(saved, "missing")
    assert {:error, :check_receipt_unconfirmed} = CommandCheck.recover(saved, receipt["id"])
    assert {:error, :command_evidence_not_attested} = CommandCheck.attest(saved, %{"checks" => [check(receipt)]}, context.policy)
  end

  test "self-modifying checks retain stop proof but cannot attest a result for the original candidate" do
    context = fixture("echo modified > input")
    {:ok, saved, receipt} = run(context)
    assert receipt["exit_code"] == 0
    refute receipt["snapshot_valid"]
    assert CommandCheck.stopped?(saved)
    assert {:error, :command_evidence_not_attested} = CommandCheck.attest(saved, %{"checks" => [check(receipt)]}, context.policy)
    assert File.read!(Path.join(context.workspace, "input")) == "unsubmitted\n"
  end

  test "timeouts terminate and reap an actual subprocess instead of treating a local wait timeout as stop" do
    context = fixture("echo $$; exec sleep 30", 100)
    {:ok, saved, receipt} = run(context)
    assert receipt["reason"] == "timeout"
    assert receipt["exit_code"] == nil
    assert receipt["native_stop_confirmed"]
    pid = check_dir(saved, receipt["id"]) |> Path.join("output") |> File.read!() |> String.trim()
    assert {_, status} = System.cmd("kill", ["-0", pid], stderr_to_stdout: true)
    assert status != 0
  end

  test "background children that create a new session cannot outlive a completed shell check" do
    command = ~S|python3 -c 'import os,time; p=os.fork(); os.setsid() if p==0 else print(p,flush=True); time.sleep(30) if p==0 else None'|
    context = fixture(command)
    {:ok, saved, receipt} = run(context)
    assert receipt["reason"] == "completed"
    assert receipt["exit_code"] == 0
    assert receipt["native_stop_confirmed"]
    pid = check_dir(saved, receipt["id"]) |> Path.join("output") |> File.read!() |> String.trim()
    {_, status} = System.cmd("kill", ["-0", pid], stderr_to_stdout: true)
    assert status != 0
  end

  test "output limits terminate the command and preserve a bounded verifiable transcript" do
    context = fixture(~S|python3 -c 'print("x"*2000000)'|)
    {:ok, saved, receipt} = run(context)
    assert receipt["reason"] == "output_limit"
    assert receipt["output_bytes"] == 1_048_576
    assert {:ok, %{"output" => preview, "output_truncated" => true}} = CommandCheck.output(saved, receipt["id"])
    assert byte_size(preview) == 16_384
    assert byte_size(File.read!(Path.join(check_dir(saved, receipt["id"]), "output"))) == 1_048_576
    assert receipt["native_stop_confirmed"]
  end

  defp await_native(context, remaining \\ 200) do
    record = current(context)

    match =
      Enum.find(record["check_runs"] || %{}, fn {id, entry} ->
        entry["status"] == "running" and File.exists?(Path.join(check_dir(record, id), "native.json"))
      end)

    cond do
      match ->
        {record, elem(match, 0)}

      remaining > 0 ->
        Process.sleep(10)
        await_native(context, remaining - 1)

      true ->
        flunk("check did not allocate a supervised process")
    end
  end

  test "cancellation keeps replacement fenced until a real stopped receipt has been recovered" do
    context = fixture("exec sleep 30", 5_000)
    task = Task.async(fn -> run(context) end)
    {running, id} = await_native(context)
    refute CommandCheck.stopped?(running)
    next = %{running["execution_binding"] | "role" => "developer"}
    assert {:error, :execution_generation_requires_native_stop} = ExecutionBinding.bind(running, next)
    assert {:error, :another_check_running} = CommandCheck.run(running, context.candidate, "other", context.policy)
    assert :ok = CommandCheck.cancel(current(context), id)
    assert {:error, :check_receipt_unconfirmed} = Task.await(task, 5_000)
    assert {:ok, stopped, receipt} = CommandCheck.recover(current(context), id)
    assert receipt["reason"] == "cancelled"
    assert CommandCheck.stopped?(stopped)
    assert {:ok, _} = ExecutionBinding.bind(stopped, next)
    assert {:error, :check_not_running} = CommandCheck.cancel(stopped, id)
  end

  test "member recovery cancels an orphaned real check and attests its stopped receipt" do
    context = fixture("exec sleep 30", 10_000)
    assert :ok = RunJournal.complete(context.record, "completed")
    supervisor = start_supervised!({Task.Supervisor, []})

    {:ok, worker} =
      Task.Supervisor.start_child(supervisor, fn ->
        {:ok, owned} = RunJournal.admit(Path.dirname(context.record["directory"]), "2", execution_binding: context.record["execution_binding"])
        run(context, owned)
      end)

    {_running, id} = await_native(context)
    ref = Process.monitor(worker)
    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^ref, :process, ^worker, :killed}
    original = current(context)
    assert RunJournal.interrupted_member?(original)
    assert {:ok, result} = SymphonyElixir.TaskRecovery.recover(original, %{}, repositories: [])
    assert result.record["attempt_id"] == original["attempt_id"]
    assert result.record["native_stop_confirmed"]
    assert CommandCheck.stopped?(result.record)
    receipt = result.record["check_runs"][id]["receipt"]
    assert receipt["reason"] == "cancelled"
    assert receipt["native_stop_confirmed"]
    assert File.exists?(Path.join(check_dir(result.record, id), "cancel"))
    assert result.outcome == "waiting"
    refute File.exists?(Path.join(result.record["directory"], "executor.lock"))
  end

  defp prepared(context) do
    flow = Map.put(context.record["workflow"], "restrictions", %{"pause" => %{"kind" => "pause", "scope" => "task"}})
    {:ok, record} = RunJournal.checkpoint(context.record, %{"workflow" => flow})
    assert {:error, :check_budget_or_control_blocked} = run(context, record)
    record = current(context)
    [{id, entry}] = Map.to_list(record["check_runs"])
    {:ok, record} = RunJournal.checkpoint(record, %{"workflow" => Map.put(record["workflow"], "restrictions", %{})})
    {record, id, entry}
  end

  test "prepared work resumes without changing the intent and rejects unsubmitted inputs" do
    context = fixture("cat input")
    {record, id, entry} = prepared(context)
    directory = check_dir(record, id)
    File.write!(Path.join(directory, "spec.json"), "interrupted prepared write")
    File.write!(Path.join(entry["spec"]["workspace"], "extra"), "unsubmitted input")
    assert {:error, :check_snapshot_changed} = run(context, record)
    File.rm!(Path.join(entry["spec"]["workspace"], "extra"))
    assert {:ok, _, receipt} = run(context, current(context))
    assert receipt["exit_code"] == 0
  end

  test "unknown ownership, redirected storage and intent changes are preserved instead of overwritten" do
    for variant <- [:owner, :parent, :spec_link, :intent] do
      context = fixture("echo forbidden")
      {record, id, entry} = prepared(context)
      directory = check_dir(record, id)

      case variant do
        :owner ->
          File.write!(Path.join(directory, ".owner"), "somebody else")
          assert {:error, :unowned_check_directory} = run(context, record)

        :parent ->
          parent = Path.dirname(directory)
          File.rename!(parent, parent <> ".saved")
          File.ln_s!(context.primary, parent)
          assert {:error, :unsafe_check_directory} = run(context, record)

        :spec_link ->
          File.ln_s!(Path.join(context.workspace, "input"), Path.join(directory, "spec.json"))
          assert {:error, :unsafe_check_spec_path} = run(context, record)
          assert File.read!(Path.join(context.workspace, "input")) == "unsubmitted\n"

        :intent ->
          entry = put_in(entry["spec"]["command"], "different")
          {:ok, record} = RunJournal.checkpoint(record, %{"check_runs" => %{id => entry}})
          assert {:error, :command_check_intent_changed} = run(context, record)
      end
    end
  end

  test "unavailable artifacts and invalid tool roots fail before launching the check" do
    context = fixture("echo forbidden")
    revision = hd(context.candidate["artifacts"])["version"]
    {prefix, rest} = String.split_at(revision, 2)
    object = Path.join([context.primary, ".git", "objects", prefix, rest])
    File.rename!(object, object <> ".saved")
    assert {:error, :check_checkout_failed} = run(context)
    context = fixture("echo forbidden", 2_000, %{"read_roots" => "not-a-list"})
    assert {:error, :invalid_command_check} = run(context)
  end

  test "a damaged launch specification does not validate an otherwise plausible receipt" do
    context = fixture("echo done")
    {:ok, saved, receipt} = run(context)
    entry = saved["check_runs"][receipt["id"]] |> Map.delete("launch_spec")
    {:ok, saved} = RunJournal.checkpoint(saved, %{"check_runs" => %{receipt["id"] => entry}})
    assert {:error, :check_receipt_unconfirmed} = CommandCheck.recover(saved, receipt["id"])
  end

  test "damaged or incomplete supervisor receipts never become completed command evidence" do
    context = fixture("echo done")
    {:ok, saved, receipt} = run(context)
    path = Path.join(check_dir(saved, receipt["id"]), "receipt.json")

    for damaged <- [nil, [], Map.delete(receipt, "exit_code")] do
      File.write!(path, Jason.encode!(damaged))
      assert {:error, :check_receipt_unconfirmed} = CommandCheck.recover(saved, receipt["id"])
      assert {:error, :command_evidence_not_attested} = CommandCheck.attest(saved, %{"checks" => [check(receipt)]}, context.policy)
    end
  end

  test "journal admission also fences a check that outlived its stopped native agent" do
    context = fixture("echo unused")
    {:ok, pending} = RunJournal.checkpoint(context.record, %{"check_runs" => %{"pending" => %{"status" => "running"}}})
    assert :ok = RunJournal.complete(pending, "completed")

    assert {:error, :check_execution_requires_recovery} =
             RunJournal.admit(Path.dirname(pending["directory"]), "2", execution_binding: pending["execution_binding"])
  end

  test "missing receipts do not start another command and cannot grant stop" do
    context = fixture("echo once")
    {:ok, saved, receipt} = run(context)
    File.rename!(Path.join(check_dir(saved, receipt["id"]), "receipt.json"), Path.join(check_dir(saved, receipt["id"]), "receipt.saved"))
    assert {:error, :check_receipt_unconfirmed} = run(context, saved)
    assert {:error, :check_receipt_unconfirmed} = CommandCheck.recover(current(context), "missing")
    refute CommandCheck.stopped?(%{"check_runs" => %{"x" => %{}}})
    refute CommandCheck.stopped?(%{"check_runs" => []})
  end

  test "invalid policy, candidate, primary checkout or absent budget never launches a command" do
    context = fixture("echo forbidden")
    assert {:error, :invalid_command_check} = CommandCheck.run(context.record, nil, "test", context.policy)
    assert {:error, :invalid_command_check} = CommandCheck.run(context.record, context.candidate, "test", %{})
    assert {:error, :invalid_command_check} = CommandCheck.run(Map.put(context.record, "workspace", context.primary), context.candidate, "test", context.policy)
    assert {:error, :check_budget_unavailable} = run(context, Map.delete(context.record, "workflow"))
    assert CommandCheck.stopped?(current(context))
  end

  test "remaining task budget clips a command's configured timeout" do
    context = fixture("exec sleep 30", 5_000)
    flow = %{context.record["workflow"] | "budget_ms" => 200}
    {:ok, record} = RunJournal.checkpoint(context.record, %{"workflow" => flow})
    {:ok, _, receipt} = run(context, record)
    assert receipt["reason"] == "timeout"
    assert receipt["timeout_ms"] <= 200
  end

  test "the command cannot forge receipts, read host-private files or change the developer checkout" do
    context =
      fixture(fn root ->
        File.write!(Path.join(root, "private"), "host-private")

        """
        python3 - <<'PY'
        import pathlib,tempfile
        root=pathlib.Path(#{Jason.encode!(root)})
        for path in [pathlib.Path('../receipt.json'),root/'developer'/'input',root/'source'/'.git'/'config']:
            try: path.write_text('forged')
            except PermissionError: pass
            else: raise AssertionError('writable host path')
        try: (root/'private').read_text()
        except PermissionError: pass
        else: raise AssertionError('readable host private file')
        with tempfile.TemporaryFile() as f: f.write(b'allowed temporary output')
        print('isolated')
        PY
        """
      end)

    assert {:ok, saved, receipt} = run(context)
    assert receipt["exit_code"] == 0
    assert receipt["snapshot_valid"]
    assert File.read!(Path.join(check_dir(saved, receipt["id"]), "output")) == "isolated\n"
    assert File.read!(Path.join(context.workspace, "input")) == "unsubmitted\n"
  end

  test "configured tool installations remain read-only while their commands can be executed" do
    context =
      fixture("custom-check", 2_000, fn root ->
        tools = Path.join(root, "toolchain")
        bin = Path.join(tools, "bin")
        File.mkdir_p!(bin)
        library = Path.join(tools, "library")
        File.write!(library, "configured tool\n")
        command = Path.join(bin, "custom-check")
        File.write!(command, "#!/bin/sh\ncat '#{library}'\nif echo changed > '#{library}' 2>/dev/null; then exit 99; fi\n")
        File.chmod!(command, 0o755)
        %{"path" => [bin, "/usr/bin", "/bin"], "read_roots" => [tools]}
      end)

    assert {:ok, _, receipt} = run(context)
    assert receipt["exit_code"] == 0
    assert File.read!(Path.join([context.root, "toolchain", "library"])) == "configured tool\n"
  end

  test "attested results survive check-worktree cleanup without rerunning the command" do
    context = fixture("echo checked")
    {:ok, saved, receipt} = run(context)
    workspace = saved["check_runs"][receipt["id"]]["spec"]["workspace"]
    git(context.primary, ["worktree", "remove", workspace])
    refute File.exists?(workspace)
    assert :ok = CommandCheck.attest(saved, %{"checks" => [check(receipt)]}, context.policy)
    assert {:ok, _, ^receipt} = run(context, saved)
  end
end
