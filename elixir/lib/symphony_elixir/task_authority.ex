defmodule SymphonyElixir.TaskAuthority do
  @moduledoc "Verify coordinator attestations without treating a bot as a human author."
  alias SymphonyElixir.{TaskDecision, TaskWorkflow}

  @spec validate(map()) :: :ok | {:error, atom()}
  def validate(tracker) do
    case tracker.provider["delegated_authority"] do
      nil ->
        :ok

      %{"principal" => principal, "publisher" => publisher, "public_key" => public} = policy
      when is_binary(principal) and is_integer(publisher) and publisher > 0 and is_binary(public) ->
        if principal == tracker.assignee and valid_policy?(policy),
          do: :ok,
          else: {:error, :invalid_delegated_authority}

      _ ->
        {:error, :invalid_delegated_authority}
    end
  end

  defp valid_policy?(policy) do
    Enum.sort(Map.keys(policy)) == ~w(principal public_key publisher) and
      match?({:ok, <<_::256>>}, Base.decode64(policy["public_key"]))
  end

  @spec actor(map(), map(), map() | nil) :: String.t() | nil
  def actor(note, payload, scope) do
    if Map.has_key?(payload, "authority") do
      delegated_actor(note, payload, scope)
    else
      case get_in(note, ["author", "id"]) do
        id when is_integer(id) and id > 0 -> to_string(id)
        _ -> nil
      end
    end
  end

  defp delegated_actor(note, payload, scope) do
    with %{policy: policy, repository: repository, issue: issue, owner: owner} <- scope,
         true <- verification_policy?(policy),
         %{"grant" => grant, "signature" => signature} <- payload["authority"],
         true <- is_map(grant) and is_binary(signature),
         true <- grant["schema"] == 1 and grant["principal"] == owner and policy["principal"] == owner,
         true <- grant["publisher"] == to_string(policy["publisher"]),
         native when is_integer(native) and native > 0 <- get_in(note, ["author", "id"]),
         true <- grant["publisher"] == to_string(native),
         true <- grant["repository"] == repository and grant["issue"] == issue,
         true <- grant["decision"] == Map.delete(payload, "authority"),
         true <- immutable_publication?(note, grant["issued_at"]),
         true <- evidence?(grant["evidence"]),
         {:ok, key} <- Base.decode64(policy["public_key"] || ""),
         {:ok, signed} <- Base.decode64(signature),
         true <- byte_size(key) == 32 and byte_size(signed) == 64,
         true <- :crypto.verify(:eddsa, :none, TaskWorkflow.canonical_json(grant), signed, [key, :ed25519]) do
      owner
    else
      _ -> nil
    end
  end

  defp verification_policy?(policy),
    do: is_map(policy) and is_integer(policy["publisher"]) and is_binary(policy["public_key"])

  defp immutable_publication?(note, issued) do
    at = TaskDecision.timestamp(note["created_at"])

    is_integer(issued) and is_integer(at) and note["created_at"] == note["updated_at"] and
      div(at, 1_000_000) >= issued - 60 and div(at, 1_000_000) <= issued + 300
  end

  defp evidence?(%{"kind" => "codex-user-request", "session" => session, "at" => at, "request" => request, "request_sha256" => sha})
       when is_binary(session) and is_binary(request) and byte_size(request) > 0 do
    is_integer(TaskDecision.timestamp(at)) and
      Regex.match?(~r/^[0-9a-f-]{36}$/, session) and
      sha == Base.encode16(:crypto.hash(:sha256, request), case: :lower)
  end

  defp evidence?(_), do: false
end
