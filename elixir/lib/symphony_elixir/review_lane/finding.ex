defmodule SymphonyElixir.ReviewLane.Finding do
  @moduledoc """
  Structured, version-bound standalone review findings (§17.1).

  A finding keeps a stable identity across rounds and records the version it
  applies to, the criterion or repository rule it violates, the exact location,
  the facts it rests on, its impact and a verifiable resolution condition.
  Advisory suggestions and conditions that block technical acceptance stay in
  separate classes: only a violated agreed standard can withhold a technical
  pass.

  A developer answer is evidence, never a verdict. Open findings are resolved
  through the independent reviewer channel only, so a developer cannot mark a
  required condition as passed, and a continuing objection has to name the
  evidence that the new version still violates the agreed standard.

  Findings submitted through the older v1 shape — one Chinese sentence per
  finding — stay readable and publishable because stored journals and older
  agents still produce it. That shape carries no identity, so it never enters
  the structured register and can never withhold a technical pass. Every other
  submission shape is refused outright instead of being read as if it carried
  the structured fields (§13.1).
  """

  alias SymphonyElixir.ReviewLane.GitLab

  @protocol 1
  @identity ~r/^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$/
  @cjk ~r/[\x{4e00}-\x{9fff}]/u
  @max_items 50
  @legacy_limit 16_384
  @legacy_marker "<!-- symphony-review:"
  @keys ~w(findings responses)
  @fields ~w(schema_version id required criterion version location evidence impact resolution regression_of)
  @response_fields ~w(finding status evidence rationale verified_by)
  @resolutions %{"fixed" => "fixed", "not_substantiated" => "refuted", "still_valid" => "open", "undecidable" => "undecidable"}
  @settled ["fixed", "refuted"]
  @text_limit 4_096

  @doc """
  Validate one submission against the fixed round it was produced for.

  Returns the normalized submission — the structured §17.1 map, or the frozen
  v1 list — or the reason the submission cannot be trusted. An unknown or
  partially structured shape is refused so it cannot be processed as if it had
  carried the missing fields.
  """
  @spec validate(term(), map()) :: {:ok, map() | [String.t()]} | {:error, atom()}
  def validate(%{"findings" => findings} = arguments, record) when is_map(record) do
    with true <- Enum.all?(Map.keys(arguments), &(&1 in @keys)),
         true <- items?(findings),
         true <- items?(Map.get(arguments, "responses", [])) do
      case protocol(arguments) do
        :structured -> structured(arguments, record)
        :legacy -> legacy(findings)
        _ -> {:error, :unsupported_review_submission_schema}
      end
    else
      _ -> {:error, :unsupported_review_submission}
    end
  end

  def validate(_arguments, _record), do: {:error, :invalid_review_submission}

  @doc "Advance the stable finding register with one accepted submission."
  @spec advance(map() | nil, map() | [String.t()], pos_integer()) :: map()
  def advance(register, %{"findings" => findings, "responses" => responses}, round) do
    register = Enum.reduce(findings, register || %{}, &record_finding(&2, &1, round))
    Enum.reduce(responses, register, &resolve(&2, &1, round))
  end

  # A v1 submission carries no identity to register, so it cannot open, block
  # or close a structured finding.
  def advance(register, _legacy, _round), do: register || %{}

  @doc "Project what currently withholds technical pass, what needs a human decision and what is only advisory."
  @spec verdict(map() | nil) :: map()
  def verdict(register) do
    entries = Map.values(register || %{})
    open = Enum.filter(entries, &required?(&1, "open"))
    undecided = Enum.filter(entries, &required?(&1, "undecidable"))

    %{
      "blocking" => open != [],
      "decision_required" => undecided != [],
      "required_open" => ids(open),
      "undecidable" => ids(undecided),
      "suggestions" => ids(Enum.reject(entries, & &1["required"])),
      "resolved" => ids(Enum.filter(entries, &(&1["status"] in @settled)))
    }
  end

  @doc "Render one finding as a native, machine-checkable comment body."
  @spec render(map()) :: String.t()
  def render(finding) do
    class = if finding["required"], do: "必需（阻止技术通过）", else: "建议（不阻止技术通过）"
    regression = if finding["regression_of"], do: "\n回归关系：原问题 #{finding["regression_of"]} 修复后重新出现。", else: ""

    "[#{class}] #{finding["id"]}（违反标准：#{finding["criterion"]}）\n\n" <>
      "位置：#{finding["location"]}\n事实依据：#{finding["evidence"]}\n影响：#{finding["impact"]}\n" <>
      "可验证的解决条件：#{finding["resolution"]}#{regression}\n\n" <>
      "适用版本：head=#{finding["version"]["head"]} base=#{finding["version"]["base"]} target=#{finding["version"]["target"]}\n" <>
      "<!-- symphony-finding #{Jason.encode!(finding)} -->"
  end

  @doc "Whether one stored finding register entry set is well formed."
  @spec register?(term()) :: boolean()
  def register?(register) when is_map(register) do
    Enum.all?(register, fn {id, entry} ->
      is_map(entry) and is_binary(id) and entry["id"] == id and Regex.match?(@identity, id) and
        is_boolean(entry["required"]) and text?(entry["criterion"]) and entry["status"] in ~w(open fixed refuted undecidable) and
        is_integer(entry["round"]) and entry["round"] > 0
    end)
  end

  def register?(_register), do: false

  # Responses, a map entry or a partially structured list decides whether the
  # caller asked for the structured protocol at all.
  defp protocol(%{"findings" => findings} = arguments) when is_list(findings) do
    cond do
      Map.has_key?(arguments, "responses") -> :structured
      Enum.all?(findings, &is_binary/1) -> :legacy
      Enum.all?(findings, &is_map/1) -> :structured
      true -> :unsupported
    end
  end

  defp structured(arguments, record) do
    findings = arguments["findings"]
    responses = Map.get(arguments, "responses", [])

    with {:ok, findings} <- collect(findings, &finding/1),
         true <- unique?(findings, & &1["id"]) or {:error, :duplicate_finding_identity},
         :ok <- every(findings, &bound?(&1, record)),
         :ok <- every(findings, &regression?(&1, record)),
         :ok <- every(responses, &response/1),
         :ok <- every(responses, &known?(&1, record)) do
      {:ok, %{"findings" => findings, "responses" => responses}}
    else
      {:error, _reason} = error -> error
    end
  end

  defp legacy(findings) do
    if Enum.all?(findings, &legacy_finding?/1), do: {:ok, findings}, else: {:error, :invalid_review_submission}
  end

  defp legacy_finding?(finding) do
    is_binary(finding) and byte_size(finding) in 1..@legacy_limit and String.valid?(finding) and
      Regex.match?(@cjk, finding) and not String.contains?(finding, @legacy_marker) and GitLab.comment_body?(finding)
  end

  # The ordered checks keep each validation rule small and report the first
  # violated one, so every refusal names a single precise reason.
  defp finding(%{} = value) do
    case first_error(finding_checks(), value) do
      nil -> {:ok, value}
      error -> {:error, error}
    end
  end

  # A finding that is not a complete structured object is refused instead of
  # being silently read as the v1 sentence shape.
  defp finding(_value), do: {:error, :unsupported_review_submission_schema}

  defp finding_checks do
    [
      {:invalid_review_finding, &(not schema?(Map.keys(&1), @fields))},
      {:unsupported_review_finding_schema, &(&1["schema_version"] != @protocol)},
      {:invalid_finding_identity, &(not identifier?(&1["id"]))},
      {:invalid_finding_class, &(not is_boolean(&1["required"]))},
      {:incomplete_review_finding, &(not complete_text?(&1))},
      {:non_chinese_review_finding, &(not chinese?(&1))},
      {:invalid_finding_version, &(not version?(&1["version"]))},
      {:invalid_finding_regression, &(not regression_identity?(&1["regression_of"]))}
    ]
  end

  defp response(%{} = value) do
    case first_error(response_checks(), value) do
      nil -> :ok
      error -> {:error, error}
    end
  end

  defp response(_value), do: {:error, :unsupported_review_submission_schema}

  defp response_checks do
    [
      {:invalid_review_response, &(not schema?(Map.keys(&1), @response_fields))},
      {:invalid_finding_status, &(not Map.has_key?(@resolutions, &1["status"]))},
      {:review_verdict_author_not_independent, &(&1["verified_by"] != "reviewer")},
      {:invalid_review_response, &(not text?(&1["finding"]))},
      {:incomplete_finding_resolution, &needs_evidence?(&1)},
      {:incomplete_finding_resolution, &needs_rationale?(&1)}
    ]
  end

  defp first_error(checks, value), do: Enum.find_value(checks, fn {error, violated?} -> if violated?.(value), do: error, else: nil end)

  defp schema?(keys, fields), do: Enum.sort(keys) == Enum.sort(fields)
  defp identifier?(value), do: is_binary(value) and Regex.match?(@identity, value)

  defp complete_text?(value), do: Enum.all?(~w(criterion location evidence impact resolution), &text?(value[&1]))
  defp chinese?(value), do: cjk?(value["impact"]) and cjk?(value["resolution"])
  defp regression_identity?(nil), do: true
  defp regression_identity?(value), do: identifier?(value)
  defp needs_evidence?(value), do: value["status"] in ["fixed", "still_valid"] and not text?(value["evidence"])
  defp needs_rationale?(value), do: value["status"] in ["not_substantiated", "undecidable"] and not text?(value["rationale"])

  defp bound?(finding, record) do
    expected = %{"head" => record["head"], "base" => record["base"], "target" => record["target_branch"]}
    if finding["version"] == expected, do: :ok, else: {:error, :finding_version_not_current}
  end

  defp regression?(finding, record) do
    case finding["regression_of"] do
      nil -> :ok
      id -> if(Map.has_key?(record["finding_register"] || %{}, id), do: :ok, else: {:error, :unknown_finding_regression})
    end
  end

  defp known?(response, record) do
    if Map.has_key?(record["finding_register"] || %{}, response["finding"]), do: :ok, else: {:error, :unknown_finding_response}
  end

  defp record_finding(register, finding, round) do
    Map.put(register, finding["id"], %{
      "id" => finding["id"],
      "required" => finding["required"],
      "criterion" => finding["criterion"],
      "status" => "open",
      "round" => round,
      "version" => finding["version"],
      "regression_of" => finding["regression_of"]
    })
  end

  defp resolve(register, response, round) do
    entry = register[response["finding"]]
    patch = %{"status" => @resolutions[response["status"]], "resolved_by" => "reviewer", "resolution" => Map.take(response, ~w(status evidence rationale)), "resolved_round" => round}

    Map.put(register, entry["id"], Map.merge(entry, patch))
  end

  defp required?(entry, status), do: entry["required"] and entry["status"] == status
  defp ids(entries), do: entries |> Enum.map(& &1["id"]) |> Enum.sort()
  defp items?(value), do: is_list(value) and length(value) <= @max_items

  defp collect(values, fun) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, done} ->
      case fun.(value) do
        {:ok, entry} -> {:cont, {:ok, done ++ [entry]}}
        error -> {:halt, error}
      end
    end)
  end

  defp every(values, fun) do
    Enum.reduce_while(values, :ok, fn value, :ok ->
      case fun.(value) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp version?(%{"head" => head, "base" => base, "target" => target} = version) when map_size(version) == 3 do
    Enum.all?([head, base], &(is_binary(&1) and Regex.match?(~r/^(?:[a-f0-9]{40}|[a-f0-9]{64})$/, &1))) and text?(target)
  end

  defp version?(_version), do: false
  defp cjk?(value), do: Regex.match?(@cjk, value)

  defp text?(value) do
    is_binary(value) and byte_size(value) <= @text_limit and String.valid?(value) and
      String.trim(value) != "" and not String.contains?(value, <<0>>)
  end

  defp unique?(values, key), do: length(Enum.uniq_by(values, key)) == length(values)
end
