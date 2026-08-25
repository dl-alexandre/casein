defmodule Casein.Agents.JidoPod.Metrics do
  @moduledoc """
  Counters for comparing the headless Jido path with the OpenCode fleet.
  """

  @table :casein_jido_pod_metrics

  @counters [
    :admitted,
    :queued,
    :running,
    :awaiting_human,
    :retrying,
    :completed,
    :failed,
    :cancelled,
    :timed_out,
    :provider_unavailable,
    :rejected,
    :legacy_opencode,
    :worker_crash
  ]

  @spec ensure_table!() :: :ok
  def ensure_table! do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
        reset()

      _ ->
        :ok
    end
  end

  @spec reset() :: :ok
  def reset do
    ensure_table!()
    Enum.each(@counters, &:ets.insert(@table, {&1, 0}))
    :ok
  end

  @spec inc(atom(), integer()) :: :ok
  def inc(name, delta \\ 1) when name in @counters and is_integer(delta) do
    ensure_table!()
    :ets.update_counter(@table, name, {2, delta}, {name, 0})
    :ok
  end

  @spec snapshot() :: map()
  def snapshot do
    ensure_table!()

    counts =
      Map.new(@counters, fn name ->
        case :ets.lookup(@table, name) do
          [{^name, value}] -> {name, value}
          [] -> {name, 0}
        end
      end)

    %{
      counts: counts,
      process_count: :erlang.system_info(:process_count),
      memory_bytes: :erlang.memory(:total),
      opencode_baseline: %{
        processes_per_worker: 1,
        requires_tmux_pane: true,
        note: "legacy OpenCode: one OS/TUI process and tmux pane per worker"
      }
    }
  end

  @spec emit(atom(), map(), map()) :: :ok
  def emit(event, measurements, metadata)
      when is_atom(event) and is_map(measurements) and is_map(metadata) do
    :telemetry.execute([:casein, :jido_pod, event], measurements, metadata)
    :ok
  end
end
