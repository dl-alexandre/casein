defmodule DevIDE.Fleet.DelegateFlow do
  @moduledoc """
  First real delegated work flow.

  A delegated task is an operator-created sequence of allowlisted workspace
  commands. Each step is executed through the fleet local execution loop, so it
  still goes through assignment, placement, protocol, workspace validation,
  artifact storage, live output, and terminal state.

  The task record itself is represented in audit + per-assignment metadata; the
  reviewable result is assembled from the workspace dossier.
  """

  alias DevIDE.Audit
  alias DevIDE.Fleet
  alias DevIDE.Runners.SafeAction

  @type status :: :completed | :failed

  @type result :: %{
          task_id: String.t(),
          workspace_id: String.t(),
          command_sequence: [String.t()],
          status: status(),
          steps: [map()],
          dossier: map(),
          started_at: DateTime.t(),
          completed_at: DateTime.t()
        }

  @spec run(String.t(), [String.t()], keyword()) :: {:ok, result()} | {:error, term()}
  def run(workspace_id, command_ids, opts \\ [])

  def run(workspace_id, command_ids, opts)
      when is_binary(workspace_id) and is_list(command_ids) and command_ids != [] do
    with {:ok, sequence} <- validate_sequence(command_ids) do
      task_id = Keyword.get(opts, :task_id) || Ecto.UUID.generate()
      actor_id = Keyword.get(opts, :actor_id, "operator")
      started_at = DateTime.utc_now()

      Audit.emit!(%{
        action: "fleet.delegate_task.created",
        actor_id: actor_id,
        workspace_id: workspace_id,
        target_type: "delegate_task",
        target_ref: task_id,
        decision: :allow,
        metadata: %{command_sequence: sequence}
      })

      {status, steps} = execute_sequence(workspace_id, sequence, task_id, opts)
      completed_at = DateTime.utc_now()
      {:ok, dossier} = Fleet.dossier(workspace_id)

      Audit.emit!(%{
        action: "fleet.delegate_task.finished",
        actor_id: actor_id,
        workspace_id: workspace_id,
        target_type: "delegate_task",
        target_ref: task_id,
        decision: :allow,
        metadata: %{status: status, command_sequence: sequence, step_count: length(steps)}
      })

      {:ok,
       %{
         task_id: task_id,
         workspace_id: workspace_id,
         command_sequence: sequence,
         status: status,
         steps: steps,
         dossier: dossier,
         started_at: started_at,
         completed_at: completed_at
       }}
    end
  end

  def run(_workspace_id, _command_ids, _opts), do: {:error, :invalid_attrs}

  defp validate_sequence(command_ids) do
    command_ids
    |> Enum.reduce_while({:ok, []}, fn command_id, {:ok, acc} ->
      case SafeAction.fetch_command(command_id) do
        {:ok, _action} -> {:cont, {:ok, [command_id | acc]}}
        :error -> {:halt, {:error, {:command_not_allowed, command_id}}}
      end
    end)
    |> case do
      {:ok, sequence} -> {:ok, Enum.reverse(sequence)}
      {:error, _reason} = error -> error
    end
  end

  defp execute_sequence(workspace_id, sequence, task_id, opts) do
    sequence
    |> Enum.with_index(1)
    |> Enum.reduce_while({:completed, []}, fn {command_id, index}, {_status, steps} ->
      step_opts = step_opts(opts, task_id, command_id, index)

      case Fleet.run_safe_command(workspace_id, command_id, step_opts) do
        {:ok, result} ->
          step = step_result(result, command_id, index)

          if result.status == :completed do
            {:cont, {:completed, [step | steps]}}
          else
            {:halt, {:failed, [step | steps]}}
          end

        {:error, reason} ->
          step = %{
            command_id: command_id,
            step_index: index,
            status: :failed,
            error: reason
          }

          {:halt, {:failed, [step | steps]}}
      end
    end)
    |> then(fn {status, steps} -> {status, Enum.reverse(steps)} end)
  end

  defp step_opts(opts, task_id, command_id, index) do
    metadata =
      opts
      |> Keyword.get(:metadata, %{})
      |> normalize_metadata()
      |> Map.merge(%{
        task_id: task_id,
        step_index: index,
        command_id: command_id,
        delegate_flow: true
      })

    opts
    |> Keyword.put(:metadata, metadata)
    |> Keyword.put_new(:run_id, Ecto.UUID.generate())
  end

  defp step_result(result, command_id, index) do
    result
    |> Map.take([
      :assignment_id,
      :execution_id,
      :runner_id,
      :lease_id,
      :workspace_id,
      :worktree_path,
      :safe_action_id,
      :argv,
      :status,
      :exit_code,
      :output_bytes
    ])
    |> Map.put(:command_id, command_id)
    |> Map.put(:step_index, index)
  end

  defp normalize_metadata(metadata) when is_map(metadata), do: metadata
  defp normalize_metadata(_metadata), do: %{}
end
