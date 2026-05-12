defmodule DevIDE.Fleet.ExecutionTimeline do
  @moduledoc """
  Replay inspection tooling for fleet executions.
  """

  alias DevIDE.Assignments
  alias DevIDE.Fleet.ArtifactStore
  alias DevIDE.Fleet.ExecutionProjectionStore

  @spec timeline(String.t()) :: {:ok, map()} | {:error, term()}
  def timeline(execution_id) when is_binary(execution_id) do
    with {:ok, execution} <- ExecutionProjectionStore.get(execution_id) do
      {:ok,
       %{
         execution: execution,
         assignment_events: Assignments.replay(execution.assignment_id),
         artifacts: ArtifactStore.chunks(execution_id),
         terminal?: DevIDE.Fleet.ExecutionStatus.terminal?(execution.state)
       }}
    else
      :error -> {:error, :execution_not_found}
    end
  end

  @spec assignment_timeline(String.t()) :: map()
  def assignment_timeline(assignment_id) when is_binary(assignment_id) do
    executions = ExecutionProjectionStore.for_assignment(assignment_id)

    %{
      assignment_id: assignment_id,
      assignment_events: Assignments.replay(assignment_id),
      executions:
        Enum.map(executions, fn execution ->
          %{
            execution: execution,
            artifacts: ArtifactStore.chunks(execution.id)
          }
        end)
    }
  end
end
