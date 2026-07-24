defmodule Casein.Codex.EventSink do
  @moduledoc false

  require Logger

  alias Casein.Codex.{Event, Store}
  alias Casein.Signals.Publish

  @topic_prefix "codex:workspace:"
  @semantic_types [
    :thread_started,
    :thread_status_changed,
    :turn_started,
    :turn_completed,
    :turn_failed,
    :approval_requested,
    :approval_resolved,
    :subagent_started,
    :subagent_stopped,
    :error
  ]

  @spec route(Event.t()) :: :ok | {:error, term()}
  def route(%Event{} = event) do
    with :ok <- maybe_persist(event) do
      Phoenix.PubSub.broadcast(Casein.PubSub, topic(event.workspace_id), {:codex_event, event})
      emit_semantic_signal(event)
      emit_audit(event)
      emit_telemetry(event)
      :ok
    end
  end

  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(workspace_id) when is_binary(workspace_id),
    do: Phoenix.PubSub.subscribe(Casein.PubSub, topic(workspace_id))

  @spec topic(String.t()) :: String.t()
  def topic(workspace_id), do: @topic_prefix <> workspace_id

  defp maybe_persist(%Event{type: :agent_message_delta}), do: :ok

  defp maybe_persist(event) do
    case Store.record(event) do
      :ok ->
        :ok

      {:error, reason} = error ->
        Logger.error("failed to persist Codex event",
          workspace_id: event.workspace_id,
          runtime_id: event.runtime_id,
          event_type: event.type,
          reason: inspect(reason)
        )

        error
    end
  end

  defp emit_semantic_signal(%Event{type: type} = event) when type in @semantic_types do
    Publish.domain_event("codex.#{type}", signal_data(event),
      workspace_id: event.workspace_id,
      subject: event.thread_id || event.runtime_id,
      id: event.id
    )
  end

  defp emit_semantic_signal(_event), do: :ok

  defp emit_audit(%Event{type: :approval_requested} = event) do
    Casein.Audit.emit!(%{
      workspace_id: event.workspace_id,
      action: "codex.approval_requested",
      target_type: "codex_approval",
      target_ref: payload_value(event.payload, :approval_id),
      decision: :allow,
      metadata: audit_metadata(event)
    })
  end

  defp emit_audit(%Event{type: :approval_resolved} = event) do
    status = payload_value(event.payload, :status)

    Casein.Audit.emit!(%{
      workspace_id: event.workspace_id,
      action: "codex.approval_resolved",
      target_type: "codex_approval",
      target_ref: payload_value(event.payload, :approval_id),
      decision: if(status in [:denied, "denied"], do: :deny, else: :allow),
      metadata: audit_metadata(event)
    })
  end

  defp emit_audit(_event), do: :ok

  defp emit_telemetry(event) do
    measurements =
      case event.type do
        :usage_updated -> usage_measurements(event.payload)
        _other -> %{count: 1}
      end

    :telemetry.execute(
      [:casein, :codex, :event],
      measurements,
      %{
        type: event.type,
        transport: event.transport,
        workspace_id: event.workspace_id,
        runtime_id: event.runtime_id,
        thread_id: event.thread_id
      }
    )
  end

  defp signal_data(event) do
    %{
      event_id: event.id,
      event_type: event.type,
      runtime_id: event.runtime_id,
      transport: event.transport,
      thread_id: event.thread_id,
      parent_thread_id: event.parent_thread_id,
      turn_id: event.turn_id,
      item_id: event.item_id,
      sequence: event.sequence,
      occurred_at: DateTime.to_iso8601(event.occurred_at),
      payload: event.payload
    }
  end

  defp audit_metadata(event) do
    %{
      "runtime_id" => event.runtime_id,
      "transport" => Atom.to_string(event.transport),
      "thread_id" => event.thread_id,
      "turn_id" => event.turn_id,
      "item_id" => event.item_id,
      "request_id" => event.request_id && to_string(event.request_id),
      "sequence" => event.sequence,
      "payload" => event.payload
    }
  end

  defp usage_measurements(payload) do
    usage = payload_value(payload, :total) || payload

    %{
      input_tokens: integer_value(usage, :input_tokens, :inputTokens),
      cached_input_tokens: integer_value(usage, :cached_input_tokens, :cachedInputTokens),
      output_tokens: integer_value(usage, :output_tokens, :outputTokens),
      reasoning_output_tokens:
        integer_value(usage, :reasoning_output_tokens, :reasoningOutputTokens),
      total_tokens: integer_value(usage, :total_tokens, :totalTokens)
    }
  end

  defp integer_value(map, snake, camel) when is_map(map) do
    value =
      Map.get(map, snake) || Map.get(map, Atom.to_string(snake)) || Map.get(map, camel) ||
        Map.get(map, Atom.to_string(camel))

    if is_integer(value), do: value, else: 0
  end

  defp integer_value(_map, _snake, _camel), do: 0
  defp payload_value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
