defmodule SymphonyElixir.WorkflowCapabilityTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.WorkflowCapability
  alias SymphonyElixirWeb.Presenter

  defmodule Snapshot do
    use GenServer

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call(:snapshot, _from, state), do: {:reply, state, state}
  end

  test "the seven layers expose deterministic, JSON-readable protocol versions" do
    layers = WorkflowCapability.layers()
    assert WorkflowCapability.version() == 2
    assert layers == WorkflowCapability.layers()

    assert Enum.map(layers, & &1.name) == [
             "领域契约",
             "Provider 与发现",
             "父子协调",
             "验证与交付",
             "Review 闭环",
             "投影与收尾",
             "部署"
           ]

    protocols = Enum.flat_map(layers, & &1.capabilities)
    assert length(Enum.uniq_by(protocols, &{&1.name, &1.version})) == length(protocols)

    assert Map.new(protocols, &{{&1.name, &1.version}, &1.minimum_version}) == %{
             {"closure_fence", 1} => 1,
             {"human_decision", 1} => 1,
             {"plan_contract", 1} => 1,
             {"plan_contract", 2} => 1,
             {"plan_manifest", 2} => 2,
             {"review_finding", 1} => 1,
             {"review_lane", 3} => 3,
             {"review_workflow", 2} => 2,
             {"task_workflow", 2} => 2,
             {"taskboard_projection", 1} => 1,
             {"work_ref", 1} => 1,
             {"workflow_capability", 2} => 2
           }

    assert Jason.decode!(Jason.encode!(layers)) |> length() == 7

    for layer <- layers do
      assert layer.capabilities == Enum.sort_by(layer.capabilities, &{&1.name, &1.version})
    end

    for protocol <- protocols do
      assert protocol.required
      assert protocol.minimum_version <= protocol.version
      assert WorkflowCapability.supported?(protocol.name, protocol.version)
      assert :ok = WorkflowCapability.require_supported!(%{protocol.name => protocol.version})
    end

    assert :ok = WorkflowCapability.require_supported!(%{})
  end

  test "legacy, future, unknown and malformed requirements fail closed" do
    for {name, version} <- [
          {"review_lane", 2},
          {"review_workflow", 1},
          {"plan_contract", 0},
          {"workflow_capability", 1},
          {"plan_manifest", 99},
          {"unknown", 1},
          {"plan_contract", "1"},
          {"plan_contract", 1.0},
          {"plan_contract", nil}
        ] do
      refute WorkflowCapability.supported?(name, version)

      error = assert_raise ArgumentError, fn -> WorkflowCapability.require_supported!(%{name => version}) end
      assert error.message =~ inspect(name)
      assert error.message =~ inspect(version)
      assert error.message =~ "migration_required"
      assert error.message =~ "do not ignore plan fields"
    end

    assert_raise ArgumentError, fn ->
      WorkflowCapability.require_supported!(%{"plan_contract" => 1, "review_lane" => 2})
    end
  end

  test "migration and rollback require verified ownership and retained artifacts" do
    migration = WorkflowCapability.migration()
    assert migration.status == :manual_verification_required
    refute migration.automatic
    assert %{from: 2, to: 3, status: :migration_required, reason: reason} = migration.review_lane
    assert reason =~ "field renaming is insufficient"
    assert Enum.join(migration.upgrade) =~ "safe handoff"
    assert Enum.join(migration.upgrade) =~ "publication receipts"
    assert Enum.join(migration.rollback) =~ "independently of the checkout"
    assert Enum.join(migration.rollback) =~ "never overlap execution"
    assert Enum.join(migration.rollback) =~ "schema 2 listener"
  end

  test "runtime state includes capability inventory without removing build or listener identity" do
    snapshot = %{running: [], retrying: [], codex_totals: %{}, rate_limits: nil}
    start_supervised!(%{id: Snapshot, start: {GenServer, :start_link, [Snapshot, snapshot, [name: __MODULE__]]}})

    payload = Presenter.state_payload(__MODULE__, 1_000)
    assert payload.workflow_capability == Presenter.workflow_capability_payload()
    assert payload.workflow_capability.version == WorkflowCapability.version()
    assert payload.workflow_capability.layers == WorkflowCapability.layers()
    assert payload.workflow_capability.migration == WorkflowCapability.migration()
    assert Map.has_key?(payload, :build)
    assert Map.has_key?(payload, :backend)
    assert Map.has_key?(payload, :review_lane_listener)
  end
end
