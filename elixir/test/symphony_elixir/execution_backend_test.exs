defmodule SymphonyElixir.ExecutionBackendTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.ExecutionBackend

  test "configuration identity detects changed or missing inputs" do
    keys = ["SYMPHONY_EXECUTION_BACKEND", "SYMPHONY_BACKEND_CONFIG_FILES"]
    previous = Map.new(keys, &{&1, System.get_env(&1)})
    on_exit(fn -> Enum.each(previous, fn {k, v} -> restore_env(k, v) end) end)
    System.delete_env("SYMPHONY_BACKEND_CONFIG_FILES")
    assert ExecutionBackend.config_hash() == nil
    path = Path.join(Path.dirname(Workflow.workflow_file_path()), "backend.toml")
    File.write!(path, "first")
    System.put_env("SYMPHONY_BACKEND_CONFIG_FILES", Jason.encode!([path]))
    hash = ExecutionBackend.config_hash()
    assert byte_size(hash) == 64
    assert :ok = ExecutionBackend.check_config(%{"backend_config_hash" => hash})
    File.write!(path, "second")
    assert {:error, :backend_configuration_changed} = ExecutionBackend.check_config(%{"backend_config_hash" => hash})
    System.put_env("SYMPHONY_EXECUTION_BACKEND", "unknown")
    assert_raise ArgumentError, ~r/Unsupported execution backend/, &ExecutionBackend.module/0
  end
end
