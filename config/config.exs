# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

if match?({:win32, _}, :os.type()) or System.get_env("CASEIN_NATIVE_WINDOWS") in ~w(1 true) do
  config :phoenix_live_view, :colocated_assets,
    target_directory: Path.expand("../assets/node_modules/phoenix-colocated", __DIR__),
    disable_symlink_warning: true
end

# Compile-time env, readable at runtime (e.g. boot-time safety assertions).
config :casein, :env, config_env()

repo_adapter =
  case System.get_env("CASEIN_REPO_ADAPTER", "postgres") |> String.downcase() do
    value when value in ["sqlite", "sqlite3"] -> Ecto.Adapters.SQLite3
    value when value in ["postgres", "postgresql"] -> Ecto.Adapters.Postgres
    value -> raise "CASEIN_REPO_ADAPTER must be postgres or sqlite, got: #{inspect(value)}"
  end

config :casein, :repo_adapter, repo_adapter

config :casein, CaseinWeb.Plugs.McpRateLimit,
  scale_ms: 60_000,
  limit: 120

config :casein,
  # Event-driven tmux topology (Slices 1/2). Default OFF — polling path
  # unchanged. Dev flips ON in config/dev.exs (Slice 3); canary/prod via
  # DEVIDE_TMUX_EVENTS after soak on flap/refresh telemetry (see
  # TmuxEventsFlapWatch moduledoc).
  tmux_events: false,
  tmux_topology_reconcile_ms: 10_000,
  # SessionDirectory reconcile while event mode is healthy (5s: quieter than the
  # old 2s poll, but keeps quiet-agent / needs_you attention flips tighter than
  # the design doc's 10s option — open question §8.1).
  session_directory_reconcile_ms: 5_000,
  tmux_events_anchor_session: "__devide_keepalive",
  # Listener-flap degradation thresholds (Slice 3).
  tmux_events_flap_watch: [
    threshold: 3,
    window_ms: 300_000,
    sustained_ms: 60_000
  ],
  tmux_ctl: [
    runner: Casein.Terminals.TmuxRunner,
    session_prefix: "devide",
    pubsub: Casein.PubSub,
    topology_reconcile_ms: 10_000,
    prefix_window_picker_hint: "Casein: use the browser window picker (C-b w)",
    prefix_session_picker_hint: "Casein: use the browser session picker (C-b s)"
  ],
  preview_ctl: [
    priv_app: :casein,
    registry_table: :preview_ctl_sessions
  ],
  # Preview-domain outbound seams (extraction slice 3). Preview modules resolve
  # core impls at runtime via Casein.Previews.Deps.impl/1 — never compile-time
  # module defaults (those re-create the xref edges this map severs). Test env
  # may repoint individual keys at fakes via Application.put_env.
  preview_deps: [
    workspaces: Casein.Workspaces.PreviewDeps,
    terminals: Casein.Terminals.PreviewDeps,
    runtimes: Casein.Runtimes.PreviewDeps,
    pane_sink: Casein.Panes.PreviewDeps
  ],
  git_ctl: [
    cache_table: :devide_git_inspector_cache,
    cache_ttl_ms: 10_000,
    agent_inference: {Casein.Git.Inspector, :infer_agent}
  ],
  deployment: [
    default_host: "devide.devbox.milcgroup.com",
    git_remote: "https://github.com/dl-alexandre/dev_ide.git",
    git_branch: "master",
    github_repo: "dl-alexandre/dev_ide",
    git_credential_helper:
      "!GH_CONFIG_DIR=/home/devbox/.config/gh-dalexandre GH_TOKEN= GITHUB_TOKEN= gh auth git-credential",
    deploy_service: "devide-deploy.service",
    remote_head_cache_ttl_ms: 60_000,
    ls_remote_timeout_ms: 5_000,
    last_deploy_path: "/run/devide/last-deploy.json",
    poller_watch_interval_ms: 30_000,
    stale_in_progress_ms: 2_700_000,
    phase_stale_in_progress_ms: %{"activate" => 600_000}
  ],
  # ETS tables used across processes (terminal fast-path, workspace access cache).
  # Must be :public — TerminalChannel and other connection processes write entries;
  # :protected only allows the Application process to insert and breaks joins.
  ets_table_access: :public,
  ecto_repos: [Casein.Repo],
  generators: [timestamp_type: :utc_datetime],
  audit_adapter: Casein.Audit.EctoAdapter,
  agent_events_adapter: Casein.Agents.AgentEvents.EctoAdapter,
  codex_store_adapter: Casein.Codex.Store.EctoAdapter,
  workspace_state_adapter: Casein.Workspaces.State.EctoAdapter,
  runtimes_adapter: Casein.Runtimes.EctoAdapter,
  # Persistent mobile companion tokens expire after this many seconds (default 90 days).
  device_link_ttl_seconds: 60 * 60 * 24 * 90,
  device_link_reaper_enabled: true

