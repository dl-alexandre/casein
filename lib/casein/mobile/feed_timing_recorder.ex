defmodule Casein.Mobile.FeedTimingRecorder do
  @moduledoc """
  Bounded, privacy-safe capture for native feed timing stages.

  The recorder is always attached in the running application and retains only
  the schema that `Casein.Mobile.FeedTiming` allowlists. It is intentionally
  in-memory: release RPC can inspect a short soak window without creating a
  durable store of connection generations.
  """

  use GenServer

  alias Casein.Mobile.{FeedTiming, FeedTimingAggregate}

  @event [:casein, :mobile, :feed, :stage]
  @handler_id {__MODULE__, :capture}
  @table __MODULE__
  @default_capacity 512
  @maximum_capacity 2_000
  @default_limit 100
  @maximum_limit 1_000
  @soak_generation_count 20
  @maximum_active_cohort_fences 4
  @cohort_fence_ttl_ms :timer.hours(1)

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

  @doc """
  Returns a fixed-schema aggregate for one explicit platform/cycle cohort.

  The aggregate never includes connection generations or individual records.
  Inputs must be a nonempty, unique list of canonical generations and the
  platform/cycle must use the fixed atom vocabulary.
  """
  @spec aggregate([String.t()], :ios | :android, :cold | :reconnect | :origin_switch) ::
          {:ok, map()} | {:error, :invalid_request}
  def aggregate(generations, platform, cycle) do
    aggregate_for(__MODULE__, generations, platform, cycle)
  end

  @doc false
  @spec aggregate_for(
          GenServer.server(),
          [String.t()],
          :ios | :android,
          :cold | :reconnect | :origin_switch
        ) :: {:ok, map()} | {:error, :invalid_request}
  def aggregate_for(server, generations, platform, cycle) do
    GenServer.call(server, {:aggregate, generations, platform, cycle, false})
  end

  @doc """
  Atomically returns an aggregate and removes only the matched retained records.

  Invalid requests remove nothing. Records outside the explicit generation,
  platform, and cycle cohort are never consumed.
  """
  @spec aggregate_and_consume(
          [String.t()],
          :ios | :android,
          :cold | :reconnect | :origin_switch
        ) :: {:ok, map()} | {:error, :invalid_request}
  def aggregate_and_consume(generations, platform, cycle) do
    aggregate_and_consume_for(__MODULE__, generations, platform, cycle)
  end

  @doc false
  @spec aggregate_and_consume_for(
          GenServer.server(),
          [String.t()],
          :ios | :android,
          :cold | :reconnect | :origin_switch
        ) :: {:ok, map()} | {:error, :invalid_request}
  def aggregate_and_consume_for(server, generations, platform, cycle) do
    GenServer.call(server, {:aggregate, generations, platform, cycle, true})
  end

  @doc """
  Opens an opaque, recorder-local fence for one physical timing cohort.

  The fence is single-use and is valid only for this recorder epoch and the
  exact platform/cycle supplied here. Callers must not inspect or persist it.
  """
  @spec begin_cohort(:ios | :android, :cold | :reconnect | :origin_switch) ::
          {:ok, term()} | {:error, :invalid_request}
  def begin_cohort(platform, cycle) do
    begin_cohort_for(__MODULE__, platform, cycle)
  end

  @doc false
  @spec begin_cohort_for(
          GenServer.server(),
          :ios | :android,
          :cold | :reconnect | :origin_switch
        ) :: {:ok, term()} | {:error, :invalid_request}
  def begin_cohort_for(server, platform, cycle) do
    GenServer.call(server, {:begin_cohort, platform, cycle})
  end

  @doc """
  Finishes one fenced physical cohort and consumes only its matched rows.

  Exactly twenty unique canonical generations are required. The finish attempt
  is single-use even when it fails validation, preventing a fence from being
  replayed with a different scope or identifier set.
  """
  @spec finish_cohort(
          term(),
          [String.t()],
          :ios | :android,
          :cold | :reconnect | :origin_switch
        ) :: {:ok, map()} | {:error, :invalid_request}
  def finish_cohort(fence, generations, platform, cycle) do
    finish_cohort_for(__MODULE__, fence, generations, platform, cycle)
  end

  @doc false
  @spec finish_cohort_for(
          GenServer.server(),
          term(),
          [String.t()],
          :ios | :android,
          :cold | :reconnect | :origin_switch
        ) :: {:ok, map()} | {:error, :invalid_request}
  def finish_cohort_for(server, fence, generations, platform, cycle) do
    GenServer.call(server, {:finish_cohort, fence, generations, platform, cycle})
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

    monotonic_ms_fun =
      Keyword.get(opts, :monotonic_ms_fun, fn -> System.monotonic_time(:millisecond) end)

    true = is_function(monotonic_ms_fun, 0)
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

    {:ok,
     %{
       table: table,
       capacity: capacity,
       handler_id: handler_id,
       recorder_epoch: make_ref(),
       active_cohort_fences: %{},
       monotonic_ms_fun: monotonic_ms_fun
     }}
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

  def handle_call({:aggregate, generations, platform, cycle, consume?}, _from, state)
      when is_boolean(consume?) do
    reply =
      with {:ok, request} <- FeedTimingAggregate.validate_request(generations, platform, cycle),
           boundary <- :ets.lookup_element(state.table, :sequence, 2),
           entries <- retained_entries_through(state.table, boundary),
           {:ok, aggregate, matched_sequences} <- FeedTimingAggregate.build(entries, request) do
        if consume? do
          Enum.each(matched_sequences, &:ets.delete(state.table, &1))
        end

        {:ok, aggregate}
      end

    {:reply, reply, state}
  end

  def handle_call({:begin_cohort, platform, cycle}, _from, state) do
    state = expire_cohort_fences(state)

    cond do
      not FeedTimingAggregate.scope_valid?(platform, cycle) ->
        {:reply, {:error, :invalid_request}, state}

      cohort_scope_active?(state.active_cohort_fences, platform, cycle) ->
        {:reply, {:error, :invalid_request}, state}

      map_size(state.active_cohort_fences) >= @maximum_active_cohort_fences ->
        {:reply, {:error, :invalid_request}, state}

      true ->
        lower_sequence = :ets.lookup_element(state.table, :sequence, 2)
        private_tag = make_ref()
        opened_at_ms = state.monotonic_ms_fun.()

        fence =
          {private_tag, state.recorder_epoch, lower_sequence, platform, cycle}

        fence_binding = %{
          recorder_epoch: state.recorder_epoch,
          lower_sequence: lower_sequence,
          platform: platform,
          cycle: cycle,
          opened_at_ms: opened_at_ms
        }

        state =
          put_in(state.active_cohort_fences[private_tag], fence_binding)

        {:reply, {:ok, fence}, state}
    end
  end

  def handle_call(
        {:finish_cohort, fence, generations, platform, cycle},
        _from,
        state
      ) do
    state = expire_cohort_fences(state)
    {binding, state} = take_cohort_fence(state, fence)

    reply =
      with {:ok, lower_sequence} <-
             validate_cohort_binding(binding, fence, platform, cycle),
           true <- exactly_soak_generation_count?(generations),
           {:ok, request} <- FeedTimingAggregate.validate_request(generations, platform, cycle),
           upper_sequence <- :ets.lookup_element(state.table, :sequence, 2),
           entries <-
             retained_entries_between(state.table, lower_sequence, upper_sequence),
           {:ok, aggregate, matched_sequences} <- FeedTimingAggregate.build(entries, request) do
        Enum.each(matched_sequences, &:ets.delete(state.table, &1))
        {:ok, aggregate}
      else
        _invalid_or_stale -> {:error, :invalid_request}
      end

    {:reply, reply, state}
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

  defp retained_entries_through(table, boundary) do
    table
    |> :ets.tab2list()
    |> Enum.filter(fn
      {sequence, _record} when is_integer(sequence) -> sequence <= boundary
      _counter -> false
    end)
  end

  defp retained_entries_between(table, lower_sequence, upper_sequence) do
    table
    |> :ets.tab2list()
    |> Enum.filter(fn
      {sequence, _record} when is_integer(sequence) ->
        sequence > lower_sequence and sequence <= upper_sequence

      _counter ->
        false
    end)
  end

  defp take_cohort_fence(state, {private_tag, _epoch, _lower, _platform, _cycle})
       when is_reference(private_tag) do
    {binding, active_cohort_fences} =
      Map.pop(state.active_cohort_fences, private_tag)

    {binding, %{state | active_cohort_fences: active_cohort_fences}}
  end

  defp take_cohort_fence(state, _malformed), do: {nil, state}

  defp validate_cohort_binding(
         %{
           recorder_epoch: epoch,
           lower_sequence: lower_sequence,
           platform: platform,
           cycle: cycle,
           opened_at_ms: opened_at_ms
         },
         {_private_tag, epoch, lower_sequence, platform, cycle},
         platform,
         cycle
       )
       when is_reference(epoch) and is_integer(lower_sequence) and lower_sequence >= 0 and
              is_integer(opened_at_ms),
       do: {:ok, lower_sequence}

  defp validate_cohort_binding(_binding, _fence, _platform, _cycle),
    do: {:error, :invalid_request}

  defp exactly_soak_generation_count?(generations),
    do: exactly_soak_generation_count?(generations, 0)

  defp exactly_soak_generation_count?([], @soak_generation_count), do: true

  defp exactly_soak_generation_count?([_generation | rest], count)
       when count < @soak_generation_count,
       do: exactly_soak_generation_count?(rest, count + 1)

  defp exactly_soak_generation_count?(_generations, _count), do: false

  defp expire_cohort_fences(state) do
    now_ms = state.monotonic_ms_fun.()

    active_cohort_fences =
      Map.reject(state.active_cohort_fences, fn
        {_tag, %{opened_at_ms: opened_at_ms}} when is_integer(opened_at_ms) ->
          opened_at_ms + @cohort_fence_ttl_ms <= now_ms

        _malformed_binding ->
          true
      end)

    %{state | active_cohort_fences: active_cohort_fences}
  end

  defp cohort_scope_active?(active_cohort_fences, platform, cycle) do
    Enum.any?(active_cohort_fences, fn
      {_tag, %{platform: ^platform, cycle: ^cycle}} -> true
      _other_scope -> false
    end)
  end
end
