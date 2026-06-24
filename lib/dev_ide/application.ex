defmodule DevIde.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Boundary,
    deps: [DevIDE, DevIde.Repo, DevIdeWeb],
    exports: []

  use Application

  @fast_path_cache_table :dev_ide_terminal_fast_path_cache

  @impl true
  def start(_type, _args) do
    assert_forward_auth_bind!()
    configure_tmux_ctl!()
    configure_preview_ctl!()
    configure_git_ctl!()
    ensure_terminal_fast_path_cache_table!()
    DevIDE.Terminals.WorkspaceAccessCache.ensure_table!()

    children =
      [
        DevIdeWeb.Telemetry,
        DevIde.Repo,
        {DevIDE.RateLimit, clean_period: :timer.minutes(10)},
        {DNSCluster, query: Application.get_env(:dev_ide, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: DevIde.PubSub},
        {Task.Supervisor, name: DevIDE.TaskSupervisor},
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
        DevIDE.Agents.MCPSessions,
        DevIDE.Agents.Activity,
        DevIDE.Labels,
        DevIDE.PreviewActivity,
        DevIDE.PreviewPanes,
        DevIDE.Audit.MemoryAdapter,
        DevIDE.Workspaces.State.MemoryAdapter,
        DevIDE.Runtimes.MemoryAdapter,
        PreviewCtl.Registry,
        PreviewCtl.Playwright.Bridge,
        DevIDE.Deployment.Registry,
        DevIDE.Deployment.Drain,
        DevIdeWeb.Endpoint
      ] ++ preview_tidewave_listener()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: DevIde.Supervisor]
    res = Supervisor.start_link(children, opts)
    _ = Task.start(fn -> DevIDE.Files.Janitor.run_on_boot() end)

    res
  end

  # Ephemeral preview environments boot the endpoint on a unix socket
  # (DEVIDE_HTTP_SOCKET, wired in runtime.exs) so the Caddy preview router can
  # dial them collision-free, mirroring the live /run/devide/current.sock model.
  # But the Tidewave agent integration dials Tidewave over a *loopback TCP* URL
  # (http://127.0.0.1:<port>/tidewave/mcp — see DevIDE.Agents.TidewaveMCP), which
  # a unix socket can't serve. So when DEVIDE_PREVIEW_TIDEWAVE_PORT is set we run
  # a SECOND Bandit listener on that loopback port serving the same endpoint plug
  # (Tidewave is `plug Tidewave` in the endpoint), giving Tidewave its TCP front
  # door without taking the primary listener off the socket. Bound to 127.0.0.1
  # only — Tidewave is a runtime-eval surface and must never leave loopback. Prod
  # never sets the var, so the live supervision tree is byte-for-byte unchanged.
  defp preview_tidewave_listener do
    with raw when is_binary(raw) <- System.get_env("DEVIDE_PREVIEW_TIDEWAVE_PORT"),
         {port, ""} when port > 0 and port < 65_536 <- Integer.parse(raw) do
      [
        Supervisor.child_spec(
          {Bandit, plug: DevIdeWeb.Endpoint, scheme: :http, ip: {127, 0, 0, 1}, port: port},
          id: :preview_tidewave_listener
        )
      ]
    else
      _ -> []
    end
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

  # Defense-in-depth (audit #10 / F3): when forward-auth is enabled, DevIDE
  # trusts the `X-Auth-Request-Email` header, which is only safe behind the proxy
  # on a loopback / unix-socket bind. If the HTTP listener is bound somewhere a
  # client could reach directly, identity can be spoofed. runtime.exs already
  # binds loopback in that case; this asserts it at boot so a misconfiguration is
  # caught loudly. Raises in dev/test (fail fast); warns + continues in prod (no
  # surprise deploys).
  defp assert_forward_auth_bind! do
    if DevIdeWeb.Plugs.ForwardAuth.enabled?() and not loopback_or_socket_bound?() do
      ip = endpoint_bind_ip()

      message =
        "Forward-auth is enabled (DevIDE trusts X-Auth-Request-Email) but the HTTP " <>
          "listener is bound to #{inspect(ip)}, not loopback/unix-socket — a client " <>
          "that reaches this port directly can spoof identity. Bind 127.0.0.1, ::1, " <>
          "or a unix socket behind the proxy. (audit #10 / F3)"

      if Application.get_env(:dev_ide, :env, :prod) in [:dev, :test] do
        raise message
      else
        require Logger
        Logger.warning(message)
      end
    end

    :ok
  end

  defp loopback_or_socket_bound? do
    case endpoint_bind_ip() do
      {127, 0, 0, 1} -> true
      {0, 0, 0, 0, 0, 0, 0, 1} -> true
      {:local, _} -> true
      # No explicit bind configured (e.g. server not started): nothing to assert.
      nil -> true
      _ -> false
    end
  end

  defp endpoint_bind_ip do
    Application.get_env(:dev_ide, DevIdeWeb.Endpoint, [])
    |> Keyword.get(:http, [])
    |> Keyword.get(:ip)
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
