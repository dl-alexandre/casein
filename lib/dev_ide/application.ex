defmodule DevIde.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      DevIdeWeb.Telemetry,
      DevIde.Repo,
      {DNSCluster, query: Application.get_env(:dev_ide, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: DevIde.PubSub},
      {Registry, keys: :unique, name: DevIDE.Terminals.Registry},
      {DynamicSupervisor, name: DevIDE.Terminals.Supervisor, strategy: :one_for_one},
      {Registry, keys: :unique, name: DevIDE.Commands.Registry},
      {DynamicSupervisor, name: DevIDE.Commands.Supervisor, strategy: :one_for_one},
      {Registry, keys: :unique, name: DevIDE.Agents.Registry},
      {DynamicSupervisor, name: DevIDE.Agents.Supervisor, strategy: :one_for_one},
      DevIDE.Audit.MemoryAdapter,
      DevIDE.Workspaces.State.MemoryAdapter,
      DevIDE.Commands.History.MemoryAdapter,
      DevIDE.Runners.MemoryAdapter,
      DevIDE.Runtimes.MemoryAdapter,
      DevIDE.Runners.ExpiryScheduler,
      DevIDE.Assignments.EventStore.MemoryAdapter,
      DevIDE.Assignments.ProjectionStore.MemoryAdapter,
      DevIDE.Assignments.Reconciler,
      DevIdeWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: DevIde.Supervisor]
    res = Supervisor.start_link(children, opts)
    _ = Task.start(fn -> DevIDE.Files.Janitor.run_on_boot() end)
    res
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    DevIdeWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
