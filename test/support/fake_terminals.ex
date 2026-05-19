defmodule DevIDE.Test.FakeTerminals do
  @moduledoc false

  use GenServer

  def new_shell(workspace_id, sid) do
    %{kind: :shell, workspace_id: workspace_id, sid: sid}
  end

  def owner_attach(workspace_id, info, opts) do
    owner = Keyword.fetch!(opts, :test_owner)

    with {:ok, pid} <- GenServer.start_link(__MODULE__, {owner, workspace_id, info, opts}) do
      GenServer.call(pid, {:attach, self()})
    end
  end

  def owner_input(owner_pid, data), do: GenServer.cast(owner_pid, {:input, data})

  def owner_resize(owner_pid, cols, rows), do: GenServer.cast(owner_pid, {:resize, cols, rows})

  def owner_detach(owner_pid, subscriber), do: GenServer.call(owner_pid, {:detach, subscriber})

  @impl true
  def init({owner, workspace_id, info, opts}) do
    {:ok,
     %{
       owner: owner,
       workspace_id: workspace_id,
       info: info,
       opts: opts,
       subscribers: MapSet.new()
     }}
  end

  @impl true
  def handle_call({:attach, subscriber}, _from, state) do
    send(
      state.owner,
      {:fake_owner_attached, self(), subscriber, state.workspace_id, state.info, state.opts}
    )

    payload = %{
      mode: "raw",
      cols: 120,
      rows: 40,
      resumable: true,
      session_id: state.info.sid
    }

    {:reply, {:ok, self(), payload},
     %{state | subscribers: MapSet.put(state.subscribers, subscriber)}}
  end

  def handle_call({:detach, subscriber}, _from, state) do
    send(state.owner, {:fake_owner_detached, self(), subscriber})
    {:reply, :ok, %{state | subscribers: MapSet.delete(state.subscribers, subscriber)}}
  end

  @impl true
  def handle_cast({:input, data}, state) do
    send(state.owner, {:fake_owner_input, self(), data})

    for subscriber <- state.subscribers do
      send(subscriber, {:terminal_payload, :data, %{data: data}})
    end

    {:noreply, state}
  end

  def handle_cast({:resize, cols, rows}, state) do
    send(state.owner, {:fake_owner_resize, self(), cols, rows})
    {:noreply, state}
  end
end
