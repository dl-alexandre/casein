defmodule DevIDE.Fleet.DossierExport do
  @moduledoc """
  Export complete assignment dossier bundles for operator review.

  The export is read-only. It gathers assignment, execution, runner, workspace,
  artifact, recovery, and timeline evidence into one JSON-safe map.
  """

  alias DevIDE.Assignments
  alias DevIDE.Assignments.Recovery
  alias DevIDE.Fleet
  alias DevIDE.Fleet.ArtifactStore
  alias DevIDE.Fleet.ExecutionProjectionStore
  alias DevIDE.Fleet.ExecutionTimeline

  @spec for_assignment(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def for_assignment(assignment_id, opts \\ [])

  def for_assignment(assignment_id, opts) when is_binary(assignment_id) do
    with {:ok, assignment} <- fetch_assignment(assignment_id),
         {:ok, dossier} <- Fleet.dossier(assignment.workspace_id, opts) do
      executions = ExecutionProjectionStore.for_assignment(assignment_id)

      bundle = %{
        exported_at: DateTime.utc_now(),
        assignment_id: assignment_id,
        workspace_id: assignment.workspace_id,
        assignment: assignment,
        assignment_events: Assignments.replay(assignment_id),
        workspace: dossier.workspace,
        executions: Enum.map(executions, &execution_bundle/1),
        runners: runners(executions),
        artifacts: Enum.flat_map(executions, &ArtifactStore.chunks(&1.id)),
        recovery_actions: Recovery.propose(assignment_id),
        timeline: ExecutionTimeline.assignment_timeline(assignment_id),
        dossier: dossier
      }

      {:ok, json_safe(bundle)}
    end
  end

  def for_assignment(_assignment_id, _opts), do: {:error, :invalid_assignment_id}

  @spec write_assignment(String.t(), Path.t(), keyword()) :: {:ok, Path.t()} | {:error, term()}
  def write_assignment(assignment_id, path, opts \\ [])

  def write_assignment(assignment_id, path, opts)
      when is_binary(assignment_id) and is_binary(path) do
    with {:ok, bundle} <- for_assignment(assignment_id, opts),
         :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, Jason.encode!(bundle, pretty: true)) do
      {:ok, path}
    end
  end

  def write_assignment(_assignment_id, _path, _opts), do: {:error, :invalid_export_path}

  defp fetch_assignment(assignment_id) do
    case Assignments.get(assignment_id) do
      {:ok, assignment} -> {:ok, assignment}
      :error -> {:error, :assignment_not_found}
    end
  end

  defp execution_bundle(execution) do
    %{
      execution: execution,
      artifacts: ArtifactStore.chunks(execution.id),
      timeline: execution_timeline(execution.id),
      runner: runner(execution.runner_id)
    }
  end

  defp execution_timeline(execution_id) do
    case Fleet.execution_timeline(execution_id) do
      {:ok, timeline} -> timeline
      {:error, reason} -> %{error: reason}
    end
  end

  defp runners(executions) do
    executions
    |> Enum.map(& &1.runner_id)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Map.new(fn runner_id -> {runner_id, runner(runner_id)} end)
  end

  defp runner(runner_id) do
    %{
      registry: registry_runner(runner_id),
      identity: runner_identity(runner_id)
    }
  end

  defp registry_runner(runner_id) do
    case Fleet.get_runner(runner_id) do
      {:ok, runner} -> runner
      :error -> nil
    end
  end

  defp runner_identity(runner_id) do
    case Fleet.runner_identity(runner_id) do
      {:ok, identity} -> identity
      :error -> nil
    end
  end

  defp json_safe(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp json_safe(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp json_safe(%Date{} = value), do: Date.to_iso8601(value)
  defp json_safe(%Time{} = value), do: Time.to_iso8601(value)

  defp json_safe(value) when is_struct(value) do
    value
    |> Map.from_struct()
    |> json_safe()
  end

  defp json_safe(value) when is_map(value) do
    value
    |> Enum.map(fn {key, nested} -> {json_key(key), json_safe(nested)} end)
    |> Map.new()
  end

  defp json_safe(value) when is_list(value), do: Enum.map(value, &json_safe/1)
  defp json_safe(value) when is_atom(value), do: Atom.to_string(value)
  defp json_safe(value), do: value

  defp json_key(key) when is_atom(key), do: Atom.to_string(key)
  defp json_key(key), do: to_string(key)
end
