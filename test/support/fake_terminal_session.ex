defmodule DevIDE.Test.FakeTerminalSession do
  @moduledoc false

  use GenServer

  def ensure_started(workspace, sid, {:fake, owner}) when is_pid(owner) do
    GenServer.start_link(__MODULE__, {workspace, sid, owner})
  end

  def subscribe(pid), do: GenServer.call(pid, {:subscribe, self()})

  def unsubscribe(pid), do: GenServer.call(pid, {:unsubscribe, self()})

  def send_input(pid, data) when is_binary(data), do: GenServer.cast(pid, {:input, data})

  def resize(pid, cols, rows), do: GenServer.cast(pid, {:resize, cols, rows})

  def seed_buffer(pid, data) when is_binary(data), do: GenServer.call(pid, {:seed_buffer, data})

  @impl true
  def init({workspace, sid, owner}) do
    {:ok,
     %{
       workspace: workspace,
       sid: sid,
       owner: owner,
       ref: make_ref(),
       subscribers: %{},
       buffer: <<>>,
       cols: 120,
       rows: 40
     }}
  end

  @impl true
  def handle_call({:subscribe, subscriber}, _from, state) do
    send(state.owner, {:fake_session_subscribed, self(), subscriber, state.workspace, state.sid})

    {:reply, {:ok, state.ref, state.cols, state.rows},
     put_in(state.subscribers[subscriber], true)}
  end

  def handle_call({:unsubscribe, subscriber}, _from, state) do
    send(state.owner, {:fake_session_unsubscribed, self(), subscriber})
    {:reply, :ok, update_in(state.subscribers, &Map.delete(&1, subscriber))}
  end

  def handle_call(:snapshot, _from, state), do: {:reply, state.buffer, state}

  def handle_call({:seed_buffer, data}, _from, state), do: {:reply, :ok, %{state | buffer: data}}

  @impl true
  def handle_cast({:input, data}, state) do
    send(state.owner, {:fake_session_input, self(), data})

    for {subscriber, true} <- state.subscribers do
      send(subscriber, {:term_data, state.ref, data})
    end

    {:noreply, state}
  end

  def handle_cast({:resize, cols, rows}, state) do
    send(state.owner, {:fake_session_resize, self(), cols, rows})
    {:noreply, %{state | cols: cols, rows: rows}}
  end
end
