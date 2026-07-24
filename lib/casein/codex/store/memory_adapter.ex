defmodule Casein.Codex.Store.MemoryAdapter do
  @moduledoc "In-memory Codex operations store used by tests."

  use GenServer
  @behaviour Casein.Codex.Store.Adapter

  alias Casein.Codex.Event
  alias Casein.Codex.Store.Projection

  @max_events 5_000

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @impl true
  def record(%Event{} = event), do: GenServer.call(__MODULE__, {:record, event})

  @impl true
  def latest_sequence(runtime_id),
    do: GenServer.call(__MODULE__, {:latest_sequence, runtime_id})

  @impl true
  def workspace_snapshot(workspace_id, opts),
    do: GenServer.call(__MODULE__, {:workspace_snapshot, workspace_id, opts})

  @impl true
  def timeline(workspace_id, thread_id, opts),
    do: GenServer.call(__MODULE__, {:timeline, workspace_id, thread_id, opts})

  @impl true
  def clear, do: GenServer.call(__MODULE__, :clear)

  @impl true
  def init(_opts), do: {:ok, empty_state()}

  @impl true
  def handle_call({:record, event}, _from, state) do
    thread = Projection.thread(Map.get(state.threads, event.thread_id), event)
    approval_id = payload_value(event.payload, :approval_id)
    approval = Projection.approval(Map.get(state.approvals, approval_id), event)

    state = %{
      state
      | events: [event | state.events] |> Enum.take(@max_events),
        sequences:
          Map.update(state.sequences, event.runtime_id, event.sequence, &max(&1, event.sequence)),
        threads: maybe_put(state.threads, event.thread_id, thread),
        approvals: maybe_put(state.approvals, approval_id, approval)
    }

    {:reply, :ok, state}
  end

  def handle_call({:latest_sequence, runtime_id}, _from, state),
    do: {:reply, Map.get(state.sequences, runtime_id, 0), state}

  def handle_call({:workspace_snapshot, workspace_id, opts}, _from, state) do
    limit = opts |> Keyword.get(:limit, 100) |> clamp_limit()

    threads =
      state.threads
      |> Map.values()
      |> Enum.filter(&(&1.workspace_id == workspace_id))
      |> Enum.sort_by(& &1.last_event_at, {:desc, DateTime})
      |> Enum.take(limit)

    approvals =
      state.approvals
      |> Map.values()
      |> Enum.filter(&(&1.workspace_id == workspace_id))
      |> maybe_pending_only(Keyword.get(opts, :pending_only, false))
      |> Enum.sort_by(& &1.requested_at, {:desc, DateTime})
      |> Enum.take(limit)

    {:reply, %{threads: threads, approvals: approvals}, state}
  end

  def handle_call({:timeline, workspace_id, thread_id, opts}, _from, state) do
    limit = opts |> Keyword.get(:limit, 200) |> clamp_limit()

    events =
      state.events
      |> Enum.filter(&(&1.workspace_id == workspace_id and &1.thread_id == thread_id))
      |> Enum.take(limit)
      |> Enum.reverse()

    {:reply, events, state}
  end

  def handle_call(:clear, _from, _state), do: {:reply, :ok, empty_state()}

  defp empty_state, do: %{events: [], threads: %{}, approvals: %{}, sequences: %{}}

  defp maybe_put(map, key, value) when is_binary(key) and is_map(value),
    do: Map.put(map, key, value)

  defp maybe_put(map, _key, _value), do: map
  defp payload_value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp maybe_pending_only(values, true), do: Enum.filter(values, &(&1.status == "pending"))
  defp maybe_pending_only(values, _false), do: values
  defp clamp_limit(value) when is_integer(value), do: value |> max(1) |> min(1_000)
  defp clamp_limit(_value), do: 100
end
