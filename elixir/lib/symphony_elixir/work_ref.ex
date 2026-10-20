defmodule SymphonyElixir.WorkRef do
  @moduledoc "Stable repository-scoped identity for tasks and standalone reviews."

  alias SymphonyElixir.TaskWorkflow

  @fields ~w(provider host repository_id kind number)
  @type t :: %{
          String.t() => String.t() | pos_integer()
        }

  @doc "Validate a native identity. Display names, paths and URLs are not identity fields."
  @spec validate(term()) :: :ok | {:error, :invalid_work_ref}
  def validate(ref) when is_map(ref) do
    if Enum.sort(Map.keys(ref)) == Enum.sort(@fields) and
         ref["provider"] in ["github", "gitlab"] and host?(ref["host"]) and
         identifier?(ref["repository_id"]) and kind?(ref) and
         is_integer(ref["number"]) and ref["number"] > 0,
       do: :ok,
       else: {:error, :invalid_work_ref}
  end

  def validate(_), do: {:error, :invalid_work_ref}

  @doc "A validated identity's unambiguous, portable journal/graph key."
  @spec key(t()) :: String.t()
  def key(ref) do
    case validate(ref) do
      :ok -> TaskWorkflow.digest(ref)
      {:error, reason} -> raise ArgumentError, Atom.to_string(reason)
    end
  end

  defp kind?(%{"provider" => "github", "kind" => kind}), do: kind in ["issue", "pr"]
  defp kind?(%{"provider" => "gitlab", "kind" => kind}), do: kind in ["issue", "mr"]

  defp identifier?(value) when is_binary(value),
    do: Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, value)

  defp identifier?(_), do: false

  defp host?(host) when is_binary(host) and byte_size(host) > 0 do
    case URI.new("https://" <> host) do
      {:ok, %URI{host: name, userinfo: nil, path: path, query: nil, fragment: nil, port: port} = uri}
      when is_binary(name) and name != "" and path in [nil, ""] ->
        canonical = URI.to_string(%{uri | host: String.downcase(name)})

        "https://" <> host == canonical and not String.ends_with?(name, ".") and port in 1..65_535 and
          not String.contains?(host, [" ", "\n", "\r", "\t", "%", "\\"])

      _ ->
        false
    end
  end

  defp host?(_), do: false
end
