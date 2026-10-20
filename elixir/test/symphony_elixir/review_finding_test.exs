defmodule SymphonyElixir.ReviewFindingTest do
  @moduledoc """
  Structured standalone finding contract (§17.1) and its publication mapping (§18.1).

  A finding keeps a stable identity across rounds, records the version it applies
  to and the violated criterion, separates advice from required conditions, and is
  only settled by the independent reviewer. The frozen v1 sentence shape stays
  readable, and every other shape is refused rather than silently degraded (§13.1).
  """

  use SymphonyElixir.TestSupport, runtime: false

  alias SymphonyElixir.ReviewLane.{Finding, Listener, Publication}

  @head String.duplicate("c", 40)
  @base String.duplicate("b", 40)

  describe "submission shape" do
    test "the frozen v1 sentence shape stays readable and publishable" do
      assert {:ok, []} = Finding.validate(%{"findings" => []}, record())
      assert {:ok, ["空输入导致越界，见 source.cpp:10。"]} = Finding.validate(%{"findings" => ["空输入导致越界，见 source.cpp:10。"]}, record())
    end

    test "every unsupported submission shape is refused instead of silently degraded" do
      for {arguments, reason} <- [
            {%{}, :invalid_review_submission},
            {"bad", :invalid_review_submission},
            {%{"findings" => ["English only"]}, :invalid_review_submission},
            {%{"findings" => ["请核对空输入。\n/approve"]}, :invalid_review_submission},
            {%{"findings" => [String.duplicate("中", 6_000)]}, :invalid_review_submission},
            {%{"findings" => [], "extra" => 1}, :unsupported_review_submission},
            {%{"findings" => "中文"}, :unsupported_review_submission},
            {%{"findings" => List.duplicate("中文", 51)}, :unsupported_review_submission},
            {%{"findings" => [], "responses" => "x"}, :unsupported_review_submission},
            {%{"findings" => ["中文", finding()]}, :unsupported_review_submission_schema},
            {%{"findings" => [123]}, :unsupported_review_submission_schema},
            {%{"findings" => ["中文"], "responses" => []}, :unsupported_review_submission_schema}
          ] do
        assert {:error, ^reason} = Finding.validate(arguments, record())
      end

      assert {:error, :invalid_review_submission} = Finding.validate(%{"findings" => []}, nil)
    end

    test "structured findings carry identity, criterion and version" do
      finding = finding()
      assert {:ok, %{"findings" => [^finding], "responses" => []}} = Finding.validate(%{"findings" => [finding]}, record())
    end

    test "a malformed structured finding is refused with a precise reason" do
      for {value, reason} <- [
            {Map.drop(finding(), ["impact"]), :invalid_review_finding},
            {%{finding() | "schema_version" => 2}, :unsupported_review_finding_schema},
            {%{finding() | "id" => "bad id"}, :invalid_finding_identity},
            {%{finding() | "required" => "yes"}, :invalid_finding_class},
            {%{finding() | "criterion" => "   "}, :incomplete_review_finding},
            {%{finding() | "impact" => "english only"}, :non_chinese_review_finding},
            {%{finding() | "resolution" => "no chinese"}, :non_chinese_review_finding},
            {%{finding() | "version" => Map.put(version(), "extra", 1)}, :invalid_finding_version},
            {%{finding() | "version" => "not a version"}, :invalid_finding_version},
            {%{finding() | "regression_of" => "bad id"}, :invalid_finding_regression},
            {%{finding() | "version" => version(String.duplicate("d", 40))}, :finding_version_not_current}
          ] do
        assert {:error, ^reason} = Finding.validate(%{"findings" => [value]}, record())
      end
    end

    test "finding identity is unique within one submission" do
      assert {:error, :duplicate_finding_identity} = Finding.validate(%{"findings" => [finding(), finding()]}, record())
    end

    test "a regression must reference an identity the register already knows" do
      assert {:error, :unknown_finding_regression} = Finding.validate(%{"findings" => [%{finding() | "regression_of" => "Gone"}]}, record())

      register = registered([finding()])
      regressed = %{finding() | "id" => "F2", "regression_of" => "F1"}
      assert {:ok, %{"findings" => [^regressed], "responses" => []}} = Finding.validate(%{"findings" => [regressed]}, record(%{"finding_register" => register}))
    end
  end

  describe "independent resolution" do
    test "only an independent reviewer response may settle a finding" do
      register = registered([finding()])
      base = %{"finding" => "F1", "status" => "fixed", "evidence" => "已补充边界测试", "rationale" => nil, "verified_by" => "reviewer"}

      for {response, reason} <- [
            {Map.drop(base, ["status"]), :invalid_review_response},
            {%{base | "status" => "done"}, :invalid_finding_status},
            {%{base | "verified_by" => "developer"}, :review_verdict_author_not_independent},
            {%{base | "finding" => "  "}, :invalid_review_response},
            {%{base | "evidence" => nil}, :incomplete_finding_resolution},
            {%{base | "status" => "undecidable", "rationale" => nil, "evidence" => nil}, :incomplete_finding_resolution},
            {%{base | "finding" => "Missing"}, :unknown_finding_response},
            {"not a map", :unsupported_review_submission_schema}
          ] do
        assert {:error, ^reason} = Finding.validate(%{"findings" => [], "responses" => [response]}, record(%{"finding_register" => register}))
      end

      refuted = %{"finding" => "F1", "status" => "not_substantiated", "evidence" => nil, "rationale" => "新版本已证明输入受限", "verified_by" => "reviewer"}
      submission = %{"findings" => [], "responses" => [refuted]}

      assert {:ok, %{"findings" => [], "responses" => [^refuted]}} =
               Finding.validate(submission, record(%{"finding_register" => register}))
    end
  end

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

      assert Finding.advance(%{"kept" => 1}, ["旧版一句话结论。"], 4) == %{"kept" => 1}
      assert Finding.advance(nil, ["旧版一句话结论。"], 4) == %{}
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

    test "a finding renders a class-separated, machine-checkable comment" do
      assert Finding.render(finding()) =~ "[必需（阻止技术通过）] F1"
      assert Finding.render(finding()) =~ "<!-- symphony-finding "
      assert Finding.render(finding()) =~ "适用版本：head=#{@head} base=#{@base} target=main"
      assert Finding.render(%{finding() | "required" => false}) =~ "[建议（不阻止技术通过）] F1"
      assert Finding.render(%{finding() | "regression_of" => "OLD"}) =~ "回归关系：原问题 OLD"
    end
  end

  describe "agent tool schema" do
    test "review_submit advertises the structured finding and response schemas" do
      [%{"name" => "review_submit", "inputSchema" => %{"properties" => properties}}] = SymphonyElixir.ReviewLane.agent_tool_specs()

      assert %{"findings" => %{"items" => finding_schema}, "responses" => %{"items" => response_schema}} = properties
      assert finding_schema["required"] == ~w(schema_version id required criterion version location evidence impact resolution regression_of)
      assert finding_schema["properties"]["version"]["required"] == ~w(head base target)
      assert response_schema["required"] == ~w(finding status evidence rationale verified_by)
    end
  end

  describe "publication mapping" do
    test "a required condition is published separately from advice" do
      submission = %{"findings" => [finding(), %{finding() | "id" => "F2", "required" => false}], "responses" => []}
      register = Finding.advance(nil, submission, 1)

      assert {:ok, prepared} = Publication.prepare(publication_record(register), submission, 20)
      bodies = Enum.map(prepared["publication"]["entries"], & &1["body"])

      assert length(bodies) == 3
      assert Enum.any?(bodies, &String.contains?(&1, "阻止技术通过：必需项 F1"))
      assert Enum.any?(bodies, &String.contains?(&1, "建议性改善（不阻止技术通过）：F2"))
      assert Enum.all?(bodies, &String.contains?(&1, "<!-- symphony-review:"))
    end

    test "advice alone never withholds a technical pass" do
      submission = %{"findings" => [%{finding() | "required" => false}], "responses" => []}
      register = Finding.advance(nil, submission, 1)

      assert {:ok, prepared} = Publication.prepare(publication_record(register), submission, 20)
      [_finding, conclusion] = prepared["publication"]["entries"]
      assert conclusion["body"] =~ "建议性改善（不阻止技术通过）：F1"
      refute conclusion["body"] =~ "阻止技术通过：必需项"
      refute Finding.verdict(register)["blocking"]
    end

    test "the frozen v1 list still publishes and a native-command body is refused" do
      assert {:ok, prepared} = Publication.prepare(publication_record(%{}), ["空输入导致越界，见 source.cpp:10。"], 20)
      assert length(prepared["publication"]["entries"]) == 2

      injection = %{finding() | "evidence" => "复现步骤：\n/approve"}
      submission = %{"findings" => [injection], "responses" => []}

      assert {:error, :invalid_review_publication_body} =
               Publication.prepare(publication_record(%{}), submission, 20)
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

  defp record(overrides \\ %{}) do
    Map.merge(%{"head" => @head, "base" => @base, "target_branch" => "main", "finding_register" => %{}}, overrides)
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
      "instructions_file" => Path.join(root, "instructions"),
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
