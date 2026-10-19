defmodule SymphonyElixir.LiveCleanupTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.TestSupport, as: Support

  test "successful cleanup runs once and returns body result" do
    assert :result = Support.with_cleanup(fn -> :result end, [fn -> send(self(), :cleaned) end])
    assert_received :cleaned
    refute_received :cleaned
  end

  test "primary assertion survives successful cleanup" do
    error =
      assert_raise ExUnit.AssertionError, fn ->
        Support.with_cleanup(fn -> assert false, "credential visible" end, [fn -> send(self(), :cleaned) end])
      end

    assert error.message == "credential visible"
    assert_received :cleaned
  end

  test "both failures retain original stacks and later cleanup still runs" do
    error =
      assert_raise ExUnit.MultiError, fn ->
        Support.with_cleanup(fn -> assert false, "credential visible" end, [fn -> raise "close HTTP 403" end, fn -> send(self(), :restored) end])
      end

    assert [
             {:error, %ExUnit.AssertionError{message: "credential visible"}, [_ | _]},
             {:error, %RuntimeError{message: "close HTTP 403"}, [_ | _]}
           ] = error.errors

    assert_received :restored
  end

  test "cleanup failure after successful body still fails" do
    error =
      assert_raise ExUnit.MultiError, fn ->
        Support.with_cleanup(fn -> :ok end, [fn -> raise "close failed" end])
      end

    assert [{:error, %RuntimeError{message: "close failed"}, [_ | _]}] = error.errors
  end

  test "throw and exit also run all cleanup" do
    error =
      assert_raise ExUnit.MultiError, fn ->
        Support.with_cleanup(fn -> throw(:primary) end, [
          fn -> exit(:cleanup) end,
          fn -> send(self(), :restored) end
        ])
      end

    assert [{:throw, :primary, [_ | _]}, {:exit, :cleanup, [_ | _]}] = error.errors
    assert_received :restored
  end
end
