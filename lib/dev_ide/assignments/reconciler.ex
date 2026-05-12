defmodule DevIDE.Assignments.Reconciler do
  @moduledoc """
  Supervised periodic reconciler for orchestrated assignments.

  Every tick:
    1. Lists all non-terminal assignments
    2. Expires any whose lease has passed
    3. Recovers stale assignments stuck in `claimed` without a heartbeat

  The tick interval and stale threshold are configurable:

      config :dev_ide, :assignment_reconcile_interval_ms, 30_000
      config :dev_ide, :assignment_stale_threshold_ms, 120_000

  Crashes during a tick are not caught — they surface in the supervisor
  restart logs so operational issues are visible.
  """

  use GenServer
  require Logger

  alias DevIDE.Assignments
  alias DevIDE.Assignments.StateMachine

  @default_interval_ms 30_000
  @default_stale_ms 120_000

  ## Public API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def interval_ms,
    do: Application.get_env(:dev_ide, :assignment_reconcile_interval_ms, @default_interval_ms)

  def stale_threshold_ms,
    do: Application.get_env(:dev_ide, :assignment_stale_threshold_ms, @default_stale_ms)

  ## Callbacks

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval_ms, interval_ms())
    schedule_tick(interval)
    {:ok, %{interval_ms: interval}}
  end

  @impl true
  def handle_info(:tick, state) do
    now = DateTime.utc_now()

    expired =
      Assignments.list()
      |> Enum.reject(fn a -> StateMachine.terminal?(a.state) end)
      |> Enum.filter(fn a ->
        a.lease_expires_at != nil and DateTime.compare(a.lease_expires_at, now) != :gt
      end)
      |> Enum.map(fn a ->
        case Assignments.expire(a.id) do
          {:ok, expired} -> expired
          _ -> a
        end
      end)

    if expired != [] do
      Logger.info("Reconciler expired #{length(expired)} assignment lease(s)")
    end

    stale_threshold = stale_threshold_ms()

    stale =
      Assignments.list()
      |> Enum.filter(fn a -> a.state == "claimed" end)
      |> Enum.filter(fn a ->
        a.claimed_at != nil and
          DateTime.compare(
            DateTime.add(a.claimed_at, stale_threshold, :millisecond),
            now
          ) != :gt
      end)
      |> Enum.map(fn a ->
        case Assignments.abandon(a.id, %{reason: "stale_recovery"}) do
          {:ok, abandoned} -> abandoned
          _ -> a
        end
      end)

    if stale != [] do
      Logger.info("Reconciler recovered #{length(stale)} stale assignment(s)")
    end

    schedule_tick(state.interval_ms)
    {:noreply, state}
  end

  ## Internal

  defp schedule_tick(interval), do: Process.send_after(self(), :tick, interval)
end
