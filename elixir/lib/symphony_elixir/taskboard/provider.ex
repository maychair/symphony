defmodule SymphonyElixir.Taskboard.Provider do
  @moduledoc """
  Provider operations used by the Taskboard while keeping repository Issues as
  the only source of task data.
  """

  alias SymphonyElixir.Tracker.Issue

  @type result(t) :: {:ok, t} | {:error, term()}
  @priorities %{
    "priority:p0" => 0,
    "priority:p1" => 1,
    "priority:p2" => 2,
    "priority:p3" => 3,
    "p0" => 0,
    "p1" => 1,
    "p2" => 2,
    "p3" => 3
  }

  @callback list_issues(map(), keyword()) :: result([Issue.t()])
  @callback issue_detail(map(), String.t(), keyword()) :: result(map())
  @callback create_issue(map(), map(), keyword()) :: result(map())
  @callback comment(map(), String.t(), String.t(), keyword()) :: result(map())
  @callback add_label(map(), String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  @callback remove_label(map(), String.t(), String.t(), keyword()) :: :ok | {:error, term()}

  @spec module_for(String.t()) :: {:ok, module()} | {:error, term()}
  def module_for("github"), do: {:ok, SymphonyElixir.Taskboard.GitHub}
  def module_for("gitlab"), do: {:ok, SymphonyElixir.Taskboard.GitLab}
  def module_for("memory"), do: {:ok, SymphonyElixir.Taskboard.Memory}
  def module_for(kind), do: {:error, {:unsupported_taskboard_tracker, kind}}

  @spec summary(String.t() | nil) :: String.t() | nil
  def summary(nil), do: nil

  def summary(description) when is_binary(description) do
    description
    |> String.replace(~r/<!--.*?-->/s, " ")
    |> String.replace(~r/[#>*_`\[\]()]/u, " ")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> case do
      "" -> nil
      text -> String.slice(text, 0, 220)
    end
  end

  @spec priority([String.t()]) :: integer() | nil
  def priority(labels) when is_list(labels) do
    Enum.find_value(labels, fn label -> Map.get(@priorities, String.downcase(label)) end)
  end

  @spec iso8601(term()) :: String.t() | nil
  def iso8601(%DateTime{} = value), do: value |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  def iso8601(value) when is_binary(value), do: value
  def iso8601(_value), do: nil

  @spec issue_number(Issue.t()) :: pos_integer() | nil
  def issue_number(%Issue{id: id, native_ref: native_ref}) do
    value = (is_map(native_ref) && (native_ref["iid"] || native_ref["number"])) || id

    case Integer.parse(to_string(value)) do
      {number, ""} when number > 0 -> number
      _ -> nil
    end
  end

  @spec resolve_secret(term(), String.t()) :: String.t() | nil
  def resolve_secret("$" <> env_name, fallback) do
    if Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*$/, env_name) do
      present(System.get_env(env_name) || fallback)
    end
  end

  def resolve_secret(nil, fallback), do: present(fallback)
  def resolve_secret(value, _fallback), do: present(value)

  @spec present(term()) :: String.t() | nil
  def present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  def present(_value), do: nil

  @spec encode(term()) :: String.t()
  def encode(value), do: URI.encode(to_string(value), &URI.char_unreserved?/1)
end
