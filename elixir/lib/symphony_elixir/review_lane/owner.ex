defmodule SymphonyElixir.ReviewLane.Owner do
  @moduledoc "Review compatibility boundary for shared native execution ownership."

  @spec new(pid()) :: map()
  defdelegate new(pid), to: SymphonyElixir.ExecutionOwner
  @spec valid?(term()) :: boolean()
  defdelegate valid?(owner), to: SymphonyElixir.ExecutionOwner
  @spec authorized?(term(), term(), pid()) :: boolean()
  defdelegate authorized?(recorded, supplied, caller), to: SymphonyElixir.ExecutionOwner
  @spec local_pid(term()) :: pid() | nil
  defdelegate local_pid(owner), to: SymphonyElixir.ExecutionOwner
end
