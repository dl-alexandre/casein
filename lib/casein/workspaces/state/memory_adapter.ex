defmodule Casein.Workspaces.State.MemoryAdapter do
  @moduledoc "In-memory adapter for `Casein.Workspaces.State`. Used by tests and dev fallback."
  use GenServer
  @behaviour Casein.Workspaces.State.Adapter

  alias Casein.Workspaces.State.WorkspaceRecord

  ## API

  def start_link(_opts \\ []),
    do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @impl Casein.Workspaces.State.Adapter
  def upsert(%WorkspaceRecord{} = r), do: GenServer.call(__MODULE__, {:upsert, r})

  @impl Casein.Workspaces.State.Adapter
  def upsert_all(records) when is_list(records),
    do: GenServer.call(__MODULE__, {:upsert_all, records})

  @impl Casein.Workspaces.State.Adapter
  def get(external_id), do: GenServer.call(__MODULE__, {:get, external_id})

  @impl Casein.Workspaces.State.Adapter
  def get_many(external_ids) when is_list(external_ids),
    do: GenServer.call(__MODULE__, {:get_many, external_ids})

  @impl Casein.Workspaces.State.Adapter
  def records_for_host_paths(host_paths) when is_list(host_paths),
    do: GenServer.call(__MODULE__, {:records_for_host_paths, host_paths})

  @impl Casein.Workspaces.State.Adapter
  def list, do: GenServer.call(__MODULE__, :list)

  @impl Casein.Workspaces.State.Adapter
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

  def handle_call({:upsert_all, records}, _from, state) do
    now = DateTime.utc_now()

    {new_state, out} =
      Enum.reduce(records, {state, []}, fn %WorkspaceRecord{external_id: ext} = r, {st, acc} ->
        existing = Map.get(st, ext)

        record = %{
          r
          | id: r.id || (existing && existing.id) || Ecto.UUID.generate(),
            inserted_at: (existing && existing.inserted_at) || r.inserted_at || now,
            updated_at: now
        }

        {Map.put(st, ext, record), [record | acc]}
      end)

    {:reply, {:ok, Enum.reverse(out)}, new_state}
  end

  def handle_call({:get, ext}, _from, state) do
    case Map.fetch(state, ext) do
      {:ok, record} -> {:reply, {:ok, record}, state}
      :error -> {:reply, :error, state}
    end
  end

  def handle_call({:get_many, ids}, _from, state) do
    {:reply, Map.take(state, ids), state}
  end

  def handle_call({:records_for_host_paths, host_paths}, _from, state) do
    result =
      state
      |> Map.values()
      |> Enum.filter(&(&1.host_path in host_paths))
      |> Enum.group_by(& &1.host_path)
      |> Map.new(fn {path, records} -> {path, WorkspaceRecord.preferred(records)} end)

    {:reply, result, state}
  end

  def handle_call(:list, _from, state), do: {:reply, Map.values(state), state}

  def handle_call({:delete, ext}, _from, state),
    do: {:reply, :ok, Map.delete(state, ext)}

  def handle_call(:clear, _from, _state), do: {:reply, :ok, %{}}
end
