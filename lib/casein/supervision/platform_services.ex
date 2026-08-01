defmodule Casein.Supervision.PlatformServices do
  @moduledoc false

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec child_specs() :: [Supervisor.child_spec() | module()]
  def child_specs do
    [
      {Casein.RateLimit, clean_period: :timer.minutes(10)},
      {Task.Supervisor, name: Casein.TaskSupervisor},
      Casein.Mobile.FeedTimingRecorder,
      {Registry, keys: :unique, name: Casein.Mobile.UserObserverRegistry},
      {DynamicSupervisor, name: Casein.Mobile.UserObserverSupervisor, strategy: :one_for_one},
      # Lazy per-workspace filesystem watchers for the Files panel tree.
      {Registry, keys: :unique, name: Casein.Files.Watcher.Registry},
      {DynamicSupervisor, name: Casein.Files.Watcher.Supervisor, strategy: :one_for_one},
      # Dedicated HTTP/2 Finch pool for APNs (it refuses HTTP/1.1). Idle until a
      # push is sent; started here so the connection is warm before the first.
      {Finch, name: Casein.Push.APNS.Finch, pools: %{default: [protocols: [:http2]]}},
      Casein.Git.InspectorCache,
      Casein.DeviceLinks.Reaper,
      Casein.Agents.OrchestratorTokens.Reaper,
      Casein.Runtimes.Reaper,
      Casein.Workspaces.Reconciler,
      Casein.SignalBus.child_spec(),
      Casein.Signals.AlertsRouter,
      Casein.Signals.DegradationWatch,
      # Slice 3: host tmux control-listener flap → audit / ops:health (mirrors
      # DegradationWatch patterns; thresholds via :tmux_events_flap_watch).
      Casein.Signals.TmuxEventsFlapWatch,
      Casein.Signals.DiskPressureWatch
    ]
  end

  @impl true
  def init(_opts) do
    Supervisor.init(child_specs(), strategy: :one_for_one)
  end
end
