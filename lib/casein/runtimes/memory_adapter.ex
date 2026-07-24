defmodule Casein.Runtimes.MemoryAdapter do
  @moduledoc "In-memory adapter for runtime orchestration records."

  use GenServer

  @behaviour Casein.Runtimes

  alias Casein.Runtimes.{LifecycleEvent, Runtime}

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, %{runtimes: %{}, events: %{}}, name: __MODULE__)
  end

  @impl true
  def create_runtime(%Runtime{} = runtime, %LifecycleEvent{} = event),
    do: GenServer.call(__MODULE__, {:create_runtime, runtime, event})

  @impl true
  def update_runtime(%Runtime{} = runtime, event),
    do: GenServer.call(__MODULE__, {:update_runtime, runtime, event})

  @impl true
  def get_runtime(runtime_id), do: GenServer.call(__MODULE__, {:get_runtime, runtime_id})

  @impl true
  def list_runtimes(filters), do: GenServer.call(__MODULE__, {:list_runtimes, filters})

  @impl true
  def events_for(runtime_id), do: GenServer.call(__MODULE__, {:events_for, runtime_id})

  @impl true
  def clear, do: GenServer.call(__MODULE__, :clear)

  @impl GenServer
  def init(state), do: {:ok, state}

  @impl GenServer
  def handle_call(
        {:create_runtime, %Runtime{} = runtime, %LifecycleEvent{} = event},
        _from,
        state
      ) do
    now = DateTime.utc_now()
    runtime = %{runtime | inserted_at: runtime.inserted_at || now, updated_at: now}

    state =
      state
      |> put_in([:runtimes, runtime.id], runtime)
      |> put_event(event)

    {:reply, {:ok, runtime}, state}
  end

  def handle_call({:update_runtime, %Runtime{} = runtime, event}, _from, state) do
    runtime = %{runtime | updated_at: DateTime.utc_now()}

    state =
      state
      |> put_in([:runtimes, runtime.id], runtime)
      |> maybe_put_event(event)

    {:reply, {:ok, runtime}, state}
  end

  def handle_call({:get_runtime, runtime_id}, _from, state) do
    case Map.fetch(state.runtimes, runtime_id) do
      {:ok, runtime} -> {:reply, {:ok, runtime}, state}
      :error -> {:reply, :error, state}
    end
  end

  def handle_call({:list_runtimes, filters}, _from, state) do
    runtimes =
      state.runtimes
      |> Map.values()
      |> Enum.filter(&matches_filters?(&1, filters || %{}))
      |> Enum.sort_by(& &1.created_at, {:asc, DateTime})

    {:reply, runtimes, state}
  end

  def handle_call({:events_for, runtime_id}, _from, state) do
    events =
      state.events
      |> Map.get(runtime_id, [])
      |> Enum.sort_by(& &1.inserted_at, {:asc, DateTime})

    {:reply, events, state}
  end

  def handle_call(:clear, _from, _state) do
    {:reply, :ok, %{runtimes: %{}, events: %{}}}
  end

  defp maybe_put_event(state, nil), do: state
  defp maybe_put_event(state, %LifecycleEvent{} = event), do: put_event(state, event)

  defp put_event(state, %LifecycleEvent{} = event) do
    update_in(state, [:events, event.runtime_id], &[event | &1 || []])
  end

  defp matches_filters?(%Runtime{} = runtime, filters) do
    Enum.all?(filters, fn
      {"workspace_id", value} -> runtime.workspace_id == value
      {"host_id", value} -> runtime.host_id == value
      {"host", value} -> runtime.host_id == value
      {"status", value} -> runtime.status == value
      {"repo", value} -> runtime.repo == value
      {"branch", value} -> runtime.branch == value
      {"isolation_mode", value} -> runtime.isolation_mode == value
      {"branch_isolation", value} -> runtime.isolation_mode == value
      {"runtime_id", value} -> runtime.id == value
      {"id", value} -> runtime.id == value
      _ -> true
    end)
  end
end
