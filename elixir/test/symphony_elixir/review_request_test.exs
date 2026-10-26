defmodule SymphonyElixir.ReviewRequestTest do
  use SymphonyElixir.TestSupport, runtime: false
  alias SymphonyElixir.ReviewRequest

  setup do
    root = Path.dirname(Workflow.workflow_file_path())
    source = Path.join(root, "source")
    File.mkdir_p!(source)
    git(source, ["init", "-q"])
    File.write!(Path.join(source, "source.txt"), "base")
    git(source, ["add", "."])
    git(source, ["commit", "-qm", "base"])
    base = git(source, ["rev-parse", "HEAD"])
    File.write!(Path.join(source, "source.txt"), "head")
    git(source, ["commit", "-qam", "head"])
    head = git(source, ["rev-parse", "HEAD"])
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", workspace_root: Path.join(root, "runs"))
    {:ok, root: root, source: source, base: base, head: head}
  end

  test "local input uses an isolated merge-base snapshot and preserves supplied context", c do
    git(c.source, ["checkout", "-qb", "diverged", c.base])
    File.write!(Path.join(c.source, "other.txt"), "other branch")
    git(c.source, ["add", "."])
    git(c.source, ["commit", "-qm", "diverged"])
    request = %{"kind" => "local", "repository" => c.source, "base" => "diverged", "head" => c.head, "target_branch" => "main", "mr" => %{"description" => "明确的验收要求"}}
    assert {:ok, context} = ReviewRequest.prepare(request, %{})
    assert context.record["base"] == c.base
    assert context.record["head"] == c.head
    assert context.mr == request["mr"]
    assert File.read!(Path.join(context.repository, "source.txt")) == "head"
    refute context.repository == c.source
    assert git(c.source, ["branch", "--show-current"]) == "diverged"
    assert :ok = ReviewRequest.cleanup(context)
    refute File.exists?(context.repository)
    assert :ok = ReviewRequest.cleanup(%{})
    assert {:ok, explicit} = ReviewRequest.prepare(Map.put(request, "workspace", Path.join(c.root, "runs/explicit")), %{})
    ReviewRequest.cleanup(explicit)
    assert File.dir?(explicit.repository)
    assert {:error, :review_snapshot_already_exists} = ReviewRequest.prepare(Map.put(request, "workspace", Path.join(c.root, "runs/explicit")), %{})
  end

  test "invalid input cannot change source or silently replace fixed revisions", c do
    request = %{"kind" => "local", "repository" => c.source, "base" => c.base, "head" => c.head, "target_branch" => "main"}

    for invalid <- [
          nil,
          %{},
          %{"kind" => "unknown"},
          Map.put(request, "repository", "relative"),
          Map.put(request, "repository", Path.join(c.root, "missing")),
          Map.put(request, "head", "missing"),
          Map.put(request, "head", ""),
          Map.put(request, "record", []),
          Map.put(request, "record", %{"head" => c.base}),
          Map.put(request, "mr", []),
          Map.put(request, "discussions", %{}),
          Map.put(request, "workspace", "relative"),
          Map.put(request, "workspace", 12)
        ] do
      assert {:error, _} = ReviewRequest.prepare(invalid, %{})
    end

    assert {:error, _} = ReviewRequest.prepare(request, nil)
    assert {:ok, context} = ReviewRequest.prepare(request, %{})
    assert context.mr == %{}
    ReviewRequest.cleanup(context)
    assert git(c.source, ["rev-parse", "HEAD"]) == c.head
  end

  test "MR preparation pins native identity and leaves requirement reading to the workflow", c do
    {config, request} = native_fixture(c)
    assert {:ok, context} = ReviewRequest.prepare(request, config)
    assert context.record["head"] == c.head
    assert context.record["base"] == c.base
    assert context.mr["description"] == "Closes #1"
    refute Map.has_key?(context.mr, "symphony_issue_evidence")
    refute File.read!(Path.join(c.root, "native-reads.jsonl")) =~ "/issues/"
    assert :ok = ReviewRequest.cleanup(context)

    for {key, value} <- [{"project", "other/repo"}, {"host", "foreign.invalid"}, {"provider", "github"}, {"number", 0}, {"record", %{"iid" => 2}}, {"record", %{"head" => c.base}}] do
      assert {:error, _} = ReviewRequest.prepare(Map.put(request, key, value), config)
    end

    assert {:error, _} = ReviewRequest.prepare(request, Map.put(config, "provider", "unknown"))
    set_response(c, "user", %{"id" => 99})
    assert {:error, :review_identity_mismatch} = ReviewRequest.prepare(request, config)
  end

  test "unsafe remotes cannot be used", c do
    {config, request} = native_fixture(c)

    for url <- [nil, "https://foreign.invalid/team/repo.git", "https://user@review.invalid/team/repo.git", "https://review.invalid/other/repo.git"] do
      set_response(c, "projects/team%2Frepo", %{"id" => 10, "path_with_namespace" => "team/repo", "web_url" => "https://review.invalid/team/repo", "ssh_url_to_repo" => url})
      assert {:error, :unsafe_project_remote} = ReviewRequest.prepare(request, config)
    end
  end

  test "provider identity is checked before fetching the subject and missing tools fail closed", c do
    {config, request} = native_fixture(c)

    for {identity, expected} <- [{%{"id" => 99}, :review_identity_mismatch}, {"EXIT", :command_failed}] do
      set_response(c, "user", identity)
      File.rm(Path.join(c.root, "native-reads.jsonl"))
      assert {:error, reason} = ReviewRequest.prepare(request, config)
      assert reason == expected or (is_tuple(reason) and elem(reason, 0) == expected)
      assert File.read!(Path.join(c.root, "native-reads.jsonl")) == "user\n"
    end

    assert {:error, :review_identity_mismatch} = ReviewRequest.prepare(request, Map.put(config, "publisher_id", nil))
    assert {:error, :invalid_review_number} = ReviewRequest.prepare(Map.put(request, "number", "bad"), config)
    assert {:error, :legacy_review_resume_not_supported} = ReviewRequest.prepare(Map.put(request, "record", %{"resume_thread_id" => "legacy"}), config)
    previous = System.get_env("PATH")

    try do
      System.put_env("PATH", c.root)
      local = %{"kind" => "local", "repository" => c.source, "base" => c.base, "head" => c.head, "target_branch" => "main"}
      assert {:error, {:command_unavailable, _}} = ReviewRequest.prepare(local, %{})
    after
      System.put_env("PATH", previous)
    end
  end

  test "source acquisition uses the existing bounded transport", c do
    bin = Path.join(c.root, "bounded-bin")
    File.mkdir_p!(bin)
    timeout = System.find_executable("timeout")
    File.write!(Path.join(bin, "git"), "#!/bin/sh\nexec /bin/sleep 2\n")
    File.write!(Path.join(bin, "timeout"), "#!/bin/sh\n[ \"$1\" = '--signal=TERM' ] && [ \"$2\" = '30s' ] || exit 72\nshift 2\nexec #{timeout} --signal=TERM 0.1s \"$@\"\n")
    for name <- ["git", "timeout"], do: File.chmod!(Path.join(bin, name), 0o755)
    previous = System.get_env("PATH")

    try do
      System.put_env("PATH", bin <> ":" <> previous)
      request = %{"kind" => "local", "repository" => c.source, "base" => c.base, "head" => c.head, "target_branch" => "main"}
      assert {:error, {:command_failed, "git", 124}} = ReviewRequest.prepare(request, %{})
    after
      System.put_env("PATH", previous)
    end
  end

  test "native descriptions with many Issue links and long evidence reach the workflow unchanged", c do
    {config, request} = native_fixture(c)
    path = "projects/team%2Frepo/merge_requests/1"
    mr = c.root |> Path.join("responses.json") |> File.read!() |> Jason.decode!() |> Map.fetch!(path)
    description = "Closes #1 Closes #2 Closes #3 Closes #4 Closes #5\n" <> String.duplicate("evidence", 10_000)
    mr = Map.put(mr, "description", description)
    set_response(c, path, mr)
    assert {:ok, context} = ReviewRequest.prepare(request, config)
    assert context.mr == mr
    refute File.read!(Path.join(c.root, "native-reads.jsonl")) =~ "/issues/"
    ReviewRequest.cleanup(context)
    set_response(c, path, [])
    assert {:error, :invalid_native_review} = ReviewRequest.prepare(request, config)
  end

  test "GitHub review preserves native requirement links for the workflow", c do
    {config, request} = native_fixture(c)
    config = config |> Map.put("provider", "github") |> Map.put("gh_bin", config["glab_bin"])
    set_response(c, "repos/team/repo", %{"id" => 10, "full_name" => "team/repo", "html_url" => "https://review.invalid/team/repo", "ssh_url" => "git@review.invalid:team/repo.git"})

    set_response(c, "repos/team/repo/pulls/1", %{
      "number" => 1,
      "head" => %{"sha" => c.head},
      "base" => %{"sha" => c.base, "ref" => "main", "repo" => %{"id" => 10}},
      "user" => %{"id" => 1},
      "requested_reviewers" => [],
      "state" => "open",
      "html_url" => "https://review.invalid/team/repo/pull/1",
      "body" => "Fixes https://review.invalid/team/repo/issues/1"
    })

    for path <- ["repos/team/repo/issues/1/comments", "repos/team/repo/pulls/1/reviews", "repos/team/repo/pulls/1/comments"] do
      set_response(c, path <> "?per_page=100&page=1", [])
    end

    assert {:ok, context} = ReviewRequest.prepare(request, config)
    assert context.mr["description"] == "Fixes https://review.invalid/team/repo/issues/1"
    refute Map.has_key?(context.mr, "symphony_issue_evidence")
    refute "repos/team/repo/issues/1" in String.split(File.read!(Path.join(c.root, "native-reads.jsonl")), "\n")
    ReviewRequest.cleanup(context)
  end

  defp git(cwd, args) do
    {output, 0} = System.cmd("git", ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-C", cwd | args], stderr_to_stdout: true)
    String.trim(output)
  end

  defp set_response(c, path, response) do
    file = Path.join(c.root, "responses.json")
    values = if File.exists?(file), do: Jason.decode!(File.read!(file)), else: %{}
    File.write!(file, Jason.encode!(Map.put(values, path, response)))
  end

  defp native_fixture(c) do
    cli = Path.join(c.root, "glab")

    File.write!(cli, """
    #!/usr/bin/env python3
    import sys,json,pathlib
    a=sys.argv[1:];path=a[a.index('--method')+2]
    with pathlib.Path(#{inspect(Path.join(c.root, "native-reads.jsonl"))}).open('a') as f:f.write(path+'\\n')
    value=json.loads(pathlib.Path(#{inspect(Path.join(c.root, "responses.json"))}).read_text()).get(path,{})
    if value=='EXIT':sys.exit(3)
    print(json.dumps(value))
    """)

    File.chmod!(cli, 0o755)
    set_response(c, "user", %{"id" => 20})

    set_response(c, "projects/team%2Frepo", %{
      "id" => 10,
      "path_with_namespace" => "team/repo",
      "web_url" => "https://review.invalid/team/repo",
      "ssh_url_to_repo" => "git@review.invalid:team/repo.git"
    })

    set_response(c, "projects/team%2Frepo/merge_requests/1", %{
      "project_id" => 10,
      "iid" => 1,
      "sha" => c.head,
      "diff_refs" => %{"base_sha" => c.base},
      "target_branch" => "main",
      "description" => "Closes #1"
    })

    set_response(c, "projects/team%2Frepo/merge_requests/1/discussions?per_page=100&page=1", [])
    bin = Path.join(c.root, "bin")
    File.mkdir_p!(bin)
    executable = System.find_executable("git")

    File.write!(Path.join(bin, "git"), """
    #!/usr/bin/env python3
    import os,sys
    a=sys.argv[1:]
    if 'fetch' in a:a=a[:a.index('fetch')]+['fetch',#{inspect(c.source)},'HEAD']
    os.execv(#{inspect(executable)},[#{inspect(executable)}]+a)
    """)

    File.chmod!(Path.join(bin, "git"), 0o755)
    previous = System.get_env("PATH")
    System.put_env("PATH", bin <> ":" <> previous)
    on_exit(fn -> restore_env("PATH", previous) end)
    config = %{"provider" => "gitlab", "host" => "review.invalid", "publisher_id" => 20, "projects" => %{"team/repo" => %{"id" => 10, "checkout" => c.source}}, "glab_bin" => cli}
    {config, %{"kind" => "mr", "project" => "team/repo", "number" => "1"}}
  end
end
