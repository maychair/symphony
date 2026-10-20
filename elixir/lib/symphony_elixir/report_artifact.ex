defmodule SymphonyElixir.ReportArtifact do
  @moduledoc "Immutable UTF-8 Markdown report bytes, scoped to an owning native Issue and declared output."
  alias SymphonyElixir.{NativeWork, TaskWorkflow, WorkRef}

  @doc "Build a bounded report artifact; its version hashes the exact bytes, not a summary or a mutable path."
  @spec build(map(), term(), term()) :: {:ok, map()} | {:error, atom()}
  def build(work, id, body) do
    if WorkRef.validate(work) == :ok and work["kind"] == "issue" and text?(id, 128) and text?(body, 16_384) and
         not String.contains?(body <> id, "<!-- symphony-") and NativeWork.comment_body?(work["provider"], body) do
      version = Base.encode16(:crypto.hash(:sha256, body), case: :lower)
      {:ok, %{"id" => id, "kind" => "report", "version" => version, "source" => source_ref(work, id, version), "body" => body}}
    else
      {:error, :invalid_report_artifact}
    end
  end

  @spec source_ref(map(), String.t(), String.t()) :: String.t()
  def source_ref(work, id, version), do: "report:" <> TaskWorkflow.digest(%{"work" => work, "artifact" => id, "version" => version})

  @doc "Produce a verifiable retained snapshot without claiming native publication or report quality."
  @spec snapshot(map(), map()) :: {:ok, map()} | {:error, atom()}
  def snapshot(work, artifact) do
    case build(work, artifact["id"], artifact["body"]) do
      {:ok, ^artifact} ->
        file = %{"path" => "report.md", "mode" => "100644", "size" => byte_size(artifact["body"]), "sha256" => artifact["version"], "content" => artifact["body"]}
        data = %{"source" => artifact["source"], "version" => artifact["version"], "work" => work, "artifact" => artifact["id"], "files" => [Map.delete(file, "content")], "bytes" => file["size"]}
        {:ok, %{receipt: Map.put(data, "digest", TaskWorkflow.digest(data)), files: [file]}}

      _ ->
        {:error, :invalid_report_artifact}
    end
  end

  @doc "Check retained report metadata and bytes against a fixed reference, including an inline body when supplied."
  @spec validate(map(), map(), term()) :: :ok | {:error, atom()}
  def validate(work, reference, %{files: [%{"content" => body}]} = stored) do
    with {:ok, artifact} <- build(work, reference["id"], body),
         true <- Map.take(reference, ~w(id version source)) == Map.take(artifact, ~w(id version source)),
         true <- not Map.has_key?(reference, "body") or reference["body"] == body,
         {:ok, ^stored} <- snapshot(work, artifact) do
      :ok
    else
      _ -> {:error, :invalid_stored_report}
    end
  end

  def validate(_, _, _), do: {:error, :invalid_stored_report}

  defp text?(value, limit),
    do: is_binary(value) and byte_size(value) <= limit and String.valid?(value) and String.trim(value) != "" and not String.contains?(value, <<0>>)
end
