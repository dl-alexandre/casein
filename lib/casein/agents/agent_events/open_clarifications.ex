defmodule Casein.Agents.AgentEvents.OpenClarifications do
  @moduledoc false

  # Shared H28 projection for mobile open-clarification inbox hydration.
  #
  # Filter resolved BEFORE newest-per-pane distinct. Distinct-first permanently
  # hides older still-open requests when a newer same-pane request was resolved
  # — unanswerable with no marker. Windows desktop compiles against SQLite and
  # cannot use Postgres `->>` / DISTINCT ON; MemoryAdapter and the SQLite Ecto
  # path both call this pure projector so behaviour stays identical.

  alias Casein.Agents.AgentEvent

  @spec project([AgentEvent.t()], String.t(), String.t(), non_neg_integer()) :: [AgentEvent.t()]
  def project(events, request_type, resolved_type, limit)
      when is_list(events) and is_binary(request_type) and is_binary(resolved_type) and
             is_integer(limit) and limit >= 0 do
    resolved_ids =
      events
      |> Enum.filter(&(&1.event_type == resolved_type))
      |> MapSet.new(&payload_request_event_id/1)

    events
    |> Enum.filter(&(&1.event_type == request_type))
    |> Enum.reject(&MapSet.member?(resolved_ids, &1.id))
    |> Enum.sort_by(&{&1.occurred_at, &1.inserted_at, &1.id}, :desc)
    |> Enum.uniq_by(&{&1.agent_session_id, &1.tmux_session_id, &1.pane_id})
    |> Enum.take(limit)
  end

  defp payload_request_event_id(%AgentEvent{payload: payload}) when is_map(payload) do
    Map.get(payload, "request_event_id") || Map.get(payload, :request_event_id)
  end

  defp payload_request_event_id(_), do: nil
end
