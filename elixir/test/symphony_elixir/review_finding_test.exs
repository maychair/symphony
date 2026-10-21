defmodule SymphonyElixir.ReviewFindingTest do
  @moduledoc """
  Structured standalone finding contract (§17.1) and its publication mapping (§18.1).

  A finding keeps a stable identity across rounds, records the version it applies
  to and the violated criterion, separates advice from required conditions, and is
  only settled by the reviewer. Old string-list submissions are rejected.
  """

  use SymphonyElixir.TestSupport, runtime: false

  alias SymphonyElixir.ReviewLane.{Finding, Listener, Publication}

  @head String.duplicate("c", 40)
  @base String.duplicate("b", 40)

  describe "register and verdict" do
    test "identity survives rounds and the verdict separates advice from required conditions" do
      register = registered([finding(), %{finding() | "id" => "F2", "required" => false}])
      assert Finding.register?(register)
      refute Finding.register?(nil)
      refute Finding.register?(%{"F1" => %{"id" => "F2"}})

      verdict = Finding.verdict(register)
      assert verdict["blocking"]
      refute verdict["decision_required"]
      assert verdict["required_open"] == ["F1"]
      assert verdict["suggestions"] == ["F2"]
      assert verdict["resolved"] == []
    end

    test "rounds advance an existing register instead of dropping open conditions" do
      register = registered([finding()])
      still = %{"finding" => "F1", "status" => "still_valid", "evidence" => "新版本仍然越界", "rationale" => nil, "verified_by" => "reviewer"}
      open = Finding.advance(register, %{"findings" => [], "responses" => [still]}, 2)
      assert Finding.verdict(open)["blocking"]
      assert Finding.verdict(open)["required_open"] == ["F1"]

      fixed = %{"finding" => "F1", "status" => "fixed", "evidence" => "已补充边界测试", "rationale" => nil, "verified_by" => "reviewer"}
      assert Finding.verdict(Finding.advance(register, %{"findings" => [], "responses" => [fixed]}, 2))["resolved"] == ["F1"]

      undecided = %{"finding" => "F1", "status" => "undecidable", "evidence" => nil, "rationale" => "证据不足", "verified_by" => "reviewer"}
      advanced = Finding.advance(register, %{"findings" => [], "responses" => [undecided]}, 2)
      assert Finding.verdict(advanced)["decision_required"]
      assert Finding.verdict(advanced)["undecidable"] == ["F1"]
    end
  end

  describe "publication mapping" do
    test "publication uses the single validated body rather than rendering another conclusion" do
      submission = %{"findings" => [finding()], "responses" => []}
      record = publication_record(%{}) |> Map.put("review_result", Map.merge(submission, %{"protocol" => 3, "body" => "Validated findings body"}))
      assert {:ok, prepared} = Publication.prepare(record, submission, 20)
      assert [%{"body" => "Validated findings body"}] = prepared["publication"]["entries"]
    end

    test "old result protocols cannot publish and native-command bodies are refused" do
      old = Map.delete(publication_record(%{}), "review_protocol")
      assert {:error, :unsupported_review_result} = Publication.prepare(old, ["old finding"], 20)
      submission = %{"findings" => [], "responses" => []}
      record = put_in(publication_record(%{}), ["review_result", "body"], "example\n/approve")
      assert {:error, :invalid_review_publication_body} = Publication.prepare(record, submission, 20)
    end

    test "publication validity distinguishes no intent from an inconsistent one" do
      assert Publication.valid?(%{}, 20)
      inconsistent = %{"publication" => %{"version" => 1, "actor" => 20, "entries" => []}, "submission" => 42}
      refute Publication.valid?(inconsistent, 20)
    end

    test "publication validity refuses malformed entries and missing published receipts" do
      assert {:ok, prepared} = Publication.prepare(publication_record(%{}), %{"findings" => [], "responses" => []}, 20)
      assert Publication.valid?(prepared, 20)

      [entry] = prepared["publication"]["entries"]
      refute Publication.valid?(put_in(prepared["publication"]["entries"], [nil]), 20)
      refute Publication.valid?(put_in(prepared["publication"]["entries"], [%{entry | "status" => "corrupt"}]), 20)
      refute Publication.valid?(put_in(prepared["publication"]["entries"], [Map.put(entry, "native_candidate", %{"note_id" => 1})]), 20)
      malformed = prepared |> Map.put("submission", %{"findings" => nil, "responses" => []}) |> put_in(["review_result", "findings"], nil)
      refute Publication.valid?(malformed, 20)

      missing_receipt = entry |> Map.put("status", "published") |> Map.put("receipt", nil)
      refute Publication.valid?(put_in(prepared["publication"]["entries"], [missing_receipt]), 20)
    end
  end

  describe "listener integration" do
    test "a structured review publishes a versioned conclusion and survives restart" do
      {root, config} = start_review_fixture()

      assert :ok = Listener.request_review("team/repo", 1)
      {:ok, [issue]} = Listener.issues()
      {:ok, _, _} = Listener.begin_run(issue.id)

      assert :ok = owned_submit(issue.id, %{"findings" => [finding()]})
      :ok = owned_checkpoint(issue.id, %{"native_stop_confirmed" => true})
      {:ok, [_]} = Listener.issues()

      discussions = Jason.decode!(File.read!(Path.join(root, "discussions.json")))
      assert length(discussions) == 1

      record = review_record(config, issue)
      assert Finding.register?(record["finding_register"])
      assert record["verdict"]["blocking"]

      stop_supervised!(Listener)
      start_supervised!({Listener, config: config})
      await_listener()
      {:ok, [restored]} = Listener.issues()
      assert restored.native_ref["phase"] == "completed"
      assert restored.native_ref["verdict"]["blocking"]
    end
  end

  defp registered(findings), do: Finding.advance(nil, %{"findings" => findings, "responses" => []}, 1)

  defp version(head \\ @head), do: %{"head" => head, "base" => @base, "target" => "main"}

  defp finding(overrides \\ %{}) do
    Map.merge(
      %{
        "schema_version" => 1,
        "id" => "F1",
        "required" => true,
        "criterion" => "空输入必须被拒绝",
        "version" => version(),
        "location" => "source.cpp:10",
        "evidence" => "用空字符串调用时越界",
        "impact" => "输入校验缺失会导致越界",
        "resolution" => "拒绝空输入并补充边界测试",
        "regression_of" => nil
      },
      overrides
    )
  end

  defp publication_record(register) do
    %{
      "review_protocol" => 3,
      "review_result" => %{"protocol" => 3, "findings" => [], "responses" => [], "body" => "LGTM!"},
      "id" => "round-1",
      "round" => 1,
      "work" => %{"provider" => "gitlab", "host" => "review.invalid", "repository_id" => "10", "kind" => "mr", "number" => 7},
      "head" => @head,
      "base" => @base,
      "response_sha" => String.duplicate("a", 64),
      "policy_sha" => String.duplicate("b", 64),
      "finding_register" => register,
      "verdict" => Finding.verdict(register)
    }
  end

  # --- listener integration fixture (mirrors the lifecycle test's native glab stub) ---

  defp start_review_fixture do
    root = Path.dirname(Workflow.workflow_file_path())
    Supervisor.terminate_child(SymphonyElixir.Supervisor, Listener)

    on_exit(fn ->
      write_workflow_file!(Path.join(root, "WORKFLOW.md"), tracker_kind: "memory")
      Supervisor.restart_child(SymphonyElixir.Supervisor, Listener)
    end)

    fixture = Path.join(root, "fixture")
    File.mkdir_p!(Path.join(root, "source"))
    File.write!(Path.join(root, "instructions"), "## Common\nReview only.\n## Standards\nRead standards.\n## Spec\nVerify scope.\n")
    File.write!(Path.join(root, "discussions.json"), "[]")

    File.write!(fixture, """
    #!/usr/bin/env python3
    import sys,json,pathlib
    r=pathlib.Path(#{inspect(root)});a=sys.argv[1:];path=a[a.index('--method')+2];method=a[a.index('--method')+1]
    ds=json.loads((r/'discussions.json').read_text())
    if path=='user':out={'id':20,'username':'reviewer'}
    elif '/discussions' in path:
      if method=='POST':
        body=a[a.index('--raw-field')+1].split('=',1)[1];n=len(ds)+1
        out={'id':str(n),'notes':[{'id':n,'body':body,'resolved':False,'created_at':'2026-01-01T00:00:00Z','author':{'id':20,'username':'reviewer'}}]}
        ds.append(out);(r/'discussions.json').write_text(json.dumps(ds))
      else:out=ds
    else:out={'id':1001,'project_id':10,'iid':1,'state':'opened','sha':'#{@head}','diff_refs':{'base_sha':'#{@base}'},'target_branch':'main','author':{'id':30},'reviewers':[{'id':20,'username':'reviewer'}],'web_url':'https://review.invalid/team/repo/-/merge_requests/1'}
    if path=='projects/team%2Frepo':out={'id':10,'path_with_namespace':'team/repo','web_url':'https://review.invalid/team/repo'}
    elif '/merge_requests?' in path:out=[out]
    print(json.dumps(out))
    """)

    File.chmod!(fixture, 0o755)
    File.ln_s!(fixture, Path.join(root, "glab"))

    config = %{
      "enabled" => true,
      "host" => "review.invalid",
      "provider" => "gitlab",
      "reviewer_id" => 20,
      "publisher_id" => 20,
      "projects" => %{"team/repo" => %{"id" => 10, "checkout" => Path.join(root, "source")}},
      "state_dir" => Path.join(root, "state"),
      "instruction_files" => [Path.join(root, "instructions")],
      "result_command" => SymphonyElixir.TestSupport.workflow_result_command(),
      "glab_bin" => Path.join(root, "glab")
    }

    start_supervised!({Listener, config: config})
    await_listener()
    {root, config}
  end

  defp owns(id), do: get_in(:sys.get_state(Listener), [:records, String.replace_prefix(id, "review:", ""), "execution_owner"])
  defp owned_submit(id, arguments), do: SymphonyElixir.TestSupport.submit_review(id, arguments)
  defp owned_checkpoint(id, changes), do: Listener.checkpoint(id, owns(id), changes)

  defp review_record(config, issue) do
    records = config["state_dir"] |> Path.join("review-lane.json") |> File.read!() |> Jason.decode!() |> Map.fetch!("records")
    Map.fetch!(records, String.replace_prefix(issue.id, "review:", ""))
  end

  defp await_listener(attempts \\ 100) do
    cond do
      Listener.health().health == :listening ->
        :ok

      attempts == 0 ->
        flunk("Listener did not become ready")

      true ->
        Process.sleep(10)
        await_listener(attempts - 1)
    end
  end
end
