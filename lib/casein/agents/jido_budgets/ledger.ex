defmodule Casein.Agents.JidoBudgets.Ledger do
  @moduledoc """
  In-memory budget ledger. Stores sizes, counts, and reasons only — never
  prompts, source, secrets, or action output.
  """

  use GenServer

  alias Casein.Agents.JidoBudgets.Limits

  @max_admission_samples 64
  @max_crashes 128
  @max_decisions 32

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec reset() :: :ok
  def reset, do: GenServer.call(__MODULE__, :reset)

  @spec snapshot() :: map()
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)

  @spec last_decision(String.t()) :: map() | nil
  def last_decision(workspace_id) when is_binary(workspace_id) do
    GenServer.call(__MODULE__, {:last_decision, workspace_id})
  end

  @spec record_decision(String.t(), :admit | :queue | :reject | :drain, atom(), map()) :: :ok
  def record_decision(workspace_id, action, reason, extra \\ %{})
      when is_binary(workspace_id) and action in [:admit, :queue, :reject, :drain] and
             is_atom(reason) do
    GenServer.cast(__MODULE__, {:decision, workspace_id, action, reason, extra})
  end

  @spec try_provider(String.t()) :: :ok | {:error, :provider_limit}
  def try_provider(attempt_id) when is_binary(attempt_id) do
    GenServer.call(__MODULE__, {:try_provider, attempt_id})
  end

  @spec release_provider(String.t()) :: :ok
  def release_provider(attempt_id) when is_binary(attempt_id) do
    GenServer.call(__MODULE__, {:release_provider, attempt_id})
  end

  @spec charge_memory(String.t(), String.t(), non_neg_integer()) ::
          :ok | {:error, :memory_limit}
  def charge_memory(workspace_id, attempt_id, bytes)
      when is_binary(workspace_id) and is_binary(attempt_id) and is_integer(bytes) and bytes >= 0 do
    GenServer.call(__MODULE__, {:charge_memory, workspace_id, attempt_id, bytes})
  end

  @spec release_memory(String.t()) :: :ok
  def release_memory(attempt_id) when is_binary(attempt_id) do
    GenServer.call(__MODULE__, {:release_memory, attempt_id})
  end

  @spec acquire_lease(String.t(), String.t()) :: :ok
  def acquire_lease(workspace_id, attempt_id)
      when is_binary(workspace_id) and is_binary(attempt_id) do
    GenServer.call(__MODULE__, {:acquire_lease, workspace_id, attempt_id})
  end

  @spec release_lease(String.t()) :: :ok
  def release_lease(attempt_id) when is_binary(attempt_id) do
    GenServer.call(__MODULE__, {:release_lease, attempt_id})
  end

  @spec crash(String.t()) :: :ok
  def crash(workspace_id) when is_binary(workspace_id) do
    GenServer.cast(__MODULE__, {:crash, workspace_id})
  end

  @spec record_admission(non_neg_integer()) :: :ok
  def record_admission(latency_ms) when is_integer(latency_ms) and latency_ms >= 0 do
    GenServer.cast(__MODULE__, {:admission, latency_ms})
  end

  @spec sample_host(map()) :: :ok
  def sample_host(sample) when is_map(sample) do
    GenServer.cast(__MODULE__, {:sample_host, sample})
  end

  @impl true
  def init(_opts), do: {:ok, empty()}

  @impl true
  def handle_call(:reset, _from, _state), do: {:reply, :ok, empty()}

  def handle_call(:snapshot, _from, state) do
    {:reply, public_snapshot(state), state}
  end

  def handle_call({:last_decision, workspace_id}, _from, state) do
    {:reply, Map.get(state.decisions, workspace_id), state}
  end

  def handle_call({:try_provider, attempt_id}, _from, state) do
    cond do
      MapSet.member?(state.providers, attempt_id) ->
        {:reply, :ok, state}

      MapSet.size(state.providers) >= Limits.get(:max_provider_inflight) ->
        {:reply, {:error, :provider_limit}, state}

      true ->
        {:reply, :ok, %{state | providers: MapSet.put(state.providers, attempt_id)}}
    end
  end

  def handle_call({:release_provider, attempt_id}, _from, state) do
    {:reply, :ok, %{state | providers: MapSet.delete(state.providers, attempt_id)}}
  end

  def handle_call({:charge_memory, workspace_id, attempt_id, bytes}, _from, state) do
    current = Map.get(state.memory, attempt_id, 0)
    next = current + bytes
    fleet = fleet_memory(state) - current + next

    cond do
      next > Limits.get(:max_worker_memory_bytes) ->
        {:reply, {:error, :memory_limit}, state}

      fleet > Limits.get(:max_fleet_memory_bytes) ->
        {:reply, {:error, :memory_limit}, state}

      true ->
        memory = Map.put(state.memory, attempt_id, next)
        owners = Map.put(state.memory_owners, attempt_id, workspace_id)
        {:reply, :ok, %{state | memory: memory, memory_owners: owners}}
    end
  end

  def handle_call({:release_memory, attempt_id}, _from, state) do
    {:reply, :ok,
     %{
       state
       | memory: Map.delete(state.memory, attempt_id),
         memory_owners: Map.delete(state.memory_owners, attempt_id)
     }}
  end

  def handle_call({:acquire_lease, workspace_id, attempt_id}, _from, state) do
    lease = %{
      workspace_id: workspace_id,
      attempt_id: attempt_id,
      acquired_at: now_ms(),
      released_at: nil
    }

    {:reply, :ok, %{state | leases: Map.put(state.leases, attempt_id, lease)}}
  end

  def handle_call({:release_lease, attempt_id}, _from, state) do
    leases =
      case Map.get(state.leases, attempt_id) do
        nil ->
          state.leases

        lease ->
          Map.put(state.leases, attempt_id, %{lease | released_at: now_ms()})
      end

    {:reply, :ok, %{state | leases: leases}}
  end

  @impl true
  def handle_cast({:decision, workspace_id, action, reason, extra}, state) do
    entry = %{
      workspace_id: workspace_id,
      action: action,
      reason: reason,
      at: DateTime.utc_now(),
      extra: sanitize_extra(extra)
    }

    decisions =
      state.decisions
      |> Map.put(workspace_id, entry)
      |> trim_map(@max_decisions)

    {:noreply, %{state | decisions: decisions}}
  end

  def handle_cast({:crash, workspace_id}, state) do
    crashes =
      [{now_ms(), workspace_id} | state.crashes]
      |> Enum.take(@max_crashes)

    {:noreply, %{state | crashes: crashes}}
  end

  def handle_cast({:admission, latency_ms}, state) do
    samples = Enum.take([latency_ms | state.admission], @max_admission_samples)
    {:noreply, %{state | admission: samples}}
  end

  def handle_cast({:sample_host, sample}, state) do
    {:noreply, %{state | host: sanitize_host(sample)}}
  end

  defp public_snapshot(state) do
    window = Limits.get(:crash_window_ms)
    cutoff = now_ms() - window
    recent = Enum.filter(state.crashes, fn {ts, _} -> ts >= cutoff end)
    leaked = leaked_leases(state)

    %{
      provider_inflight: MapSet.size(state.providers),
      max_provider_inflight: Limits.get(:max_provider_inflight),
      fleet_memory_bytes: fleet_memory(state),
      worker_memory: Map.new(state.memory),
      crash_count: length(recent),
      crash_window_ms: window,
      leaked_leases: length(leaked),
      leaked_attempt_ids: leaked,
      admission_latency_ms: admission_stats(state.admission),
      last_decisions:
        Map.new(state.decisions, fn {ws, entry} -> {ws, public_decision(entry)} end),
      host: state.host
    }
  end

  defp public_decision(entry) do
    %{
      action: entry.action,
      reason: entry.reason,
      at: entry.at,
      extra: entry.extra
    }
  end

  defp leaked_leases(state) do
    now = now_ms()
    stale_after = Limits.get(:default_attempt_deadline_ms) * 2

    state.leases
    |> Enum.filter(fn {_id, lease} ->
      is_nil(lease.released_at) and now - lease.acquired_at > stale_after
    end)
    |> Enum.map(fn {id, _} -> id end)
  end

  defp fleet_memory(state), do: state.memory |> Map.values() |> Enum.sum()

  defp admission_stats([]), do: %{count: 0, last_ms: 0, max_ms: 0, mean_ms: 0}

  defp admission_stats(samples) do
    %{
      count: length(samples),
      last_ms: hd(samples),
      max_ms: Enum.max(samples),
      mean_ms: div(Enum.sum(samples), length(samples))
    }
  end

  defp sanitize_extra(extra) when is_map(extra) do
    extra
    |> Map.take([
      :running,
      :queued,
      :fleet_running,
      :provider_inflight,
      :memory_bytes,
      :crash_count,
      :leaked_leases,
      :queue_depth,
      :drained
    ])
    |> Map.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp sanitize_extra(_), do: %{}

  defp sanitize_host(sample) when is_map(sample) do
    Map.take(sample, [
      :process_count,
      :memory_bytes,
      :rss_bytes,
      :cpu_ratio,
      :status,
      :reasons
    ])
  end

  defp trim_map(map, max) when map_size(map) <= max, do: map

  defp trim_map(map, max) do
    map
    |> Enum.sort_by(fn {_k, entry} -> entry.at end, {:desc, DateTime})
    |> Enum.take(max)
    |> Map.new()
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp empty do
    %{
      provider_inflight: 0,
      providers: MapSet.new(),
      memory: %{},
      memory_owners: %{},
      leases: %{},
      crashes: [],
      decisions: %{},
      admission: [],
      host: %{}
    }
  end
end
