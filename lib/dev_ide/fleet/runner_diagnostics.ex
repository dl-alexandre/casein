defmodule DevIDE.Fleet.RunnerDiagnostics do
  @moduledoc """
  Read-only operator diagnostics for one fleet runner.

  This module assembles registry, identity, lease, assignment, execution, and
  dossier evidence. It never mutates orchestration state.
  """

  alias DevIDE.Assignments
  alias DevIDE.Assignments.Status, as: AssignmentStatus
  alias DevIDE.Fleet
  alias DevIDE.Fleet.Dossier
  alias DevIDE.Fleet.ExecutionProjection
  alias DevIDE.Fleet.ExecutionProjectionStore
  alias DevIDE.Fleet.ExecutionStatus

  @spec get(String.t()) :: {:ok, map()} | {:error, :runner_not_found}
  def get(runner_id) when is_binary(runner_id) do
    with {:ok, runner} <- Fleet.get_runner(runner_id) do
      identity =
        case Fleet.runner_identity(runner_id) do
          {:ok, identity} -> identity
          :error -> nil
        end

      active_leases = Enum.filter(Fleet.active_leases(), &(&1.runner_id == runner_id))

      executions =
        ExecutionProjectionStore.list()
        |> Enum.filter(&(&1.runner_id == runner_id))
        |> Enum.sort_by(&sort_time/1, {:desc, DateTime})

      assignment_ids =
        (Enum.map(active_leases, & &1.assignment_id) ++ Enum.map(executions, & &1.assignment_id))
        |> Enum.uniq()

      assignments = assignments_by_id(assignment_ids)

      {:ok,
       %{
         runner: runner,
         identity: identity,
         active_leases: active_leases,
         assignments: assignments,
         current_execution: Enum.find(executions, &(not ExecutionStatus.terminal?(&1.state))),
         executions: executions,
         recent_failures: recent_failures(executions, assignments),
         dossiers: dossiers(assignments)
       }}
    else
      :error -> {:error, :runner_not_found}
    end
  end

  def get(_runner_id), do: {:error, :runner_not_found}

  defp assignments_by_id(assignment_ids) do
    assignment_ids
    |> Enum.map(fn assignment_id -> {assignment_id, assignment(assignment_id)} end)
    |> Enum.reject(fn {_id, assignment} -> is_nil(assignment) end)
    |> Map.new()
  end

  defp assignment(assignment_id) do
    case Assignments.get(assignment_id) do
      {:ok, assignment} -> assignment
      :error -> nil
    end
  end

  defp recent_failures(executions, assignments) do
    execution_failures =
      executions
      |> Enum.filter(&ExecutionStatus.failure?(&1.state))
      |> Enum.map(fn execution ->
        %{
          type: :execution,
          assignment_id: execution.assignment_id,
          execution_id: execution.id,
          state: execution.state,
          reason: execution.failure_reason,
          occurred_at: execution.completed_at || execution.started_at
        }
      end)

    assignment_failures =
      assignments
      |> Map.values()
      |> Enum.filter(&AssignmentStatus.failure?(&1.state))
      |> Enum.map(fn assignment ->
        %{
          type: :assignment,
          assignment_id: assignment.id,
          execution_id: nil,
          state: assignment.state,
          reason: assignment.failure_reason,
          occurred_at: assignment.completed_at || assignment.updated_at
        }
      end)

    (execution_failures ++ assignment_failures)
    |> Enum.sort_by(&(&1.occurred_at || DateTime.from_unix!(0)), {:desc, DateTime})
    |> Enum.take(10)
  end

  defp dossiers(assignments) do
    assignments
    |> Map.values()
    |> Enum.map(fn assignment ->
      case Dossier.workspace(assignment.workspace_id, limit: 25) do
        {:ok, dossier} -> {assignment.id, dossier}
        {:error, _reason} -> {assignment.id, nil}
      end
    end)
    |> Map.new()
  end

  defp sort_time(%ExecutionProjection{started_at: %DateTime{} = started_at}), do: started_at
  defp sort_time(_execution), do: DateTime.from_unix!(0)
end
