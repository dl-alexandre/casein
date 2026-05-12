defmodule DevIDE.Fleet.Dossier do
  @moduledoc """
  Read-only workspace dossier assembled from orchestration evidence.

  The dossier is not a new source of truth. It gathers the durable or
  replayable records already owned by the assignment event store, command
  history, execution projections, artifact store, audit log, and workspace
  cache into one operator-facing structure.
  """

  alias DevIDE.Assignments
  alias DevIDE.Assignments.Assignment
  alias DevIDE.Assignments.Recovery
  alias DevIDE.Assignments.Status, as: AssignmentStatus
  alias DevIDE.Audit
  alias DevIDE.Commands.History
  alias DevIDE.Fleet.ArtifactStore
  alias DevIDE.Fleet.ExecutionProjection
  alias DevIDE.Fleet.ExecutionProjectionStore
  alias DevIDE.Fleet.ExecutionStatus
  alias DevIDE.Workspaces.State

  @type t :: %{
          workspace_id: String.t(),
          workspace: map() | nil,
          git_sha: String.t() | nil,
          branch: String.t() | nil,
          worktree_path: String.t() | nil,
          assignment_history: [map()],
          command_history: [map()],
          executions: [map()],
          artifacts: [map()],
          failures: [map()],
          recovery_actions: [map()],
          approval_decisions: [map()]
        }

  @spec workspace(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def workspace(workspace_id, opts \\ [])

  def workspace(workspace_id, opts) when is_binary(workspace_id) do
    limit = Keyword.get(opts, :limit, 50)
    workspace = workspace_record(workspace_id)
    assignments = Assignments.list_by_workspace(workspace_id)
    assignment_ids = MapSet.new(assignments, & &1.id)

    executions =
      ExecutionProjectionStore.list()
      |> Enum.filter(&MapSet.member?(assignment_ids, &1.assignment_id))
      |> Enum.sort_by(&execution_sort_key/1, {:desc, DateTime})

    command_history = History.recent_for(workspace_id, limit)
    approval_decisions = approval_decisions(workspace_id, assignment_ids)
    recovery_actions = recovery_actions(workspace_id, assignments)

    execution_trail =
      execution_trail(
        assignments,
        executions,
        command_history,
        recovery_actions,
        approval_decisions
      )

    artifacts = Enum.flat_map(execution_trail, & &1.artifacts)

    {:ok,
     %{
       workspace_id: workspace_id,
       workspace: workspace,
       git_sha: dossier_git_sha(workspace, executions),
       branch: dossier_branch(workspace),
       worktree_path: dossier_worktree_path(workspace, executions),
       assignment_history: assignment_history(assignments, executions),
       command_history: Enum.take(command_history, limit),
       executions: execution_trail,
       artifacts: artifacts,
       failures: failures(assignments, executions),
       recovery_actions: recovery_actions,
       approval_decisions: approval_decisions
     }}
  end

  def workspace(_workspace_id, _opts), do: {:error, :invalid_workspace_id}

  defp workspace_record(workspace_id) do
    case State.get(workspace_id) do
      {:ok, record} -> Map.from_struct(record)
      :error -> nil
    end
  end

  defp assignment_history(assignments, executions) do
    executions_by_assignment = Enum.group_by(executions, & &1.assignment_id)

    assignments
    |> Enum.sort_by(&(&1.updated_at || &1.inserted_at), {:desc, DateTime})
    |> Enum.map(fn assignment ->
      assignment_executions = Map.get(executions_by_assignment, assignment.id, [])

      %{
        assignment: assignment,
        events: Assignments.replay(assignment.id),
        executions: assignment_executions,
        artifacts: artifacts_for(assignment_executions),
        recovery_proposals: Recovery.propose(assignment.id)
      }
    end)
  end

  defp artifacts_for(%ExecutionProjection{} = execution), do: artifacts_for([execution])

  defp artifacts_for(executions) when is_list(executions) do
    Enum.flat_map(executions, fn %ExecutionProjection{} = execution ->
      execution.id
      |> ArtifactStore.chunks()
      |> Enum.map(fn chunk ->
        %{
          assignment_id: execution.assignment_id,
          execution_id: execution.id,
          runner_id: execution.runner_id,
          workspace_id: execution.workspace_id,
          lease_id: execution.lease_id,
          stream: chunk.stream,
          data: chunk.data,
          byte_size: chunk.byte_size,
          timestamp: chunk.timestamp
        }
      end)
    end)
  end

  defp execution_trail(
         assignments,
         executions,
         command_history,
         recovery_actions,
         approval_decisions
       ) do
    assignments_by_id = Map.new(assignments, &{&1.id, &1})
    command_history_by_assignment = command_history_by_assignment(command_history)
    recovery_actions_by_assignment = recovery_actions_by_assignment(recovery_actions)
    approvals_by_assignment = approvals_by_assignment(approval_decisions)

    Enum.map(executions, fn %ExecutionProjection{} = execution ->
      assignment = Map.get(assignments_by_id, execution.assignment_id)
      command_record = Map.get(command_history_by_assignment, execution.assignment_id)

      artifacts =
        execution
        |> artifacts_for()
        |> Enum.map(&enrich_artifact(&1, execution, assignment, command_record))

      %{
        assignment_id: execution.assignment_id,
        execution_id: execution.id,
        runner_id: execution.runner_id,
        workspace_id: execution.workspace_id || assignment_value(assignment, :workspace_id),
        lease_id: execution.lease_id,
        command: command_summary(assignment, command_record),
        exit_status: exit_status(execution, command_record),
        exit_code: exit_code(execution, command_record),
        artifacts: artifacts,
        recovery_actions: Map.get(recovery_actions_by_assignment, execution.assignment_id, []),
        approval_decisions: Map.get(approvals_by_assignment, execution.assignment_id, [])
      }
    end)
  end

  defp enrich_artifact(artifact, execution, assignment, command_record) do
    artifact
    |> Map.put(:command, command_summary(assignment, command_record))
    |> Map.put(:exit_status, exit_status(execution, command_record))
    |> Map.put(:exit_code, exit_code(execution, command_record))
    |> Map.put(
      :workspace_id,
      artifact.workspace_id || assignment_value(assignment, :workspace_id)
    )
  end

  defp failures(assignments, executions) do
    assignment_failures =
      assignments
      |> Enum.filter(&AssignmentStatus.failure?(&1.state))
      |> Enum.map(fn %Assignment{} = assignment ->
        %{
          type: :assignment,
          assignment_id: assignment.id,
          state: assignment.state,
          reason: assignment.failure_reason,
          occurred_at: assignment.completed_at || assignment.updated_at
        }
      end)

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

    assignment_failures ++ execution_failures
  end

  defp recovery_actions(workspace_id, assignments) do
    assignment_ids = MapSet.new(assignments, & &1.id)

    audit_actions =
      Audit.list(limit: 1_000)
      |> Enum.filter(fn event ->
        event.workspace_id == workspace_id or
          (event.target_type == "assignment" and MapSet.member?(assignment_ids, event.target_ref))
      end)
      |> Enum.filter(&String.starts_with?(&1.action, "assignment.recovery."))

    proposals =
      assignments
      |> Enum.flat_map(&Recovery.propose(&1.id))
      |> Enum.map(&%{type: :proposal, action: &1})

    Enum.map(audit_actions, &%{type: :audit, action: &1}) ++ proposals
  end

  defp approval_decisions(workspace_id, assignment_ids) do
    Audit.list(limit: 1_000)
    |> Enum.filter(fn event ->
      String.starts_with?(event.action, "run.approval_") and
        (event.workspace_id == workspace_id or
           MapSet.member?(assignment_ids, metadata_value(event.metadata, "approval_target_ref")))
    end)
    |> Enum.map(fn event ->
      %{
        type: :approval,
        approval_id: metadata_value(event.metadata, "approval_id") || event.target_ref,
        status: approval_status(event),
        action: metadata_value(event.metadata, "approval_action"),
        target_type: metadata_value(event.metadata, "approval_target_type"),
        target_ref: metadata_value(event.metadata, "approval_target_ref"),
        actor_id: event.actor_id,
        event: event
      }
    end)
  end

  defp dossier_git_sha(workspace, executions) do
    manager_payload = metadata_value(workspace, "manager_payload")

    execution_value(executions, :git_sha) ||
      metadata_value(workspace, "git_sha") ||
      metadata_value(workspace, "sha") ||
      metadata_value(manager_payload, "git_sha") ||
      metadata_value(manager_payload, "sha")
  end

  defp dossier_branch(workspace) do
    manager_payload = metadata_value(workspace, "manager_payload")

    metadata_value(workspace, "branch") ||
      metadata_value(manager_payload, "branch")
  end

  defp dossier_worktree_path(workspace, executions) do
    execution_value(executions, :worktree_path) ||
      metadata_value(workspace, "host_path") ||
      metadata_value(workspace, "worktree_path")
  end

  defp execution_value(executions, key) do
    executions
    |> Enum.map(&Map.get(&1, key))
    |> Enum.find(&present?/1)
  end

  defp execution_sort_key(%ExecutionProjection{started_at: %DateTime{} = started_at}),
    do: started_at

  defp execution_sort_key(_execution), do: DateTime.from_unix!(0)

  defp metadata_value(nil, _key), do: nil

  defp metadata_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, existing_atom(key))
  end

  defp metadata_value(_value, _key), do: nil

  defp existing_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp command_history_by_assignment(command_history) do
    command_history
    |> Enum.map(fn record -> {metadata_value(record.metadata, "assignment_id"), record} end)
    |> Enum.reject(fn {assignment_id, _record} -> assignment_id in [nil, ""] end)
    |> Map.new()
  end

  defp recovery_actions_by_assignment(recovery_actions) do
    Enum.group_by(recovery_actions, fn
      %{type: :proposal, action: %{assignment_id: assignment_id}} -> assignment_id
      %{type: :audit, action: %{target_ref: assignment_id}} -> assignment_id
      _ -> nil
    end)
  end

  defp approvals_by_assignment(approval_decisions) do
    Enum.group_by(approval_decisions, fn
      %{target_type: "assignment", target_ref: assignment_id} -> assignment_id
      _ -> nil
    end)
  end

  defp approval_status(%{action: "run.approval_requested"}), do: "requested"
  defp approval_status(%{action: "run.approval_granted"}), do: "granted"
  defp approval_status(%{action: "run.approval_denied"}), do: "denied"
  defp approval_status(%{metadata: metadata}), do: metadata_value(metadata, "approval_status")

  defp command_summary(assignment, nil) do
    metadata = assignment_value(assignment, :metadata) || %{}

    %{
      id: metadata_value(metadata, "command_id"),
      safe_action_id: metadata_value(metadata, "safe_action_id"),
      argv: nil
    }
  end

  defp command_summary(assignment, command_record) do
    metadata = assignment_value(assignment, :metadata) || %{}

    %{
      id: command_record.command_id || metadata_value(metadata, "command_id"),
      safe_action_id: metadata_value(metadata, "safe_action_id"),
      argv: command_record.argv
    }
  end

  defp exit_status(_execution, %{status: status}) when not is_nil(status), do: status
  defp exit_status(%ExecutionProjection{state: :completed}, _record), do: "succeeded"
  defp exit_status(%ExecutionProjection{state: state}, _record), do: Atom.to_string(state)

  defp exit_code(%ExecutionProjection{evidence: evidence}, command_record) do
    metadata_value(evidence, "exit_code") || command_exit_code(command_record)
  end

  defp command_exit_code(%{exit_code: exit_code}), do: exit_code
  defp command_exit_code(_record), do: nil

  defp assignment_value(nil, _key), do: nil
  defp assignment_value(%Assignment{} = assignment, key), do: Map.get(assignment, key)

  defp present?(value), do: is_binary(value) and value != ""
end
