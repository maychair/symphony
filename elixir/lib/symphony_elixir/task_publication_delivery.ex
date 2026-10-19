defmodule SymphonyElixir.TaskPublicationDelivery do
  @moduledoc """
  Confirm an approved publication artifact reached its native target.

  The engine publishes candidates to their owning native Issue through
  TaskPublication, which persists the send intent, reads the response back and
  never reposts blindly. This boundary resolves that native fact for one fixed
  publication artifact: it binds the candidate digest, the artifact id, its Git
  revision and the target WorkRef into a stable identity, then rechecks the
  receipt against a fresh native read. It never writes and a write response alone
  is never accepted as delivery.
  """
  alias SymphonyElixir.{GitArtifact, NativeWork, TaskDecision, TaskPublication, TaskWorkflow, WorkRef}

  @payload ~w(work contract_sha inputs artifacts)

  @doc "Stable publication identity binding the fixed artifact, its version and the native target."
  @spec source_ref(map(), map()) :: String.t()
  def source_ref(work, artifact) do
    identity = %{"work" => work, "artifact" => artifact["id"], "version" => artifact["version"], "target" => target(work, artifact)}
    "publication:" <> TaskWorkflow.digest(identity)
  end

  @doc "Read the native delivery of one publication artifact without writing or accepting an unconfirmed send."
  @spec read(map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def read(work, artifact, opts) do
    with :ok <- scope?(work, artifact) do
      case opts[:candidate] do
        %{"source" => source, "actor" => actor} = candidate -> confirm(work, artifact, candidate, source, actor, opts)
        _ -> unconfirmed(artifact["id"])
      end
    end
  end

  @doc "Recheck a delivered observation against a fresh native read; version drift is never silently accepted."
  @spec current?(map(), keyword()) :: boolean()
  def current?(snapshot, opts) do
    case NativeWork.read(snapshot.work, opts) do
      {:ok, current} ->
        NativeWork.snapshot_ref(current) == snapshot.version and
          Enum.any?(current.notes, &(TaskDecision.source_ref(&1) == snapshot.source))

      _ ->
        false
    end
  end

  defp confirm(work, artifact, candidate, source, actor, opts) do
    payload = Map.take(candidate, @payload)

    with true <-
           candidate["work"] == work and artifact in candidate["artifacts"] and
             TaskWorkflow.digest(payload) == candidate["digest"],
         {:ok, snapshot} <- NativeWork.read(work, opts),
         {:ok, results} <- TaskPublication.observe(opts[:runtime] || %{}, snapshot, actor),
         [%{receipt: receipt}] <- Enum.filter(results, &result?(&1, source, payload)),
         %{} = receipt <- receipt,
         [note] <- Enum.filter(snapshot.notes, &(&1["id"] == receipt["note_id"])) do
      delivered(work, artifact, candidate, note, snapshot)
    else
      {:error, _} = error -> error
      _ -> {:error, :publication_delivery_unconfirmed}
    end
  end

  defp delivered(work, artifact, candidate, note, snapshot) do
    source = TaskDecision.source_ref(note)

    receipt = %{
      "artifact" => artifact["id"],
      "version" => artifact["version"],
      "candidate" => candidate["digest"],
      "target" => target(work, artifact),
      "note_id" => note["id"],
      "author" => to_string(get_in(note, ["author", "id"])),
      "content" => TaskWorkflow.digest(note["body"]),
      "source" => source,
      "publication" => source_ref(work, artifact)
    }

    observation = %{work: work, source: source, version: NativeWork.snapshot_ref(snapshot), publication: true}
    {:ok, %{artifact: artifact["id"], status: "delivered", snapshot: observation, receipt: receipt}}
  end

  defp scope?(work, artifact) do
    target = target(work, artifact)

    cond do
      not publication?(artifact) -> {:error, :invalid_publication_artifact}
      artifact["source"] != GitArtifact.source_ref(work, artifact["version"]) -> {:error, :publication_source_mismatch}
      WorkRef.validate(target) != :ok or target != work -> {:error, :publication_target_unavailable}
      true -> :ok
    end
  end

  # The engine publishes candidates to the artifact's owning Issue, so a declared
  # native target that is not that WorkRef could never be reached by a readback.
  defp target(work, artifact), do: Map.get(artifact, "target", work)

  defp publication?(%{"id" => id, "kind" => "publication", "version" => version, "source" => source}) do
    is_binary(id) and byte_size(id) <= 128 and String.trim(id) != "" and is_binary(source) and revision?(version)
  end

  defp publication?(_), do: false

  defp revision?(version),
    do: is_binary(version) and Regex.match?(~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/, version)

  defp result?(result, source, payload) do
    is_map(result.receipt) and result.receipt["source"] == source and
      result.envelope["kind"] == "candidate" and result.envelope["payload"] == payload
  end

  defp unconfirmed(id), do: {:ok, %{artifact: id, status: "publication_unconfirmed", snapshot: nil, receipt: nil}}
end
