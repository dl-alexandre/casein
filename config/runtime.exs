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
#     PHX_SERVER=true bin/casein start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
# Test env is exempt from shell-inherited server/listener config: on the
# devbox the live release exports PHX_SERVER/PORT in interactive shells, and
# honoring them here made `mix test` boot a server on :4000 against the live
# instance instead of staying on the test.exs listener.
truthy_env? = fn name ->
  System.get_env(name) in ~w(1 true TRUE yes YES on ON)
end

falsey_env? = fn name ->
  System.get_env(name) in ~w(0 false FALSE no NO off OFF)
end

lan_insecure_http? = truthy_env?.("CASEIN_LAN_INSECURE_HTTP")
lan_mode? = truthy_env?.("CASEIN_LAN") or lan_insecure_http?
release_cli? = truthy_env?.("CASEIN_RELEASE_CLI")
desktop_mode? = System.get_env("CASEIN_PROFILE") == "desktop"
desktop_lan? = desktop_mode? and truthy_env?.("CASEIN_DESKTOP_LAN")
portable_mode? = System.get_env("CASEIN_PROFILE") == "portable"

# Optional, exact-path public desktop downloads. Casein never scans this
# directory and exposes no upload or arbitrary-path route: an operator must
# explicitly name each file that may be served.
config :casein, :desktop_downloads,
  windows: [
    path: System.get_env("CASEIN_WINDOWS_DOWNLOAD_PATH"),
    sha256: System.get_env("CASEIN_WINDOWS_DOWNLOAD_SHA256")
  ]

operator_config_path = System.get_env("CASEIN_OPERATOR_CONFIG_FILE")
operator_overlay? = is_binary(operator_config_path) and operator_config_path != ""

operator_config =
  if operator_overlay? do
    Casein.Deployment.OperatorConfig.load!(operator_config_path)
  else
    []
  end

config :casein,
       :desktop_terminal_backend,
       Casein.Desktop.TerminalBackend.default(:os.type())

# SECURITY: allow a :global orchestrator token to make MCP `tools/call`
# requests box-wide. Default off — tool execution normally requires a
# workspace-scoped token so a leaked global token can't become box-wide RCE
# via MCP. Enable only on a single-tenant box you fully trust.
config :casein,
       :allow_global_mcp_tool_calls,
       truthy_env?.("CASEIN_ALLOW_GLOBAL_MCP_TOOL_CALLS")

mobile_terminal_allowlist = fn name ->
  name
  |> System.get_env("")
  |> String.split(",", trim: true)
  |> Enum.map(&String.trim/1)
  |> Enum.reject(&(&1 == ""))
  |> Enum.uniq()
end

# Raw mobile terminal access is an elevated deployment capability. Keep both
# switches fail-closed: enabling requires an explicit deployment flag, an
# explicit kill-switch release, and exact user/device/workspace allowlists.
config :casein, :mobile_terminal,
  enabled: truthy_env?.("CASEIN_MOBILE_TERMINAL_ENABLED"),
  kill_switch: not falsey_env?.("CASEIN_MOBILE_TERMINAL_KILL_SWITCH"),
  user_ids: mobile_terminal_allowlist.("CASEIN_MOBILE_TERMINAL_USER_IDS"),
  device_link_ids: mobile_terminal_allowlist.("CASEIN_MOBILE_TERMINAL_DEVICE_LINK_IDS"),
  workspace_ids: mobile_terminal_allowlist.("CASEIN_MOBILE_TERMINAL_WORKSPACE_IDS")

# When on, MCP `tools/list` advertises only a small core set + the search_tools
# / invoke_tool meta-tools instead of every tool, to cut context and improve
# tool selection on large surfaces. Off by default (full tool list). The
# meta-tools are always callable; this only changes what tools/list advertises.
config :casein, :mcp_tool_search, truthy_env?.("CASEIN_MCP_TOOL_SEARCH")

# When on, the terminal MCP server advertises the read-only workspace_digest
# tool (operator situation digest: sessions, worktrees, deploy, activity,
# risks) in tools/list. Off by default while the digest shape settles; the
# tool stays callable by name either way.
config :casein, :workspace_digest, truthy_env?.("CASEIN_WORKSPACE_DIGEST")

# When on, workspace_digest is served by a live per-workspace
# Casein.Operator.SituationServer (event-fed digest + stateful risk detectors
# broadcasting on "situation:<ws>") started on the first digest request.
# Off by default: the digest cold-builds per call and no server is started.
config :casein, :situation_server, truthy_env?.("CASEIN_SITUATION_SERVER")

