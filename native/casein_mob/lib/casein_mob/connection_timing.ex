defmodule CaseinMob.ConnectionTiming do
  @moduledoc """
  Privacy-bounded cold hydration and reconnect stage timing.

  Only fixed stage/cycle atoms and elapsed milliseconds are emitted. Origins,
  credentials, card contents, terminal output, and network payloads are never
  included.
  """

  require Logger

  @event [:casein_mob, :connection, :stage]
  @boot_key {__MODULE__, :boot_started_at}
  @cycles [:cold, :reconnect]
  @stages [
    :app_start,
    :dns_ready,
    :dependencies_ready,
    :client_started,
    :database_ready,
    :root_started,
    :configuration_restored,
    :connect_requested,
    :reconnect_requested,
    :transport_connected,
    :authoritative_cards_joined,
    :no_configuration,
    :disconnected
  ]

  @spec start_boot() :: integer()
  def start_boot do
    started_at = now()
    :persistent_term.put(@boot_key, started_at)
    emit(:cold, :app_start, started_at)
    started_at
  end

  @spec boot_started_at() :: integer() | nil
  def boot_started_at do
    :persistent_term.get(@boot_key, nil)
  end

  @spec boot_stage(atom()) :: :ok
  def boot_stage(stage) when stage in @stages do
    emit(:cold, stage, boot_started_at() || now())
    :ok
  end

  @spec stage(atom(), atom(), integer()) :: :ok
  def stage(cycle, stage, started_at)
      when cycle in @cycles and stage in @stages and is_integer(started_at) do
    emit(cycle, stage, started_at)
    :ok
  end

  @doc false
  def reset do
    :persistent_term.erase(@boot_key)
    :ok
  end

  defp emit(cycle, stage, started_at) do
    elapsed_ms = max(now() - started_at, 0)

    :telemetry.execute(
      @event,
      %{elapsed_ms: elapsed_ms, count: 1},
      %{cycle: cycle, stage: stage}
    )

    Logger.info("mobile_connection_timing cycle=#{cycle} stage=#{stage} elapsed_ms=#{elapsed_ms}")
  end

  defp now, do: System.monotonic_time(:millisecond)
end
