defmodule DevIDE.Assignments.Reducer do
  @moduledoc """
  Derives an `%Assignment{}` projection from an ordered event stream.

  Pure function — no side effects, no mutation.  Accepts a list of events
  and returns the materialized assignment state.
  """

  alias DevIDE.Assignments.{Assignment, Event}

  @spec reduce([Event.t()]) :: Assignment.t() | nil
  def reduce(events) when is_list(events) do
    events
    |> Enum.sort_by(& &1.sequence)
    |> Enum.reduce(nil, &apply_event/2)
  end

  defp apply_event(%Event{type: :created, payload: p} = e, nil) do
    %Assignment{
      id: e.assignment_id,
      workspace_id: fetch_string(p, :workspace_id),
      run_id: Map.get(p, :run_id) || Map.get(p, "run_id"),
      state: "requested",
      metadata: Map.get(p, :metadata) || Map.get(p, "metadata") || %{},
      inserted_at: e.occurred_at,
      updated_at: e.occurred_at
    }
  end

  defp apply_event(%Event{type: :claimed, payload: p} = e, %Assignment{} = a) do
    %{
      a
      | state: "claimed",
        lease_owner: fetch_string(p, :lease_owner),
        lease_expires_at: Map.get(p, :lease_expires_at) || Map.get(p, "lease_expires_at"),
        claimed_at: e.occurred_at,
        updated_at: e.occurred_at
    }
  end

  defp apply_event(%Event{type: :started} = e, %Assignment{} = a) do
    %{a | state: "running", updated_at: e.occurred_at}
  end

  defp apply_event(%Event{type: :completed} = e, %Assignment{} = a) do
    %{a | state: "completed", completed_at: e.occurred_at, updated_at: e.occurred_at}
  end

  defp apply_event(%Event{type: :failed, payload: p} = e, %Assignment{} = a) do
    %{
      a
      | state: "failed",
        completed_at: e.occurred_at,
        failure_reason: fetch_string(p, :failure_reason),
        updated_at: e.occurred_at
    }
  end

  defp apply_event(%Event{type: :abandoned, payload: p} = e, %Assignment{} = a) do
    %{
      a
      | state: "abandoned",
        completed_at: e.occurred_at,
        failure_reason: fetch_string(p, :failure_reason),
        updated_at: e.occurred_at
    }
  end

  defp apply_event(%Event{type: :expired, payload: p} = e, %Assignment{} = a) do
    %{
      a
      | state: "expired",
        completed_at: e.occurred_at,
        failure_reason: fetch_string(p, :failure_reason),
        updated_at: e.occurred_at
    }
  end

  defp apply_event(_event, acc), do: acc

  defp fetch_string(map, key) do
    case Map.get(map, key) do
      nil -> Map.get(map, to_string(key))
      value -> value
    end
  end
end
