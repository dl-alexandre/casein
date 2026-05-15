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
         {:ok, root} <- workspace_root(payload, offer, opts) do
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
        # Track B (remote resilience): per-stream sequence numbers + UTF-8 boundary buffer
        output_seqs: %{},
        utf8_buffers: %{},
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
        stream = normalize_stream(stream)
        buffer = Map.get(state.utf8_buffers, stream, <<>>)
        {complete_chunks, new_buffer} = split_utf8_complete(IO.iodata_to_binary(data), buffer)

        # Always update the UTF-8 buffer up-front; the next :cmd_data must see
        # the trailing partial bytes even if no chunks are ready this turn.
        state = put_in(state.utf8_buffers[stream], new_buffer)

        result =
          Enum.reduce_while(complete_chunks, {:ok, state}, fn chunk, {:ok, acc} ->
            # Read last_seq from the accumulator so multiple chunks emitted in
            # the same :cmd_data message get monotonically increasing seqs.
            seq = Map.get(acc.output_seqs, stream, 0) + 1

            output = %Messages.OutputChunk{
              assignment_id: state.assignment_id,
              execution_id: state.execution_id,
              stream: stream,
              chunk: chunk,
              seq: seq,
              timestamp: DateTime.utc_now()
            }

            case acc.report_fun.(output) do
              {:ok, _} ->
                new_acc =
                  acc
                  |> Map.update!(:output_bytes, &(&1 + byte_size(chunk)))
                  |> put_in([:output_seqs, stream], seq)

                {:cont, {:ok, new_acc}}

              {:error, reason} ->
                # Best-effort: do not silently drop the execution. Try to
                # surface ExecutionFailed so the controller has a protocol
                # record of what happened. If that also fails, give up — no
                # retry loop, to bound the damage from a flapping transport.
                report_failure(acc, {:report_failed, reason})
                {:halt, {:error, {:report_failed, reason}}}
            end
          end)

        case result do
          {:ok, new_state} -> collect(new_state)
          {:error, reason} -> {:error, reason}
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

  defp workspace_root(payload, offer, opts) do
    case runner_worktree_path(payload, offer, opts) do
      path when is_binary(path) and path != "" ->
        validate_workspace_root(path)

      _ ->
        with {:ok, workspace} <- WorkspaceContext.validate(payload.workspace_id) do
          validate_workspace_root(workspace.worktree_path)
        end
    end
  end

  defp runner_worktree_path(payload, offer, opts) do
    Keyword.get(opts, :worktree_path) ||
      Map.get(payload, :worktree_path) ||
      assignment_worktree_path(offer)
  end

  defp assignment_worktree_path(%{assignment: assignment}) when is_map(assignment) do
    Map.get(assignment, "worktree_path") || Map.get(assignment, :worktree_path)
  end

  defp assignment_worktree_path(%{"assignment" => assignment}) when is_map(assignment) do
    Map.get(assignment, "worktree_path") || Map.get(assignment, :worktree_path)
  end

  defp assignment_worktree_path(_offer), do: nil

  defp validate_workspace_root(path) when is_binary(path) and path != "" do
    if File.dir?(path), do: {:ok, path}, else: {:error, :workspace_root_missing}
  end

  defp validate_workspace_root(_path), do: {:error, :workspace_root_missing}

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

  # Best-effort terminator when `report_fun` itself errors mid-execution.
  # We never want an execution to "vanish" from the controller's perspective:
  # if we can't ship OutputChunks, at minimum we try once to ship an
  # ExecutionFailed describing why. Any error there is swallowed — the
  # transport is clearly broken and another attempt isn't going to help.
  defp report_failure(state, reason) do
    failed = %Messages.ExecutionFailed{
      assignment_id: state.assignment_id,
      execution_id: state.execution_id,
      failed_at: DateTime.utc_now(),
      reason: "report_failed: #{inspect(reason)}",
      evidence: %{
        failure_class: "report_failed",
        underlying: inspect(reason),
        safe_action_id: state.action.id,
        output_bytes: state.output_bytes
      }
    }

    _ = state.report_fun.(failed)
    :ok
  catch
    _kind, _err -> :ok
  end

  # --- Track B: UTF-8 boundary buffering + sequence numbers (remote resilience) ---

  # Splits incoming bytes + previous incomplete UTF-8 buffer into complete UTF-8 strings
  # and returns the remaining incomplete prefix.
  # This ensures we never emit an OutputChunk that ends in the middle of a multi-byte
  # UTF-8 character.
  defp split_utf8_complete(new_bytes, buffer) do
    combined = buffer <> new_bytes

    case :unicode.characters_to_list(combined) do
      list when is_list(list) ->
        # All bytes form valid, complete UTF-8.
        {[combined], <<>>}

      {:incomplete, good_chars, _rest} ->
        # Trailing bytes are a valid *prefix* of a multi-byte char awaiting
        # completion — buffer them so the next chunk can finish the character.
        good = :unicode.characters_to_binary(good_chars)
        rest = binary_part(combined, byte_size(good), byte_size(combined) - byte_size(good))
        {[good], rest}

      {:error, good_chars, rest_with_bad} ->
        # `rest_with_bad` starts with an invalid byte. Buffering it would loop
        # forever — the bad byte will never become valid no matter what arrives
        # next. Pass it through raw; terminals render U+FFFD for bad bytes and
        # the operator sees what actually came over the wire.
        good = :unicode.characters_to_binary(good_chars)
        {[good <> rest_with_bad], <<>>}
    end
  end
end
