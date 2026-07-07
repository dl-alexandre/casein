defmodule DevIDE.Signals do
  @moduledoc """
  CloudEvents envelopes for DevIDE domain events, built on `jido_signal`.

  `DevIDE.Signals.Context` propagates correlation/causation ids and
  `DevIDE.Audit` stamps them into event metadata; this module converts an
  audit event into its CloudEvents form.

  Phase 3: `DevIDE.SignalBus` runs under `DevIde.Supervision.PlatformServices`,
  `DevIDE.Signals.Publish` publishes envelopes from `DevIDE.Audit`'s broadcast
  path, and `DevIDE.Signals.AlertsRouter` routes alert-worthy signals to
  `DevIDE.Push.Dispatcher`.
  """

  alias DevIDE.Audit.Event
  alias Jido.Signal
  alias Jido.Signal.Trace

  @type_prefix "devide.audit."

  @doc "Signal-type prefix for audit-derived signals."
  @spec type_prefix() :: String.t()
  def type_prefix, do: @type_prefix

  @doc "CloudEvents type for an audit action, e.g. \"devide.audit.agent.blocked\"."
  @spec type_for(String.t()) :: String.t()
  def type_for(action) when is_binary(action), do: @type_prefix <> action

  @doc """
  Convert an audit event into a CloudEvents signal.

  The signal shares the event's id (one identity across both records); the
  correlation/causation ids stamped in event metadata become the signal's
  trace extension.
  """
  @spec from_audit_event(Event.t()) :: Signal.t()
  def from_audit_event(%Event{} = event) do
    Signal.new!(type_for(event.action), event_data(event), %{
      id: event.id,
      source: "/devide/audit/#{event.workspace_id || "global"}",
      subject: event.target_ref,
      time: event.inserted_at && DateTime.to_iso8601(event.inserted_at)
    })
    |> put_trace(event.metadata || %{})
  end

  defp event_data(%Event{} = event) do
    %{
      workspace_id: event.workspace_id,
      actor_id: event.actor_id,
      action: event.action,
      target_type: event.target_type,
      target_ref: event.target_ref,
      decision: event.decision,
      reason: event.reason,
      metadata: event.metadata || %{}
    }
  end

  defp put_trace(signal, metadata) do
    case metadata["correlation_id"] do
      nil ->
        signal

      correlation_id ->
        # Context.new!/1 always generates its own trace_id, so rebuild the
        # struct directly; the span_id only needs to be unique per signal.
        ctx = %Trace.Context{
          trace_id: correlation_id,
          span_id: new_span_id(),
          parent_span_id: nil,
          causation_id: metadata["causation_id"],
          tracestate: nil
        }

        Trace.put!(signal, ctx)
    end
  end

  defp new_span_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
