defmodule Casein.Agents.JidoPod.Fleet do
  @moduledoc """
  Fleet-wide admission and fairness for headless Jido workers.

  Per-workspace caps live on the pod. This process only tracks running leases
  and wakes the waiting workspace with the fewest running workers.
  """

  use GenServer

  @default_max_running 8

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec try_acquire(String.t()) :: :ok | {:error, :fleet_limit}
  def try_acquire(workspace_id) when is_binary(workspace_id) do
    GenServer.call(__MODULE__, {:try_acquire, workspace_id})
  end

  @spec release(String.t()) :: :ok
  def release(workspace_id) when is_binary(workspace_id) do
    GenServer.call(__MODULE__, {:release, workspace_id})
  end

  @spec register_waiter(String.t(), pid()) :: :ok
  def register_waiter(workspace_id, pid \\ self())
      when is_binary(workspace_id) and is_pid(pid) do
    GenServer.cast(__MODULE__, {:register_waiter, workspace_id, pid})
  end

  @spec unregister_waiter(String.t()) :: :ok
  def unregister_waiter(workspace_id) when is_binary(workspace_id) do
    GenServer.cast(__MODULE__, {:unregister_waiter, workspace_id})
  end

  @spec snapshot() :: map()
  def snapshot do
    GenServer.call(__MODULE__, :snapshot)
  end

  @spec reset() :: :ok
  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  @impl true
  def init(_opts) do
    {:ok, empty_state()}
  end

  @impl true
  def handle_call({:try_acquire, workspace_id}, _from, state) do
    running = fleet_running(state)

    mine = Map.get(state.running, workspace_id, 0)

    cond do
      running >= max_running() ->
        {:reply, {:error, :fleet_limit}, state}

      fairer_waiter?(state, workspace_id, mine) ->
        {:reply, {:error, :fairness}, state}

      true ->
        {:reply, :ok, bump(state, workspace_id, 1)}
    end
  end

  def handle_call({:release, workspace_id}, _from, state) do
    state = bump(state, workspace_id, -1)
    {:reply, :ok, notify_next(state)}
  end

  def handle_call(:snapshot, _from, state) do
    {:reply,
     %{
       running: Map.new(state.running),
       fleet_running: fleet_running(state),
       waiters: Map.keys(state.waiters),
       max_running: max_running()
     }, state}
  end

  def handle_call(:reset, _from, _state) do
    {:reply, :ok, empty_state()}
  end

  @impl true
  def handle_cast({:register_waiter, workspace_id, pid}, state) do
    state = drop_waiter(state, workspace_id)
    ref = Process.monitor(pid)
    {:noreply, %{state | waiters: Map.put(state.waiters, workspace_id, {pid, ref})}}
  end

  def handle_cast({:unregister_waiter, workspace_id}, state) do
    {:noreply, drop_waiter(state, workspace_id)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    waiters =
      state.waiters
      |> Enum.reject(fn {_ws, {_pid, waiter_ref}} -> waiter_ref == ref end)
      |> Map.new()

    {:noreply, %{state | waiters: waiters}}
  end

  defp fairer_waiter?(state, workspace_id, mine) do
    Enum.any?(state.waiters, fn {other, _} ->
      other != workspace_id and Map.get(state.running, other, 0) < mine
    end)
  end

  defp notify_next(state) do
    case next_waiter(state) do
      nil ->
        state

      {workspace_id, {pid, _ref}} ->
        send(pid, :jido_fleet_available)
        drop_waiter(state, workspace_id)
    end
  end

  defp next_waiter(%{waiters: waiters}) when map_size(waiters) == 0, do: nil

  defp next_waiter(state) do
    state.waiters
    |> Enum.min_by(fn {workspace_id, _} -> Map.get(state.running, workspace_id, 0) end)
  end

  defp bump(state, workspace_id, delta) do
    current = Map.get(state.running, workspace_id, 0)
    next = max(current + delta, 0)

    running =
      if next == 0,
        do: Map.delete(state.running, workspace_id),
        else: Map.put(state.running, workspace_id, next)

    %{state | running: running}
  end

  defp drop_waiter(state, workspace_id) do
    case Map.pop(state.waiters, workspace_id) do
      {nil, _} ->
        state

      {{_pid, ref}, waiters} ->
        Process.demonitor(ref, [:flush])
        %{state | waiters: waiters}
    end
  end

  defp fleet_running(state), do: state.running |> Map.values() |> Enum.sum()

  defp empty_state, do: %{running: %{}, waiters: %{}}

  defp max_running do
    config() |> Keyword.get(:max_running_fleet, @default_max_running)
  end

  defp config do
    Application.get_env(:casein, :jido_pod, [])
  end
end
