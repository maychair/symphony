defmodule SymphonyElixir.ReviewWorkflowTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.{ReviewAxis, ReviewWorkflow, TaskWorkflow}

  setup do
    root = Path.join(System.tmp_dir!(), "review-workflow-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    policy = Path.join(root, "policy.md")
    File.write!(policy, "## Common\nRead fixed input.\n## Standards\nCheck standards.\n## Spec\nCheck requirements.\n")
    on_exit(fn -> File.rm_rf!(root) end)
    record = %{"round" => 1, "head" => String.duplicate("a", 40), "base" => String.duplicate("b", 40), "target_branch" => "main", "policy_sha" => TaskWorkflow.digest(File.read!(policy))}
    {:ok, context: %{config: %{"policy_file" => policy}, record: record, repository: root, mr: %{}, discussions: []}, root: root}
  end

  defp run(context, opts \\ []), do: ReviewWorkflow.run(context, Keyword.put_new(opts, :checkpoint, fn _ -> :ok end))

  defp complete(axis),
    do: %{
      "status" => "complete",
      "report" => "已完成独立审查",
      "findings" => [],
      "responses" => [],
      "thread_id" => axis,
      "turn_id" => axis <> "-turn",
      "reads_verified" => true,
      "native_stop_confirmed" => true
    }

  test "a caller must supply its checkpoint owner before native allocation", %{context: c} do
    assert {:error, :review_checkpoint_required} = ReviewWorkflow.run(c)
    assert {:error, :review_checkpoint_required} = ReviewWorkflow.run(c, checkpoint: nil)
  end

  test "manual and automatic callers execute the same two axes concurrently and render the same result", %{context: c} do
    parent = self()

    runner = fn axis, _context, event ->
      send(parent, {:started, axis, self()})
      event.(%{"thread_id" => axis})

      receive do
        :finish -> complete(axis)
      end
    end

    run = Task.async(fn -> run(c, axis_runner: runner) end)
    assert_receive {:started, first, a}
    assert_receive {:started, second, b}
    assert first != second and a != b
    send(a, :finish)
    send(b, :finish)
    assert {:ok, manual} = Task.await(run)
    assert manual["status"] == "passed" and manual["body"] == "LGTM!"
    assert {:ok, automatic} = run(c, axis_runner: fn axis, _, _ -> complete(axis) end)
    assert manual == automatic
  end

  test "failed reads, a crash and a deadline cannot become no-findings success", %{context: c} do
    for mode <- [:read_failure, :crash, :timeout] do
      runner = fn axis, _, _ ->
        case {axis, mode} do
          {"standards", :read_failure} ->
            complete(axis) |> Map.put("reads_verified", false) |> Map.put("status", "failed")

          {"standards", :crash} ->
            exit(:fixture_failure)

          {"standards", :timeout} ->
            Process.sleep(1_000)
            complete(axis)

          _ ->
            complete(axis)
        end
      end

      assert {:ok, result} = run(c, axis_runner: runner, deadline: System.monotonic_time(:millisecond) + 100)
      refute result["status"] == "passed"
      refute result["body"] == "LGTM!"
    end
  end

  test "missing and malformed shared rules fail before any reviewer is allocated", %{context: c, root: root} do
    for body <- ["", "## Common\nOnly one axis\n", "## Common\nx\n## Standards\nx\n## Spec\nx\n## Spec\nx"] do
      File.write!(c.config["policy_file"], body)
      assert {:error, :shared_review_policy_unavailable} = run(c)
    end

    assert {:error, :shared_review_policy_unavailable} = ReviewWorkflow.rules(%{})
    assert {:error, :shared_review_policy_unavailable} = ReviewWorkflow.rules(%{"policy_file" => Path.join(root, "missing")})
  end

  test "stop signals reach both reviewers and foreign checkpoints cannot forge completion", %{context: c} do
    parent = self()

    runner = fn axis, _context, event ->
      event.(%{"thread_id" => axis})
      send(parent, {:waiting, axis})

      receive do
        :symphony_stop -> %{complete(axis) | "status" => "failed", "report" => "收到停止要求"}
      end
    end

    task = Task.async(fn -> run(c, axis_runner: runner) end)
    assert_receive {:waiting, _}
    assert_receive {:waiting, _}
    send(task.pid, {:review_axis_checkpoint, self(), make_ref(), "standards", %{"status" => "complete"}})
    send(task.pid, :symphony_stop)
    assert {:error, {:scheduler_stop, axes}} = Task.await(task)
    assert axes["standards"]["report"] == "收到停止要求"
  end

  test "a blocked durable checkpoint cannot outlive the workflow deadline", %{context: c} do
    checkpoint = fn
      %{"axes" => _} ->
        Process.sleep(150)
        :ok

      _ ->
        :ok
    end

    runner = fn axis, _, event ->
      event.(%{"thread_allocation_intent" => true})
      complete(axis)
    end

    deadline = System.monotonic_time(:millisecond) + 50
    assert {:ok, result} = run(c, checkpoint: checkpoint, axis_runner: runner, deadline: deadline)
    assert result["status"] == "failed"
    refute result["body"] == "LGTM!"
  end

  test "central roles are snapshotted with the policy and cannot configure security", %{context: c, root: root} do
    files =
      Map.new(["standards", "spec"], fn axis ->
        path = Path.join(root, axis <> ".toml")
        File.write!(path, ~s(model = "review-model"\nmodel_reasoning_effort = "high"\nsandbox_mode = "danger-full-access"\n))
        {axis, path}
      end)

    config = Map.put(c.config, "role_files", files)
    assert %{"spec" => %{"model" => "review-model", "model_reasoning_effort" => "high"}} = models = ReviewWorkflow.role_settings(config)
    assert {:ok, _, original} = ReviewWorkflow.rules(config)
    assert {:ok, _, plain} = ReviewWorkflow.rules(c.config)
    refute original == plain
    parent = self()

    runner = fn axis, context, _event ->
      assert context.models == models
      assert context.record["policy_sha"] == original
      send(parent, {:review_started, axis, self()})

      receive do
        :finish -> complete(axis)
      end
    end

    task = Task.async(fn -> run(%{c | config: config, record: Map.put(c.record, "policy_sha", original)}, axis_runner: runner) end)
    assert_receive {:review_started, _, first}
    assert_receive {:review_started, _, second}
    File.write!(files["spec"], ~s(model = "changed"\nmodel_reasoning_effort = "low"\n))
    send(first, :finish)
    send(second, :finish)
    assert {:ok, result} = Task.await(task)
    assert result["policy_sha"] == original
    assert {:ok, _, changed} = ReviewWorkflow.rules(config)
    refute changed == original
    assert {:error, :shared_review_policy_unavailable} = ReviewWorkflow.rules(Map.put(config, "role_files", Map.take(files, ["spec"])))
    File.write!(files["spec"], ~s(model = "incomplete"\n))
    assert {:error, :shared_review_policy_unavailable} = ReviewWorkflow.rules(config)
    assert ReviewAxis.halt(%{"native_stop_confirmed" => true}) == %{"native_stop_confirmed" => true}
    assert ReviewAxis.halt(%{})["native_stop_confirmed"] == true
    assert ReviewAxis.halt(%{"thread_allocation_intent" => true})["native_stop_confirmed"] == false
    assert ReviewAxis.halt(%{"thread_id" => "unknown-without-workspace"})["native_stop_confirmed"] == false
    assert %{"success" => false} = ReviewAxis.execute_agent_tool("review_read", %{"kind" => "diff"}, [])
  end

  test "admitted policy changes and an already requested stop allocate no reviewers", %{context: c} do
    send(self(), :symphony_stop)
    assert {:error, :scheduler_stop} = run(c)
    File.write!(c.config["policy_file"], File.read!(c.config["policy_file"]) <> "changed")
    assert {:error, :review_policy_changed} = run(c)
  end

  test "allocation is refused when cancellation arrives after axes start", %{context: c} do
    parent = self()

    runner = fn axis, _, event ->
      send(parent, {:before_allocation, self()})

      receive do
        :symphony_stop -> :ok
      end

      assert {:error, :scheduler_stop} = event.(%{"thread_allocation_intent" => true})
      %{complete(axis) | "status" => "failed"}
    end

    task = Task.async(fn -> run(c, axis_runner: runner) end)
    assert_receive {:before_allocation, _}
    assert_receive {:before_allocation, _}
    send(task.pid, :symphony_stop)
    assert {:error, {:scheduler_stop, _}} = Task.await(task)
  end

  defmodule Backend do
    import ExUnit.Assertions

    def start_session(root, opts) do
      if File.exists?(Path.join(root, "start-error")), do: {:error, :cannot_start}, else: allocate_session(root, opts)
    end

    defp allocate_session(root, opts) do
      with :ok <- opts[:on_thread_intent].() do
        if File.exists?(Path.join(root, "start-timeout")) do
          {:error, :response_timeout}
        else
          :ok = opts[:on_thread_started].("native-thread")
          {:ok, %{thread_id: "native-thread", workspace: root}}
        end
      end
    end

    def review_read(session, ["git", "rev-parse", "HEAD"]) do
      if File.exists?(Path.join(session.workspace, "read-error")), do: {:error, :sandbox_failed}, else: {:ok, String.duplicate("a", 40)}
    end

    def review_read(_, ["git", "ls-files"]), do: {:ok, "source.c\n"}
    def review_read(_, _), do: {:ok, "diff --git a/source.c b/source.c\n+fixed\n"}

    def run_turn(session, _prompt, _issue, opts) do
      :ok = opts[:before_turn].()
      opts[:on_message].(%{event: :session_started, turn_id: "native-turn"})
      assert %{"success" => false} = ReviewAxis.execute_agent_tool("unknown", %{}, [])
      assert %{"success" => false} = ReviewAxis.execute_agent_tool("review_axis_submit", %{"status" => "complete", "report" => "已完成", "findings" => []}, [])
      assert %{"success" => true} = ReviewAxis.execute_agent_tool("review_read", %{"kind" => "diff"}, [])
      assert %{"success" => true} = ReviewAxis.execute_agent_tool("review_read", %{"kind" => "list"}, [])
      assert %{"success" => true} = ReviewAxis.execute_agent_tool("review_read", %{"kind" => "commits"}, [])

      assert %{"success" => true} = ReviewAxis.execute_agent_tool("review_read", %{"kind" => "file", "path" => "source.c"}, [])
      assert %{"success" => false} = ReviewAxis.execute_agent_tool("review_axis_submit", %{}, [])

      failure_marker = Path.join(session.workspace, "failed-read-path")
      failed_read = File.exists?(failure_marker)

      if failed_read do
        path = File.read!(failure_marker)
        assert %{"success" => false} = ReviewAxis.execute_agent_tool("review_read", %{"kind" => "file", "path" => path}, [])
      end

      assert %{"success" => success} = ReviewAxis.execute_agent_tool("review_axis_submit", %{"status" => "complete", "report" => "已完成本轴核对", "findings" => []}, [])
      assert success == not failed_read

      if File.exists?(Path.join(session.workspace, "sandbox-error")) do
        opts[:on_message].(%{
          payload: %{"method" => "item/completed", "params" => %{"item" => %{"type" => "commandExecution", "exitCode" => 1, "aggregatedOutput" => "bwrap: sandbox initialization failed"}}}
        })
      end

      cond do
        File.exists?(Path.join(session.workspace, "turn-raise")) -> raise "fixture exception"
        File.exists?(Path.join(session.workspace, "turn-error")) -> {:error, :turn_failed}
        true -> {:ok, %{}}
      end
    end

    def confirm_session(_), do: :ok
    def stop_session(_), do: :ok
  end

  test "native read probes and restricted reader are required for a real axis result", %{context: c, root: root} do
    [_, submission] = ReviewAxis.tool_binding().tool_specs
    response_schema = get_in(submission, ["inputSchema", "properties", "responses", "items"])
    assert Enum.all?(~w(finding status evidence rationale verified_by), &(&1 in response_schema["required"]))
    assert get_in(response_schema, ["properties", "verified_by", "enum"]) == ["reviewer"]
    File.write!(Path.join(root, "source.c"), "int value;\n")
    File.ln_s!("/etc/passwd", Path.join(root, "link"))
    File.write!(Path.join(root, "binary"), <<255, 254>>)
    {:ok, rules, _} = ReviewWorkflow.rules(c.config)
    context = Map.put(c, :rules, rules)
    event = fn _ -> :ok end
    assert %{"status" => "complete", "reads_verified" => true, "native_stop_confirmed" => true} = ReviewAxis.run("standards", context, event, backend: Backend)
    alias_root = root <> "-alias"
    File.ln_s!(root, alias_root)
    on_exit(fn -> File.rm(alias_root) end)
    assert %{"status" => "complete"} = ReviewAxis.run("spec", %{context | repository: alias_root}, event, backend: Backend)

    File.write!(Path.join(root, "oversized"), String.duplicate("x", 4_194_305))

    for path <- ["../secret", "/etc/passwd", "link", "missing", ".git/config", "binary", "oversized"] do
      File.write!(Path.join(root, "failed-read-path"), path)
      result = ReviewAxis.run("spec", context, event, backend: Backend)
      assert result["status"] == "failed"
      assert result["read_failure"]
      refute result["reads_verified"]
    end

    File.rm!(Path.join(root, "failed-read-path"))

    send(self(), :symphony_stop)
    assert %{"status" => "failed", "native_stop_confirmed" => true} = ReviewAxis.run("standards", context, event, backend: Backend)
    events = self()

    _ =
      ReviewAxis.run(
        "spec",
        context,
        fn data ->
          send(events, {:checkpoint, data})
          :ok
        end,
        backend: Backend
      )

    assert_received {:checkpoint, %{"thread_allocation_intent" => true}}
    assert_received {:checkpoint, %{"turn_allocation_intent" => true}}
    incomplete = put_in(context.mr, %{"symphony_issue_evidence" => %{"status" => "incomplete"}})
    assert %{"status" => "needs_input", "native_stop_confirmed" => true} = ReviewAxis.run("spec", incomplete, event, backend: Backend)

    for marker <- ["start-error", "read-error", "turn-error", "turn-raise", "sandbox-error", "start-timeout"] do
      File.write!(Path.join(root, marker), "")
      result = ReviewAxis.run("spec", context, event, backend: Backend)
      assert result["status"] == "failed"
      if marker == "start-timeout", do: refute(result["native_stop_confirmed"])
      File.rm!(Path.join(root, marker))
    end
  end
end
