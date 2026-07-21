defmodule TmuxCtl.Test.FakeEventSource do
  @moduledoc """
  Per-test push-event source for `TmuxCtl.EventSource` consumers.

  Message-passing only (no app-env), so it is safe for `async: true` tests —
  unlike `TmuxCtl.Test.FakeState`.

      {:ok, fake} = start_supervised(TmuxCtl.Test.FakeEventSource)
      {:ok, %{listener: ^fake, connected?: true}} =
        TmuxCtl.Test.FakeEventSource.subscribe(fake, self())

      TmuxCtl.Test.FakeEventSource.emit(fake, %{type: :window_add, ...})
      TmuxCtl.Test.FakeEventSource.set_connected(fake, false)
  """

  use GenServer

  @behaviour TmuxCtl.EventSource

  @type event :: map()

  @doc "Start a fresh fake event source for one test."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc false
  def child_spec(opts) do
    %{
      id: {__MODULE__, make_ref()},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  @impl TmuxCtl.EventSource
  def subscribe(pid, subscriber) when is_pid(pid) and is_pid(subscriber) do
    GenServer.call(pid, {:subscribe, subscriber})
  end

  def subscribe(_arg, _subscriber), do: {:error, :unavailable}

  @doc "Push a tmux event map to every registered subscriber."
  @spec emit(pid(), event()) :: :ok
  def emit(pid, event) when is_pid(pid) and is_map(event) do
    GenServer.cast(pid, {:emit, event})
  end

  @doc """
  Flip the fake listener connected flag and notify subscribers with
  `{:listener_up, label}` / `{:listener_down, label}`.
  """
  @spec set_connected(pid(), boolean()) :: :ok
  def set_connected(pid, connected?) when is_pid(pid) and is_boolean(connected?) do
    GenServer.cast(pid, {:set_connected, connected?})
  end

  @doc "Return current fake status (for assertions)."
  @spec status(pid()) :: map()
  def status(pid) when is_pid(pid), do: GenServer.call(pid, :status)

  @impl true
  def init(opts) do
    {:ok,
     %{
       label: Keyword.get(opts, :label, "test"),
       connected?: Keyword.get(opts, :connected?, true),
       subscribers: MapSet.new()
     }}
  end

  @impl true
  def handle_call({:subscribe, subscriber}, _from, state) do
    Process.monitor(subscriber)
    state = %{state | subscribers: MapSet.put(state.subscribers, subscriber)}

    {:reply, {:ok, %{listener: self(), connected?: state.connected?}}, state}
  end

  def handle_call(:status, _from, state) do
    {:reply,
     %{
       connected?: state.connected?,
       label: state.label,
       subscriber_count: MapSet.size(state.subscribers)
     }, state}
  end

  @impl true
  def handle_cast({:emit, event}, state) do
    broadcast(state, {TmuxCtl.Events, {:tmux_event, event}})
    {:noreply, state}
  end

  def handle_cast({:set_connected, connected?}, state) do
    state = %{state | connected?: connected?}
    kind = if connected?, do: :listener_up, else: :listener_down
    broadcast(state, {TmuxCtl.Events, {kind, state.label}})
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | subscribers: MapSet.delete(state.subscribers, pid)}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp broadcast(state, message) do
    Enum.each(state.subscribers, &send(&1, message))
  end
end
