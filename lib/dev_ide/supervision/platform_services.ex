defmodule DevIde.Supervision.PlatformServices do
  @moduledoc false

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {DevIDE.RateLimit, clean_period: :timer.minutes(10)},
      {Task.Supervisor, name: DevIDE.TaskSupervisor},
      {Registry, keys: :unique, name: DevIDE.Mobile.UserObserverRegistry},
      {DynamicSupervisor, name: DevIDE.Mobile.UserObserverSupervisor, strategy: :one_for_one},
      DevIDE.Git.InspectorCache
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
