defmodule DevIDE.Assignments.EventStore.MemoryAdapter do
  @moduledoc "In-memory append-only event store for assignments."

  use GenServer

  @behaviour DevIDE.Assignments.EventStore

  alias DevIDE.Assignments.Event

  ## API

  def start_link(_opts \\ []),
    do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @impl DevIDE.Assignments.EventStore
  def append(%Event{} = event),
    do: GenServer.call(__MODULE__, {:append, event})

  @impl DevIDE.Assignments.EventStore
  def events_for(assignment_id),
    do: GenServer.call(__MODULE__, {:events_for, assignment_id})

  @impl DevIDE.Assignments.EventStore
  def list_events(_opts \\ []), do: GenServer.call(__MODULE__, :list_all)

  @impl DevIDE.Assignments.EventStore
  def distinct_assignment_ids, do: GenServer.call(__MODULE__, :distinct_assignment_ids)

  @impl DevIDE.Assignments.EventStore
  def clear, do: GenServer.call(__MODULE__, :clear)

  ## Callbacks

  @impl GenServer
  def init(_), do: {:ok, %{streams: %{}}}

  @impl GenServer
  def handle_call({:append, %Event{} = event}, _from, state) do
    existing = Map.get(state.streams, event.assignment_id, [])
    max_seq = existing |> Enum.map(& &1.sequence) |> Enum.max(fn -> 0 end)
    event = %{event | sequence: max_seq + 1}
    updated = [event | existing]

    {:reply, {:ok, event}, put_in(state, [:streams, event.assignment_id], updated)}
  end

  def handle_call({:events_for, id}, _from, state) do
    events =
      state.streams
      |> Map.get(id, [])
      |> Enum.sort_by(& &1.sequence)

    {:reply, events, state}
  end

  def handle_call(:list_all, _from, state) do
    events =
      state.streams
      |> Map.values()
      |> Enum.flat_map(& &1)
      |> Enum.sort_by(&{&1.assignment_id, &1.sequence})

    {:reply, events, state}
  end

  def handle_call(:distinct_assignment_ids, _from, state) do
    {:reply, Map.keys(state.streams), state}
  end

  def handle_call(:clear, _from, _state), do: {:reply, :ok, %{streams: %{}}}
end
