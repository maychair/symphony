defmodule SymphonyElixir.TaskPlanAssessment do
  @moduledoc """
  Re-derive one plan member's current business assessment from native sources.

  The closure fence and the read-only Taskboard projection both consume this
  single shape, so a business conclusion is never re-derived from a cache or
  from a different source set than the one that produced it.
  """

  alias SymphonyElixir.{TaskExecution, WorkRef}

  @doc "Observe one member and return its flow, journal record and native snapshot."
  @spec assess(map(), map(), map()) :: {:ok, map()} | {:error, term()}
  def assess(parent, member, configured) do
    with {:ok, observation} <- TaskExecution.observe(parent, member.work, configured.executions, configured.opts) do
      snapshot = observation.plan.members[WorkRef.key(member.work)]
      {:ok, %{flow: observation.flow, record: observation.record, snapshot: snapshot, evidence: observation.evidence}}
    end
  end
end
