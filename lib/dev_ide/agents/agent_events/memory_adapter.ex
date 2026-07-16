defmodule DevIDE.Agents.AgentEvents.MemoryAdapter do
  @moduledoc false

  use GenServer

  @behaviour DevIDE.Agents.AgentEvents.Adapter

  alias DevIDE.Agents.AgentEvent

  @max_events 10_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, empty_state(), Keyword.put_new(opts, :name, __MODULE__))
  end

  @impl true
  def record(attrs), do: GenServer.call(__MODULE__, {:record, attrs})

  @impl true
  def recent_for(workspace_id, opts) do
    GenServer.call(__MODULE__, {:recent_for, workspace_id, Keyword.fetch!(opts, :limit)})
  end

  @impl true
  def replay(workspace_id, after_at, after_id, opts) do
    GenServer.call(
      __MODULE__,
      {:replay, workspace_id, after_at, after_id, Keyword.fetch!(opts, :limit)}
    )
  end

  @impl true
  def list_for_session(workspace_id, agent_session_id, opts) do
    GenServer.call(
      __MODULE__,
      {:list_for_session, workspace_id, agent_session_id, Keyword.fetch!(opts, :limit)}
    )
  end

  @impl true
  def list_by_correlation(correlation_id, opts) do
    GenServer.call(
      __MODULE__,
      {:list_by_correlation, correlation_id, Keyword.fetch!(opts, :limit)}
    )
  end

  @impl true
  def clear, do: GenServer.call(__MODULE__, :clear)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:record, attrs}, _from, state) do
    case duplicate(state, attrs) do
      %AgentEvent{} = event ->
        {:reply, {:ok, event, :duplicate}, state}

      nil ->
        case Ecto.Changeset.apply_action(AgentEvent.changeset(%AgentEvent{}, attrs), :insert) do
          {:ok, event} ->
            event = ensure_id(event)
            state = put_event(state, event)
            {:reply, {:ok, event, :inserted}, state}

          {:error, _changeset} = error ->
            {:reply, error, state}
        end
    end
  end

  def handle_call({:recent_for, workspace_id, limit}, _from, state) do
    events = select(state, &(&1.workspace_id == workspace_id), limit, :desc)
    {:reply, events, state}
  end

  def handle_call({:replay, workspace_id, after_at, after_id, limit}, _from, state) do
    events =
      state.events
      |> Map.values()
      |> Enum.filter(&(&1.workspace_id == workspace_id))
      |> Enum.sort_by(&{&1.inserted_at, &1.id}, :asc)
      |> Enum.filter(&after_cursor?(&1, after_at, after_id))
      |> Enum.take(limit)

    {:reply, events, state}
  end

  def handle_call(
        {:list_for_session, workspace_id, agent_session_id, limit},
        _from,
        state
      ) do
    events =
      select(
        state,
        &(&1.workspace_id == workspace_id and &1.agent_session_id == agent_session_id),
        limit,
        :desc
      )

    {:reply, events, state}
  end

  def handle_call({:list_by_correlation, correlation_id, limit}, _from, state) do
    events = select(state, &(&1.correlation_id == correlation_id), limit, :asc)
    {:reply, events, state}
  end

  def handle_call(:clear, _from, _state), do: {:reply, :ok, empty_state()}

  defp duplicate(state, %{source_event_id: source_event_id} = attrs)
       when is_binary(source_event_id) and source_event_id != "" do
    with id when is_binary(id) <-
           Map.get(state.dedupe, {attrs.workspace_id, attrs.stream_id, source_event_id}) do
      Map.get(state.events, id)
    end
  end

  defp duplicate(_state, _attrs), do: nil

  defp ensure_id(%AgentEvent{id: nil} = event), do: %{event | id: Ecto.UUID.generate()}
  defp ensure_id(event), do: event

  defp put_event(state, event) do
    order = [event.id | state.order] |> Enum.take(@max_events)
    keep = MapSet.new(order)
    events = state.events |> Map.put(event.id, event) |> Map.filter(fn {id, _} -> id in keep end)

    dedupe =
      events
      |> Map.values()
      |> Enum.reduce(%{}, fn
        %{source_event_id: source_event_id} = item, index when is_binary(source_event_id) ->
          Map.put(index, {item.workspace_id, item.stream_id, source_event_id}, item.id)

        _item, index ->
          index
      end)

    %{events: events, order: order, dedupe: dedupe}
  end

  defp select(state, predicate, limit, direction) do
    state.events
    |> Map.values()
    |> Enum.filter(predicate)
    |> Enum.sort_by(&sort_key/1, direction)
    |> Enum.take(limit)
  end

  defp sort_key(event), do: {event.occurred_at, event.inserted_at, event.id}

  defp after_cursor?(event, %DateTime{} = after_at, after_id) when is_binary(after_id) do
    DateTime.compare(event.inserted_at, after_at) == :gt or
      (DateTime.compare(event.inserted_at, after_at) == :eq and event.id > after_id)
  end

  defp after_cursor?(_event, _after_at, _after_id), do: true

  defp empty_state, do: %{events: %{}, order: [], dedupe: %{}}
end