# When on, Casein.Ops.PgProbe polls the box's Postgres servers (host 5432 +
# release 15432 by default) for connection saturation and leak-shaped
# application_names (wf_*, casein-<uuid>), emitting ops.pg_saturation_*
# audit rows and "ops:health" broadcasts on threshold transitions. Off by
# default — it shells out to psql once per interval.
config :casein, :pg_probe, truthy_env?.("CASEIN_PG_PROBE")

# When on, start the host-tmux control-mode listener and wire topology
# watchers to event-triggered refreshes (reconcile poll remains). Default
# off — flag-off path is byte-identical to pure 300ms polling.
# Rollback: CASEIN_TMUX_EVENTS=0. Only applied when the env var is set, so
# a config-file default (e.g. flipping dev/test on) survives unset envs.
if System.get_env("CASEIN_TMUX_EVENTS") do
  config :casein, :tmux_events, truthy_env?.("CASEIN_TMUX_EVENTS")
end

# Probe targets as JSON, e.g.
# [{"host":"127.0.0.1","port":5432,"user":"postgres","dbname":"postgres"}].
# Parsed by PgProbe at runtime; invalid JSON falls back to the defaults.
if pg_probe_targets = System.get_env("CASEIN_PG_PROBE_TARGETS") do
  config :casein, :pg_probe_targets_json, pg_probe_targets
end

if pg_probe_user = System.get_env("CASEIN_PG_PROBE_USER") do
  config :casein, :pg_probe_user, pg_probe_user
end

if pg_probe_dbname = System.get_env("CASEIN_PG_PROBE_DBNAME") do
  config :casein, :pg_probe_dbname, pg_probe_dbname
end

if pg_probe_password = System.get_env("CASEIN_PG_PROBE_PASSWORD") do
  config :casein, :pg_probe_password, pg_probe_password
end

# Comma-separated globs (relative to the workspace root and each agent
# worktree root) naming freeze-skill sentinel files. The situation digest only
# *reports* matching sentinels as frozen_scopes; nothing is enforced. Default:
# the elixir-phoenix freeze skill's `.claude/.freeze` convention.
if freeze_globs = System.get_env("CASEIN_FREEZE_SENTINEL_GLOBS") do
  config :casein, :freeze_sentinel_globs, String.split(freeze_globs, ",", trim: true)
end

lan_http_host = fn ->
  case System.get_env("CASEIN_LAN_HOST") do
    host when is_binary(host) and host != "" ->
      host

    _ ->
      case :inet.gethostname() do
        {:ok, name} ->
          short =
            name
            |> to_string()
            |> String.split(".")
            |> List.first()

          case short do
            nil -> "localhost"
            "" -> "localhost"
            short -> "#{short}.local"
          end

        {:error, _} ->
          "localhost"
      end
  end
end

lan_http_ips = fn ->
  (System.get_env("CASEIN_LAN_IPS") || System.get_env("CASEIN_LAN_IP") || "")
  |> String.split(",", trim: true)
  |> Enum.map(&String.trim/1)
  |> Enum.reject(&(&1 == ""))
  |> Enum.uniq()
end

