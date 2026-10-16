defmodule SymphonyElixir.BuildInfo do
  @moduledoc "Immutable package input identity and the executable observed when this runtime started."

  @root Path.expand("../..", __DIR__)
  @inputs Enum.sort_by(
            [Path.join(@root, "mix.exs"), Path.join(@root, "mix.lock")] ++
              Enum.filter(Path.wildcard(Path.join(@root, "{lib,config}/**/*")), &File.regular?/1),
            &Path.split/1
          )
  for path <- @inputs do
    @external_resource path
  end

  @source_sha256 @inputs
                 |> Enum.map(fn path -> [Path.relative_to(path, Path.dirname(@root)), <<0>>, File.read!(path)] end)
                 |> then(&:crypto.hash(:sha256, &1))
                 |> Base.encode16(case: :lower)

  @spec capture() :: :ok
  def capture do
    executable = executable_path()

    :persistent_term.put(__MODULE__, %{
      source_sha256: @source_sha256,
      executable_sha256: executable_hash(executable),
      executable_path: executable,
      pid: System.pid(),
      started_at: DateTime.to_iso8601(DateTime.utc_now())
    })

    :ok
  end

  @spec identity() :: map()
  def identity, do: :persistent_term.get(__MODULE__)

  @doc false
  @spec __mix_recompile__?() :: boolean()
  def __mix_recompile__? do
    inputs =
      Enum.sort_by(
        [Path.join(@root, "mix.exs"), Path.join(@root, "mix.lock")] ++
          Enum.filter(Path.wildcard(Path.join(@root, "{lib,config}/**/*")), &File.regular?/1),
        &Path.split/1
      )

    digest =
      inputs
      |> Enum.map(fn path -> [Path.relative_to(path, Path.dirname(@root)), <<0>>, File.read!(path)] end)
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    digest != @source_sha256
  end

  defp executable_path do
    :escript.script_name() |> to_string() |> Path.expand()
  rescue
    _ -> nil
  end

  defp executable_hash(path) when is_binary(path) do
    case File.read(path) do
      {:ok, bytes} -> :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
      _ -> nil
    end
  end

  defp executable_hash(_path), do: nil
end
