import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/dev_ide start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
# Test env is exempt from shell-inherited server/listener config: on the
# devbox the live release exports PHX_SERVER/PORT in interactive shells, and
# honoring them here made `mix test` boot a server on :4000 against the live
# instance instead of staying on the test.exs listener.
if config_env() != :test do
  if System.get_env("PHX_SERVER") do
    config :dev_ide, DevIdeWeb.Endpoint, server: true
  end

  devide_http =
    case System.get_env("DEVIDE_HTTP_SOCKET") do
      nil -> [port: String.to_integer(System.get_env("PORT", "4000"))]
      sock -> [ip: {:local, sock}, port: 0]
    end

  config :dev_ide, DevIdeWeb.Endpoint, http: devide_http
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :dev_ide, DevIde.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :dev_ide, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # CSP frame-src for preview-pane iframes. Defaults to unrestricted preview
  # embedding; DEV_IDE_PREVIEW_FRAME_SRC overrides the whole directive when set.
  preview_frame_src =
    System.get_env("DEV_IDE_PREVIEW_FRAME_SRC") ||
      "frame-src * data: blob:"

  config :dev_ide, :preview_frame_src, preview_frame_src

  # Bind address. Defaults to all interfaces for container/k8s deploys that
  # front DevIDE with their own network policy. When DevIDE runs behind a
  # forward-auth reverse proxy, it MUST be unreachable except through that
  # proxy (otherwise a client could spoof the `X-Auth-Request-*` headers
  # directly). Set `PHX_IP=127.0.0.1` (or `::1`) in that case.
  forward_auth? =
    System.get_env("DEV_IDE_FORWARD_AUTH") in ~w(1 true yes) or
      System.get_env("DEV_IDE_ADMINS") not in [nil, ""]

  if forward_auth? do
    config :dev_ide, :forward_auth, true
  end

  bind_ip =
    case System.get_env("PHX_IP") do
      nil ->
        if forward_auth?, do: {127, 0, 0, 1}, else: {0, 0, 0, 0, 0, 0, 0, 0}

      str ->
        case str |> String.to_charlist() |> :inet.parse_address() do
          {:ok, addr} -> addr
          {:error, _} -> raise "PHX_IP is not a valid IP address: #{inspect(str)}"
        end
    end

  http_socket = System.get_env("DEVIDE_HTTP_SOCKET")

  if forward_auth? and is_nil(http_socket) and
       bind_ip not in [{127, 0, 0, 1}, {0, 0, 0, 0, 0, 0, 0, 1}] do
    raise """
    forward-auth is enabled, but PHX_IP binds DevIDE outside loopback.

    Set PHX_IP=127.0.0.1, unset PHX_IP, or run behind DEVIDE_HTTP_SOCKET so
    browser identity headers cannot be spoofed by direct network access.
    """
  end

  on_devbox? = System.get_env("DEV_IDE_ON_DEVBOX") in ~w(1 true yes)

  # Allow WebSocket connections from localhost (Preview MCP browser) when
  # running on-devbox. The loopback preview browser sends Origin:
  # http://localhost:<port>, so production uses an explicit allowlist instead
  # of disabling origin checks.
  check_origin =
    if on_devbox? do
      ["https://#{host}", "//localhost", "//127.0.0.1"]
    else
      true
    end

  http_opts =
    case http_socket do
      nil -> [ip: bind_ip]
      sock -> [ip: {:local, sock}, port: 0]
    end

  config :dev_ide, DevIdeWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: http_opts,
    secret_key_base: secret_key_base,
    check_origin: check_origin

  # ---- DevIDE runtime configuration -----------------------------------
  # These mirror what `audit_remote.md` CC-1 expects every prod boot to
  # validate. The API token is fail-closed (api_auth returns 503 if
  # missing), so we surface that here as a fail-fast on boot instead of
  # discovering it on the first request.

  System.get_env("DEV_IDE_API_TOKEN") ||
    raise """
    environment variable DEV_IDE_API_TOKEN is missing.
    The HTTP API refuses every request with 503 when no token is
    configured. Generate one with: mix phx.gen.secret
    """

  if scoped_tokens = System.get_env("DEV_IDE_WORKSPACE_API_TOKENS") do
    case Jason.decode(scoped_tokens) do
      {:ok, map} when is_map(map) ->
        config :dev_ide, :workspace_api_tokens, map

      _ ->
        raise """
        environment variable DEV_IDE_WORKSPACE_API_TOKENS is invalid.
        Expected JSON object mapping bearer token to workspace_id or list of workspace_ids.
        """
    end
  end

  if root = System.get_env("DEV_IDE_WORKSPACES_ROOT") do
    config :dev_ide, :workspaces_root, root
  end

  positive_integer_env = fn name ->
    case System.get_env(name) do
      value when value in [nil, ""] ->
        nil

      value ->
        case Integer.parse(value) do
          {n, ""} when n > 0 -> n
          _ -> nil
        end
    end
  end

  # Idle GC for `devide_*` tmux sessions. Durable workspace sessions are the
  # default, so session GC is opt-in via env vars rather than enabled by a
  # short production default.
  config :dev_ide,
         :tmux_idle_seconds,
         positive_integer_env.("DEV_IDE_TMUX_IDLE_SECONDS")

  # Periodic sweep for blank, auto-named, never-used windows that pile up
  # *inside* `devide_*` sessions (extra `Ctrl-b c` windows a user opens and
  # abandons, or orphans the subscriber-based session GC can't see after a
  # restart). See DevIDE.Terminals.TmuxWindowJanitor for the kill policy. The
  # sweep is opt-in because DevIDE's primary contract is durable tmux sessions.
  # A window must be idle for the idle window before it's eligible.
  config :dev_ide,
         :tmux_window_sweep_ms,
         positive_integer_env.("DEV_IDE_TMUX_WINDOW_SWEEP_MS")

  config :dev_ide,
         :tmux_window_idle_seconds,
         positive_integer_env.("DEV_IDE_TMUX_WINDOW_IDLE_SECONDS")

  # Same sweep also reaps whole orphaned sessions: blank `devide_*` sessions
  # with no attached client, idle this long, where every pane is just a shell.
  # Catches per-tab sessions left by closed tabs and orphans the restart wiped
  # from the reactive janitor's subscriber map. Per-tab independence is kept —
  # an attached (live) session is never touched.
  config :dev_ide,
         :tmux_session_idle_seconds,
         positive_integer_env.("DEV_IDE_TMUX_SESSION_IDLE_SECONDS")

  preview_script_env =
    case System.get_env("DEV_IDE_PREVIEW_PLAYWRIGHT_SCRIPT") do
      "" -> nil
      value -> value
    end

  preview_artifacts_root_env =
    case System.get_env("DEV_IDE_PREVIEW_ARTIFACTS_ROOT") do
      "" -> nil
      value -> value
    end

  case System.get_env("DEV_IDE_PREVIEW_CONTROL_ADAPTER") do
    adapter when adapter in [nil, ""] ->
      :ok

    "memory" ->
      config :dev_ide, :preview_control_adapter, :memory

    "playwright" ->
      config :dev_ide,
        preview_control_adapter: :playwright,
        preview_playwright_script: preview_script_env || "scripts/preview_playwright.mjs"

    other ->
      raise """
      environment variable DEV_IDE_PREVIEW_CONTROL_ADAPTER is invalid: #{inspect(other)}.
      Expected one of: memory, playwright
      """
  end

  if script = preview_script_env do
    config :dev_ide, :preview_playwright_script, script
  end

  if root = preview_artifacts_root_env do
    config :dev_ide, :preview_artifacts_root, root
  end

  # Default headers injected into preview control sessions when the agent
  # passes none — typically the forward-auth identity so loopback preview
  # fetches don't 401 behind the auth proxy. JSON object env wins over the
  # email shorthand. Caller-provided default_headers always override these.
  preview_default_headers =
    case System.get_env("DEV_IDE_PREVIEW_DEFAULT_HEADERS") do
      json when is_binary(json) and json != "" ->
        case Jason.decode(json) do
          {:ok, headers} when is_map(headers) ->
            headers

          _ ->
            raise """
            environment variable DEV_IDE_PREVIEW_DEFAULT_HEADERS must be a JSON
            object of header name/value pairs, got: #{inspect(json)}
            """
        end

      _ ->
        # Workspace-scoped preview MCP derives headers from the workspace owner
        # at call time (PreviewTools + Workspaces.forward_auth_headers/1).
        # Static env is only for non-workspace preview paths or local dev.
        email =
          System.get_env("DEV_IDE_PREVIEW_FORWARD_AUTH_EMAIL") ||
            if forward_auth? do
              nil
            else
              System.get_env("DEV_IDE_DEVBOX_USER_EMAIL")
            end

        if is_binary(email) and email != "" do
          %{"X-Auth-Request-Email" => email}
        end
    end

  if preview_default_headers do
    config :dev_ide, :preview_default_headers, preview_default_headers
  end

  if domain = System.get_env("DEV_IDE_FORWARD_AUTH_EMAIL_DOMAIN") do
    config :dev_ide, :forward_auth_email_domain, domain
  end

  if modes_json = System.get_env("DEV_IDE_WORKSPACE_MODES") do
    modes =
      modes_json
      |> Jason.decode!()
      |> Map.new(fn {id, mode_str} -> {id, String.to_existing_atom(mode_str)} end)

    config :dev_ide, :workspace_modes, modes
  end

  # Workspace source — the default (`DevIDE.WorkspaceSource.Local`) walks a
  # filesystem root and is right for a single-developer mix phx.server flow.
  # On devbox the source of truth is the milc-devbox manager; without flipping
  # to its WorkspaceSource, deep links from the manager's "DevIDE" buttons
  # land on the empty workspace picker because the local source can't resolve
  # the workspace id as a directory under /workspaces. Two activation paths:
  #
  #   * DEV_IDE_WORKSPACE_SOURCE=manager|local   — explicit override.
  #   * DEV_IDE_ON_DEVBOX=true                   — auto-detect on devbox
  #                                                (same flag the integration
  #                                                already uses for path
  #                                                resolution and docker exec).
  on_devbox? = System.get_env("DEV_IDE_ON_DEVBOX") in ["true", "1", "yes"]

  case System.get_env("DEV_IDE_WORKSPACE_SOURCE") do
    "manager" ->
      config :dev_ide, :workspace_source, DevIDE.Integrations.Manager.WorkspaceSource

    "local" ->
      config :dev_ide, :workspace_source, DevIDE.WorkspaceSource.Local

    nil when on_devbox? ->
      config :dev_ide, :workspace_source, DevIDE.Integrations.Manager.WorkspaceSource

    _ ->
      :ok
  end

  if on_devbox? do
    config :dev_ide, :on_devbox, true

    unless Application.get_env(:dev_ide, :forward_auth_email_domain) do
      config :dev_ide, :forward_auth_email_domain, "milcgroup.com"
    end

    config :dev_ide, :preview_loopback_port, String.to_integer(System.get_env("PORT") || "4000")

    preview_app_url =
      case System.get_env("DEVIDE_URL") do
        url when is_binary(url) and url != "" -> url
        _ -> "https://#{host}"
      end

    config :dev_ide, :preview_app_url, preview_app_url
  end

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :dev_ide, DevIdeWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :dev_ide, DevIdeWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :dev_ide, DevIde.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://hexdocs.pm/swoosh/Swoosh.html#module-installation for details.
end
