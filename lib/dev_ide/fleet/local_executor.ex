defmodule DevIDE.Fleet.LocalExecutor do
  @moduledoc """
  Local safe-action executor for the fleet protocol boundary.

  This is the M45 local execution loop. It intentionally behaves like a runner:

    * resolve an allowlisted `DevIDE.Runners.SafeAction`
    * validate the assignment's workspace context
    * report `ExecutionStarted` through the protocol
    * execute argv through the existing command adapter
    * stream stdout/stderr as `OutputChunk` protocol messages
    * report terminal success/failure through the protocol

  It does not accept raw argv or shell strings from callers. The only executable
  payload comes from the safe-action registry.
  """

  alias DevIDE.Assignments
  alias DevIDE.BoundedBuffer
  alias DevIDE.Commands
  alias DevIDE.Commands.History
  alias DevIDE.Fleet
  alias DevIDE.Fleet.Protocol
  alias DevIDE.Fleet.Protocol.Messages
  alias DevIDE.Fleet.WorkspaceContext
  alias DevIDE.Runners.SafeAction

  @default_timeout_ms 30 * 60 * 1000
  @max_history_output 64 * 1024

  @type result :: %{
          assignment_id: String.t(),
          execution_id: String.t(),
          runner_id: String.t(),
          lease_id: String.t(),
          workspace_id: String.t(),
          worktree_path: String.t(),
          safe_action_id: String.t(),
          command_id: String.t(),
          argv: [String.t()],
          status: :completed | :failed,
          exit_code: term(),
          output_bytes: non_neg_integer()
        }

  @spec execute_assignment(String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def execute_assignment(assignment_id, opts \\ [])

  def execute_assignment(assignment_id, opts) when is_binary(assignment_id) do
    with {:ok, assignment} <- fetch_assignment(assignment_id),
         {:ok, lease} <- fetch_lease(assignment_id),
         {:ok, action} <- action_for_assignment(assignment),
         {:ok, workspace} <- WorkspaceContext.validate(assignment.workspace_id),
         {:ok, root} <- workspace_root(workspace),
         {:ok, claimed} <- ensure_claimed(assignment, lease, opts) do
      execute(claimed, lease, action, root, opts)
    end
  end

  def execute_assignment(_assignment_id, _opts), do: {:error, :invalid_assignment_id}

  defp execute(assignment, lease, %SafeAction{} = action, root, opts) do
    execution_id = Keyword.get(opts, :execution_id) || Ecto.UUID.generate()
    timeout_ms = Keyword.get(opts, :timeout_ms, default_timeout_ms())
    started_at = DateTime.utc_now()
    history_id = start_history(assignment, action, started_at, opts)

    started = %Messages.ExecutionStarted{
      assignment_id: assignment.id,
      execution_id: execution_id,
      started_at: started_at
    }

    with {:ok, _started_assignment} <- send_message(started, lease),
         {:ok, ref, handle} <- Commands.spawn(root, action.argv, self()) do
      collect(%{
        assignment: assignment,
        lease: lease,
        action: action,
        root: root,
        execution_id: execution_id,
        ref: ref,
        handle: handle,
        timeout_ms: timeout_ms,
        output_bytes: 0,
        output_buffer: "",
        history_id: history_id,
        started_at: started_at
      })
    else
      {:error, reason} = error ->
        _ = report_spawn_failure(assignment, lease, execution_id, reason)
        finish_history(history_id, :failed, :spawn_failed, started_at, "")
        error
    end
  end

  defp collect(state) do
    receive do
      {:cmd_data, ref, stream, data} when ref == state.ref ->
        chunk = IO.iodata_to_binary(data)
        stream = normalize_stream(stream)

        output = %Messages.OutputChunk{
          assignment_id: state.assignment.id,
          execution_id: state.execution_id,
          stream: stream,
          chunk: chunk,
          timestamp: DateTime.utc_now()
        }

        case send_message(output, state.lease) do
          {:ok, _} ->
            collect(%{
              state
              | output_bytes: state.output_bytes + byte_size(chunk),
                output_buffer:
                  BoundedBuffer.append(state.output_buffer, chunk, @max_history_output,
                    truncation_marker: "[...truncated]\n"
                  )
            })

          {:error, reason} ->
            {:error, {:output_rejected, reason}}
        end

      {:cmd_exit, ref, code} when ref == state.ref ->
        terminal(state, code)
    after
      state.timeout_ms ->
        Commands.kill(state.handle)
        terminal(state, :timeout)
    end
  end

  defp terminal(state, 0) do
    completed = %Messages.ExecutionCompleted{
      assignment_id: state.assignment.id,
      execution_id: state.execution_id,
      completed_at: DateTime.utc_now(),
      evidence: %{
        exit_code: 0,
        output_bytes: state.output_bytes,
        safe_action_id: state.action.id,
        command_id: state.action.command_id
      }
    }

    with {:ok, _assignment} <- send_message(completed, state.lease) do
      finish_history(state.history_id, :succeeded, 0, state.started_at, state.output_buffer)
      {:ok, result(state, :completed, 0)}
    end
  end

  defp terminal(state, code) do
    failed = %Messages.ExecutionFailed{
      assignment_id: state.assignment.id,
      execution_id: state.execution_id,
      failed_at: DateTime.utc_now(),
      reason: failure_reason(code),
      evidence: %{
        exit_code: code,
        output_bytes: state.output_bytes,
        safe_action_id: state.action.id,
        command_id: state.action.command_id
      }
    }

    with {:ok, _assignment} <- send_message(failed, state.lease) do
      finish_history(state.history_id, :failed, code, state.started_at, state.output_buffer)
      {:ok, result(state, :failed, code)}
    end
  end

  defp start_history(assignment, %SafeAction{} = action, started_at, opts) do
    metadata =
      opts
      |> Keyword.get(:metadata, %{})
      |> normalize_metadata()
      |> Map.merge(%{
        assignment_id: assignment.id,
        safe_action_id: action.id,
        safe_action_version: action.version,
        protocol: "devide.fleet.local.v1"
      })

    case History.start_run(%{
           id: assignment.run_id || Ecto.UUID.generate(),
           workspace_id: assignment.workspace_id,
           actor_id: Keyword.get(opts, :actor_id),
           command_id: action.command_id,
           started_at: started_at,
           metadata: metadata
         }) do
      {:ok, %{id: id}} -> id
      _ -> nil
    end
  end

  defp finish_history(nil, _status, _exit_code, _started_at, _output), do: :ok

  defp finish_history(history_id, status, exit_code, started_at, output) do
    _ =
      History.finish_run(history_id, %{
        status: status,
        exit_code: exit_code,
        started_at: started_at,
        finished_at: DateTime.utc_now(),
        output: output
      })

    :ok
  end

  defp result(state, status, exit_code) do
    %{
      assignment_id: state.assignment.id,
      execution_id: state.execution_id,
      runner_id: state.lease.runner_id,
      lease_id: state.lease.id,
      workspace_id: state.assignment.workspace_id,
      worktree_path: state.root,
      safe_action_id: state.action.id,
      command_id: state.action.command_id,
      argv: state.action.argv,
      status: status,
      exit_code: exit_code,
      output_bytes: state.output_bytes
    }
  end

  defp report_spawn_failure(assignment, lease, execution_id, reason) do
    failed = %Messages.ExecutionFailed{
      assignment_id: assignment.id,
      execution_id: execution_id,
      failed_at: DateTime.utc_now(),
      reason: "spawn_failed: #{inspect(reason)}",
      evidence: %{failure_class: "spawn_failed"}
    }

    send_message(failed, lease)
  end

  defp send_message(message, lease) do
    message
    |> Protocol.wrap(runner_id: lease.runner_id, lease_id: lease.id)
    |> Protocol.send_to_controller()
  end

  defp ensure_claimed(%{state: "claimed"} = assignment, _lease, _opts), do: {:ok, assignment}
  defp ensure_claimed(%{state: "running"} = assignment, _lease, _opts), do: {:ok, assignment}

  defp ensure_claimed(%{state: "requested"} = assignment, lease, opts) do
    Assignments.claim(assignment.id, lease.runner_id, lease_ms: lease_ms(lease, opts))
  end

  defp ensure_claimed(%{state: "queued"} = assignment, lease, opts) do
    Assignments.claim(assignment.id, lease.runner_id, lease_ms: lease_ms(lease, opts))
  end

  defp ensure_claimed(assignment, _lease, _opts), do: {:error, {:not_claimable, assignment.state}}

  defp lease_ms(lease, opts) do
    Keyword.get_lazy(opts, :lease_ms, fn ->
      max(DateTime.diff(lease.expires_at, DateTime.utc_now(), :millisecond), 1)
    end)
  end

  defp fetch_assignment(assignment_id) do
    case Assignments.get(assignment_id) do
      {:ok, assignment} -> {:ok, assignment}
      :error -> {:error, :assignment_not_found}
    end
  end

  defp fetch_lease(assignment_id) do
    case Fleet.get_lease(assignment_id) do
      {:ok, lease} -> {:ok, lease}
      :error -> {:error, :lease_not_found}
    end
  end

  defp action_for_assignment(%{metadata: metadata}) do
    safe_action_id = metadata_value(metadata, "safe_action_id")
    command_id = metadata_value(metadata, "command_id")

    cond do
      is_binary(safe_action_id) ->
        safe_action_id
        |> SafeAction.fetch()
        |> normalize_action_result()

      is_binary(command_id) ->
        command_id
        |> SafeAction.fetch_command()
        |> normalize_action_result()

      true ->
        {:error, :safe_action_missing}
    end
  end

  defp normalize_action_result({:ok, %SafeAction{} = action}), do: {:ok, action}
  defp normalize_action_result(:error), do: {:error, :safe_action_not_allowed}

  defp workspace_root(%WorkspaceContext{worktree_path: path})
       when is_binary(path) and path != "" do
    if File.dir?(path), do: {:ok, path}, else: {:error, :workspace_root_missing}
  end

  defp workspace_root(_workspace), do: {:error, :workspace_root_missing}

  defp metadata_value(metadata, key) when is_map(metadata) do
    Map.get(metadata, key) || Map.get(metadata, String.to_atom(key))
  end

  defp metadata_value(_metadata, _key), do: nil

  defp normalize_metadata(metadata) when is_map(metadata), do: metadata
  defp normalize_metadata(_metadata), do: %{}

  defp normalize_stream(:stderr), do: "stderr"
  defp normalize_stream(:stdout), do: "stdout"
  defp normalize_stream("stderr"), do: "stderr"
  defp normalize_stream("stdout"), do: "stdout"
  defp normalize_stream(_stream), do: "stdout"

  defp failure_reason(:timeout), do: "timeout"
  defp failure_reason(code), do: "exit_code=#{inspect(code)}"

  defp default_timeout_ms do
    Application.get_env(:dev_ide, :fleet_local_executor_timeout_ms, @default_timeout_ms)
  end
end
