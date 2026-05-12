defmodule DevIDE.Fleet.OperatorWorkflow do
  @moduledoc """
  Operator-facing workflow over delegated fleet execution.

  This module does not mutate orchestration state directly. Command runbook
  actions go through `DevIDE.Fleet.run_safe_command/3`, recovery goes through
  approved recovery wrappers, takeover attachment goes through `Takeover`, and
  evidence is read from `Dossier`.
  """

  alias DevIDE.Assignments
  alias DevIDE.Assignments.Assignment
  alias DevIDE.Assignments.Recovery
  alias DevIDE.Assignments.RecoveryAction
  alias DevIDE.Audit
  alias DevIDE.Fleet.Approvals
  alias DevIDE.Fleet.Dossier
  alias DevIDE.Fleet.OperatorNotifications
  alias DevIDE.Fleet.Takeover
  alias DevIDE.Runners.SafeAction
  alias DevIDE.Runs.Status

  @runbook_actions [
    %{
      id: "rerun_tests",
      label: "Rerun tests",
      kind: :safe_command,
      command_id: "test",
      requires_approval?: false
    },
    %{
      id: "rerun_precommit",
      label: "Rerun precommit",
      kind: :safe_command,
      command_id: "precommit",
      requires_approval?: false
    },
    %{
      id: "rebuild_assets",
      label: "Rebuild assets",
      kind: :safe_command,
      command_id: "assets.build",
      requires_approval?: false
    },
    %{
      id: "inspect_dossier",
      label: "Inspect dossier",
      kind: :read_dossier,
      requires_approval?: false
    },
    %{
      id: "attach_session",
      label: "Attach session",
      kind: :takeover,
      requires_approval?: true
    }
  ]

  @terminal_review_statuses ~w(succeeded failed)

  @type review_item :: %{
          id: String.t(),
          type: :delegated_execution,
          status: :needs_review,
          task_id: String.t() | nil,
          step_index: term(),
          workspace_id: String.t(),
          assignment_id: String.t(),
          execution_id: String.t(),
          runner_id: String.t() | nil,
          lease_id: String.t() | nil,
          command: map(),
          exit_status: String.t(),
          exit_code: term(),
          artifacts: [map()],
          recovery_options: [map()],
          dossier: map()
        }

  @spec review_queue(String.t(), keyword()) :: {:ok, [review_item()]} | {:error, term()}
  def review_queue(workspace_id, opts \\ [])

  def review_queue(workspace_id, opts) when is_binary(workspace_id) do
    with {:ok, dossier} <- Dossier.workspace(workspace_id, opts) do
      assignments_by_id = assignments_by_id(dossier.assignment_history)

      reviews =
        dossier.executions
        |> Enum.filter(&delegated_reviewable?(&1, assignments_by_id))
        |> Enum.map(&review_item(&1, assignments_by_id))

      {:ok, reviews}
    end
  end

  def review_queue(_workspace_id, _opts), do: {:error, :invalid_workspace_id}

  @spec runbook_actions() :: [map()]
  def runbook_actions, do: @runbook_actions

  @spec runbook_action(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def runbook_action(action_id, workspace_id, opts \\ [])

  def runbook_action(action_id, workspace_id, opts)
      when is_binary(action_id) and is_binary(workspace_id) do
    with {:ok, action} <- fetch_runbook_action(action_id) do
      do_runbook_action(action, workspace_id, opts)
    end
  end

  def runbook_action(_action_id, _workspace_id, _opts), do: {:error, :invalid_attrs}

  @spec apply_approved_recovery(RecoveryAction.t(), String.t() | nil, String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def apply_approved_recovery(action, approval_id, operator_id, opts \\ [])

  def apply_approved_recovery(%RecoveryAction{} = action, approval_id, operator_id, opts)
      when is_binary(operator_id) do
    with {:ok, _approval} <-
           Approvals.require_granted(approval_id, action.kind, action.assignment_id) do
      if Keyword.get(opts, :rerun, false) and
           action.kind in [:retry_assignment, :requeue_assignment] do
        rerun_recovery(action, approval_id, operator_id, opts)
      else
        apply_recovery(action, approval_id, operator_id)
      end
    end
  end

  def apply_approved_recovery(_action, _approval_id, _operator_id, _opts),
    do: {:error, :invalid_recovery_action}

  defp do_runbook_action(%{kind: :safe_command} = action, workspace_id, opts) do
    metadata =
      opts
      |> Keyword.get(:metadata, %{})
      |> normalize_metadata()
      |> Map.merge(%{
        runbook_action_id: action.id,
        operator_workflow: true
      })

    opts =
      opts
      |> Keyword.put(:metadata, metadata)
      |> Keyword.put_new(:actor_id, Keyword.get(opts, :operator_id, "operator"))

    case DevIDE.Fleet.run_safe_command(workspace_id, action.command_id, opts) do
      {:ok, result} ->
        {:ok, %{action: action, result: result}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_runbook_action(%{kind: :read_dossier} = action, workspace_id, opts) do
    with {:ok, dossier} <- Dossier.workspace(workspace_id, opts) do
      {:ok, %{action: action, dossier: dossier}}
    end
  end

  defp do_runbook_action(%{kind: :takeover} = action, _workspace_id, opts) do
    with {:ok, assignment_id} <- fetch_required_opt(opts, :assignment_id),
         {:ok, _approval} <-
           Approvals.require_granted(
             Keyword.get(opts, :approval_id),
             :attach_session,
             assignment_id
           ),
         {:ok, takeover} <- Takeover.prepare(assignment_id, opts) do
      {:ok, %{action: action, takeover: takeover}}
    end
  end

  defp rerun_recovery(%RecoveryAction{} = action, approval_id, operator_id, opts) do
    with {:ok, _dry_run} <- Recovery.dry_run(action),
         {:ok, original} <- Assignments.get(action.assignment_id),
         {:ok, command_id} <- command_id_for(original),
         {:ok, _safe_action} <- SafeAction.fetch_command(command_id),
         {:ok, result} <-
           DevIDE.Fleet.run_safe_command(
             original.workspace_id,
             command_id,
             recovery_run_opts(action, approval_id, operator_id, opts)
           ) do
      applied =
        %{
          action
          | applied: true,
            applied_at: DateTime.utc_now(),
            dry_run_result: %{
              action: action.kind,
              original_assignment_id: action.assignment_id,
              new_assignment_id: result.assignment_id,
              execution_id: result.execution_id,
              exit_status: result.status,
              exit_code: result.exit_code
            }
        }

      audit_recovery(action, approval_id, operator_id, result)

      OperatorNotifications.emit(:recovered, %{
        workspace_id: result.workspace_id,
        assignment_id: action.assignment_id,
        execution_id: result.execution_id,
        runner_id: result.runner_id,
        lease_id: result.lease_id,
        message: "Approved recovery reran delegated execution",
        metadata: %{
          approval_id: approval_id,
          recovery_action_id: action.id,
          recovery_kind: Atom.to_string(action.kind),
          new_assignment_id: result.assignment_id
        }
      })

      {:ok, %{recovery_action: applied, execution: result, approval_id: approval_id}}
    else
      {:error, :stale} = error ->
        notify_stale(action, approval_id)
        error

      {:error, reason} ->
        {:error, reason}

      :error ->
        {:error, :assignment_not_found}
    end
  end

  defp apply_recovery(%RecoveryAction{} = action, approval_id, operator_id) do
    case Recovery.apply(action, operator_id) do
      {:ok, applied} ->
        OperatorNotifications.emit(:recovered, %{
          assignment_id: action.assignment_id,
          message: "Approved recovery action applied",
          metadata: %{
            approval_id: approval_id,
            recovery_action_id: action.id,
            recovery_kind: Atom.to_string(action.kind),
            result: applied.dry_run_result || %{}
          }
        })

        {:ok, %{recovery_action: applied, approval_id: approval_id}}

      {:error, :stale} = error ->
        notify_stale(action, approval_id)
        error

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp recovery_run_opts(action, approval_id, operator_id, opts) do
    metadata =
      opts
      |> Keyword.get(:metadata, %{})
      |> normalize_metadata()
      |> Map.merge(%{
        recovered_from: action.assignment_id,
        recovery_action_id: action.id,
        recovery_kind: Atom.to_string(action.kind),
        approval_id: approval_id,
        operator_workflow: true
      })

    opts
    |> Keyword.delete(:rerun)
    |> Keyword.put(:actor_id, operator_id)
    |> Keyword.put(:metadata, metadata)
  end

  defp audit_recovery(%RecoveryAction{} = action, approval_id, operator_id, result) do
    Audit.emit!(%{
      action: "assignment.recovery.#{action.kind}",
      actor_id: operator_id,
      workspace_id: result.workspace_id,
      target_type: "assignment",
      target_ref: action.assignment_id,
      decision: :allow,
      metadata: %{
        approval_id: approval_id,
        recovery_action_id: action.id,
        result: %{
          action: action.kind,
          original_assignment_id: action.assignment_id,
          new_assignment_id: result.assignment_id,
          execution_id: result.execution_id,
          exit_status: result.status,
          exit_code: result.exit_code
        }
      }
    })
  end

  defp notify_stale(%RecoveryAction{} = action, approval_id) do
    OperatorNotifications.emit(:stale, %{
      assignment_id: action.assignment_id,
      message: "Approved recovery proposal is stale",
      metadata: %{
        approval_id: approval_id,
        recovery_action_id: action.id,
        recovery_kind: Atom.to_string(action.kind)
      }
    })
  end

  defp fetch_runbook_action(action_id) do
    case Enum.find(@runbook_actions, &(&1.id == action_id)) do
      nil -> {:error, :unknown_runbook_action}
      action -> {:ok, action}
    end
  end

  defp fetch_required_opt(opts, key) do
    case Keyword.get(opts, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_required_option, key}}
    end
  end

  defp assignments_by_id(assignment_history) do
    Map.new(assignment_history, fn %{assignment: %Assignment{} = assignment} ->
      {assignment.id, assignment}
    end)
  end

  defp delegated_reviewable?(execution, assignments_by_id) do
    assignment = Map.get(assignments_by_id, execution.assignment_id)
    metadata = assignment_value(assignment, :metadata) || %{}

    delegated?(metadata) and
      Status.normalize(execution.exit_status) in @terminal_review_statuses
  end

  defp delegated?(metadata) do
    metadata_value(metadata, "delegate_flow") in [true, "true"] or
      present?(metadata_value(metadata, "task_id"))
  end

  defp review_item(execution, assignments_by_id) do
    assignment = Map.get(assignments_by_id, execution.assignment_id)
    metadata = assignment_value(assignment, :metadata) || %{}

    %{
      id: execution.execution_id,
      type: :delegated_execution,
      status: :needs_review,
      task_id: metadata_value(metadata, "task_id"),
      step_index: metadata_value(metadata, "step_index"),
      workspace_id: execution.workspace_id,
      assignment_id: execution.assignment_id,
      execution_id: execution.execution_id,
      runner_id: execution.runner_id,
      lease_id: execution.lease_id,
      command: execution.command,
      exit_status: Status.normalize(execution.exit_status),
      exit_code: execution.exit_code,
      artifacts: execution.artifacts,
      recovery_options: execution.recovery_actions,
      dossier: %{
        workspace_id: execution.workspace_id,
        assignment_id: execution.assignment_id,
        execution_id: execution.execution_id,
        ref:
          "dossier://#{execution.workspace_id}/assignments/#{execution.assignment_id}/executions/#{execution.execution_id}"
      }
    }
  end

  defp command_id_for(%Assignment{} = assignment) do
    case metadata_value(assignment.metadata || %{}, "command_id") do
      command_id when is_binary(command_id) and command_id != "" -> {:ok, command_id}
      _ -> {:error, :command_id_missing}
    end
  end

  defp assignment_value(nil, _key), do: nil
  defp assignment_value(%Assignment{} = assignment, key), do: Map.get(assignment, key)

  defp normalize_metadata(metadata) when is_map(metadata), do: metadata
  defp normalize_metadata(_metadata), do: %{}

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

  defp present?(value), do: is_binary(value) and value != ""
end
