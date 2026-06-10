defmodule DevIDE.Fleet.Protocol.Validator do
  @moduledoc """
  Layered validation for protocol messages.

  Validation is four distinct phases, never collapsed:

    1. Envelope valid? — structure, version, timestamps
    2. Message structurally valid? — required fields, types
    3. Lease valid? — lease exists, belongs to runner, not expired
    4. Transition valid? — message sequence respects state machine

  Each phase returns `{:ok, context}` or `{:error, reason}`.
  The context accumulates validated data for downstream phases.
  """

  alias DevIDE.Fleet
  alias DevIDE.Fleet.ExecutionProjection
  alias DevIDE.Fleet.ExecutionProjectionStore
  alias DevIDE.Fleet.ExecutionStatus
  alias DevIDE.Fleet.Protocol.Envelope
  alias DevIDE.Fleet.Protocol.Messages

  @current_version 1

  @type context :: %{
          envelope: Envelope.t(),
          lease: Fleet.Lease.t() | nil,
          runner: Fleet.Runner.t() | nil,
          execution: Fleet.Execution.t() | nil
        }

  @doc """
  Validate an envelope through all four phases.

  Returns `{:ok, context}` or `{:error, reason}` at the first failure.
  """
  @spec validate(Envelope.t()) :: {:ok, context()} | {:error, term()}
  def validate(%Envelope{} = envelope) do
    with {:ok, ctx1} <- validate_envelope(envelope),
         {:ok, ctx2} <- validate_message_struct(ctx1),
         :ok <- validate_runner_origin(ctx2),
         {:ok, ctx3} <- validate_lease(ctx2) do
      validate_transition(ctx3)
    end
  end

  ## Phase 1: Envelope validation

  defp validate_envelope(%Envelope{} = envelope) do
    cond do
      envelope.version != @current_version ->
        {:error, {:invalid_version, envelope.version, @current_version}}

      not valid_uuid?(envelope.message_id) ->
        {:error, :invalid_message_id}

      not valid_datetime?(envelope.sent_at) ->
        {:error, :invalid_sent_at}

      not valid_uuid?(envelope.runner_id) ->
        {:error, :invalid_runner_id}

      not valid_uuid?(envelope.lease_id) ->
        {:error, :invalid_lease_id}

      true ->
        {:ok,
         %{
           envelope: envelope,
           lease: nil,
           runner: nil,
           execution: nil
         }}
    end
  end

  ## Phase 2: Message structural validation

  defp validate_message_struct(%{envelope: envelope} = ctx) do
    payload = envelope.payload

    cond do
      Messages.state_transition?(payload) ->
        validate_state_transition_fields(payload, ctx)

      Messages.observational?(payload) ->
        validate_observational_fields(payload, ctx)

      Messages.lifecycle?(payload) ->
        validate_lifecycle_fields(payload, ctx)

      true ->
        validate_generic_fields(payload, ctx)
    end
  end

  defp validate_state_transition_fields(%Messages.ExecutionStarted{} = msg, ctx) do
    required_present?(
      [msg.assignment_id, msg.execution_id],
      ctx,
      :missing_execution_started_fields
    )
  end

  defp validate_state_transition_fields(%Messages.ExecutionCompleted{} = msg, ctx) do
    required_present?(
      [msg.assignment_id, msg.execution_id, msg.completed_at],
      ctx,
      :missing_execution_completed_fields
    )
  end

  defp validate_state_transition_fields(%Messages.ExecutionFailed{} = msg, ctx) do
    required_present?(
      [msg.assignment_id, msg.execution_id, msg.failed_at, msg.reason],
      ctx,
      :missing_execution_failed_fields
    )
  end

  defp validate_state_transition_fields(%Messages.ExecutionAbandoned{} = msg, ctx) do
    required_present?(
      [msg.assignment_id, msg.execution_id, msg.reason],
      ctx,
      :missing_execution_abandoned_fields
    )
  end

  defp validate_observational_fields(%Messages.OutputChunk{} = msg, ctx) do
    required_present?(
      [msg.assignment_id, msg.execution_id, msg.stream, msg.chunk],
      ctx,
      :missing_output_chunk_fields
    )
  end

  defp validate_observational_fields(%Messages.ArtifactChunk{} = msg, ctx) do
    required_present?(
      [msg.assignment_id, msg.execution_id, msg.artifact_id, msg.chunk],
      ctx,
      :missing_artifact_chunk_fields
    )
  end

  defp validate_observational_fields(%Messages.Telemetry{} = msg, ctx) do
    required_present?(
      [msg.runner_id, msg.timestamp],
      ctx,
      :missing_telemetry_fields
    )
  end

  defp validate_lifecycle_fields(%Messages.Heartbeat{} = msg, ctx) do
    required_present?([msg.runner_id], ctx, :missing_heartbeat_fields)
  end

  defp validate_lifecycle_fields(%Messages.LeaseRenewed{} = msg, ctx) do
    with {:ok, ctx} <-
           required_present?([msg.lease_id, msg.expires_at], ctx, :missing_lease_renewed_fields),
         true <-
           DateTime.compare(msg.expires_at, DateTime.utc_now()) == :gt ||
             {:error, :invalid_lease_renewal_expiry} do
      {:ok, ctx}
    end
  end

  defp validate_generic_fields(%Messages.AssignmentOffered{} = msg, ctx) do
    required_present?(
      [msg.assignment_id, msg.safe_action_id, msg.workspace_id],
      ctx,
      :missing_assignment_offered_fields
    )
  end

  defp validate_generic_fields(%Messages.AssignmentAccepted{} = msg, ctx) do
    required_present?([msg.assignment_id], ctx, :missing_assignment_accepted_fields)
  end

  defp validate_generic_fields(%Messages.AssignmentRejected{} = msg, ctx) do
    required_present?([msg.assignment_id, msg.reason], ctx, :missing_assignment_rejected_fields)
  end

  defp validate_generic_fields(%Messages.AssignmentRevoked{} = msg, ctx) do
    required_present?([msg.assignment_id], ctx, :missing_assignment_revoked_fields)
  end

  defp validate_generic_fields(_msg, ctx), do: {:ok, ctx}

  defp validate_runner_origin(%{envelope: %{payload: %Messages.AssignmentOffered{}}}),
    do: {:error, :runner_cannot_send_controller_instruction}

  defp validate_runner_origin(%{envelope: %{payload: %Messages.AssignmentRevoked{}}}),
    do: {:error, :runner_cannot_send_controller_instruction}

  defp validate_runner_origin(_ctx), do: :ok

  ## Phase 3: Lease validation

  defp validate_lease(%{envelope: envelope} = ctx) do
    case fetch_lease(envelope) do
      :error ->
        {:error, :lease_not_found}

      {:ok, lease} ->
        validate_lease_runner(lease, envelope.runner_id, ctx)
    end
  end

  defp fetch_lease(%Envelope{} = envelope) do
    with :error <- Fleet.get_lease(envelope.lease_id),
         :error <- get_lease_by_id(envelope.lease_id) do
      case Messages.assignment_id(envelope.payload) do
        nil -> :error
        assignment_id -> Fleet.get_lease(assignment_id)
      end
    end
  end

  defp get_lease_by_id(lease_id) do
    Fleet.list_leases()
    |> Enum.find(&(&1.id == lease_id))
    |> case do
      nil -> :error
      lease -> {:ok, lease}
    end
  end

  defp validate_lease_runner(lease, runner_id, ctx) do
    if lease.runner_id == runner_id do
      now = DateTime.utc_now()

      if lease.state == :active and DateTime.compare(lease.expires_at, now) == :gt do
        {:ok, %{ctx | lease: lease}}
      else
        {:error, :lease_expired_or_inactive}
      end
    else
      {:error, :lease_runner_mismatch}
    end
  end

  ## Phase 4: Transition validation

  defp validate_transition(%{envelope: envelope, lease: lease} = ctx) do
    payload = envelope.payload

    with :ok <- validate_assignment_scope(payload, lease),
         {:ok, ctx} <- bind_execution(payload, ctx) do
      cond do
        Messages.state_transition?(payload) ->
          validate_state_sequence(payload, lease, ctx)

        Messages.observational?(payload) ->
          validate_observational_sequence(payload, ctx)

        Messages.lifecycle?(payload) ->
          {:ok, ctx}

        true ->
          {:ok, ctx}
      end
    end
  end

  defp validate_state_sequence(%Messages.ExecutionStarted{}, _lease, ctx) do
    case ctx.execution do
      nil -> {:ok, ctx}
      %ExecutionProjection{state: :pending} -> {:ok, ctx}
      %ExecutionProjection{} -> {:error, :execution_already_started}
    end
  end

  defp validate_state_sequence(%Messages.ExecutionCompleted{}, _lease, ctx) do
    require_started_execution(ctx)
  end

  defp validate_state_sequence(%Messages.ExecutionFailed{}, _lease, ctx) do
    require_started_execution(ctx)
  end

  defp validate_state_sequence(%Messages.ExecutionAbandoned{}, _lease, ctx) do
    require_started_execution(ctx)
  end

  defp validate_observational_sequence(%Messages.Telemetry{}, ctx), do: {:ok, ctx}

  defp validate_observational_sequence(_payload, ctx) do
    require_started_execution(ctx)
  end

  defp validate_assignment_scope(payload, lease) do
    case Messages.assignment_id(payload) do
      nil ->
        :ok

      assignment_id when assignment_id == lease.assignment_id ->
        :ok

      _other ->
        {:error, :lease_assignment_mismatch}
    end
  end

  defp bind_execution(%Messages.ExecutionStarted{} = msg, ctx) do
    case ExecutionProjectionStore.get(msg.execution_id) do
      {:ok, %ExecutionProjection{} = execution} ->
        validate_execution_scope(execution, msg.assignment_id, ctx)

      :error ->
        {:ok, %{ctx | execution: nil}}
    end
  end

  defp bind_execution(%{execution_id: execution_id, assignment_id: assignment_id}, ctx)
       when is_binary(execution_id) do
    case ExecutionProjectionStore.get(execution_id) do
      {:ok, %ExecutionProjection{} = execution} ->
        validate_execution_scope(execution, assignment_id, ctx)

      :error ->
        {:error, :execution_not_started}
    end
  end

  defp bind_execution(_payload, ctx), do: {:ok, ctx}

  defp validate_execution_scope(%ExecutionProjection{} = execution, assignment_id, ctx) do
    cond do
      execution.assignment_id != assignment_id ->
        {:error, :execution_assignment_mismatch}

      execution.runner_id != ctx.envelope.runner_id ->
        {:error, :execution_runner_mismatch}

      execution.lease_id != ctx.lease.id ->
        {:error, :execution_lease_mismatch}

      true ->
        {:ok, %{ctx | execution: execution}}
    end
  end

  defp require_started_execution(%{execution: %ExecutionProjection{state: state}} = ctx) do
    if ExecutionStatus.started?(state) do
      {:ok, ctx}
    else
      {:error, :execution_not_active}
    end
  end

  defp require_started_execution(_ctx), do: {:error, :execution_not_started}

  ## Helpers

  defp required_present?(fields, ctx, error_reason) do
    if Enum.all?(fields, &(not is_nil(&1) and &1 != "")) do
      {:ok, ctx}
    else
      {:error, error_reason}
    end
  end

  defp valid_uuid?(nil), do: false

  defp valid_uuid?(value) when is_binary(value) do
    String.length(value) == 36 and
      Regex.match?(~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i, value)
  end

  defp valid_uuid?(_), do: false

  defp valid_datetime?(%DateTime{}), do: true
  defp valid_datetime?(_), do: false
end
