defmodule SymphonyElixir.TaskDelivery do
  @moduledoc "Resolve native delivery versions without treating merge intent or old-head verification as delivered evidence."
  alias SymphonyElixir.{GitArtifact, NativeWork, WorkRef}

  @doc "Check the frozen change target belongs to the output's owning repository. This is read scope, never merge permission."
  @spec target?(map(), map()) :: boolean()
  def target?(work, artifact) do
    target = artifact["target"]

    WorkRef.validate(target) == :ok and artifact["kind"] in ["pr", "mr"] and target["kind"] == artifact["kind"] and
      Map.take(target, ~w(provider host repository_id)) == Map.take(work, ~w(provider host repository_id))
  end

  @doc "Read delivery observations for a candidate, including the exact merged revision still requiring independent verification."
  @spec read_candidate(map(), map() | nil, keyword()) :: {:ok, [map()]} | {:error, term()}
  def read_candidate(_work, nil, _opts), do: {:ok, []}

  def read_candidate(work, candidate, opts) do
    Enum.reduce_while(candidate["artifacts"], {:ok, []}, fn artifact, {:ok, observations} ->
      case read(work, artifact, opts) do
        {:ok, observation} -> {:cont, {:ok, observations ++ [observation]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  @doc "Read native merge facts for one Git output. Technical validity remains the verifier's responsibility."
  @spec read(map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def read(work, %{"kind" => kind} = artifact, opts) when kind in ["pr", "mr"] do
    with true <- target?(work, artifact) or {:error, :delivery_target_unavailable},
         true <- artifact["source"] == GitArtifact.source_ref(work, artifact["version"]) or {:error, :delivery_source_mismatch},
         {:ok, snapshot} <- NativeWork.read_change(artifact["target"], opts),
         true <- snapshot.facts["target_branch"] == artifact["target_branch"] or {:error, :delivery_target_branch_changed},
         {:ok, status} <- status(work, artifact, snapshot.facts) do
      receipt = if status == "delivered", do: receipt(artifact, snapshot)
      {:ok, %{artifact: artifact["id"], status: status, snapshot: snapshot, receipt: receipt}}
    end
  end

  def read(_, artifact, _), do: {:ok, %{artifact: artifact["id"], status: "unsupported", snapshot: nil, receipt: nil}}

  defp status(work, artifact, facts) do
    repository = Map.take(work, ~w(provider host repository_id))

    cond do
      facts["merged"] and artifact["version"] == facts["revision"] -> {:ok, "delivered"}
      artifact["version"] != facts["head"] -> {:error, :delivery_candidate_changed}
      facts["source_repository"] != repository -> {:error, :delivery_source_repository_mismatch}
      facts["merged"] -> {:ok, "verification_required"}
      facts["state"] == "closed" -> {:ok, "closed_unmerged"}
      true -> {:ok, "awaiting_merge"}
    end
  end

  defp receipt(artifact, snapshot) do
    %{
      "artifact" => artifact["id"],
      "source_version" => artifact["version"],
      "delivered_version" => snapshot.facts["revision"],
      "source" => snapshot.source,
      "mapping" => snapshot.source,
      "head" => snapshot.facts["head"],
      "source_repository" => snapshot.facts["source_repository"],
      "target" => snapshot.work
    }
  end
end
