defmodule DevIDE.Supervision.PlatformServices do
  @moduledoc false

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec child_specs() :: [Supervisor.child_spec() | module()]
  def child_specs do
    [
      {DevIDE.RateLimit, clean_period: :timer.minutes(10)},
      {Task.Supervisor, name: DevIDE.TaskSupervisor},
      {Registry, keys: :unique, name: DevIDE.Mobile.UserObserverRegistry},
      {DynamicSupervisor, name: DevIDE.Mobile.UserObserverSupervisor, strategy: :one_for_one},
      # Dedicated HTTP/2 Finch pool for APNs (it refuses HTTP/1.1). Idle until a
      # push is sent; started here so the connection is warm before the first.
      {Finch, name: DevIDE.Push.APNS.Finch, pools: %{default: [protocols: [:http2]]}},
      DevIDE.Git.InspectorCache,
      DevIDE.DeviceLinks.Reaper,
      DevIDE.Agents.OrchestratorTokens.Reaper,
      DevIDE.Runtimes.Reaper,
      DevIDE.SignalBus.child_spec(),
      DevIDE.Signals.AlertsRouter,
      DevIDE.Signals.DegradationWatch
    ]
  end

  @impl true
  def init(_opts) do
    Supervisor.init(child_specs(), strategy: :one_for_one)
  end
end
