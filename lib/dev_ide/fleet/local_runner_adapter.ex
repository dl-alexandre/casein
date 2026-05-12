defmodule DevIDE.Fleet.LocalRunnerAdapter do
  @moduledoc """
  Local adapter for the runner protocol boundary.

  Even for local execution, this adapter behaves like a real remote
  boundary:

    1. Serialize the envelope to a transport map
    2. Validate (envelope → message → lease → transition)
    3. Deserialize back to typed structs
    4. Dispatch to the appropriate handler

  This ensures that later extraction to Channel/WebSocket/SSH
  transport is a **translation-layer change**, not a rewrite.

  ## Dispatch rules

  The adapter routes validated messages to handlers that update
  fleet and assignment state through the canonical APIs:

    * `ExecutionStarted` → `Assignments.start/1`
    * `ExecutionCompleted` → `Assignments.complete/1` (or `fail/2`)
    * `ExecutionFailed` → `Assignments.fail/2`
    * `OutputChunk` → appended to Run Ledger artifact
    * `Heartbeat` → `Fleet.heartbeat/1`

  Observational messages are silently accepted and routed to
  artifact storage without mutating orchestration state.
  """

  require Logger

  alias DevIDE.Export.Sanitizer
  alias DevIDE.Fleet
  alias DevIDE.Fleet.ArtifactStore
  alias DevIDE.Fleet.ExecutionProjection
  alias DevIDE.Fleet.ExecutionProjectionStore
  alias DevIDE.Fleet.Notification
  alias DevIDE.Fleet.OperatorNotifications
  alias DevIDE.Fleet.OutputStream
  alias DevIDE.Fleet.Protocol.{Envelope, Validator}
  alias DevIDE.Fleet.Protocol.Messages
  alias DevIDE.Fleet.WorkspaceContext
  alias DevIDE.Terminals.TmuxAdapter

  @pubsub DevIde.PubSub

  @doc """
  Send a message from runner to controller through the local boundary.

  Simulates full wire serialization, validation, and dispatch.
  """
  @spec send_to_controller(Envelope.t()) :: {:ok, term()} | {:error, term()}
  def send_to_controller(%Envelope{} = envelope) do
    # Phase 1: Serialize (as if going over the wire)
    wire = Envelope.to_map(envelope)

    # Phase 2: Deserialize (as if receiving from wire)
    with {:ok, deserialized} <- Envelope.from_map(wire),
         # Phase 3: Validate through all four layers
         {:ok, context} <- Validator.validate(deserialized) do
      # Phase 4: Dispatch
      dispatch(deserialized.payload, context)
    else
      {:error, reason} ->
        Logger.warning("LocalRunnerAdapter rejected message: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Send an offer from controller to runner.

  This is the reverse direction: controller initiates assignment
  placement by offering work to a specific runner.
  """
  @spec offer_assignment(String.t(), Messages.AssignmentOffered.t()) ::
          {:ok, Messages.AssignmentAccepted.t() | Messages.AssignmentRejected.t()}
          | {:error, term()}
  def offer_assignment(runner_id, %Messages.AssignmentOffered{} = offer) do
    envelope =
      Envelope.wrap(offer,
        runner_id: runner_id,
        lease_id: offer.assignment_id
      )

    # Simulate transport round-trip
    wire = Envelope.to_map(envelope)

    # For offers, skip lease validation (lease doesn't exist yet — we're creating it).
    # Validate only envelope structure and message fields.
    with {:ok, deserialized} <- Envelope.from_map(wire),
         :ok <- validate_offer_structure(deserialized) do
      # For local adapter, auto-accept if runner is idle
      case Fleet.get_runner(runner_id) do
        {:ok, runner} when runner.state in [:idle, :online, :registering] ->
          accepted = %Messages.AssignmentAccepted{assignment_id: offer.assignment_id}

          # Acquire lease on behalf of runner
          case Fleet.acquire_lease(runner_id, offer.assignment_id,
                 duration_ms: offer.lease_duration_ms || 15 * 60 * 1000
               ) do
            {:ok, lease} ->
              {:ok, accepted, lease}

            {:error, reason} ->
              rejected = %Messages.AssignmentRejected{
                assignment_id: offer.assignment_id,
                reason: to_string(reason)
              }

              {:ok, rejected, nil}
          end

        _ ->
          rejected = %Messages.AssignmentRejected{
            assignment_id: offer.assignment_id,
            reason: "runner_busy"
          }

          {:ok, rejected, nil}
      end
    end
  end

  defp validate_offer_structure(%Envelope{} = envelope) do
    # Only validate envelope structure and message fields for offers.
    # Skip lease and transition validation.
    with true <- envelope.version == 1 || {:error, :invalid_version},
         true <- valid_uuid?(envelope.message_id) || {:error, :invalid_message_id},
         true <- valid_datetime?(envelope.sent_at) || {:error, :invalid_sent_at},
         true <- valid_uuid?(envelope.runner_id) || {:error, :invalid_runner_id},
         true <- valid_string?(envelope.lease_id) || {:error, :invalid_lease_id},
         true <- not is_nil(envelope.payload.assignment_id) || {:error, :missing_assignment_id},
         true <- not is_nil(envelope.payload.safe_action_id) || {:error, :missing_safe_action_id},
         true <- not is_nil(envelope.payload.workspace_id) || {:error, :missing_workspace_id} do
      :ok
    end
  end

  defp valid_uuid?(value) when is_binary(value), do: String.length(value) == 36
  defp valid_uuid?(_), do: false

  defp valid_datetime?(%DateTime{}), do: true
  defp valid_datetime?(_), do: false

  defp valid_string?(value) when is_binary(value), do: value != ""
  defp valid_string?(_), do: false

  ## Dispatch handlers

  defp dispatch(%Messages.ExecutionStarted{} = msg, ctx) do
    Logger.info("Execution started: #{msg.execution_id} for assignment #{msg.assignment_id}")

    # Register execution stream for output collection
    OutputStream.register_execution(msg.execution_id)

    # Validate workspace (workspace exists independently; execution references it)
    workspace_result =
      case DevIDE.Assignments.get(msg.assignment_id) do
        {:ok, assignment} ->
          WorkspaceContext.validate(assignment.workspace_id)

        :error ->
          {:error, :assignment_not_found}
      end

    # Create execution projection (disposable cache, rebuildable from events)
    projection = %ExecutionProjection{
      id: msg.execution_id,
      assignment_id: msg.assignment_id,
      runner_id: ctx.envelope.runner_id,
      lease_id: ctx.lease.id,
      state: :started,
      started_at: msg.started_at
    }

    case workspace_result do
      {:ok, ws_ctx} ->
        projection = %{
          projection
          | workspace_id: ws_ctx.workspace_id,
            worktree_path: ws_ctx.worktree_path,
            git_sha: ws_ctx.git_sha
        }

        ExecutionProjectionStore.create(projection)

      {:error, _} ->
        ExecutionProjectionStore.create(projection)
    end

    # Attempt tmux session creation (best-effort infrastructure)
    tmux_session =
      case workspace_result do
        {:ok, ws_ctx} ->
          case TmuxAdapter.create_session(msg.execution_id, worktree_path: ws_ctx.worktree_path) do
            {:ok, session_name} -> session_name
            {:error, _} -> nil
          end

        {:error, _} ->
          nil
      end

    if tmux_session do
      ExecutionProjectionStore.update(msg.execution_id, tmux_session: tmux_session)
    end

    # Update assignment state through canonical API
    result =
      case DevIDE.Assignments.start(msg.assignment_id) do
        {:ok, assignment} -> {:ok, assignment}
        {:error, reason} -> {:error, {:assignment_start_failed, reason}}
      end

    broadcast(%Notification{
      kind: :execution_started,
      assignment_id: msg.assignment_id,
      runner_id: ctx.envelope.runner_id,
      execution_id: msg.execution_id,
      payload: %{started_at: msg.started_at, tmux_session: tmux_session},
      occurred_at: msg.started_at
    })

    result
  end

  defp dispatch(%Messages.ExecutionCompleted{} = msg, ctx) do
    Logger.info("Execution completed: #{msg.execution_id}")
    evidence = sanitize_evidence(msg.evidence)

    result =
      case DevIDE.Assignments.complete(msg.assignment_id) do
        {:ok, assignment} -> {:ok, assignment}
        {:error, reason} -> {:error, {:assignment_complete_failed, reason}}
      end

    ExecutionProjectionStore.update(msg.execution_id,
      state: :completed,
      completed_at: msg.completed_at,
      evidence: evidence
    )

    OutputStream.prune_execution(msg.execution_id)
    Fleet.release_lease(msg.assignment_id)

    broadcast(%Notification{
      kind: :execution_completed,
      assignment_id: msg.assignment_id,
      runner_id: ctx.envelope.runner_id,
      execution_id: msg.execution_id,
      payload: %{completed_at: msg.completed_at, evidence: evidence},
      occurred_at: msg.completed_at
    })

    maybe_emit_operator_notification(:completed, result, msg, ctx)

    result
  end

  defp dispatch(%Messages.ExecutionFailed{} = msg, ctx) do
    reason = redact_text(msg.reason)
    evidence = sanitize_evidence(msg.evidence)
    Logger.info("Execution failed: #{msg.execution_id}, reason: #{reason}")

    result =
      case DevIDE.Assignments.fail(msg.assignment_id, %{reason: reason}) do
        {:ok, assignment} -> {:ok, assignment}
        {:error, reason} -> {:error, {:assignment_fail_failed, reason}}
      end

    ExecutionProjectionStore.update(msg.execution_id,
      state: :failed,
      completed_at: msg.failed_at,
      failure_reason: reason,
      evidence: evidence
    )

    OutputStream.prune_execution(msg.execution_id)
    Fleet.release_lease(msg.assignment_id)

    broadcast(%Notification{
      kind: :execution_failed,
      assignment_id: msg.assignment_id,
      runner_id: ctx.envelope.runner_id,
      execution_id: msg.execution_id,
      payload: %{failed_at: msg.failed_at, reason: reason, evidence: evidence},
      occurred_at: msg.failed_at
    })

    maybe_emit_operator_notification(:failed, result, msg, ctx)

    result
  end

  defp dispatch(%Messages.ExecutionAbandoned{} = msg, ctx) do
    reason = redact_text(msg.reason)
    Logger.info("Execution abandoned: #{msg.execution_id}")

    result =
      case DevIDE.Assignments.abandon(msg.assignment_id, %{reason: reason}) do
        {:ok, assignment} -> {:ok, assignment}
        {:error, reason} -> {:error, {:assignment_abandon_failed, reason}}
      end

    ExecutionProjectionStore.update(msg.execution_id,
      state: :abandoned,
      failure_reason: reason
    )

    OutputStream.prune_execution(msg.execution_id)
    Fleet.release_lease(msg.assignment_id)

    broadcast(%Notification{
      kind: :execution_abandoned,
      assignment_id: msg.assignment_id,
      runner_id: ctx.envelope.runner_id,
      execution_id: msg.execution_id,
      payload: %{reason: reason},
      occurred_at: DateTime.utc_now()
    })

    result
  end

  defp dispatch(%Messages.Heartbeat{} = msg, _ctx) do
    case Fleet.heartbeat(msg.runner_id) do
      {:ok, runner} -> {:ok, runner}
      {:error, reason} -> {:error, reason}
      :error -> {:error, :runner_not_found}
    end
  end

  defp dispatch(%Messages.OutputChunk{} = msg, _ctx) do
    chunk = redact_text(msg.chunk)

    # Observational: store durably in ArtifactStore, publish to live OutputStream
    # Order matters: ArtifactStore first (durable), then OutputStream (ephemeral)
    :ok = ArtifactStore.append_chunk(msg.execution_id, msg.stream, chunk, msg.timestamp)
    OutputStream.append_chunk(msg.execution_id, msg.stream, chunk, msg.timestamp)

    broadcast(%Notification{
      kind: :output_chunk,
      assignment_id: msg.assignment_id,
      execution_id: msg.execution_id,
      payload: %{stream: msg.stream, chunk: chunk, byte_size: byte_size(chunk)},
      occurred_at: msg.timestamp
    })

    {:ok, :observational_accepted}
  end

  defp dispatch(%Messages.ArtifactChunk{} = msg, _ctx) do
    chunk = redact_text(msg.chunk)
    Logger.debug("ArtifactChunk [#{msg.artifact_id}]: position #{msg.position}")
    :ok = ArtifactStore.append_chunk(msg.execution_id, artifact_stream(msg), chunk, msg.timestamp)

    broadcast(%Notification{
      kind: :output_chunk,
      assignment_id: msg.assignment_id,
      execution_id: msg.execution_id,
      payload: %{
        artifact_id: msg.artifact_id,
        position: msg.position,
        byte_size: byte_size(chunk)
      },
      occurred_at: msg.timestamp
    })

    {:ok, :observational_accepted}
  end

  defp dispatch(%Messages.Telemetry{} = msg, _ctx) do
    Logger.debug("Telemetry: #{msg.cpu_percent}% CPU, #{msg.memory_mb}MB")

    broadcast(%Notification{
      kind: :telemetry,
      runner_id: msg.runner_id,
      payload: %{cpu_percent: msg.cpu_percent, memory_mb: msg.memory_mb},
      occurred_at: msg.timestamp
    })

    {:ok, :observational_accepted}
  end

  defp dispatch(%Messages.LeaseRenewed{} = msg, ctx) do
    Logger.info("Lease renewed: #{msg.lease_id} until #{msg.expires_at}")

    Fleet.renew_lease(msg.lease_id, ctx.envelope.runner_id, msg.expires_at)
  end

  defp dispatch(%Messages.AssignmentAccepted{} = msg, _ctx) do
    Logger.info("Assignment accepted: #{msg.assignment_id}")
    {:ok, msg}
  end

  defp dispatch(%Messages.AssignmentRejected{} = msg, _ctx) do
    Logger.info("Assignment rejected: #{msg.assignment_id}, reason: #{msg.reason}")
    {:ok, msg}
  end

  defp dispatch(%Messages.AssignmentRevoked{} = msg, _ctx) do
    Logger.info("Assignment revoked: #{msg.assignment_id}")

    case Fleet.revoke_lease(msg.assignment_id) do
      :ok -> {:ok, :revoked}
      :error -> {:error, :lease_not_found}
    end
  end

  defp dispatch(msg, _ctx) do
    Logger.warning("Unhandled message type: #{inspect(msg)}")
    {:error, :unhandled_message_type}
  end

  defp maybe_emit_operator_notification(kind, {:ok, assignment}, msg, ctx) do
    OperatorNotifications.emit(kind, %{
      workspace_id: assignment.workspace_id,
      assignment_id: msg.assignment_id,
      execution_id: msg.execution_id,
      runner_id: ctx.envelope.runner_id,
      lease_id: ctx.lease.id,
      metadata: terminal_notification_metadata(msg)
    })

    :ok
  end

  defp maybe_emit_operator_notification(_kind, _result, _msg, _ctx), do: :ok

  defp terminal_notification_metadata(%Messages.ExecutionCompleted{evidence: evidence}),
    do: %{exit_status: "succeeded", evidence: sanitize_evidence(evidence)}

  defp terminal_notification_metadata(%Messages.ExecutionFailed{
         reason: reason,
         evidence: evidence
       }),
       do: %{
         exit_status: "failed",
         reason: redact_text(reason),
         evidence: sanitize_evidence(evidence)
       }

  defp sanitize_evidence(evidence) when is_map(evidence), do: Sanitizer.scrub(evidence)
  defp sanitize_evidence(_evidence), do: %{}

  defp redact_text(value) when is_binary(value), do: Sanitizer.redact_text(value)
  defp redact_text(value), do: value || ""

  defp artifact_stream(%Messages.ArtifactChunk{artifact_id: artifact_id})
       when is_binary(artifact_id) and artifact_id != "",
       do: "artifact:" <> artifact_id

  defp artifact_stream(_msg), do: "artifact"

  ## Attach / Reconnect

  @doc """
  Attempt to attach to a running execution.

  Reconnect semantics:
    1. Look up the active execution projection for the assignment
    2. Check if tmux session is still alive
    3. If alive, return attach command + historical chunks from ArtifactStore
    4. If not alive, return error (execution may have completed or failed)
  """
  @spec attach(String.t()) ::
          {:ok, %{command: String.t(), chunks: [map()], execution: ExecutionProjection.t()}}
          | {:error, :no_active_execution | :session_not_alive | term()}
  def attach(assignment_id) do
    case ExecutionProjectionStore.active_for_assignment(assignment_id) do
      {:ok, projection} ->
        if projection.tmux_session && TmuxAdapter.session_alive?(projection.tmux_session) do
          historical = ArtifactStore.chunks(projection.id)

          {:ok,
           %{
             command: TmuxAdapter.attach_command(projection.tmux_session),
             chunks: historical,
             execution: projection
           }}
        else
          {:error, :session_not_alive}
        end

      :error ->
        {:error, :no_active_execution}
    end
  end

  defp broadcast(%Notification{} = notification) do
    Phoenix.PubSub.broadcast(@pubsub, "fleet", {__MODULE__, notification})

    if notification.assignment_id do
      Phoenix.PubSub.broadcast(
        @pubsub,
        "fleet:assignments:#{notification.assignment_id}",
        {__MODULE__, notification}
      )
    end

    if notification.runner_id do
      Phoenix.PubSub.broadcast(
        @pubsub,
        "fleet:runners:#{notification.runner_id}",
        {__MODULE__, notification}
      )
    end

    if notification.execution_id do
      Phoenix.PubSub.broadcast(
        @pubsub,
        "fleet:executions:#{notification.execution_id}",
        {__MODULE__, notification}
      )
    end
  end
end
