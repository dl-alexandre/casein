defmodule DevIDE.Audit.MemoryAdapter do
  @moduledoc """
  Capped in-memory audit ring. Mainly used in test environments.
  """

  use GenServer
  @behaviour DevIDE.Audit.Adapter

  alias DevIDE.Audit.Event

  @max 1_000

  ## API

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl DevIDE.Audit.Adapter
  def record(%Event{} = e) do
    GenServer.cast(__MODULE__, {:record, e})
    :ok
  end

  @impl DevIDE.Audit.Adapter
  def list(opts \\ []) do
    n = Keyword.get(opts, :limit, @max)
    GenServer.call(__MODULE__, {:list, n})
  end

  @impl DevIDE.Audit.Adapter
  def recent_for(workspace_id, n) do
    GenServer.call(__MODULE__, {:recent_for, workspace_id, n})
  end

  @impl DevIDE.Audit.Adapter
  def recent_with_action_prefix(workspace_id, action_prefix, n) do
    GenServer.call(__MODULE__, {:recent_with_action_prefix, workspace_id, action_prefix, n})
  end

  @impl DevIDE.Audit.Adapter
  def recent_for_tool(workspace_id, tool, n) do
    GenServer.call(__MODULE__, {:recent_for_tool, workspace_id, tool, n})
  end

  @impl DevIDE.Audit.Adapter
  def list_by_correlation(correlation_id) do
    GenServer.call(__MODULE__, {:list_by_correlation, correlation_id})
  end

  @impl DevIDE.Audit.Adapter
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

  def handle_call({:recent_with_action_prefix, ws_id, prefix, n}, _from, state) do
    matches =
      state.events
      |> Enum.filter(fn e ->
        e.workspace_id == ws_id and is_binary(e.action) and String.starts_with?(e.action, prefix)
      end)
      |> Enum.take(n)

    {:reply, matches, state}
  end

  def handle_call({:recent_for_tool, ws_id, tool, n}, _from, state) do
    matches =
      state.events
      |> Enum.filter(&(&1.workspace_id == ws_id and &1.tool == tool))
      |> Enum.take(n)

    {:reply, matches, state}
  end

  def handle_call({:list_by_correlation, correlation_id}, _from, state) do
    # Events are stored newest-first; the chain reads oldest-first.
    matches =
      state.events
      |> Enum.filter(&(is_map(&1.metadata) and &1.metadata["correlation_id"] == correlation_id))
      |> Enum.reverse()

    {:reply, matches, state}
  end

  def handle_call(:clear, _from, state), do: {:reply, :ok, %{state | events: []}}
end
