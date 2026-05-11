defmodule DevIDE.Audit.MemoryAdapter do
  @moduledoc """
  Capped in-memory audit ring. Swap with an Ecto-backed adapter in M11.
  """

  use GenServer
  @behaviour DevIDE.Audit

  alias DevIDE.Audit.Event

  @max 1_000

  ## API

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl DevIDE.Audit
  def record(%Event{} = e) do
    GenServer.cast(__MODULE__, {:record, e})
    :ok
  end

  @impl DevIDE.Audit
  def list(opts \\ []) do
    n = Keyword.get(opts, :limit, @max)
    GenServer.call(__MODULE__, {:list, n})
  end

  @impl DevIDE.Audit
  def recent_for(workspace_id, n) do
    GenServer.call(__MODULE__, {:recent_for, workspace_id, n})
  end

  @impl DevIDE.Audit
  def clear, do: GenServer.call(__MODULE__, :clear)

  ## Callbacks

  @impl GenServer
  def init([]), do: {:ok, %{events: []}}

  @impl GenServer
  def handle_cast({:record, event}, state) do
    events = [event | state.events] |> Enum.take(@max)
    {:noreply, %{state | events: events}}
  end

  @impl GenServer
  def handle_call({:list, n}, _from, state),
    do: {:reply, Enum.take(state.events, n), state}

  def handle_call({:recent_for, ws_id, n}, _from, state) do
    matches = Enum.filter(state.events, &(&1.workspace_id == ws_id)) |> Enum.take(n)
    {:reply, matches, state}
  end

  def handle_call(:clear, _from, state), do: {:reply, :ok, %{state | events: []}}
end
