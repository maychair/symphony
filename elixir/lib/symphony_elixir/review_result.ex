defmodule SymphonyElixir.ReviewResult do
  @moduledoc """
  Canonical result for a two-axis unified review.

  The result is derived from the engine-owned axes and is bound to the exact
  reviewed revisions and policy. A technical pass requires two complete,
  independently verified axes and no unresolved required findings.
  """

  alias SymphonyElixir.ReviewLane.Finding

  @axes ["standards", "spec"]
  @statuses ["complete", "failed", "needs_input"]
  @result_statuses ["passed", "changes_requested", "failed", "needs_input"]
  @result_fields ~w(protocol status head base policy_sha axes findings responses body)
  @axis_fields ~w(status findings responses report thread_id turn_id native_stop_confirmed reads_verified)
  @runtime_axis_fields ~w(workspace worker_host thread_allocation_intent turn_allocation_intent native_stop_receipt native_stop_error read_failure)
  @failed_body "评审未通过。"
  @needs_input_body "评审需要补充输入。"
  @incomplete_body "该审查轴未完成。"

  @doc "Aggregate two engine-owned axes into one canonical, fail-closed result."
  @spec aggregate(map(), map()) :: {:ok, map()} | {:error, atom()}
  def aggregate(record, axes) when is_map(record) and is_map(axes) do
    with :ok <- revision_record?(record),
         {:ok, register} <- valid_register(record["finding_register"]),
         {:ok, axes} <- valid_axes(axes),
         {:ok, findings, responses} <- valid_review_items(axes, record) do
      review = %{"findings" => findings, "responses" => responses}
      advanced = Finding.advance(register, review, record["round"])
      unresolved = unresolved(advanced, record["round"])
      status = status(axes, findings, unresolved)

      {:ok,
       %{
         "protocol" => 2,
         "status" => status,
         "head" => record["head"],
         "base" => record["base"],
         "policy_sha" => record["policy_sha"],
         "axes" => axes,
         "findings" => findings,
         "responses" => responses,
         "body" => render_body(status, axes, unresolved)
       }}
    end
  end

  def aggregate(_record, _axes), do: {:error, :invalid_review_result}

  @doc "Validate a result against the exact axes and revision persisted by the engine."
  @spec validate(term(), map()) :: :ok | {:error, atom()}
  def validate(%{} = result, record) when is_map(record) do
    with :ok <- result_shape(result),
         {:ok, axes} <- valid_axes(result["axes"]),
         {:ok, findings, responses} <- valid_review_items(axes, record),
         :ok <- revision?(result, record),
         true <- (result["findings"] == findings and result["responses"] == responses) or {:error, :forged_review_flattening},
         {:ok, expected} <- aggregate(record, axes),
         true <- result == expected or {:error, :invalid_review_result} do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def validate(_result, _record), do: {:error, :invalid_review_result}

  @doc "Render the already-derived canonical native review comment body."
  @spec render(map()) :: String.t()
  def render(%{"status" => status, "axes" => axes, "body" => body} = result)
      when status in @result_statuses and is_map(axes) and is_binary(body) do
    with :ok <- result_shape(result),
         {:ok, axes} <- valid_axes(axes),
         true <- status != "passed" or (complete_axes?(axes) and no_required_findings?(axes)),
         true <- if(status == "passed", do: body == "LGTM!", else: String.trim(body) != "LGTM!") do
      body
    else
      _ -> render_failure()
    end
  end

  def render(_result), do: render_failure()

  defp result_shape(result) do
    if Enum.sort(Map.keys(result)) == Enum.sort(@result_fields) and result["protocol"] == 2 and
         result["status"] in @result_statuses and is_binary(result["body"]),
       do: :ok,
       else: {:error, :invalid_review_result}
  end

  defp valid_axes(axes) when is_map(axes) and map_size(axes) == 2 do
    if Enum.sort(Map.keys(axes)) == Enum.sort(@axes),
      do: Enum.reduce_while(@axes, {:ok, axes}, &valid_axis(&1, axes, &2)),
      else: {:error, :invalid_review_axes}
  end

  defp valid_axes(_axes), do: {:error, :invalid_review_axes}

  defp valid_axis(name, axes, {:ok, acc}) do
    case valid_axis(axes[name]) do
      :ok -> {:cont, {:ok, acc}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp valid_axis(%{} = axis) do
    keys = Map.keys(axis)
    allowed = @axis_fields ++ @runtime_axis_fields

    cond do
      not Enum.all?(@axis_fields, &Map.has_key?(axis, &1)) -> {:error, :invalid_review_axis}
      not Enum.all?(keys, &(&1 in allowed)) -> {:error, :invalid_review_axis}
      not shape_fields?(axis) -> {:error, :invalid_review_axis}
      axis["status"] == "complete" and not complete_axis?(axis) -> {:error, :incomplete_review_axis}
      true -> :ok
    end
  end

  defp valid_axis(_axis), do: {:error, :invalid_review_axis}

  defp shape_fields?(axis) do
    axis["status"] in @statuses and axis_items?(axis) and
      is_binary(axis["report"]) and String.valid?(axis["report"]) and identity?(axis["thread_id"]) and identity?(axis["turn_id"]) and
      is_boolean(axis["native_stop_confirmed"]) and is_boolean(axis["reads_verified"])
  end

  defp axis_items?(axis) do
    is_list(axis["findings"]) and is_list(axis["responses"]) and
      Enum.all?(axis["findings"], &is_map/1) and Enum.all?(axis["responses"], &is_map/1)
  end

  defp complete_axis?(%{"status" => "complete"} = axis) do
    text?(axis["report"]) and text?(axis["thread_id"]) and text?(axis["turn_id"]) and
      axis["native_stop_confirmed"] == true and axis["reads_verified"] == true and axis["read_failure"] != true
  end

  defp complete_axis?(_axis), do: false

  defp valid_review_items(axes, record) do
    findings = flattened(axes, "findings")
    responses = flattened(axes, "responses")

    with true <- unique_by?(findings, "id") or {:error, :duplicate_finding_identity},
         true <- unique_by?(responses, "finding") or {:error, :duplicate_review_response},
         true <- disjoint_resolutions?(findings, responses) or {:error, :conflicting_finding_resolution},
         {:ok, normalized} <-
           Finding.validate(%{"findings" => findings, "responses" => responses}, record) do
      {:ok, normalized["findings"], normalized["responses"]}
    end
  end

  defp unique_by?(items, field), do: length(Enum.uniq_by(items, & &1[field])) == length(items)

  defp disjoint_resolutions?(findings, responses) do
    MapSet.disjoint?(MapSet.new(findings, & &1["id"]), MapSet.new(responses, & &1["finding"]))
  end

  defp valid_register(nil), do: {:ok, %{}}

  defp valid_register(register) when is_map(register) do
    if Finding.register?(register), do: {:ok, register}, else: {:error, :invalid_finding_register}
  end

  defp valid_register(_register), do: {:error, :invalid_finding_register}

  defp revision_record?(record) do
    if is_integer(record["round"]) and record["round"] > 0 and revision_value?(record["head"]) and
         revision_value?(record["base"]) and digest?(record["policy_sha"]),
       do: :ok,
       else: {:error, :review_result_version_mismatch}
  end

  defp revision?(result, record) do
    if result["head"] == record["head"] and result["base"] == record["base"] and
         result["policy_sha"] == record["policy_sha"],
       do: revision_record?(record),
       else: {:error, :review_result_version_mismatch}
  end

  defp status(axes, findings, unresolved) do
    statuses = Enum.map(@axes, &axes[&1]["status"])

    cond do
      "failed" in statuses -> "failed"
      "needs_input" in statuses -> "needs_input"
      not complete_axes?(axes) -> "failed"
      unresolved != [] -> "needs_input"
      findings != [] -> "changes_requested"
      true -> "passed"
    end
  end

  defp complete_axes?(%{"standards" => standards, "spec" => spec}) do
    complete_axis?(standards) and complete_axis?(spec) and standards["thread_id"] != spec["thread_id"] and
      standards["turn_id"] != spec["turn_id"]
  end

  defp no_required_findings?(axes), do: flattened(axes, "findings") == []

  defp unresolved(after_advance, round) do
    after_advance
    |> Enum.filter(fn {_id, entry} ->
      entry["round"] < round and entry["required"] == true and entry["status"] in ["open", "undecidable"]
    end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  defp flattened(axes, field), do: Enum.flat_map(@axes, &Map.fetch!(axes[&1], field))

  defp render_body("passed", _axes, []), do: "LGTM!"

  defp render_body("changes_requested", axes, _unresolved), do: axis_sections(axes)

  defp render_body("needs_input", axes, unresolved),
    do: @needs_input_body <> "\n\n" <> axis_sections(axes) <> unresolved_section(unresolved)

  defp render_body("failed", axes, unresolved),
    do: @failed_body <> "\n\n" <> axis_sections(axes) <> unresolved_section(unresolved)

  defp render_failure, do: render_body("failed", %{}, [])

  defp axis_sections(axes) do
    Enum.map_join(@axes, "\n\n", &axis_section(&1, axes[&1]))
  end

  defp axis_section(name, axis) when is_map(axis) do
    heading = "## " <> String.capitalize(name)
    report = if text?(axis["report"]), do: axis["report"], else: @incomplete_body
    findings = Enum.map(axis["findings"], &Finding.render/1)

    heading <> "\n\n" <> report <> if(findings == [], do: "", else: "\n\n" <> Enum.join(findings, "\n\n"))
  end

  defp axis_section(name, _axis), do: "## #{String.capitalize(name)}\n\n" <> @incomplete_body

  defp unresolved_section([]), do: ""

  defp unresolved_section(ids) do
    "\n\n## 尚未解决的必要项\n\n必需 Finding #{Enum.join(ids, "、")} 尚未由独立评审响应解决。"
  end

  defp identity?(nil), do: true
  defp identity?(value), do: text?(value)
  defp text?(value), do: is_binary(value) and String.valid?(value) and String.trim(value) != ""

  defp revision_value?(value),
    do: is_binary(value) and Regex.match?(~r/^(?:[a-f0-9]{40}|[a-f0-9]{64})$/, value)

  defp digest?(value), do: is_binary(value) and Regex.match?(~r/^[a-f0-9]{64}$/, value)
end