if config_env() != :test do
  if System.get_env("PHX_SERVER") do
    config :casein, CaseinWeb.Endpoint, server: true
  end

  if lan_mode? do
    config :casein, :lan_mode, true

    if lan_insecure_http? do
      config :casein, :lan_insecure_http, true
      config :casein, :session_same_site, nil
    end
  end

  if portable_mode? or lan_mode? do
    config :casein, deployment_capabilities: []
  else
    if operator_overlay? do
      config :casein,
        deployment_capabilities:
          Casein.Deployment.OperatorConfig.deployment_capabilities(operator_config)
    end
  end

  if desktop_mode? do
    desktop_launch_token =
      System.get_env("CASEIN_DESKTOP_LAUNCH_TOKEN") ||
        raise "CASEIN_PROFILE=desktop requires CASEIN_DESKTOP_LAUNCH_TOKEN"

    if byte_size(desktop_launch_token) < 32 do
      raise "CASEIN_DESKTOP_LAUNCH_TOKEN must contain at least 32 bytes"
    end

    config :casein,
      desktop_mode: true,
      desktop_lan: desktop_lan?,
      desktop_lan_hosts:
        if(desktop_lan?,
          do: [lan_http_host.() | lan_http_ips.()],
          else: []
        ),
      desktop_launch_token: desktop_launch_token,
      deployment_capabilities: [],
      tmux_host_anchor: false,
      secure_session_cookie: false,
      session_cookie_key: "_casein_desktop_key"
  end

  if default_workspace = System.get_env("CASEIN_DEFAULT_WORKSPACE") do
    config :casein, :default_workspace, default_workspace
  else
    if lan_mode? do
      config :casein, :default_workspace, "home"
    end
  end

  if config_env() == :dev do
    if sock = System.get_env("CASEIN_HTTP_SOCKET") do
      config :casein, CaseinWeb.Endpoint, http: [ip: {:local, sock}, port: 0]
    end
  else
    casein_http =
      case System.get_env("CASEIN_HTTP_SOCKET") do
        nil -> [port: String.to_integer(System.get_env("PORT", "4000"))]
        sock -> [ip: {:local, sock}, port: 0]
      end

    config :casein, CaseinWeb.Endpoint, http: casein_http
  end

  present_env = fn name ->
    case System.get_env(name) do
      nil -> nil
      "" -> nil
      value -> value
    end
  end

  push_provider = present_env.("CASEIN_PUSH_PROVIDER")

  fcm_enabled? =
    push_provider in ["fcm", "firebase", "native"] or
      not is_nil(present_env.("CASEIN_FCM_PROJECT_ID"))

  apns_enabled? =
    push_provider in ["apns", "native"] or
      not is_nil(present_env.("CASEIN_APNS_TEAM_ID")) or
      not is_nil(present_env.("CASEIN_APNS_KEY_ID")) or
      not is_nil(present_env.("CASEIN_APNS_PRIVATE_KEY")) or
      not is_nil(present_env.("CASEIN_APNS_PRIVATE_KEY_PATH"))

  if fcm_enabled? do
    fcm_provider_config =
      [
        project_id: present_env.("CASEIN_FCM_PROJECT_ID"),
        access_token_fun: {Casein.Push.FCMToken, :access_token, []}
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    fcm_token_config =
      [
        access_token: present_env.("CASEIN_FCM_ACCESS_TOKEN"),
        service_account_json: present_env.("CASEIN_FCM_SERVICE_ACCOUNT_JSON"),
        service_account_path:
          present_env.("CASEIN_FCM_SERVICE_ACCOUNT_PATH") ||
            present_env.("GOOGLE_APPLICATION_CREDENTIALS"),
        token_uri: present_env.("CASEIN_FCM_TOKEN_URI")
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    config :casein, Casein.Push.FCMProvider, fcm_provider_config
    config :casein, Casein.Push.FCMToken, fcm_token_config
  end

  if apns_enabled? do
    apns_provider_config =
      [
        team_id: present_env.("CASEIN_APNS_TEAM_ID"),
        key_id: present_env.("CASEIN_APNS_KEY_ID"),
        topic: present_env.("CASEIN_APNS_TOPIC"),
        private_key: present_env.("CASEIN_APNS_PRIVATE_KEY"),
        private_key_path: present_env.("CASEIN_APNS_PRIVATE_KEY_PATH"),
        environment: present_env.("CASEIN_APNS_ENV") || "sandbox"
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    config :casein, Casein.Push.APNSProvider, apns_provider_config
  end

  # Web Push (VAPID) for the installed PWA. Keys are base64url; decode at boot so
  # a malformed value fails fast instead of at first push. Provider stays inert
  # (unconfigured) unless BOTH keys decode.
  decode_vapid = fn
    nil ->
      nil

    value ->
      case Base.url_decode64(value, padding: false) do
        {:ok, bin} -> bin
        :error -> nil
      end
  end

  vapid_public = decode_vapid.(present_env.("CASEIN_VAPID_PUBLIC_KEY"))
  vapid_private = decode_vapid.(present_env.("CASEIN_VAPID_PRIVATE_KEY"))
  vapid_subject = present_env.("CASEIN_VAPID_SUBJECT") || "mailto:admin@localhost"

  web_push_enabled? = not is_nil(vapid_public) and not is_nil(vapid_private)

  if web_push_enabled? do
    config :casein, Casein.Push.WebPushProvider, %{
      public_key: vapid_public,
      private_key: vapid_private,
      subject: vapid_subject
    }
  end

  cond do
    push_provider in ["apns"] ->
      config :casein, :push_provider, Casein.Push.APNSProvider

    push_provider in ["fcm", "firebase"] ->
      config :casein, :push_provider, Casein.Push.FCMProvider

    # Native wins when explicitly selected or any native transport is configured:
    # NativeProvider now also routes "web" → WebPushProvider (its config is set
    # above whenever VAPID keys are present), so APNs/FCM and Web Push coexist.
    push_provider in ["native"] or fcm_enabled? or apns_enabled? ->
      config :casein, :push_provider, Casein.Push.NativeProvider

    # Web-only: no native transport configured, just VAPID keys.
    push_provider in ["web"] or web_push_enabled? ->
      config :casein, :push_provider, Casein.Push.WebPushProvider

    true ->
      :ok
  end
end

if config_env() == :prod and not release_cli? do
  repo_adapter = Application.compile_env(:casein, :repo_adapter, Ecto.Adapters.Postgres)

  if repo_adapter == Ecto.Adapters.SQLite3 do
    database_path =
      System.get_env("DATABASE_PATH") ||
        System.get_env("SQLITE_DATABASE_PATH") ||
        cond do
          desktop_mode? ->
            Casein.Desktop.Runtime.database_path()

          lan_mode? ->
            "/var/lib/casein/lan/casein.sqlite3"

          true ->
            raise """
            environment variable DATABASE_PATH is missing for SQLite releases.
            For local LAN mode, casein lan up writes DATABASE_PATH automatically.
            """
        end

    config :casein, Casein.Repo,
      database: database_path,
      journal_mode: :delete,
      pool_size: String.to_integer(System.get_env("POOL_SIZE") || "1"),
      busy_timeout: String.to_integer(System.get_env("SQLITE_BUSY_TIMEOUT_MS") || "5000")
  else
    if desktop_mode? do
      raise """
      CASEIN_PROFILE=desktop requires a SQLite-compiled release.
      Rebuild with CASEIN_REPO_ADAPTER=sqlite and CASEIN_RELEASE_PROFILE=desktop.
      """
    end

    database_url =
      System.get_env("DATABASE_URL") ||
        raise """
        environment variable DATABASE_URL is missing.
        For example: ecto://USER:PASS@HOST/DATABASE
        """

    maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

    config :casein, Casein.Repo,
      # ssl: true,
      url: database_url,
      pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
      # For machines with several cores, consider starting multiple pools of `pool_size`
      # pool_count: 4,
      socket_options: maybe_ipv6
  end

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

  config :casein, :origin_identity_secret, secret_key_base

  host = System.get_env("PHX_HOST") || "example.com"

  config :casein, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # CSP frame-src for preview-pane iframes. Defaults to unrestricted preview
  # embedding; CASEIN_PREVIEW_FRAME_SRC overrides the whole directive when set.
  preview_frame_src =
    System.get_env("CASEIN_PREVIEW_FRAME_SRC") ||
      "frame-src * data: blob:"

  config :casein, :preview_frame_src, preview_frame_src

  # Own-origin previews (`pv-<port>-<workspace>.<domain>`). Requires the edge
  # `pv-*` route from scripts/preview-router.sh to be live, so it is switched on
  # per-deployment rather than by default. See `Casein.Previews.OwnOrigin`.
  config :casein, :preview_own_origin,
    enabled: System.get_env("CASEIN_PREVIEW_OWN_ORIGIN", "0") in ~w(1 true yes),
    domain: System.get_env("CASEIN_PREVIEW_DOMAIN", "devbox.milcgroup.com")

  # Bind address. Defaults to all interfaces for container/k8s deploys that
  # front Casein with their own network policy. When Casein runs behind a
  # forward-auth reverse proxy, it MUST be unreachable except through that
  # proxy (otherwise a client could spoof the `X-Auth-Request-*` headers
  # directly). Set `PHX_IP=127.0.0.1` (or `::1`) in that case.
  forward_auth? =
    System.get_env("CASEIN_FORWARD_AUTH") in ~w(1 true yes) or
      System.get_env("CASEIN_ADMINS") not in [nil, ""]

  if forward_auth? do
    config :casein, :forward_auth, true
  end

  bind_ip =
    case {desktop_mode?, desktop_lan?, System.get_env("PHX_IP")} do
      {true, false, nil} ->
        {127, 0, 0, 1}

      {true, false, str} when str not in ["127.0.0.1", "::1"] ->
        raise "CASEIN_PROFILE=desktop requires PHX_IP to be loopback"

      {true, false, str} ->
        case str |> String.to_charlist() |> :inet.parse_address() do
          {:ok, addr} -> addr
          {:error, _} -> raise "PHX_IP is not a valid IP address: #{inspect(str)}"
        end

      {true, true, nil} ->
        {0, 0, 0, 0}

      {true, true, str} ->
        case str |> String.to_charlist() |> :inet.parse_address() do
          {:ok, addr} -> addr
          {:error, _} -> raise "PHX_IP is not a valid IP address: #{inspect(str)}"
        end

      {false, _desktop_lan, nil} ->
        if forward_auth? or lan_insecure_http?,
          do: {127, 0, 0, 1},
          else: {0, 0, 0, 0, 0, 0, 0, 0}

      {false, _desktop_lan, str} ->
        case str |> String.to_charlist() |> :inet.parse_address() do
          {:ok, addr} -> addr
          {:error, _} -> raise "PHX_IP is not a valid IP address: #{inspect(str)}"
        end
    end

  http_socket = System.get_env("CASEIN_HTTP_SOCKET")

  if forward_auth? and is_nil(http_socket) and
       bind_ip not in [{127, 0, 0, 1}, {0, 0, 0, 0, 0, 0, 0, 1}] do
    raise """
    forward-auth is enabled, but PHX_IP binds Casein outside loopback.

    Set PHX_IP=127.0.0.1, unset PHX_IP, or run behind CASEIN_HTTP_SOCKET so
    browser identity headers cannot be spoofed by direct network access.
    """
  end

  on_devbox? = System.get_env("CASEIN_ON_DEVBOX") in ~w(1 true yes)
  canonical_devbox_host = "casein.devbox.milcgroup.com"

  if on_devbox? and host != canonical_devbox_host do
    raise """
    CASEIN_ON_DEVBOX requires PHX_HOST=#{canonical_devbox_host}; got #{inspect(host)}.
    Legacy public hosts must not mint, exchange, rotate, or revoke mobile credentials.
    """
  end

  if on_devbox? do
    config :casein, :canonical_public_origin, "https://#{canonical_devbox_host}"

    # Retired hosts that the edge proxy still answers for. Browser navigations
    # are redirected to the canonical origin; credential-bearing requests keep
    # failing closed above.
    config :casein, :deprecated_public_hosts, ["devide.devbox.milcgroup.com"]
  end

  # Allow WebSocket connections from localhost (Preview MCP browser) when
  # running on-devbox. The loopback preview browser sends Origin:
  # http://localhost:<port>, so production uses an explicit allowlist instead
  # of disabling origin checks. LAN mode accepts local-network hostnames that
  # are selected at install time.
  check_origin =
    cond do
      desktop_lan? ->
        CaseinWeb.OriginOptions.desktop_lan(
          Casein.Desktop.Runtime.requested_port(),
          lan_http_host.(),
          lan_http_ips.()
        )

      desktop_mode? ->
        CaseinWeb.OriginOptions.desktop(Casein.Desktop.Runtime.requested_port())

      lan_mode? ->
        CaseinWeb.OriginOptions.lan(lan_http_host.(),
          scheme: if(lan_insecure_http?, do: "http", else: "https"),
          port:
            String.to_integer(
              System.get_env(
                if(lan_insecure_http?,
                  do: "CASEIN_LAN_INSECURE_HTTP_PORT",
                  else: "CASEIN_LAN_HTTPS_PORT"
                )
              ) || if(lan_insecure_http?, do: "80", else: "443")
            ),
          lan_ip: System.get_env("CASEIN_LAN_IP")
        )

      on_devbox? ->
        CaseinWeb.OriginOptions.on_devbox(host)

      true ->
        true
    end

  http_opts =
    case http_socket do
      nil when desktop_mode? -> [ip: bind_ip, port: Casein.Desktop.Runtime.requested_port()]
      nil -> [ip: bind_ip]
      sock -> [ip: {:local, sock}, port: 0]
    end

  endpoint_url =
    cond do
      desktop_lan? ->
        [
          host: lan_http_host.(),
          port: Casein.Desktop.Runtime.requested_port(),
          scheme: "http"
        ]

      desktop_mode? ->
        [host: "localhost", scheme: "http"]

      lan_insecure_http? ->
        [
          host: lan_http_host.(),
          port: String.to_integer(System.get_env("CASEIN_LAN_INSECURE_HTTP_PORT") || "80"),
          scheme: "http"
        ]

      true ->
        [host: host, port: 443, scheme: "https"]
    end

  runtime_force_ssl? =
    cond do
      desktop_mode? -> false
      lan_insecure_http? -> false
      falsey_env?.("CASEIN_FORCE_SSL") -> false
      true -> true
    end

  config :casein,
    runtime_force_ssl: runtime_force_ssl?,
    runtime_force_ssl_options: [
      rewrite_on: [:x_forwarded_proto],
      exclude: [
        hosts: ["localhost", "127.0.0.1"]
      ]
    ]

  config :casein, CaseinWeb.Endpoint,
    url: endpoint_url,
    http: http_opts,
    secret_key_base: secret_key_base,
    check_origin: check_origin

  # ---- Casein runtime configuration -----------------------------------
  # These mirror what `audit_remote.md` CC-1 expects every prod boot to
  # validate. The API token is fail-closed (api_auth returns 503 if
  # missing), so we surface that here as a fail-fast on boot instead of
  # discovering it on the first request.

  System.get_env("CASEIN_API_TOKEN") ||
    raise """
    environment variable CASEIN_API_TOKEN is missing.
    The HTTP API refuses every request with 503 when no token is
    configured. Generate one with: mix phx.gen.secret
    """

  if origin_id = System.get_env("CASEIN_ORIGIN_ID") do
    config :casein, :origin_id, origin_id
  end

  if origin_name = System.get_env("CASEIN_ORIGIN_DISPLAY_NAME") do
    config :casein, :origin_display_name, origin_name
  end

  env_workspace_tokens =
    case System.get_env("CASEIN_WORKSPACE_API_TOKENS") do
      nil ->
        %{}

      scoped_tokens ->
        case Jason.decode(scoped_tokens) do
          {:ok, map} when is_map(map) ->
            map

          _ ->
            raise """
            environment variable CASEIN_WORKSPACE_API_TOKENS is invalid.
            Expected JSON object mapping bearer token to workspace_id or list of workspace_ids.
            """
        end
    end

  # Workspace tokens minted at runtime (Casein.Agents.WorkspaceTokens) persist
  # to this store so they survive restarts; the path must match
  # WorkspaceTokens.store_path/0. Env-provided tokens win on conflict.
  workspace_tokens_store =
    Path.join(System.get_env("HOME") || "/home/devbox", ".casein/workspace-api-tokens.json")

  stored_workspace_tokens =
    with true <- File.regular?(workspace_tokens_store),
         {:ok, body} <- File.read(workspace_tokens_store),
         {:ok, map} when is_map(map) <- Jason.decode(body) do
      map
    else
      _ -> %{}
    end

  workspace_tokens = Map.merge(stored_workspace_tokens, env_workspace_tokens)

  if map_size(workspace_tokens) > 0 do
    config :casein, :workspace_api_tokens, workspace_tokens
  end

  if root = System.get_env("CASEIN_WORKSPACES_ROOT") do
    config :casein, :workspaces_root, root
  end

  if root = System.get_env("CASEIN_LAN_PATH_ROOT") do
    config :casein, :lan_path_root, root
  end

  case System.get_env("CASEIN_HOME_WORKSPACE_PATH") do
    home_workspace_path when is_binary(home_workspace_path) and home_workspace_path != "" ->
      config :casein, :home_workspace_path, home_workspace_path

      config :casein,
             :lan_path_root,
             System.get_env("CASEIN_LAN_PATH_ROOT") || home_workspace_path

    _ ->
      :ok
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

  boolean_env? = fn name ->
    System.get_env(name) in ~w(1 true yes)
  end

  # Fail-safe default: raw terminal input requires local host + manual workspace
  # mode unless this deployment explicitly opts into raw everywhere.
  config :casein,
         :raw_terminal_everywhere,
         boolean_env?.("CASEIN_RAW_TERMINAL_EVERYWHERE")

  config :casein,
         :mcp_max_body_bytes,
         positive_integer_env.("CASEIN_MCP_MAX_BODY_BYTES")

  # Deployment-wide kill switch for auto-applying a review-agent run's own
  # proposal (Casein.Proposals.AutoApply). Off by default — even a workspace
  # with an active per-workspace unlock (Workspaces.grant_agent_write_unlock/3)
  # auto-applies nothing until an operator explicitly opts the whole
  # deployment in here.
  config :casein,
         Casein.Proposals.AutoApply,
         enabled: boolean_env?.("CASEIN_AGENT_AUTO_APPLY_ENABLED")

  # Idle GC for `casein_*` tmux sessions. Durable workspace sessions are the
  # default, so session GC is opt-in via env vars rather than enabled by a
  # short production default.
  config :casein,
         :tmux_idle_seconds,
         positive_integer_env.("CASEIN_TMUX_IDLE_SECONDS")

  # Periodic sweep for blank, auto-named, never-used windows that pile up
  # *inside* `casein_*` sessions (extra `Ctrl-b c` windows a user opens and
  # abandons, or orphans the subscriber-based session GC can't see after a
  # restart). See Casein.Terminals.TmuxWindowJanitor for the kill policy. The
  # sweep is opt-in because Casein's primary contract is durable tmux sessions.
  # A window must be idle for the idle window before it's eligible.
  config :casein,
         :tmux_window_sweep_ms,
         positive_integer_env.("CASEIN_TMUX_WINDOW_SWEEP_MS")

  config :casein,
         :tmux_window_idle_seconds,
         positive_integer_env.("CASEIN_TMUX_WINDOW_IDLE_SECONDS")

  # Same sweep also reaps whole orphaned sessions: blank `casein_*` sessions
  # with no attached client, idle this long, where every pane is just a shell.
  # Catches per-tab sessions left by closed tabs and orphans the restart wiped
  # from the reactive janitor's subscriber map. Per-tab independence is kept —
  # an attached (live) session is never touched.
  config :casein,
         :tmux_session_idle_seconds,
         positive_integer_env.("CASEIN_TMUX_SESSION_IDLE_SECONDS")

  # Agent-worktree runtime reaper: expires stale `terminal_report_worktree`
  # records and tears down clean, idle worktrees so the pane picker does not
  # accumulate one tab per agent launch. Enabled by default in prod; set
  # CASEIN_RUNTIME_REAPER_ENABLED=0 to disable or DRY_RUN=1 for log-only.
  runtime_reaper_enabled? =
    case System.get_env("CASEIN_RUNTIME_REAPER_ENABLED") do
      value when value in ~w(0 false FALSE no NO off OFF) -> false
      _ -> true
    end

  runtime_reaper_dry_run? =
    case System.get_env("CASEIN_RUNTIME_REAPER_DRY_RUN") do
      value when value in ~w(1 true TRUE yes YES on ON) -> true
      _ -> false
    end

  config :casein, :runtime_reaper_enabled, runtime_reaper_enabled?
  config :casein, :runtime_reaper_dry_run, runtime_reaper_dry_run?

  config :casein,
         :runtime_reaper_ttl_seconds,
         positive_integer_env.("CASEIN_RUNTIME_REAPER_TTL_SECONDS") || 6 * 60 * 60

  config :casein,
         :runtime_reaper_sweep_interval_ms,
         positive_integer_env.("CASEIN_RUNTIME_REAPER_SWEEP_INTERVAL_MS") || 3_600_000

  # Workspace reconciler — retires persisted workspace records the devbox
  # manager has stopped listing (deleted workspaces otherwise linger in the
  # sidebar forever). Only ever acts under the Manager source; see
  # `Casein.Workspaces.Reconciler`. Off by default, and dry-run unless told
  # otherwise, so a deploy starts by logging its plan. Env names keep the
  # frozen CASEIN_ operator prefix, matching the runtime reaper above.
  config :casein,
         :workspace_reconciler_enabled,
         System.get_env("CASEIN_WORKSPACE_RECONCILER_ENABLED") in ~w(1 true TRUE yes YES on ON)

  config :casein,
         :workspace_reconciler_dry_run,
         System.get_env("CASEIN_WORKSPACE_RECONCILER_DRY_RUN") not in ~w(0 false FALSE no NO off OFF)

  config :casein,
         :workspace_reconciler_grace_ms,
         positive_integer_env.("CASEIN_WORKSPACE_RECONCILER_GRACE_MS") || 30 * 60 * 1_000

  config :casein,
         :workspace_reconciler_sweep_interval_ms,
         positive_integer_env.("CASEIN_WORKSPACE_RECONCILER_SWEEP_INTERVAL_MS") || 3_600_000

  # Identity the reconciler presents to the manager. An admin email widens its
  # listing to every user's workspaces; without one it safely reconciles only
  # the workspaces of whichever user the manager resolves it to.
  if admin_email = System.get_env("CASEIN_WORKSPACE_RECONCILER_ADMIN_EMAIL") do
    config :casein, :workspace_reconciler_admin_email, admin_email
  end

  deployment_config =
    :casein
    |> Application.get_env(:deployment, [])
    |> then(fn config ->
      if operator_overlay? do
        Casein.Deployment.OperatorConfig.deployment(config, operator_config)
      else
        config
      end
    end)
    |> then(fn config ->
      case System.get_env("CASEIN_DEPLOY_WEBHOOK_SECRET") do
        secret when is_binary(secret) and secret != "" ->
          Keyword.put(config, :github_webhook_secret, secret)

        _ ->
          config
      end
    end)
    |> then(fn config ->
      case System.get_env("CASEIN_GITHUB_REPO") do
        repo when is_binary(repo) and repo != "" -> Keyword.put(config, :github_repo, repo)
        _ -> config
      end
    end)

  config :casein, :deployment, deployment_config

  preview_script_env =
    case System.get_env("CASEIN_PREVIEW_PLAYWRIGHT_SCRIPT") do
      "" -> nil
      value -> value
    end

  preview_artifacts_root_env =
    case System.get_env("CASEIN_PREVIEW_ARTIFACTS_ROOT") do
      "" -> nil
      value -> value
    end

  artifact_projects_root_env =
    case System.get_env("CASEIN_ARTIFACT_PROJECTS_ROOT") do
      "" -> nil
      value -> value
    end

  case System.get_env("CASEIN_PREVIEW_CONTROL_ADAPTER") do
    adapter when adapter in [nil, ""] ->
      :ok

    "memory" ->
      config :casein, :preview_control_adapter, :memory

    "playwright" ->
      config :casein,
        preview_control_adapter: :playwright,
        preview_playwright_script: preview_script_env || "scripts/preview_playwright.mjs"

    other ->
      raise """
      environment variable CASEIN_PREVIEW_CONTROL_ADAPTER is invalid: #{inspect(other)}.
      Expected one of: memory, playwright
      """
  end

  if script = preview_script_env do
    config :casein, :preview_playwright_script, script
  end

  if root = preview_artifacts_root_env do
    config :casein, :preview_artifacts_root, root
  end

  if root = artifact_projects_root_env do
    config :casein, :artifact_projects_root, root
  end

  # Default headers injected into preview control sessions when the agent
  # passes none — typically the forward-auth identity so loopback preview
  # fetches don't 401 behind the auth proxy. JSON object env wins over the
  # email shorthand. Caller-provided default_headers always override these.
  preview_default_headers =
    case System.get_env("CASEIN_PREVIEW_DEFAULT_HEADERS") do
      json when is_binary(json) and json != "" ->
        case Jason.decode(json) do
          {:ok, headers} when is_map(headers) ->
            headers

          _ ->
            raise """
            environment variable CASEIN_PREVIEW_DEFAULT_HEADERS must be a JSON
            object of header name/value pairs, got: #{inspect(json)}
            """
        end

      _ ->
        # Workspace-scoped preview MCP derives headers from the workspace owner
        # at call time (PreviewTools + Workspaces.forward_auth_headers/1).
        # Static env is only for non-workspace preview paths or local dev.
        email =
          System.get_env("CASEIN_PREVIEW_FORWARD_AUTH_EMAIL") ||
            if forward_auth? do
              nil
            else
              System.get_env("CASEIN_DEVBOX_USER_EMAIL")
            end

        if is_binary(email) and email != "" do
          %{"X-Auth-Request-Email" => email}
        end
    end

  if preview_default_headers do
    config :casein, :preview_default_headers, preview_default_headers
  end

  if domain = System.get_env("CASEIN_FORWARD_AUTH_EMAIL_DOMAIN") do
    config :casein, :forward_auth_email_domain, domain
  end

  if modes_json = System.get_env("CASEIN_WORKSPACE_MODES") do
    modes =
      modes_json
      |> Jason.decode!()
      |> Map.new(fn {id, mode_str} -> {id, String.to_existing_atom(mode_str)} end)

    config :casein, :workspace_modes, modes
  end

  # Workspace source — the default (`Casein.WorkspaceSource.Local`) walks a
  # filesystem root and is right for a single-developer mix phx.server flow.
  # On devbox the source of truth is the milc-devbox manager; without flipping
  # to its WorkspaceSource, deep links from the manager's "Casein" buttons
  # land on the empty workspace picker because the local source can't resolve
  # the workspace id as a directory under /workspaces. Two activation paths:
  #
  #   * CASEIN_WORKSPACE_SOURCE=manager|local   — explicit override.
  #   * CASEIN_ON_DEVBOX=true                   — auto-detect on devbox
  #                                                (same flag the integration
  #                                                already uses for path
  #                                                resolution and docker exec).
  on_devbox? = System.get_env("CASEIN_ON_DEVBOX") in ["true", "1", "yes"]

  case System.get_env("CASEIN_WORKSPACE_SOURCE") do
    "manager" ->
      config :casein, :workspace_source, Casein.WorkspaceSource.Manager

    "local" ->
      config :casein, :workspace_source, Casein.WorkspaceSource.Local

    nil when on_devbox? ->
      config :casein, :workspace_source, Casein.WorkspaceSource.Manager

    _ ->
      :ok
  end

  if on_devbox? do
    config :casein, :on_devbox, true

    unless Application.get_env(:casein, :forward_auth_email_domain) do
      config :casein, :forward_auth_email_domain, "milcgroup.com"
    end

    config :casein, :preview_loopback_port, String.to_integer(System.get_env("PORT") || "4000")

    # Managed Devbox links follow the already-enforced canonical PHX_HOST.
    # CASEIN_URL historically described a workspace preview origin, so it must
    # not drive credential-bearing API/MCP URLs or cockpit deep links.
    canonical_devbox_url = "https://#{host}"
    config :casein, :preview_app_url, canonical_devbox_url
    config :casein, :agent_mcp_base_url, canonical_devbox_url
    config :casein, :api_base_url, canonical_devbox_url

    # Optional dedicated, isolated origin for PR-shareable artifacts. Serving
    # workspace-authored (untrusted) HTML from its own origin — rather than the
    # cockpit's — means a compromised artifact can't reach cockpit cookies or its
    # same-origin surface. When CASEIN_ARTIFACT_URL is set AND the manager routes
    # that subdomain through the same oauth2-proxy forward_auth to this host,
    # artifact public_urls are built from it; unset → artifacts stay on the
    # cockpit origin (current behavior). Safe no-op until the infra route exists.
    case System.get_env("CASEIN_ARTIFACT_URL") do
      url when is_binary(url) and url != "" ->
        config :casein, :artifact_public_url, url

      _ ->
        :ok
    end
  end

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :casein, CaseinWeb.Endpoint,
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
  # CaseinWeb.RuntimeSSLPlug owns HTTP-to-HTTPS redirects at runtime so local
  # LAN HTTP services can disable that behavior without rebuilding the release.
  # Check `Plug.SSL` for supported redirect/HSTS options.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :casein, Casein.Mailer,
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
