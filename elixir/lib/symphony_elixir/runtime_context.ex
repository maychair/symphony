defmodule SymphonyElixir.RuntimeContext do
  @moduledoc "Explicit repository scope for workers sharing one BEAM runtime."

  @spec current() :: map() | nil
  def current, do: Process.get(__MODULE__)

  @spec install(map() | nil) :: :ok
  def install(context) do
    Process.put(__MODULE__, context)
    :ok
  end

  @spec with_context(map() | nil, (-> result)) :: result when result: var
  def with_context(context, fun) do
    previous = current()
    install(context)

    try do
      fun.()
    after
      install(previous)
    end
  end

  @spec wrap((-> result)) :: (-> result) when result: var
  def wrap(fun) do
    context = current()
    fn -> with_context(context, fun) end
  end

  @spec server(module()) :: GenServer.server()
  def server(module) do
    case current() do
      nil -> module
      %{id: id} -> {:via, Registry, {SymphonyElixir.RepositoryRegistry, {id, module}}}
    end
  end

  @spec whereis(module()) :: pid() | nil
  def whereis(module) do
    GenServer.whereis(server(module))
  rescue
    ArgumentError -> nil
  end

  @spec environment() :: map()
  def environment, do: (current() || %{})[:environment] || %{}

  @spec get_env(String.t(), String.t() | nil) :: String.t() | nil
  def get_env(name, default \\ nil), do: Map.get(environment(), name, System.get_env(name, default))
end
