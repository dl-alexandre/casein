defmodule DevIde.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @fast_path_cache_table :dev_ide_terminal_fast_path_cache

  @impl true
  def start(_type, _args) do
    ensure_terminal_fast_path_cache_table!()
    DevIDE.Terminals.WorkspaceAccessCache.ensure_table!()

    children = [
      DevIdeWeb.Telemetry,
      DevIde.Repo,
      {DNSCluster, query: Application.get_env(:dev_ide, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: DevIde.PubSub},
      {Registry, keys: :unique, name: DevIDE.Terminals.Registry},
      {DynamicSupervisor, name: DevIDE.Terminals.Supervisor, strategy: :one_for_one},
      DevIDE.Terminals.TmuxJanitor,
      DevIDE.Terminals.TmuxWindowJanitor,
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
      DevIDE.Fleet.RunnerDirectory,
      DevIDE.Fleet.Registry,
      DevIDE.Fleet.Queue,
      DevIDE.Fleet.OutputStream,
      DevIDE.Fleet.ExecutionProjectionStore,
      DevIDE.Fleet.ArtifactStore.MemoryAdapter,
      DevIDE.Fleet.OperatorNotifications,
      {DevIDE.Fleet.PlacementPass, interval_ms: 5_000},
      DevIDE.Assignments.EventStore.MemoryAdapter,
      DevIDE.Assignments.ProjectionStore.MemoryAdapter,
      {Task, fn -> DevIDE.Assignments.Replay.rebuild_all() end},
      DevIDE.Assignments.Reconciler,
      DevIDE.PreviewControl.Registry,
      DevIDE.PreviewControl.PlaywrightBridge,
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
  defp ensure_terminal_fast_path_cache_table! do
    case :ets.whereis(@fast_path_cache_table) do
      :undefined ->
        # :public because TerminalChannel (and other non-app processes) must insert
        # verified fast-path claims on joins/reconnects. See ChannelAuth, TerminalChannel
        # moduledoc comments, and WorkspaceAccessCache for the trust model.
        access = Application.get_env(:dev_ide, :ets_table_access, :protected)
        :ets.new(@fast_path_cache_table, [:named_table, access, :set])

      _ ->
        :ok
    end
  end

  @impl true
  def config_change(changed, _new, removed) do
    DevIdeWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
