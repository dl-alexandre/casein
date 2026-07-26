defmodule Casein.Signals do
  @moduledoc """
  CloudEvents envelopes for Casein domain events, built on `jido_signal`.

  `Casein.Signals.Context` propagates correlation/causation ids and
  `Casein.Audit` stamps them into event metadata; this module converts an
  audit event into its CloudEvents form.

  Phase 3: `Casein.SignalBus` runs under `Casein.Supervision.PlatformServices`,
  `Casein.Signals.Publish` publishes envelopes from `Casein.Audit`'s broadcast
  path, and `Casein.Signals.AlertsRouter` routes alert-worthy signals to
  `Casein.Push.Dispatcher`.
  """

  alias Casein.Agents.AgentEvent
  alias Casein.Audit.Event
  alias Jido.Signal
  alias Jido.Signal.Trace

  alias Casein.Signals.Context

  @type_prefix "casein.audit."
  @domain_prefix "casein."

  @doc "Signal-type prefix for audit-derived signals."
  @spec type_prefix() :: String.t()
  def type_prefix, do: @type_prefix

  @doc "CloudEvents type for an audit action, e.g. \"casein.audit.agent.blocked\"."
  @spec type_for(String.t()) :: String.t()
  def type_for(action) when is_binary(action), do: @type_prefix <> action

  @doc "CloudEvents type for a domain event, e.g. \"casein.deploy.failed\"."
  @spec domain_type(String.t()) :: String.t()
  def domain_type(event) when is_binary(event), do: @domain_prefix <> event

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
      source: "/casein/audit/#{event.workspace_id || "global"}",
      subject: event.target_ref,
      time: event.inserted_at && DateTime.to_iso8601(event.inserted_at)
    })
    |> put_trace(event.metadata || %{})
  end

  @doc "Convert a durable agent timeline event into a metadata-only Jido signal."
  @spec from_agent_event(AgentEvent.t()) :: Signal.t()
  def from_agent_event(%AgentEvent{} = event) do
    Signal.new!(domain_type("agent_event." <> event.event_type), agent_event_data(event), %{
      id: event.id,
      source: "/casein/agent/#{event.workspace_id}",
      subject: event.agent_session_id || event.tmux_session_id || event.runtime_id,
      time: event.occurred_at && DateTime.to_iso8601(event.occurred_at)
    })
    |> put_trace(event.payload || %{})
  end

  defp agent_event_data(%AgentEvent{} = event) do
    %{
      workspace_id: event.workspace_id,
      stream_id: event.stream_id,
      producer: event.producer,
      ingress: event.ingress,
      source_event_id: event.source_event_id,
      event_type: event.event_type,
      privacy_class: event.privacy_class,
      agent_session_id: event.agent_session_id,
      tmux_session_id: event.tmux_session_id,
      pane_id: event.pane_id,
      runtime_id: event.runtime_id,
      actor_id: event.actor_id,
      status: event.status,
      summary: event.summary,
      payload: event.payload || %{}
    }
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

  @doc """
  Build a CloudEvents signal for a non-audit domain event.

  Domain events use the `casein.<event>` type namespace (distinct from
  `casein.audit.*`) so bus consumers can subscribe broadly while audit
  routing keeps its existing prefix.
  """
  @spec from_domain_event(String.t(), map(), keyword()) :: Signal.t()
  def from_domain_event(event, data, opts \\ []) when is_binary(event) and is_map(data) do
    workspace_id = Keyword.get(opts, :workspace_id)
    subject = Keyword.get(opts, :subject)
    id = Keyword.get_lazy(opts, :id, &Ecto.UUID.generate/0)
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    stamped =
      Context.stamp(%{
        metadata: %{
          "event" => event,
          "domain" => true
        }
      })

    payload =
      data
      |> Map.put(:event, event)
      |> Map.put(:workspace_id, workspace_id)
      |> Map.put(:metadata, stamped.metadata)

    Signal.new!(domain_type(event), payload, %{
      id: id,
      source: domain_source(workspace_id, event),
      subject: subject,
      time: now
    })
    |> put_trace(stamped.metadata)
  end

  defp domain_source(nil, event), do: "/casein/domain/#{event}"
  defp domain_source(workspace_id, _event), do: "/casein/domain/#{workspace_id}"

  defp new_span_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
