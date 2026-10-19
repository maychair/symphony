defmodule SymphonyElixir.NativeReopenTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.NativeWork

  test "both providers reopen only a fresh closed revision and read back open" do
    for provider <- ["github", "gitlab"] do
      f = fixture(provider)
      assert {:ok, snapshot} = NativeWork.read(f.work, f.opts)
      assert :sent = NativeWork.reopen(snapshot, f.opts)
      assert {:ok, reopened} = NativeWork.read(f.work, f.opts)
      assert reopened.raw["state"] == "open"
      assert {:not_sent, :native_issue_not_closed} = NativeWork.reopen(reopened, f.opts)
      expected = if provider == "github", do: {"PATCH", %{"state" => "open"}}, else: {"PUT", %{"state_event" => "reopen"}}
      assert [write] = Agent.get(f.state, & &1.writes)
      assert {write["method"], write["body"]} == expected
    end
  end

  test "a changed native revision prevents reopening and preserves the closed issue" do
    for provider <- ["github", "gitlab"] do
      f = fixture(provider)
      {:ok, snapshot} = NativeWork.read(f.work, f.opts)
      Agent.update(f.state, &put_in(&1.objects[f.path]["title"], "Changed after assessment"))
      assert {:not_sent, :native_snapshot_changed} = NativeWork.reopen(snapshot, f.opts)
      assert Agent.get(f.state, & &1.writes) == []
      assert {:ok, current} = NativeWork.read(f.work, f.opts)
      assert current.raw["state"] == "closed"
    end
  end

  test "invalid targets and failed refreshes never send a reopen" do
    f = fixture("github")
    {:ok, snapshot} = NativeWork.read(f.work, f.opts)
    assert {:not_sent, :invalid_native_reopen} = NativeWork.reopen(nil, f.opts)
    assert {:not_sent, :expected_issue} = NativeWork.reopen(put_in(snapshot.work["kind"], "pr"), f.opts)
    assert {:not_sent, :unregistered_plan_repository} = NativeWork.reopen(snapshot, repositories: [])
    failing = Keyword.put(f.opts, :request, fn _, _, _, _, _ -> {:error, :offline} end)
    assert {:not_sent, _reason} = NativeWork.reopen(snapshot, failing)
    assert Agent.get(f.state, & &1.writes) == []
  end

  test "rejected writes and lost responses remain uncertain for both providers" do
    for provider <- ["github", "gitlab"], reply <- [{:ok, %{status: 503}}, {:error, :lost_reply}] do
      f = fixture(provider)
      {:ok, snapshot} = NativeWork.read(f.work, f.opts)
      writer = fn _, _, _, _, _, _ -> reply end
      expected = if match?({:ok, _}, reply), do: {:native_write_status, 503}, else: :native_write_failed
      assert {:uncertain, ^expected} = NativeWork.reopen(snapshot, Keyword.put(f.opts, :write_request, writer))
      assert {:ok, current} = NativeWork.read(f.work, f.opts)
      assert current.raw["state"] == "closed"
    end
  end

  test "close with rejected write and 1-arg calls for close and reopen" do
    f = fixture("github")
    {:ok, closed_snapshot} = NativeWork.read(f.work, f.opts)
    # Default 1-arg reopen call
    assert {:not_sent, :unregistered_plan_repository} = NativeWork.reopen(closed_snapshot)

    # Reopen to open state
    assert :sent = NativeWork.reopen(closed_snapshot, f.opts)
    {:ok, open_snapshot} = NativeWork.read(f.work, f.opts)
    assert open_snapshot.raw["state"] == "open"

    # Default 1-arg close call
    assert {:not_sent, :unregistered_plan_repository} = NativeWork.close(open_snapshot)

    # close with 503 status
    rejected = fn _, _, _, _, _, _ -> {:ok, %{status: 503, body: %{}}} end

    assert {:uncertain, {:native_write_status, 503}} =
             NativeWork.close(open_snapshot, Keyword.put(f.opts, :write_request, rejected))
  end

  defp fixture(provider) do
    work = %{"provider" => provider, "host" => provider <> ".test", "repository_id" => "10", "kind" => "issue", "number" => 2}
    prefix = if provider == "github", do: "/repos/team/repo", else: "/projects/team%2Frepo"
    suffix = if provider == "github", do: "/comments", else: "/notes"
    url = "https://" <> work["host"] <> "/team/repo"
    path = prefix <> "/issues/2"

    repository =
      Map.take(work, ~w(provider host repository_id))
      |> Map.merge(%{
        "path" => "team/repo",
        "api_url" => "https://" <> work["host"] <> if(provider == "github", do: "/api/v3", else: "/api/v4"),
        "credential" => "$UNUSED_CLOSURE_FIXTURE"
      })

    native = fn state ->
      base = %{"id" => 102, "title" => "Member", "state" => state, "assignees" => [%{"id" => 1}]}

      if provider == "github",
        do: Map.merge(base, %{"number" => 2, "body" => "body", "html_url" => url <> "/issues/2"}),
        else: Map.merge(base, %{"iid" => 2, "description" => "body", "project_id" => 10, "web_url" => url <> "/-/issues/2"})
    end

    repository_object =
      if provider == "github",
        do: %{"id" => 10, "full_name" => "team/repo", "html_url" => url},
        else: %{"id" => 10, "path_with_namespace" => "team/repo", "web_url" => url}

    objects = %{prefix => repository_object, path => native.("closed"), (path <> suffix) => []}
    state = start_supervised!({Agent, fn -> %{objects: objects, reads: 0, writes: []} end}, id: make_ref())

    request = fn ^provider, "GET", requested, _query, _settings ->
      read_and_count(state, path, requested)
    end

    write = fn ^provider, method, requested, query, body, _settings ->
      Agent.get_and_update(state, fn current ->
        closed = Map.merge(current.objects[requested], %{"state" => "open"})
        entry = %{"method" => method, "path" => requested, "query" => query, "body" => body}
        {{:ok, %{status: 200, body: closed}}, %{current | objects: Map.put(current.objects, requested, closed), writes: current.writes ++ [entry]}}
      end)
    end

    %{work: work, path: path, state: state, opts: [repositories: [repository], request: request, write_request: write]}
  end

  defp read_and_count(state, path, requested) do
    Agent.get_and_update(state, fn current ->
      reads = if requested == path, do: current.reads + 1, else: current.reads
      {{:ok, %{status: 200, body: Map.fetch!(current.objects, requested)}}, %{current | reads: reads}}
    end)
  end
end
