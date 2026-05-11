defmodule DevIDE.Runners.ExpiryScheduler do
  @moduledoc """
  Periodically calls `DevIDE.Runners.expire_leases/1` so leases held by
  silent or dead runners are reclaimed and audited.

  Without this, `Runners.expire_leases/1` is defined but never invoked,
  and a runner that disappears mid-job holds its assignment lease
  indefinitely — blocking any other runner from claiming the same work.
  This was the only critical code-level Fleet gap (see
  `docs/audit_fleet.md` CC-F1).

  The expiration itself is idempotent and already audits each
  transition via `Runners.expire_leases/1`. This module adds only
  the periodic trigger.

  If a tick crashes, the supervisor restarts the scheduler and the
  next interval kicks in — we deliberately do not catch errors here,
  so a real adapter-level bug is visible in supervisor restart logs
  rather than silently swallowed.

  Configurable via:

      config :dev_ide, :lease_expiry_interval_ms, 30_000
  """

  use GenServer
  require Logger

  alias DevIDE.Runners

  @default_interval_ms 30_000

  ## Public API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Returns the configured tick interval in milliseconds."
  def interval_ms,
    do: Application.get_env(:dev_ide, :lease_expiry_interval_ms, @default_interval_ms)

  ## Callbacks

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval_ms, interval_ms())
    schedule_tick(interval)
    {:ok, %{interval_ms: interval}}
  end

  @impl true
  def handle_info(:tick, state) do
    expired = Runners.expire_leases(DateTime.utc_now())

    if expired != [] do
      Logger.info("expired #{length(expired)} runner lease(s)")
    end

    schedule_tick(state.interval_ms)
    {:noreply, state}
  end

  ## Internal

  defp schedule_tick(interval), do: Process.send_after(self(), :tick, interval)
end
