defmodule DevIDE.Workspaces.State.MemoryAdapter do
  @moduledoc "In-memory adapter for `DevIDE.Workspaces.State`. Used by tests and dev fallback."
  use GenServer
  @behaviour DevIDE.Workspaces.State

  alias DevIDE.Workspaces.State.WorkspaceRecord

  ## API

  def start_link(_opts \\ []),
    do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @impl DevIDE.Workspaces.State
  def upsert(%WorkspaceRecord{} = r), do: GenServer.call(__MODULE__, {:upsert, r})

  @impl DevIDE.Workspaces.State
  def get(external_id), do: GenServer.call(__MODULE__, {:get, external_id})

  @impl DevIDE.Workspaces.State
  def list, do: GenServer.call(__MODULE__, :list)

  @impl DevIDE.Workspaces.State
  def delete(external_id), do: GenServer.call(__MODULE__, {:delete, external_id})

  def clear, do: GenServer.call(__MODULE__, :clear)

  ## Callbacks

  @impl GenServer
  def init(_), do: {:ok, %{}}

  @impl GenServer
  def handle_call({:upsert, %WorkspaceRecord{external_id: ext} = r}, _from, state) do
    now = DateTime.utc_now()
    existing = Map.get(state, ext)

    record = %{
      r
      | id: r.id || (existing && existing.id) || Ecto.UUID.generate(),
        inserted_at: (existing && existing.inserted_at) || r.inserted_at || now,
        updated_at: now
    }

    {:reply, {:ok, record}, Map.put(state, ext, record)}
  end

  def handle_call({:get, ext}, _from, state) do
    case Map.fetch(state, ext) do
      {:ok, record} -> {:reply, {:ok, record}, state}
      :error -> {:reply, :error, state}
    end
  end

  def handle_call(:list, _from, state), do: {:reply, Map.values(state), state}

  def handle_call({:delete, ext}, _from, state),
    do: {:reply, :ok, Map.delete(state, ext)}

  def handle_call(:clear, _from, _state), do: {:reply, :ok, %{}}
end
