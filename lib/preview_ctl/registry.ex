defmodule PreviewCtl.Registry do
  @moduledoc """
  ETS-backed registry of live preview control session runtime entries.

  A GenServer owner serializes writes; reads go straight to the `:protected`
  ETS table from any process, keeping concurrent observe/click lookups off the
  GenServer mailbox.
  """
  use GenServer

  # Runtime entries for live preview control sessions. The ETS table is :protected:
  # the GenServer owner serializes all writes (put/update/delete) so updates are
  # race-free, while reads (get) go straight to ETS from any process and skip the
  # GenServer mailbox entirely — important under concurrent agent observe/click.
  @default_table :preview_ctl_sessions

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def put(session_id, entry) when is_integer(session_id) do
    GenServer.call(__MODULE__, {:put, session_id, entry})
  end

  def get(session_id) when is_integer(session_id) do
    lookup(session_id)
  end

  def update(session_id, fun) when is_integer(session_id) and is_function(fun, 1) do
    GenServer.call(__MODULE__, {:update, session_id, fun})
  end

  def delete(session_id) when is_integer(session_id) do
    GenServer.call(__MODULE__, {:delete, session_id})
  end

  def clear, do: GenServer.call(__MODULE__, :clear)

  @impl GenServer
  def init(_) do
    ensure_table!()
    {:ok, %{}}
  end

  @impl GenServer
  def handle_call({:put, session_id, entry}, _from, state) do
    true = :ets.insert(table(), {session_id, entry})
    {:reply, :ok, state}
  end

  def handle_call({:update, session_id, fun}, _from, state) do
    case lookup(session_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      entry ->
        updated = fun.(entry)
        true = :ets.insert(table(), {session_id, updated})
        {:reply, {:ok, updated}, state}
    end
  end

  def handle_call({:delete, session_id}, _from, state) do
    :ets.delete(table(), session_id)
    {:reply, :ok, state}
  end

  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(table())
    {:reply, :ok, state}
  end

  defp lookup(session_id) do
    case :ets.lookup(table(), session_id) do
      [{^session_id, entry}] -> entry
      _ -> nil
    end
  end

  defp ensure_table! do
    case :ets.whereis(table()) do
      :undefined ->
        :ets.new(table(), [:named_table, :protected, :set])

      _ ->
        :ok
    end
  end

  defp table do
    Application.get_env(:preview_ctl, :registry_table, @default_table)
  end
end
