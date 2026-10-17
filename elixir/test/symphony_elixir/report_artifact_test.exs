defmodule SymphonyElixir.ReportArtifactTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.{ArtifactStore, ReportArtifact, TaskWorkflow}

  defp fixture do
    work = %{"provider" => "github", "host" => "github.test", "repository_id" => "10", "kind" => "issue", "number" => 2}
    repository = Map.take(work, ~w(provider host repository_id)) |> Map.merge(%{"path" => "team/repo", "api_url" => "https://github.test/api/v3", "credential" => "$UNUSED_REPORT"})
    root = Path.join(System.tmp_dir!(), "report-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    owner = %{"kind" => "candidate", "work" => work, "revision" => TaskWorkflow.digest("candidate")}
    {:ok, report} = ReportArtifact.build(work, "analysis", "# Findings\n\nEvidence supports this bounded conclusion.\n")
    {root, work, report, owner, [repositories: [repository]]}
  end

  test "report versions bind exact UTF-8 bytes, output identity and native Issue scope" do
    {_root, work, report, _owner, _opts} = fixture()
    assert report["version"] == Base.encode16(:crypto.hash(:sha256, report["body"]), case: :lower)
    assert {:ok, snapshot} = ReportArtifact.snapshot(work, report)
    assert :ok = ReportArtifact.validate(work, Map.take(report, ~w(id version source)), snapshot)
    assert {:error, :invalid_stored_report} = ReportArtifact.validate(work, %{report | "body" => "changed"}, snapshot)
    assert {:error, :invalid_stored_report} = ReportArtifact.validate(work, report, %{})
    assert {:error, :invalid_stored_report} = ReportArtifact.validate(%{work | "number" => 3}, report, snapshot)
    assert {:error, :invalid_report_artifact} = ReportArtifact.snapshot(work, Map.put(report, "version", String.duplicate("0", 64)))

    for body <- [nil, "", " ", <<255>>, <<0>>, String.duplicate("x", 16_385), "<!-- symphony-plan-decision {} -->"] do
      assert {:error, :invalid_report_artifact} = ReportArtifact.build(work, "analysis", body)
    end

    assert {:error, :invalid_report_artifact} = ReportArtifact.build(work, "", "report")
    assert {:error, :invalid_report_artifact} = ReportArtifact.build(%{}, "analysis", "report")
    gitlab = %{work | "provider" => "gitlab", "host" => "gitlab.test"}
    assert {:error, :invalid_report_artifact} = ReportArtifact.build(gitlab, "analysis", "Result\n/close")
  end

  test "native report storage retains consumers without Git and rejects damaged bytes or forged references" do
    {root, work, report, owner, opts} = fixture()
    assert {:ok, saved} = ArtifactStore.retain_report(root, work, report, owner, opts)
    assert {:ok, ^saved} = ArtifactStore.retain_report(root, work, report, owner, opts)
    assert {:ok, ^saved} = ArtifactStore.read_report(root, work, Map.drop(report, ["body"]), opts)
    assert {:error, :invalid_artifact_file} = ArtifactStore.read(root, work, report["version"], opts)
    consumer = %{owner | "kind" => "dependency", "work" => %{work | "number" => 3}}
    assert {:ok, ^saved} = ArtifactStore.retain_report(root, work, report, consumer, opts)
    assert {:ok, owners} = ArtifactStore.report_references(root, work, report, opts)
    assert Enum.sort(owners) == Enum.sort([owner, consumer])
    assert {:error, :invalid_artifact_reference} = ArtifactStore.retain_report(root, work, report, %{}, opts)
    assert {:error, :artifact_storage_limit} = ArtifactStore.retain_report(root, work, report, owner, Keyword.put(opts, :artifact_max_bytes, 1))
    assert {:error, :artifact_storage_limit} = ArtifactStore.read_report(root, work, report, Keyword.put(opts, :artifact_max_bytes, 1))
    assert {:error, :invalid_report_artifact} = ArtifactStore.read_report(root, work, Map.put(report, "source", "../../foreign"), opts)
    [path] = Path.wildcard(Path.join(root, "report-*.json"))
    data = Jason.decode!(File.read!(path)) |> Map.update!("files", &Enum.map(&1, fn file -> Map.put(file, "content", Base.encode64("changed")) end))
    File.write!(path, Jason.encode!(data))
    assert {:error, :invalid_stored_report} = ArtifactStore.read_report(root, work, report, opts)
    assert {:error, :artifact_publication_conflict} = ArtifactStore.retain_report(root, work, report, owner, opts)
  end
end
