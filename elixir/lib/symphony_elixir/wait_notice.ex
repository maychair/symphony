defmodule SymphonyElixir.WaitNotice do
  @moduledoc "Native waiting-notice deduplication shared by Issue and Review delivery."

  @spec find([map()], (map() -> boolean())) :: map() | nil
  def find(notes, matches?), do: Enum.find(notes, matches?)

  @spec ensure([map()], (map() -> boolean()), (-> :ok | {:error, term()})) :: :ok | {:error, term()}
  def ensure(notes, matches?, publish) do
    if find(notes, matches?), do: :ok, else: publish.()
  end
end
