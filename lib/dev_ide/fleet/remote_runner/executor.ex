defmodule DevIDE.Fleet.RemoteRunner.Executor do
  @moduledoc """
  Executes one controller-offered safe action for a remote runner.

  The executable payload is resolved from `SafeAction`; runner-side assignment
  metadata is never trusted as argv.
  """

  alias DevIDE.Commands
  alias DevIDE.Fleet.Protocol
  alias DevIDE.Fleet.Protocol.Messages
  alias DevIDE.Fleet.WorkspaceContext
  alias DevIDE.Runners.SafeAction

  @type report_fun :: (struct() -> {:ok, term()} | {:error, term()})

  @spec run(map(), report_fun(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(offer, report_fun, opts \\ []) when is_function(report_fun, 1) do
    with {:ok, payload} <- offer_payload(offer),
         {:ok, action} <- SafeAction.fetch(payload.safe_action_id),
         {:ok, workspace} <- WorkspaceContext.validate(payload.workspace_id),
         {:ok, root} <- workspace_root(workspace) do
      execute(payload, action, root, report_fun, opts)
    end
  end

  defp execute(payload, %SafeAction{} = action, root, report_fun, opts) do
    execution_id = Keyword.get(opts, :execution_id) || Ecto.UUID.generate()
    started_at = DateTime.utc_now()

    started = %Messages.ExecutionStarted{
      assignment_id: payload.assignment_id,
      execution_id: execution_id,
      started_at: started_at
    }

    with {:ok, _} <- report_fun.(started),
         {:ok, ref, handle} <- Commands.spawn(root, action.argv, self()) do
      collect(%{
        assignment_id: payload.assignment_id,
        execution_id: execution_id,
        action: action,
        ref: ref,
        handle: handle,
        report_fun: report_fun,
        output_bytes: 0,
        timeout_ms: Keyword.get(opts, :timeout_ms, payload.lease_duration_ms || 30 * 60 * 1000)
      })
    else
      {:error, reason} ->
        failed = %Messages.ExecutionFailed{
          assignment_id: payload.assignment_id,
          execution_id: execution_id,
          failed_at: DateTime.utc_now(),
          reason: "spawn_failed: #{inspect(reason)}",
          evidence: %{failure_class: "spawn_failed", safe_action_id: action.id}
        }

        _ = report_fun.(failed)
        {:error, reason}
    end
  end

  defp collect(state) do
    receive do
      {:cmd_data, ref, stream, data} when ref == state.ref ->
        chunk = IO.iodata_to_binary(data)

        output = %Messages.OutputChunk{
          assignment_id: state.assignment_id,
          execution_id: state.execution_id,
          stream: normalize_stream(stream),
          chunk: chunk,
          timestamp: DateTime.utc_now()
        }

        with {:ok, _} <- state.report_fun.(output) do
          collect(%{state | output_bytes: state.output_bytes + byte_size(chunk)})
        end

      {:cmd_exit, ref, 0} when ref == state.ref ->
        completed = %Messages.ExecutionCompleted{
          assignment_id: state.assignment_id,
          execution_id: state.execution_id,
          completed_at: DateTime.utc_now(),
          evidence: %{
            exit_code: 0,
            output_bytes: state.output_bytes,
            safe_action_id: state.action.id,
            command_id: state.action.command_id
          }
        }

        with {:ok, _} <- state.report_fun.(completed) do
          {:ok, result(state, :completed, 0)}
        end

      {:cmd_exit, ref, code} when ref == state.ref ->
        failed = %Messages.ExecutionFailed{
          assignment_id: state.assignment_id,
          execution_id: state.execution_id,
          failed_at: DateTime.utc_now(),
          reason: "exit_code=#{code}",
          evidence: %{
            exit_code: code,
            output_bytes: state.output_bytes,
            safe_action_id: state.action.id,
            command_id: state.action.command_id
          }
        }

        with {:ok, _} <- state.report_fun.(failed) do
          {:ok, result(state, :failed, code)}
        end
    after
      state.timeout_ms ->
        Commands.kill(state.handle)

        failed = %Messages.ExecutionFailed{
          assignment_id: state.assignment_id,
          execution_id: state.execution_id,
          failed_at: DateTime.utc_now(),
          reason: "timeout",
          evidence: %{exit_code: :timeout, output_bytes: state.output_bytes}
        }

        with {:ok, _} <- state.report_fun.(failed) do
          {:ok, result(state, :failed, :timeout)}
        end
    end
  end

  defp offer_payload(%{envelope: envelope}) when is_map(envelope) do
    with {:ok, decoded} <- Protocol.deserialize(envelope) do
      {:ok, decoded.payload}
    end
  end

  defp offer_payload(%{"envelope" => envelope}) when is_map(envelope) do
    with {:ok, decoded} <- Protocol.deserialize(envelope) do
      {:ok, decoded.payload}
    end
  end

  defp offer_payload(_offer), do: {:error, :invalid_offer}

  defp workspace_root(%WorkspaceContext{worktree_path: path})
       when is_binary(path) and path != "" do
    if File.dir?(path), do: {:ok, path}, else: {:error, :workspace_root_missing}
  end

  defp workspace_root(_workspace), do: {:error, :workspace_root_missing}

  defp normalize_stream(:stderr), do: "stderr"
  defp normalize_stream(:stdout), do: "stdout"
  defp normalize_stream(stream) when is_binary(stream), do: stream
  defp normalize_stream(_), do: "stdout"

  defp result(state, status, exit_code) do
    %{
      assignment_id: state.assignment_id,
      execution_id: state.execution_id,
      safe_action_id: state.action.id,
      command_id: state.action.command_id,
      status: status,
      exit_code: exit_code,
      output_bytes: state.output_bytes
    }
  end
end
