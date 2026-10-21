defmodule SymphonyElixir.ReviewLane.Finding do
  @moduledoc "Persist and project the finding register from validated workflow artifacts."
  @identity ~r/^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$/
  @resolutions %{"fixed" => "fixed", "not_substantiated" => "refuted", "still_valid" => "open", "undecidable" => "undecidable"}
  @settled ["fixed", "refuted"]
  @text_limit 4_096

  @doc "Advance the stable finding register with one accepted submission."
  @spec advance(map() | nil, map(), pos_integer()) :: map()
  def advance(register, %{"findings" => findings, "responses" => responses}, round) do
    register = Enum.reduce(findings, register || %{}, &record_finding(&2, &1, round))
    Enum.reduce(responses, register, &resolve(&2, &1, round))
  end

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

  defp text?(value) do
    is_binary(value) and byte_size(value) <= @text_limit and String.valid?(value) and
      String.trim(value) != "" and not String.contains?(value, <<0>>)
  end
end
