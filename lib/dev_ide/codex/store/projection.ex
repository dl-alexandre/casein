defmodule Casein.Codex.Store.Projection do
  @moduledoc false

  alias Casein.Codex.Event

  @spec thread(map() | nil, Event.t()) :: map() | nil
  def thread(existing, %Event{thread_id: thread_id} = event)
      when is_binary(thread_id) and thread_id != "" do
    existing =
      existing ||
        %{
          thread_id: thread_id,
          workspace_id: event.workspace_id,
          runtime_id: event.runtime_id,
          parent_thread_id: event.parent_thread_id,
          session_id: event.session_id,
          transport: event.transport,
          status: nil,
          active_flags: [],
          current_turn_id: nil,
          agent_role: nil,
          agent_nickname: nil,
          preview: nil,
          usage: %{},
          metadata: %{}
        }

    existing
    |> Map.merge(%{
      workspace_id: event.workspace_id,
      runtime_id: event.runtime_id,
      transport: event.transport,
      last_sequence: event.sequence,
      last_event_at: event.occurred_at
    })
    |> put_present(:parent_thread_id, event.parent_thread_id)
    |> put_present(:session_id, event.session_id)
    |> apply_thread_event(event)
  end

  def thread(_existing, _event), do: nil

  @spec approval(map() | nil, Event.t()) :: map() | nil
  def approval(existing, %Event{type: type} = event)
      when type in [:approval_requested, :approval_resolved] do
    approval_id = value(event.payload, :approval_id)

    if is_binary(approval_id) and approval_id != "" do
      existing =
        existing ||
          %{
            id: approval_id,
            workspace_id: event.workspace_id,
            runtime_id: event.runtime_id,
            thread_id: event.thread_id,
            turn_id: event.turn_id,
            item_id: event.item_id,
            request_id: request_id(event.request_id),
            kind: string_value(value(event.payload, :approval_kind)),
            status: "pending",
            resolution: %{},
            payload: json_map(event.payload),
            metadata: json_map(event.metadata),
            requested_at: event.occurred_at,
            resolved_at: nil
          }

      case type do
        :approval_requested ->
          existing

        :approval_resolved ->
          existing
          |> Map.put(:status, string_value(value(event.payload, :status)) || "resolved")
          |> Map.put(:resolution, resolution(value(event.payload, :resolution)))
          |> Map.put(:resolved_at, event.occurred_at)
          |> Map.put(:metadata, Map.merge(existing.metadata, json_map(event.metadata)))
      end
    end
  end

  def approval(_existing, _event), do: nil

  defp apply_thread_event(thread, %Event{type: :thread_started, payload: payload}) do
    thread
    |> put_present(:status, string_value(value(payload, :status)))
    |> Map.put(:active_flags, list_value(value(payload, :active_flags)))
    |> put_present(:agent_role, value(payload, :agent_role))
    |> put_present(:agent_nickname, value(payload, :agent_nickname))
    |> put_present(:preview, value(payload, :preview))
  end

  defp apply_thread_event(thread, %Event{type: :thread_status_changed, payload: payload}) do
    thread
    |> put_present(:status, string_value(value(payload, :status)))
    |> Map.put(:active_flags, list_value(value(payload, :active_flags)))
  end

  defp apply_thread_event(thread, %Event{type: :turn_started, turn_id: turn_id}) do
    thread
    |> Map.put(:current_turn_id, turn_id)
    |> Map.put(:status, "active")
  end

  defp apply_thread_event(thread, %Event{type: type})
       when type in [:turn_completed, :turn_failed] do
    Map.put(thread, :current_turn_id, nil)
  end

  defp apply_thread_event(thread, %Event{type: :usage_updated, payload: payload}) do
    Map.put(thread, :usage, json_map(payload))
  end

  defp apply_thread_event(thread, %Event{type: :subagent_started, payload: payload}) do
    thread
    |> Map.put(:status, "active")
    |> put_present(:agent_role, value(payload, :agent_type))
  end

  defp apply_thread_event(thread, %Event{type: :subagent_stopped}),
    do: Map.put(thread, :status, "idle")

  defp apply_thread_event(thread, _event), do: thread

  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, ""), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp list_value(value) when is_list(value), do: Enum.map(value, &string_value/1)
  defp list_value(_value), do: []
  defp request_id(nil), do: nil
  defp request_id(value), do: to_string(value)
  defp string_value(nil), do: nil
  defp string_value(value) when is_binary(value), do: value
  defp string_value(value) when is_atom(value), do: Atom.to_string(value)
  defp string_value(value), do: to_string(value)
  defp resolution(nil), do: %{}
  defp resolution(value) when is_map(value), do: json_map(value)
  defp resolution(value), do: %{"value" => string_value(value)}

  defp json_map(map) when is_map(map) do
    map
    |> Jason.encode!()
    |> Jason.decode!()
  end

  defp json_map(_value), do: %{}
end
