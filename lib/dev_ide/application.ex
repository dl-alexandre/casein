defmodule Casein.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Boundary,
    top_level?: true,
    deps: [Casein, Casein.Repo, CaseinWeb],
    exports: []

  use Application

  @fast_path_cache_table :casein_terminal_fast_path_cache

  @impl true
  def start(_type, _args) do
    CaseinWeb.Plugs.ForwardAuth.assert_safe_listener_bind!()
    unless desktop_powershell?() or native_windows?(), do: configure_tmux_ctl!()
    configure_preview_ctl!()
    configure_git_ctl!()
    ensure_terminal_fast_path_cache_table!()
    Casein.Terminals.WorkspaceAccessCache.ensure_table!()
    Casein.Terminals.CommandLog.ensure_table!()
    Casein.Terminals.ScrollbackArchive.ensure_table!()
    Casein.Terminals.TemplatePreference.ensure_table!()
    Casein.Terminals.SessionRecovery.ensure_table!()

    # jido_signal extensions self-register only via @after_compile, which
    # never fires for precompiled deps — without this, the trace extension
    # is unknown at runtime and Casein.Signals.from_audit_event/1 raises.
    _ = Jido.Signal.Ext.Registry.register(Jido.Signal.Ext.Trace)

    children =
      [
        CaseinWeb.Telemetry,
        Casein.Repo,
        {DNSCluster, query: Application.get_env(:casein, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Casein.PubSub},
        Casein.Desktop.LaunchReplayStore,
        Casein.Supervision.PlatformServices,
        Casein.Supervision.StateStores,
        Casein.Supervision.Terminals,
        Casein.Supervision.Commands,
        Casein.Supervision.Agents,
        Casein.Supervision.Operator,
        Casein.Supervision.Previews,
        PreviewCtl.Playwright.Bridge,
        Casein.Supervision.Deployment,
        CaseinWeb.Endpoint
      ] ++ desktop_terminal_sessions() ++ preview_tidewave_listener() ++ desktop_status()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Casein.Supervisor]
    res = Supervisor.start_link(children, opts)
    _ = Task.start(fn -> Casein.Files.Janitor.run_on_boot() end)

    res
  end

  defp desktop_powershell? do
    Casein.Desktop.TerminalBackend.native_session?(desktop_mode?())
  end

  defp desktop_terminal_sessions do
    if desktop_powershell?() do
      [
        {Registry, keys: :unique, name: Casein.Desktop.PowerShellSession.Registry},
        {DynamicSupervisor,
         strategy: :one_for_one, name: Casein.Desktop.PowerShellSession.Supervisor}
      ]
    else
      []
    end
  end

  # Ephemeral preview environments boot the endpoint on a unix socket
  # (DEVIDE_HTTP_SOCKET, wired in runtime.exs) so the Caddy preview router can
  # dial them collision-free, mirroring the live /run/devide/current.sock model.
  # But the Tidewave agent integration dials Tidewave over a *loopback TCP* URL
  # (http://127.0.0.1:<port>/tidewave/mcp — see Casein.Agents.TidewaveMCP), which
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
          {Bandit, plug: CaseinWeb.Endpoint, scheme: :http, ip: {127, 0, 0, 1}, port: port},
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
        access = Application.get_env(:casein, :ets_table_access, :protected)
        :ets.new(@fast_path_cache_table, [:named_table, access, :set])

      _ ->
        :ok
    end
  end

  defp configure_tmux_ctl! do
    for {key, value} <- Application.get_env(:casein, :tmux_ctl, []) do
      Application.put_env(:tmux_ctl, key, value)
    end

    # Publish PATH (incl. the Casein shim dirs) synchronously so the first
    # window sees the shim dirs on PATH, then heal the shim FILES off the boot
    # path: ensure_best_effort/0 may shell out to install-agent-shims.sh, and a
    # stalled install must not block start/2 before the Endpoint/Repo come up.
    # Per-pane shell integration and PaneEnv re-heal, so async is a head start,
    # not a correctness dependency.
    Application.put_env(:tmux_ctl, :terminal_env, Casein.Terminals.Shims.env())
    Task.start(fn -> Casein.Terminals.Shims.sync_tmux_terminal_env!() end)

    if Application.get_env(:tmux_ctl, :default_command, :unset) == :unset do
      Application.put_env(:tmux_ctl, :default_command, terminal_shell_command())
    end

    Application.put_env(
      :tmux_ctl,
      :shared_write_guard,
      {Casein.Deployment.Drain, :guard_shared_write}
    )
  end

  # Publishes runtime.json for the desktop host once the endpoint is bound
  # (docs/desktop/platform_architecture.md, "Status contract"). Ordered after
  # CaseinWeb.Endpoint so server_info/1 reports the real port — desktop
  # requests PORT=0. The resolver is injected here because the Casein domain
  # boundary cannot reference CaseinWeb.
  defp desktop_status do
    if desktop_mode?() do
      [{Casein.Desktop.Status, port_resolver: fn -> CaseinWeb.Endpoint.server_info(:http) end}]
    else
      []
    end
  end

  defp desktop_mode?, do: Application.get_env(:casein, :desktop_mode, false)

  defp native_windows?, do: match?({:win32, _}, :os.type())

  defp terminal_shell_command do
    Application.get_env(:casein, :tmux_login_shell_command) ||
      System.get_env("DEV_IDE_TMUX_LOGIN_SHELL") ||
      Casein.Terminals.Shims.shell_command()
  end

  defp configure_git_ctl! do
    base = Application.get_env(:casein, :git_ctl, [])

    merged =
      case Application.get_env(:casein, :git_inspector_cache_ttl_ms) do
        nil -> base
        ttl -> Keyword.put(base, :cache_ttl_ms, ttl)
      end

    for {key, value} <- merged do
      Application.put_env(:git_ctl, key, value)
    end
  end

  defp configure_preview_ctl! do
    base = Application.get_env(:casein, :preview_ctl, [])

    merged =
      base
      |> Keyword.put(:adapter, preview_ctl_adapter())
      |> maybe_put_preview_env(:playwright_script, :preview_playwright_script)

    for {key, value} <- merged do
      Application.put_env(:preview_ctl, key, value)
    end
  end

  defp preview_ctl_adapter do
    case Application.get_env(:casein, :preview_control_adapter, :memory) do
      :playwright -> PreviewCtl.Playwright.Adapter
      _ -> PreviewCtl.Test.FakeAdapter
    end
  end

  defp maybe_put_preview_env(keyword, preview_key, dev_ide_key) do
    case Application.get_env(:casein, dev_ide_key) do
      nil -> keyword
      value -> Keyword.put(keyword, preview_key, value)
    end
  end

  @impl true
  def config_change(changed, _new, removed) do
    CaseinWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
