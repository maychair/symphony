defmodule SymphonyElixir.ReviewOwnerTest do
  use ExUnit.Case
  alias SymphonyElixir.ReviewLane.Owner

  test "attempt identities bind the actual caller and VM, not just a copied ticket" do
    owner = Owner.new(self())
    assert Owner.valid?(owner)
    assert Owner.local_pid(owner) == self()
    assert Owner.authorized?(owner, owner, self())
    refute Owner.authorized?(owner, Owner.new(self()), self())
    task = Task.async(fn -> Owner.authorized?(owner, owner, self()) end)
    refute Task.await(task)
    foreign = %{owner | "vm" => String.duplicate("0", 32)}
    refute Owner.authorized?(foreign, foreign, self())
    assert Owner.local_pid(foreign) == nil

    for invalid <- [nil, %{}, Map.put(owner, "extra", true), %{owner | "pid" => "bad"}, %{owner | "token" => nil}] do
      refute Owner.valid?(invalid)
      assert Owner.local_pid(invalid) == nil
    end

    oversized = %{owner | "pid" => "<999999999999999999999999999999.0.0>"}
    assert Owner.local_pid(oversized) == nil
  end
end
