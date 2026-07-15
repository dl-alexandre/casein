defmodule DevIDE.Codex.EventRouter do
  @moduledoc """
  Runtime-local fanout and lightweight projection for canonical Codex events.

  The router owns the monotonically increasing runtime sequence, so ordering
  survives an App Server Port restart. Streaming deltas are broadcast but are
  intentionally excluded from the retained projection.
  """

  use GenServer

  alias DevIDE.Codex.Event

  @type server :: GenServer.server()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    case Keyword.get(opts, :name) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  def child_spec(opts) do
    runtime_id = Keyword.fetch!(opts, :runtime_id)

    %{
      id: {__MODULE__, runtime_id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      type: :worker
    }
  end

  @spec subscribe(server(), pid()) :: :ok
  def subscribe(server, subscriber \\ self()) when is_pid(subscriber) do
    GenServer.call(server, {:subscribe, subscriber})
  end

  @spec publish(server(), Event.t()) :: {:ok, Event.t()} | {:error, :runtime_mismatch}
  def publish(server, %Event{} = event), do: GenServer.call(server, {:publish, event})

  @spec runtime_status(server(), String.t(), atom(), map()) :: :ok
  def runtime_status(server, runtime_id, status, metadata) when is_map(metadata) do
    GenServer.cast(server, {:runtime_status, runtime_id, status, metadata})
  end

  @spec snapshot(server()) :: map()
  def snapshot(server), do: GenServer.call(server, :snapshot)

  @impl true
  def init(opts) do
    state = %{
      workspace_id: Keyword.fetch!(opts, :workspace_id),
      runtime_id: Keyword.fetch!(opts, :runtime_id),
      sequence: 0,
      runtime_status: :starting,
      runtime_metadata: %{},
      subscribers: %{},
      threads: %{},
      turns: %{},
      approvals: %{}
    }

    state =
      opts
      |> Keyword.get(:subscriber)
      |> List.wrap()
      |> Enum.filter(&is_pid/1)
      |> Enum.reduce(state, &put_subscriber(&2, &1))

    {:ok, state}
  end

  @impl true
  def handle_call({:subscribe, subscriber}, _from, state) do
    state = put_subscriber(state, subscriber)
    send_runtime_status(subscriber, state)
    {:reply, :ok, state}
  end

  def handle_call({:publish, event}, _from, state) do
    if event.workspace_id == state.workspace_id and event.runtime_id == state.runtime_id do
      event = Event.resequence(event, state.sequence + 1)
      state = project(%{state | sequence: event.sequence}, event)
      Enum.each(Map.keys(state.subscribers), &send(&1, {:codex_event, event}))
      {:reply, {:ok, event}, state}
    else
      {:reply, {:error, :runtime_mismatch}, state}
    end
  end

  def handle_call(:snapshot, _from, state) do
    snapshot = %{
      workspace_id: state.workspace_id,
      runtime_id: state.runtime_id,
      sequence: state.sequence,
      runtime_status: state.runtime_status,
      runtime_metadata: state.runtime_metadata,
      threads: state.threads,
      turns: state.turns,
      approvals: state.approvals
    }

    {:reply, snapshot, state}
  end

  @impl true
  def handle_cast({:runtime_status, runtime_id, status, metadata}, state) do
    state = %{state | runtime_status: status, runtime_metadata: metadata}

    Enum.each(
      Map.keys(state.subscribers),
      &send(
        &1,
        {:codex_app_server_status, runtime_id, status,
         %{workspace_id: state.workspace_id, metadata: metadata}}
      )
    )

    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    subscribers =
      case Map.get(state.subscribers, pid) do
        ^ref -> Map.delete(state.subscribers, pid)
        _other -> state.subscribers
      end

    {:noreply, %{state | subscribers: subscribers}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp project(state, %Event{type: :thread_started, thread_id: thread_id} = event) do
    put_in(state.threads[thread_id], event)
  end

  defp project(state, %Event{type: :thread_status_changed, thread_id: thread_id} = event) do
    put_in(state.threads[thread_id], event)
  end

  defp project(state, %Event{type: type, turn_id: turn_id} = event)
       when type in [:turn_started, :turn_completed] do
    put_in(state.turns[turn_id], event)
  end

  defp project(state, %Event{type: type, payload: %{approval_id: approval_id}} = event)
       when type in [:approval_requested, :approval_resolved] do
    put_in(state.approvals[approval_id], event)
  end

  defp project(state, _event), do: state

  defp put_subscriber(state, subscriber) do
    if Map.has_key?(state.subscribers, subscriber) do
      state
    else
      %{state | subscribers: Map.put(state.subscribers, subscriber, Process.monitor(subscriber))}
    end
  end

  defp send_runtime_status(subscriber, state) do
    send(
      subscriber,
      {:codex_app_server_status, state.runtime_id, state.runtime_status,
       %{workspace_id: state.workspace_id, metadata: state.runtime_metadata}}
    )
  end
end
