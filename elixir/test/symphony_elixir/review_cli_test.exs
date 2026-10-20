defmodule SymphonyElixir.ReviewCliTest do
  use SymphonyElixir.TestSupport, runtime: false
  alias Mix.Tasks.Symphony.Review
  alias SymphonyElixir.TaskWorkflow
  import ExUnit.CaptureIO

  test "manual task invokes the engine and emits the same canonical result" do
    {workflow, request, root} = fixture()
    output = capture_io(fn -> Review.run(["--workflow", workflow, "--request", request]) end)
    result = output |> String.trim() |> Jason.decode!()
    assert result["protocol"] == 2
    assert result["body"] == "LGTM!"
    assert result["axes"]["standards"]["thread_id"] != result["axes"]["spec"]["thread_id"]
    assert Enum.all?(result["axes"], fn {_, axis} -> axis["native_stop_confirmed"] end)
    assert Path.wildcard(Path.join(root, "runs/*/source")) == []
    assert File.exists?(Path.join(root, "source/source.txt"))
    [journal] = Path.wildcard(Path.join(root, "journal/manual/*/review-lane.json"))
    saved = journal |> File.read!() |> Jason.decode!()
    assert saved["runtime"]["result"] == result
    assert Enum.all?(saved["runtime"]["axes"], fn {_, axis} -> axis["thread_allocation_intent"] and axis["turn_allocation_intent"] end)
    capture_io(fn -> Review.run(["--workflow", workflow, "--request", request]) end)
    assert length(Jason.decode!(File.read!(journal))["history"]) == 1
  end

  test "manual controller death retains native identities and fences a replacement" do
    {workflow, request, root} = fixture()
    File.write!(Path.join(root, "hang"), "")
    {pid, ref} = spawn_monitor(fn -> capture_io(fn -> Review.run(["--workflow", workflow, "--request", request]) end) end)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    journal = await_manual_turns(root)
    saved = journal |> File.read!() |> Jason.decode!()
    assert Enum.all?(saved["runtime"]["axes"], fn {_, axis} -> is_binary(axis["thread_id"]) and axis["turn_allocation_intent"] end)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 1_000
    assert_manual_fenced(workflow, request)
    data = request |> File.read!() |> Jason.decode!()
    alias_path = Path.join(root, "source-alias")
    File.ln_s!(data["repository"], alias_path)
    File.write!(request, Jason.encode!(%{data | "repository" => alias_path, "head" => data["base"]}))
    assert_manual_fenced(workflow, request)
    requests = root |> Path.join("native-requests.jsonl") |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    assert Enum.count(requests, &(&1["method"] == "thread/start")) == 2
    assert File.exists?(journal)
    assert Path.wildcard(Path.join(root, "runs/*/source")) != []
  end

  test "unwritable manual journal refuses allocation" do
    {workflow, request, root} = fixture()
    File.mkdir_p!(Path.join(root, "journal"))
    File.write!(Path.join(root, "journal/manual"), "occupied")
    assert_raise Mix.Error, ~r/Manual review journal unavailable/, fn -> Review.run(["--workflow", workflow, "--request", request]) end
    refute File.exists?(Path.join(root, "native-requests.jsonl"))
  end

  defp await_manual_turns(root, attempts \\ 500)
  defp await_manual_turns(_root, 0), do: flunk("manual native turns were not persisted")

  defp await_manual_turns(root, attempts) do
    paths = Path.wildcard(Path.join(root, "journal/manual/*/review-lane.json"))

    ready =
      Enum.find(paths, fn path ->
        axes = path |> File.read!() |> Jason.decode!() |> get_in(["runtime", "axes"])
        map_size(axes) == 2 and Enum.all?(axes, fn {_, axis} -> is_binary(axis["turn_id"]) end)
      end)

    if ready do
      ready
    else
      Process.sleep(10)
      await_manual_turns(root, attempts - 1)
    end
  end

  defp assert_manual_fenced(workflow, request, attempts \\ 100)
  defp assert_manual_fenced(_workflow, _request, 0), do: flunk("manual controller lock did not settle")

  defp assert_manual_fenced(workflow, request, attempts) do
    error = assert_raise Mix.Error, fn -> Review.run(["--workflow", workflow, "--request", request]) end

    if error.message =~ "requires recovery" do
      :ok
    else
      assert error.message =~ "review_journal_locked"
      Process.sleep(10)
      assert_manual_fenced(workflow, request, attempts - 1)
    end
  end

  test "manual MR entry persists the native subject without publishing" do
    {workflow, request, root} = fixture()
    local = request |> File.read!() |> Jason.decode!()
    {head, 0} = System.cmd("git", ["-C", local["repository"], "rev-parse", "HEAD"])
    head = String.trim(head)

    responses = %{
      "user" => %{"id" => 21},
      "projects/team%2Frepo" => %{"id" => 10, "path_with_namespace" => "team/repo", "web_url" => "https://review.invalid/team/repo", "ssh_url_to_repo" => "git@review.invalid:team/repo.git"},
      "projects/team%2Frepo/merge_requests/1" => %{
        "project_id" => 10,
        "iid" => 1,
        "sha" => head,
        "diff_refs" => %{"base_sha" => local["base"]},
        "target_branch" => "main",
        "description" => "Closes #1"
      },
      "projects/team%2Frepo/merge_requests/1/discussions?per_page=100&page=1" => [],
      "projects/team%2Frepo/issues/1" => %{"iid" => 1, "description" => "原生任务要求"}
    }

    File.write!(Path.join(root, "api.json"), Jason.encode!(responses))
    cli = Path.join(root, "glab")

    File.write!(cli, """
    #!/usr/bin/env python3
    import sys,json,pathlib
    a=sys.argv[1:];assert a[a.index('--method')+1]=='GET'
    print(json.dumps(json.loads(pathlib.Path(#{inspect(Path.join(root, "api.json"))}).read_text())[a[a.index('--method')+2]]))
    """)

    File.chmod!(cli, 0o755)
    bin = Path.join(root, "bin")
    File.mkdir_p!(bin)
    real_git = System.find_executable("git")

    File.write!(Path.join(bin, "git"), """
    #!/usr/bin/env python3
    import os,sys
    a=sys.argv[1:]
    if 'fetch' in a:a=a[:a.index('fetch')]+['fetch',#{inspect(local["repository"])},'HEAD']
    os.execv(#{inspect(real_git)},[#{inspect(real_git)}]+a)
    """)

    File.chmod!(Path.join(bin, "git"), 0o755)
    previous = System.get_env("PATH")
    System.put_env("PATH", bin <> ":" <> previous)
    on_exit(fn -> restore_env("PATH", previous) end)
    config = SymphonyElixir.ReviewLane.config()
    File.write!(workflow, String.replace(File.read!(workflow), Jason.encode!(config), Jason.encode!(Map.put(config, "glab_bin", cli))))
    WorkflowStore.force_reload()
    File.write!(request, Jason.encode!(%{"kind" => "mr", "project" => "team/repo", "number" => 1}))
    output = capture_io(fn -> Review.run(["--workflow", workflow, "--request", request]) end)
    assert Jason.decode!(String.trim(output))["body"] == "LGTM!"
    [journal] = Path.wildcard(Path.join(root, "journal/manual/*/review-lane.json"))
    subject = journal |> File.read!() |> Jason.decode!() |> Map.fetch!("subject")
    assert subject == %{"provider" => "gitlab", "host" => "review.invalid", "repository" => nil, "project" => "team/repo", "iid" => 1}
  end

  test "manual entry rejects malformed input and unavailable runtime rules" do
    {workflow, request, root} = fixture()
    assert_raise Mix.Error, ~r/Usage/, fn -> Review.run(["--unknown"]) end
    assert_raise Mix.Error, ~r/missing_option/, fn -> Review.run(["--request", request]) end
    assert_raise Mix.Error, ~r/file is invalid/, fn -> Review.run(["--workflow", workflow, "--request", Path.join(root, "missing")]) end
    File.write!(request, "invalid JSON")
    assert_raise Mix.Error, ~r/file is invalid/, fn -> Review.run(["--workflow", workflow, "--request", request]) end
    capture_io([input: "[]"], fn -> assert_raise Mix.Error, ~r/JSON object/, fn -> Review.run(["--workflow", workflow]) end end)
    capture_io([input: "{}"], fn -> assert_raise Mix.Error, ~r/invalid_review_request/, fn -> Review.run(["--workflow", workflow]) end end)
    File.write!(request, "{}")
    File.write!(Path.join(root, "policy.md"), "invalid")
    assert_raise Mix.Error, ~r/shared_review_policy_unavailable/, fn -> Review.run(["--workflow", workflow, "--request", request]) end
    File.write!(workflow, "---\ntracker:\n  kind: memory\n---\nNo review configuration\n")
    WorkflowStore.force_reload()
    assert_raise Mix.Error, ~r/review_lane_unavailable/, fn -> Review.run(["--workflow", workflow, "--request", request]) end
  end

  test "changed admitted policy fails before allocating a reviewer and retains diagnostic snapshot" do
    {workflow, request, root} = fixture()
    data = request |> File.read!() |> Jason.decode!() |> Map.put("record", %{"policy_sha" => TaskWorkflow.digest("different")})
    File.write!(request, Jason.encode!(data))
    assert_raise Mix.Error, ~r/review_policy_changed/, fn -> Review.run(["--workflow", workflow, "--request", request]) end
    assert length(Path.wildcard(Path.join(root, "runs/*/source"))) == 1
    refute File.exists?(Path.join(root, "native-requests.jsonl"))
  end

  defp fixture do
    root = Path.dirname(Workflow.workflow_file_path())
    source = Path.join(root, "source")
    File.mkdir_p!(source)

    cmd = fn args ->
      {out, 0} = System.cmd("git", ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-C", source | args], stderr_to_stdout: true)
      String.trim(out)
    end

    cmd.(["init", "-q"])
    File.write!(Path.join(source, "source.txt"), "base")
    cmd.(["add", "."])
    cmd.(["commit", "-qm", "base"])
    base = cmd.(["rev-parse", "HEAD"])
    File.write!(Path.join(source, "source.txt"), "changed")
    cmd.(["commit", "-qam", "change"])
    server = Path.join(root, "review-server")
    SymphonyElixir.TestSupport.write_review_server(server, root)
    policy = Path.join(root, "policy.md")
    File.write!(policy, "## Common\nRead complete evidence.\n## Standards\nStandards rules.\n## Spec\nSpec rules.\n")

    config = %{
      "enabled" => true,
      "provider" => "gitlab",
      "host" => "review.invalid",
      "reviewer_id" => 20,
      "publisher_id" => 21,
      "projects" => %{"team/repo" => %{"id" => 10, "checkout" => source}},
      "state_dir" => Path.join(root, "journal"),
      "policy_file" => policy
    }

    workflow = Workflow.workflow_file_path()

    File.write!(
      workflow,
      "---\ntracker:\n  kind: memory\n  provider:\n    review_lane: " <>
        Jason.encode!(config) <> "\nworkspace:\n  root: " <> Jason.encode!(Path.join(root, "runs")) <> "\ncodex:\n  command: " <> Jason.encode!(server) <> "\n---\nReview only\n"
    )

    WorkflowStore.force_reload()
    request = Path.join(root, "request.json")
    File.write!(request, Jason.encode!(%{"kind" => "local", "repository" => source, "base" => base, "head" => "HEAD", "target_branch" => "main", "issue" => %{"description" => "修复测试输入"}}))
    {workflow, request, root}
  end
end
