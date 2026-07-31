defmodule Casein.Mobile.FeedTimingRecorder do
  @moduledoc """
  Bounded, privacy-safe capture for native feed timing stages.

  The recorder is always attached in the running application and retains only
  the schema that `Casein.Mobile.FeedTiming` allowlists. It is intentionally
  in-memory: release RPC can inspect a short soak window without creating a
  durable store of connection generations.
  """

  use GenServer

  alias Casein.Mobile.FeedTiming

  @event [:casein, :mobile, :feed, :stage]
  @handler_id {__MODULE__, :capture}
  @table __MODULE__
  @default_capacity 512
  @maximum_capacity 2_000
  @default_limit 100
  @maximum_limit 1_000

  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc """
  Returns the newest retained records in chronological order.

  Each record has exactly `recorded_at_ms`, `measurements`, and `metadata`;
  the nested maps have already passed the feed timing allowlist.
  """
  @spec snapshot(pos_integer()) :: [map()]
  def snapshot(limit \\ @default_limit) do
    snapshot_for(__MODULE__, limit)
  end

  @doc false
  @spec snapshot_for(GenServer.server(), pos_integer()) :: [map()]
  def snapshot_for(server, limit \\ @default_limit) do
    GenServer.call(server, {:snapshot, limit})
  end

  @spec capacity() :: pos_integer()
  def capacity, do: GenServer.call(__MODULE__, :capacity)

  @doc false
  @spec capacity(GenServer.server()) :: pos_integer()
  def capacity(server), do: GenServer.call(server, :capacity)

  @doc false
  @spec clear() :: :ok
  def clear, do: GenServer.call(__MODULE__, :clear)

  @doc false
  @spec clear(GenServer.server()) :: :ok
  def clear(server), do: GenServer.call(server, :clear)

  @doc """
  Toggles canonical JSON byte sizing for physical soak measurements.

  The setting is runtime-only and does not alter the fixed recorder schema.
  """
  @spec configure_snapshot_sizing(boolean()) :: %{snapshot_json_bytes: boolean()}
  def configure_snapshot_sizing(enabled) when is_boolean(enabled) do
    Application.put_env(:casein, :mobile_feed_snapshot_json_bytes, enabled)
    %{snapshot_json_bytes: enabled}
  end

  @spec snapshot_sizing_enabled?() :: boolean()
  def snapshot_sizing_enabled? do
    Application.get_env(:casein, :mobile_feed_snapshot_json_bytes, false) == true
  end

  @impl true
  def init(opts) do
    capacity =
      opts
      |> Keyword.get(
        :capacity,
        Application.get_env(:casein, :mobile_feed_timing_capacity, @default_capacity)
      )
      |> normalize_capacity()

    handler_id = Keyword.get(opts, :handler_id, @handler_id)
    _ = :telemetry.detach(handler_id)

    table =
      :ets.new(@table, [
        :ordered_set,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])

    :ets.insert(table, {:sequence, 0})

    :ok =
      :telemetry.attach(
        handler_id,
        @event,
        &__MODULE__.handle_event/4,
        %{table: table, capacity: capacity}
      )

    {:ok, %{table: table, capacity: capacity, handler_id: handler_id}}
  end

  @doc false
  def handle_event(@event, measurements, metadata, %{table: table, capacity: capacity}) do
    case FeedTiming.sanitize_event(measurements, metadata) do
      {:ok, sanitized} ->
        sequence = :ets.update_counter(table, :sequence, {2, 1}, {:sequence, 0})

        record = %{
          recorded_at_ms: System.system_time(:millisecond),
          measurements: sanitized.measurements,
          metadata: sanitized.metadata
        }

        true = :ets.insert(table, {sequence, record})
        enforce_capacity(table, capacity)

        :ok

      :error ->
        :ok
    end
  rescue
    # A supervised restart can briefly leave an attached handler without its
    # owning ETS table. Dropping that one measurement is safer than affecting
    # the feed process that emitted it.
    ArgumentError -> :ok
  end

  def handle_event(_event, _measurements, _metadata, _config), do: :ok

  @impl true
  def handle_call({:snapshot, limit}, _from, state) do
    records =
      state.table
      |> :ets.tab2list()
      |> Enum.filter(fn {sequence, _record} -> is_integer(sequence) end)
      |> Enum.sort_by(&elem(&1, 0), :desc)
      |> Enum.take(normalize_limit(limit))
      |> Enum.reverse()
      |> Enum.map(&elem(&1, 1))

    {:reply, records, state}
  end

  def handle_call(:capacity, _from, state), do: {:reply, state.capacity, state}

  def handle_call(:clear, _from, state) do
    state.table
    |> :ets.tab2list()
    |> Enum.each(fn
      {sequence, _record} when is_integer(sequence) -> :ets.delete(state.table, sequence)
      _counter -> :ok
    end)

    {:reply, :ok, state}
  end

  @impl true
  def terminate(_reason, state) do
    _ = :telemetry.detach(state.handler_id)
    :ok
  end

  defp normalize_capacity(value)
       when is_integer(value) and value > 0 and value <= @maximum_capacity,
       do: value

  defp normalize_capacity(_value), do: @default_capacity

  defp normalize_limit(value)
       when is_integer(value) and value > 0 and value <= @maximum_limit,
       do: value

  defp normalize_limit(value) when is_integer(value) and value > @maximum_limit,
    do: @maximum_limit

  defp normalize_limit(_value), do: @default_limit

  defp enforce_capacity(table, capacity) do
    latest_sequence = :ets.lookup_element(table, :sequence, 2)
    cutoff = latest_sequence - capacity

    if cutoff > 0 do
      :ets.select_delete(table, [
        {
          {:"$1", :_},
          [{:is_integer, :"$1"}, {:"=<", :"$1", cutoff}],
          [true]
        }
      ])
    end

    :ok
  end
end
