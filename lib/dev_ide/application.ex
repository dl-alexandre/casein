defmodule DevIde.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @fast_path_cache_table :dev_ide_terminal_fast_path_cache

  @impl true
  def start(_type, _args) do
    configure_tmux_ctl!()
    configure_preview_ctl!()
    configure_git_ctl!()
    ensure_terminal_fast_path_cache_table!()
    DevIDE.Terminals.WorkspaceAccessCache.ensure_table!()
    DevIDE.Fleet.OutputStream.ensure_table!()

    children = [
      DevIdeWeb.Telemetry,
      DevIde.Repo,
      {DevIDE.RateLimit, clean_period: :timer.minutes(10)},
      {Oban, Application.fetch_env!(:dev_ide, Oban)},
      {DNSCluster, query: Application.get_env(:dev_ide, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: DevIde.PubSub},
      DevIDE.Git.InspectorCache,
      {Registry, keys: :unique, name: DevIDE.Terminals.Registry},
      {DynamicSupervisor, name: DevIDE.Terminals.Supervisor, strategy: :one_for_one},
      {Registry, keys: :unique, name: DevIDE.Terminals.TopologyRegistry},
      {DynamicSupervisor, name: DevIDE.Terminals.TopologySupervisor, strategy: :one_for_one},
      DevIDE.Terminals.TmuxJanitor,
      DevIDE.Terminals.TmuxWindowJanitor,
      {Registry, keys: :unique, name: DevIDE.Commands.Registry},
      {DynamicSupervisor, name: DevIDE.Commands.Supervisor, strategy: :one_for_one},
      {Registry, keys: :unique, name: DevIDE.Agents.Registry},
      {DynamicSupervisor, name: DevIDE.Agents.Supervisor, strategy: :one_for_one},
      DevIDE.Agents.Activity,
      DevIDE.Audit.MemoryAdapter,
      DevIDE.Workspaces.State.MemoryAdapter,
      DevIDE.Commands.History.MemoryAdapter,
      DevIDE.Runners.MemoryAdapter,
      DevIDE.Runtimes.MemoryAdapter,
      DevIDE.Fleet.RunnerDirectory,
      DevIDE.Fleet.Registry,
      DevIDE.Fleet.Queue,
      DevIDE.Fleet.ExecutionProjectionStore,
      DevIDE.Fleet.ArtifactStore.MemoryAdapter,
      DevIDE.Fleet.OperatorNotifications,
      {DevIDE.Fleet.PlacementPass, interval_ms: 5_000},
      DevIDE.Assignments.EventStore.MemoryAdapter,
      DevIDE.Assignments.ProjectionStore.MemoryAdapter,
      {Task, fn -> DevIDE.Assignments.Replay.rebuild_all() end},
      DevIDE.Assignments.Reconciler,
      PreviewCtl.Registry,
      PreviewCtl.Playwright.Bridge,
      DevIDE.Deployment.Registry,
      DevIDE.Deployment.Drain,
      DevIdeWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: DevIde.Supervisor]
    res = Supervisor.start_link(children, opts)
    _ = Task.start(fn -> DevIDE.Files.Janitor.run_on_boot() end)

    if Application.get_env(:dev_ide, :schedule_oban_workers, true) do
      _ = Task.start(fn -> DevIDE.Runners.ExpireLeasesWorker.ensure_scheduled() end)
    end

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

  defp configure_tmux_ctl! do
    for {key, value} <- Application.get_env(:dev_ide, :tmux_ctl, []) do
      Application.put_env(:tmux_ctl, key, value)
    end
  end

  defp configure_git_ctl! do
    base = Application.get_env(:dev_ide, :git_ctl, [])

    merged =
      case Application.get_env(:dev_ide, :git_inspector_cache_ttl_ms) do
        nil -> base
        ttl -> Keyword.put(base, :cache_ttl_ms, ttl)
      end

    for {key, value} <- merged do
      Application.put_env(:git_ctl, key, value)
    end
  end

  defp configure_preview_ctl! do
    base = Application.get_env(:dev_ide, :preview_ctl, [])

    merged =
      base
      |> Keyword.put(:adapter, preview_ctl_adapter())
      |> maybe_put_preview_env(:playwright_script, :preview_playwright_script)

    for {key, value} <- merged do
      Application.put_env(:preview_ctl, key, value)
    end
  end

  defp preview_ctl_adapter do
    case Application.get_env(:dev_ide, :preview_control_adapter, :memory) do
      :playwright -> PreviewCtl.Playwright.Adapter
      _ -> PreviewCtl.Test.FakeAdapter
    end
  end

  defp maybe_put_preview_env(keyword, preview_key, dev_ide_key) do
    case Application.get_env(:dev_ide, dev_ide_key) do
      nil -> keyword
      value -> Keyword.put(keyword, preview_key, value)
    end
  end

  @impl true
  def config_change(changed, _new, removed) do
    DevIdeWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