# Configure the endpoint
config :casein, CaseinWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: CaseinWeb.ErrorHTML, json: CaseinWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Casein.PubSub,
  live_view: [signing_salt: "Emi+CmP2"]

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :casein, Casein.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  casein: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  casein: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger.
# The metadata keys are the structured-log fields emitted across the
# terminal code (see Logger calls in lib/dev_ide); keys not listed here would
# be silently dropped from log output.
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [
    :request_id,
    :workspace_id,
    :runtime_id,
    :thread_id,
    :event_type,
    :workspace,
    :kind,
    :mode,
    :reason,
    :id,
    :sid,
    :name,
    :tmux,
    :target,
    :subscriber,
    :subscribers,
    :subscriber_mbox,
    :owner,
    :active_owners,
    :open_attachments,
    :queue_len,
    :ospid,
    :payload,
    :occurred_at
  ]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Redact auth secrets from Phoenix request param logs. Phoenix router dispatch
# logs params only (not Authorization headers); preview-proxy forwarding must
# keep req_headers intact — do not mutate headers for logging.
config :phoenix, :filter_parameters, [
  "authorization",
  "token",
  "api_token",
  "bearer",
  "access_token",
  "refresh_token",
  "workspace_api_tokens",
  "dev_ide_api_token",
  "password",
  "secret"
]

# Where Casein.Agents.TidewaveCapability resolves the locally-hosted Tidewave
# base URL from. Configured as an MFA so contexts never reference the web
# endpoint directly (keeps the context->web dependency inverted). Only fires
# when the :tidewave dep is present (dev); a no-op everywhere else.
config :casein, :tidewave_url_provider, {CaseinWeb.Endpoint, :url, []}
config :casein, :preview_mcp_url_provider, {CaseinWeb.Endpoint, :url, []}
config :casein, :terminal_mcp_url_provider, {CaseinWeb.Endpoint, :url, []}

# Preview infrastructure uses a partitioned 41000-41099 block:
#   41000-41049: ephemeral preview envs (scripts/preview-env.sh, Tidewave)
#   41050-41079: runtime-owned preview servers
#   41080-41081: preview router listener + admin listener
config :casein, :preview_env_port_range, {41_000, 41_049}
config :casein, :runtime_preview_port_range, {41_050, 41_079}
config :casein, :preview_router_port, 41_080
config :casein, :preview_router_admin_port, 41_081

# Preview-proxy WebSocket tunnel (HMR / LiveReload support). Off by default:
# it opens a new authenticated WS surface that bridges the browser to a
# workspace loopback dev server, so it stays opt-in until vetted. `max_per_workspace`
# bounds concurrent long-lived tunnels per workspace.
config :casein, :preview_proxy_hmr,
  enabled: false,
  max_per_workspace: 8,
  handshake_timeout_ms: 5_000,
  idle_timeout_ms: 60_000

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
