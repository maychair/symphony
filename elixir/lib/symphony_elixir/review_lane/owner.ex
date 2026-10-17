defmodule SymphonyElixir.ReviewLane.Owner do
  @moduledoc "Binds a review attempt to its actual BEAM worker and VM incarnation."

  @spec new(pid()) :: map()
  def new(pid) do
    %{"token" => random(), "vm" => vm(), "pid" => pid |> :erlang.pid_to_list() |> to_string()}
  end

  @spec valid?(term()) :: boolean()
  def valid?(%{"token" => token, "vm" => vm, "pid" => pid} = owner) do
    map_size(owner) == 3 and digest?(token) and digest?(vm) and
      is_binary(pid) and Regex.match?(~r/^<\d+\.\d+\.\d+>$/, pid)
  end

  def valid?(_), do: false

  @spec authorized?(term(), term(), pid()) :: boolean()
  def authorized?(recorded, supplied, caller) do
    valid?(recorded) and recorded == supplied and recorded["vm"] == vm() and
      recorded["pid"] == to_string(:erlang.pid_to_list(caller))
  end

  @spec local_pid(term()) :: pid() | nil
  def local_pid(owner) do
    if valid?(owner) and owner["vm"] == vm(), do: owner["pid"] |> String.to_charlist() |> :erlang.list_to_pid()
  rescue
    ArgumentError -> nil
  end

  defp digest?(value), do: is_binary(value) and Regex.match?(~r/^[a-f0-9]{32}$/, value)
  defp random, do: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

  defp vm do
    case :persistent_term.get(__MODULE__, nil) do
      nil ->
        :global.trans({__MODULE__, self()}, fn ->
          value = :persistent_term.get(__MODULE__, nil) || random()
          :persistent_term.put(__MODULE__, value)
          value
        end)

      value ->
        value
    end
  end
end
