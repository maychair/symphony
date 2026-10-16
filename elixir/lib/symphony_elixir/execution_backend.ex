defmodule SymphonyElixir.ExecutionBackend do
  @moduledoc "Project-selected execution transport. Tracker and delivery policy remain shared."
  alias SymphonyElixir.RunJournal
  alias SymphonyElixir.Config

  @spec kind() :: String.t()
  def kind, do: System.get_env("SYMPHONY_EXECUTION_BACKEND") || Config.settings!().agent.backend

  @spec module() :: module()
  def module do
    case kind() do
      "codex" -> SymphonyElixir.Codex.AppServer
      "omp" -> SymphonyElixir.Omp.Rpc
      other -> raise ArgumentError, "Unsupported execution backend: #{inspect(other)}"
    end
  end

  @spec command() :: String.t()
  def command do
    case kind() do
      "codex" -> System.get_env("SYMPHONY_CODEX_COMMAND") || Config.settings!().codex.command
      "omp" -> Config.settings!().omp.command
    end
  end

  @spec quota_error?(term()) :: boolean()
  def quota_error?(result),
    do: Regex.match?(~r/usage.?limit|quota|billing|credit.?exhaust|insufficient.?balance|额度|配额/i, inspect(result))

  @spec config_hash() :: String.t() | nil
  def config_hash do
    case System.get_env("SYMPHONY_BACKEND_CONFIG_FILES") do
      nil ->
        nil

      json ->
        json
        |> Jason.decode!()
        |> Enum.map(fn path -> [path, <<0>>, File.read!(path)] end)
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)
    end
  end

  @spec check_config(map()) :: :ok | {:error, term()}
  def check_config(record) do
    if is_nil(record["backend_config_hash"]) or record["backend_config_hash"] == config_hash(),
      do: :ok,
      else: {:error, :backend_configuration_changed}
  end

  @spec check_record(Path.t(), String.t()) :: :ok | {:error, term()}
  def check_record(root, id) do
    with {:ok, record} <- RunJournal.read(RunJournal.directory(root, id)) do
      cond do
        is_nil(record) -> :ok
        (record["backend"] || "codex") != kind() -> {:error, :execution_backend_changed}
        true -> check_config(record)
      end
    end
  end
end
