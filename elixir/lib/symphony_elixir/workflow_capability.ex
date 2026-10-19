defmodule SymphonyElixir.WorkflowCapability do
  @moduledoc """
  Versioned workflow protocol inventory, not a claim of deployment acceptance.

  Requirements are explicit name/version pairs. Omitted capabilities are not
  inferred; callers must pass every protocol required by their work before dispatch.
  This module neither migrates records nor transfers execution ownership.
  """

  @version 2
  @capabilities [
    {"domain_contract", "领域契约", [{"human_decision", 1}, {"plan_contract", 1}, {"plan_contract", 2}]},
    {"provider_discovery", "Provider 与发现", [{"work_ref", 1}]},
    {"parent_child_coordination", "父子协调", [{"plan_manifest", 2}]},
    {"verification_delivery", "验证与交付", [{"task_workflow", 2}]},
    {"review_loop", "Review 闭环", [{"review_lane", 3}, {"review_finding", 1}]},
    {"projection_closure", "投影与收尾", [{"closure_fence", 1}, {"taskboard_projection", 1}]},
    {"deployment", "部署", [{"workflow_capability", @version}]}
  ]

  @spec version() :: pos_integer()
  def version, do: @version

  @spec layers() :: [map()]
  def layers do
    Enum.map(@capabilities, fn {id, name, protocols} ->
      %{id: id, name: name, capabilities: Enum.map(Enum.sort(protocols), &capability/1)}
    end)
  end

  @spec supported?(String.t(), term()) :: boolean()
  def supported?(name, version) do
    Enum.any?(@capabilities, fn {_id, _label, protocols} ->
      {name, version} in protocols
    end)
  end

  @doc "Raises before dispatch when any explicitly required protocol is unsupported."
  @spec require_supported!(%{String.t() => term()}) :: :ok
  def require_supported!(requirements) when is_map(requirements) do
    requirements |> Enum.sort() |> Enum.each(&require_capability!/1)
  end

  @spec migration() :: map()
  def migration do
    %{
      status: :manual_verification_required,
      automatic: false,
      review_lane: %{
        from: 2,
        to: 3,
        status: :migration_required,
        reason: "Schema 2 cannot establish current ownership and publication receipts; field renaming is insufficient."
      },
      upgrade: [
        "Keep active executions on their original protocol until a safe handoff; verify native sessions before takeover.",
        "Reconcile object ownership, in-flight reviews and publication receipts before switching listeners.",
        "Preserve historical authorization provenance; mark unverifiable versions as insufficient evidence."
      ],
      rollback: [
        "Retain the original executable and journal independently of the checkout until handoff is verified.",
        "Reconcile native sessions and listener ownership before resuming the retained instance; never overlap execution.",
        "Do not feed schema 3 records to a schema 2 listener or fabricate missing session-stop evidence."
      ]
    }
  end

  defp capability({name, version}) do
    minimum = if name == "plan_contract", do: 1, else: version
    %{name: name, version: version, minimum_version: minimum, required: true}
  end

  defp require_capability!({name, version}) do
    unless supported?(name, version) do
      raise ArgumentError,
            "Unsupported workflow capability #{inspect(name)} version #{inspect(version)}: " <>
              "migration_required or incompatible protocol. Check layers/0 for exact supported versions; " <>
              "do not ignore plan fields or fall back to single-task execution. " <>
              "Verify ownership and receipts using migration/0 before upgrade or rollback."
    end
  end
end
