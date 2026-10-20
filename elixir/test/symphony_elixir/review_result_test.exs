defmodule SymphonyElixir.ReviewResultTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.ReviewLane.Finding
  alias SymphonyElixir.{ReviewResult, TaskWorkflow}

  defp record, do: %{"round" => 2, "head" => String.duplicate("a", 40), "base" => String.duplicate("b", 40), "policy_sha" => TaskWorkflow.digest("policy"), "target_branch" => "main"}

  defp axis(name),
    do: %{
      "status" => "complete",
      "report" => "已完成全部核对。",
      "findings" => [],
      "responses" => [],
      "thread_id" => name,
      "turn_id" => name <> "-turn",
      "reads_verified" => true,
      "native_stop_confirmed" => true
    }

  defp axes, do: Map.new(["standards", "spec"], &{&1, axis(&1)})

  defp finding do
    r = record()

    %{
      "schema_version" => 1,
      "id" => "R1",
      "required" => true,
      "criterion" => "约定的边界行为",
      "version" => %{"head" => r["head"], "base" => r["base"], "target" => "main"},
      "location" => "source.c:10",
      "evidence" => "空输入触发越界",
      "impact" => "输入可导致进程崩溃。",
      "resolution" => "空输入通过回归验证。",
      "regression_of" => nil
    }
  end

  test "clean body is exact; advisory and required findings retain separate axes" do
    assert {:ok, result} = ReviewResult.aggregate(record(), axes())
    assert result["body"] == "LGTM!"
    assert ReviewResult.render(result) == "LGTM!"
    assert ReviewResult.validate(result, record()) == :ok

    for required <- [true, false] do
      input = put_in(axes(), ["spec", "findings"], [Map.put(finding(), "required", required)])
      assert {:ok, report} = ReviewResult.aggregate(record(), input)
      assert report["status"] == "changes_requested"
      assert report["body"] =~ "## Standards"
      assert report["body"] =~ "## Spec"
      assert report["body"] =~ "空输入触发越界"
      assert ReviewResult.validate(report, record()) == :ok
    end
  end

  test "prior required findings cannot disappear without independent resolution" do
    registered = Finding.advance(nil, %{"findings" => [finding()], "responses" => []}, 1)
    r = Map.put(record(), "finding_register", registered)
    assert {:ok, pending} = ReviewResult.aggregate(r, axes())
    assert pending["status"] == "needs_input"
    assert pending["body"] =~ "R1"
    assert ReviewResult.render(pending) == pending["body"]
    response = %{"finding" => "R1", "status" => "fixed", "evidence" => "已读取修复及对应回归", "rationale" => "满足原约定", "verified_by" => "reviewer"}
    resolved = put_in(axes(), ["spec", "responses"], [response])
    assert {:ok, pass} = ReviewResult.aggregate(r, resolved)
    assert pass["body"] == "LGTM!"
    advanced = Finding.advance(registered, %{"findings" => [], "responses" => [response]}, 2)
    assert ReviewResult.validate(pass, Map.put(r, "finding_register", advanced)) == :ok
  end

  test "an independently confirmed still-valid finding completes with changes requested" do
    prior = Finding.advance(nil, %{"findings" => [finding()], "responses" => []}, 1)
    r = Map.put(record(), "finding_register", prior)

    for {judgement, expected} <- [{"still_valid", "changes_requested"}, {"undecidable", "needs_input"}] do
      response = %{"finding" => "R1", "status" => judgement, "evidence" => "已完整核对当前源码和反例", "rationale" => "独立复核结论", "verified_by" => "reviewer"}
      input = put_in(axes(), ["spec", "responses"], [response])
      assert {:ok, result} = ReviewResult.aggregate(r, input)
      assert result["status"] == expected
      refute result["body"] == "LGTM!"
      advanced = Finding.advance(prior, %{"findings" => [], "responses" => [response]}, 2)
      assert ReviewResult.validate(result, Map.put(r, "finding_register", advanced)) == :ok
      forged = Map.merge(result, %{"status" => "passed", "body" => "LGTM!"})
      refute ReviewResult.render(forged) == "LGTM!"
      assert {:ok, missing} = ReviewResult.aggregate(Map.put(r, "finding_register", advanced), axes())
      assert missing["status"] == "needs_input"
    end
  end

  test "incomplete evidence, unknown shapes and nonindependent reviewers fail closed" do
    for patch <- [%{"status" => "failed"}, %{"status" => "needs_input"}] do
      assert {:ok, result} = ReviewResult.aggregate(record(), put_in(axes(), ["standards"], Map.merge(axis("standards"), patch)))
      refute result["body"] == "LGTM!"
    end

    for patch <- [%{"thread_id" => nil}, %{"turn_id" => nil}, %{"reads_verified" => false}, %{"native_stop_confirmed" => false}, %{"report" => ""}, %{"read_failure" => true}] do
      assert {:error, _} = ReviewResult.aggregate(record(), put_in(axes(), ["standards"], Map.merge(axis("standards"), patch)))
    end

    duplicate = put_in(axes(), ["spec", "thread_id"], "standards")
    assert {:ok, %{"status" => "failed"}} = ReviewResult.aggregate(record(), duplicate)

    for invalid <- [
          nil,
          %{},
          %{"standards" => nil, "spec" => axis("spec")},
          Map.put(axes(), "third", axis("third")),
          put_in(axes(), ["spec", "findings"], ["unstructured"]),
          put_in(axes(), ["spec", "status"], "skipped"),
          put_in(axes(), ["spec", "report"], nil),
          put_in(axes(), ["spec", "unknown"], true)
        ] do
      assert {:error, _} = ReviewResult.aggregate(record(), invalid)
    end

    for invalid <- [%{}, Map.put(record(), "head", "bad"), Map.put(record(), "finding_register", []), Map.put(record(), "finding_register", %{"bad" => %{}})] do
      assert {:error, _} = ReviewResult.aggregate(invalid, axes())
    end

    assert {:error, _} = ReviewResult.aggregate(nil, axes())
    assert {:error, _} = ReviewResult.aggregate(record(), put_in(axes(), ["spec", "findings"], [%{}]))
    input = axes() |> put_in(["spec", "findings"], [finding()]) |> put_in(["standards", "findings"], [finding()])
    assert {:error, :duplicate_finding_identity} = ReviewResult.aggregate(record(), input)
  end

  test "a response cannot resolve a finding that another axis reopens in the same round" do
    registered = Finding.advance(nil, %{"findings" => [finding()], "responses" => []}, 1)
    r = Map.put(record(), "finding_register", registered)
    response = %{"finding" => "R1", "status" => "fixed", "evidence" => "本轴认为已修复", "rationale" => "满足原约定", "verified_by" => "reviewer"}
    input = axes() |> put_in(["standards", "findings"], [finding()]) |> put_in(["spec", "responses"], [response])
    assert {:error, :conflicting_finding_resolution} = ReviewResult.aggregate(r, input)
    assert registered["R1"]["status"] == "open"
    assert {:ok, pending} = ReviewResult.aggregate(%{r | "round" => 3}, axes())
    refute pending["body"] == "LGTM!"
  end

  test "invalid text and a forged pass cannot hide an incomplete axis" do
    malformed = put_in(axes(), ["standards", "report"], <<255>>)
    assert {:error, _} = ReviewResult.aggregate(record(), malformed)
    {:ok, result} = ReviewResult.aggregate(record(), axes())
    forged = Map.put(result, "axes", malformed)
    assert {:error, _} = ReviewResult.validate(forged, record())
    refute ReviewResult.render(forged) == "LGTM!"
    failed = put_in(result, ["axes", "spec", "status"], "failed")
    refute ReviewResult.render(failed) == "LGTM!"
    refute ReviewResult.render(Map.put(result, "status", "failed")) == "LGTM!"
    bad_finding = put_in(axes(), ["spec", "findings"], [Map.put(finding(), "impact", <<255>>)])
    assert {:error, _} = ReviewResult.aggregate(record(), bad_finding)
  end

  test "tampering with version, flattened items, status or canonical body cannot validate" do
    {:ok, result} = ReviewResult.aggregate(record(), axes())

    for patch <- [
          %{"head" => String.duplicate("c", 40)},
          %{"base" => "bad"},
          %{"policy_sha" => "bad"},
          %{"findings" => [finding()]},
          %{"body" => "LGTM! extra"},
          %{"protocol" => 1},
          %{"extra" => true},
          %{"status" => "failed"},
          %{"axes" => nil}
        ] do
      assert {:error, _} = ReviewResult.validate(Map.merge(result, patch), record())
    end

    assert {:error, _} = ReviewResult.validate(nil, record())
    refute ReviewResult.render(nil) == "LGTM!"
    refute ReviewResult.render(Map.put(result, "body", "LGTM! extra")) == "LGTM!"
    refute ReviewResult.render(put_in(result, ["axes", "standards", "report"], "")) == "LGTM!"
  end
end
