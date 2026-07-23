import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
sqlite_repo? =
  System.get_env("DEV_IDE_REPO_ADAPTER", "postgres")
  |> String.downcase()
  |> then(&(&1 in ["sqlite", "sqlite3"]))

if sqlite_repo? do
  config :dev_ide, DevIDE.Repo,
    database:
      System.get_env("DATABASE_PATH") ||
        Path.expand(
          "../dev_ide_test#{System.get_env("MIX_TEST_PARTITION")}.sqlite3",
          System.tmp_dir!()
        ),
    pool: Ecto.Adapters.SQL.Sandbox,
    journal_mode: :delete,
    pool_size: 1,
    busy_timeout: 5_000
else
  config :dev_ide, DevIDE.Repo,
    username: "postgres",
    password: "postgres",
    hostname: "localhost",
    database: "dev_ide_test#{System.get_env("MIX_TEST_PARTITION")}",
    pool: Ecto.Adapters.SQL.Sandbox,
    # Capped: this devbox runs many agents' test suites concurrently against one
    # postgres; schedulers × 2 per BEAM (32+ on this box) exhausts max_connections
    # and kills unrelated runs with "too many clients already".
    pool_size: min(System.schedulers_online() * 2, 10)
end

erlexec_portexe =
  Path.expand(
    "../deps/erlexec/priv/#{:erlang.system_info(:system_architecture)}/exec-port",
    __DIR__
  )

if File.exists?(erlexec_portexe) do
  config :erlexec, portexe: erlexec_portexe
end

erlexec_portexe =
  Path.expand(
    "../deps/erlexec/priv/#{:erlang.system_info(:system_architecture)}/exec-port",
    __DIR__
  )

if File.exists?(erlexec_portexe) do
  config :erlexec, portexe: erlexec_portexe
end

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :dev_ide, DevIdeWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "e3sJqbYf9MMz/gVAO91o1GceiKitJjXdk1wN/H1D+rLQfTimNa/OrBAYumnJ4ijM",
  server: false

config :dev_ide,
       :origin_identity_secret,
       "e3sJqbYf9MMz/gVAO91o1GceiKitJjXdk1wN/H1D+rLQfTimNa/OrBAYumnJ4ijM"

# Sandbox every tmux invocation onto a dedicated server (`tmux -L devide_test`)
# so the live tmux integration tests can never see, create, kill, or reconcile
# sessions on another server — on the devbox the prod release (`devide`) and the
# :4000 dev server (`devide_dev`) also run here. Each env gets its own label so
# the servers stay isolated; resolved by DevIDE.Terminals.TmuxServer.
config :dev_ide, :tmux_server_label, "devide_test"
# Never spawn the host tmux keepalive anchor during the test suite.
config :dev_ide, :tmux_host_anchor, false

# Keep test-boot deployment heartbeats out of the real /run/devide/instances.
# Devbox terminals inherit DEVIDE_INSTANCE_UUID from the canary that spawned
# them, so an unsandboxed `mix test` boot would overwrite that live canary's
# heartbeat with the test VM's pid — the deploy then reads a dead pid, drops
# the record as stale, and never drains the still-running canary.
# Keyed by OS pid, not MIX_TEST_PARTITION: concurrent agent test runs on the
# devbox share partition "0" and inherit the same DEVIDE_INSTANCE_UUID, so a
# shared dir would trip the registry's ownership guard across suites.
config :dev_ide,
       :deployment_instance_dir,
       Path.join(System.tmp_dir!(), "devide-test-instances-#{System.pid()}")

# Never probe the Caddy admin API (http://localhost:2019) from tests.
# DevIDE.Deployment.Health.status/1 is reached by /api/workspaces/:id/status,
# pane mutations, and template export (all call Export.status first). On the
# contended devbox that real HTTP GET times out and retries (~7s), making those
# endpoint tests flaky. Health tests inject :caddy_config explicitly, so this
# only neutralizes the un-injected controller path.
config :dev_ide, :caddy_admin_probe, false

# Neutralize SessionOwner.superseded?/0 in tests. It compares the inherited
# DEVIDE_HTTP_SOCKET against whatever /run/devide/current.sock resolves to;
# devbox test VMs inherit a real DEVIDE_HTTP_SOCKET from the spawning canary, so
# without this every test owner would read as "superseded" and stop asserting
# tmux sizes. Point the seam at a path that isn't a symlink → read_link fails →
# not superseded. The dedicated superseded? test overrides this with a temp
# symlink it controls.
config :dev_ide,
       :deployment_current_socket,
       Path.join(System.tmp_dir!(), "devide-test-no-current-#{System.pid()}.sock")

# Keep runtime-minted workspace tokens (DevIDE.Agents.WorkspaceTokens) out of
# the real ~/.devide store when tests exercise the materializer/pane env.
config :dev_ide,
       :workspace_tokens_store,
       Path.join(
         System.tmp_dir!(),
         "devide-test-workspace-tokens-#{System.get_env("MIX_TEST_PARTITION") || "0"}.json"
       )

# In test we don't send emails
config :dev_ide, DevIDE.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

config :dev_ide, DevIdeWeb.Plugs.McpRateLimit,
  scale_ms: 60_000,
  limit: 120

config :dev_ide,
  ets_table_access: :public,
  # Tests mutate repos and re-inspect the same cwd within one run; a cached
  # read would make those assertions order-dependent.
  git_inspector_cache_ttl_ms: 0,
  # Default audit adapter in tests is in-memory; the Ecto adapter is exercised
  # via DataCase tests that explicitly opt in.
  audit_adapter: DevIDE.Audit.MemoryAdapter,
  agent_events_adapter: DevIDE.Agents.AgentEvents.MemoryAdapter,
  grok_acp_auto_attach: false,
  codex_store_adapter: DevIDE.Codex.Store.MemoryAdapter,
  workspace_state_adapter: DevIDE.Workspaces.State.MemoryAdapter,
  runtimes_adapter: DevIDE.Runtimes.MemoryAdapter,
  forward_auth: false,
  admins: [],
  on_devbox: false,
  manager_req_options: [plug: {Req.Test, DevIDE.Integrations.Manager.Client}],
  device_link_ttl_seconds: 3_600,
  device_link_reaper_enabled: false,
  runtime_reaper_enabled: false,
  runtime_reaper_dry_run: true,
  # The integration source is used in the test suite because the existing
  # workspace flow tests assert on its HTTP-backed shape via HTTPStub servers.
  # Tests that want the Local source override this.
  workspace_source: DevIDE.WorkspaceSource.Manager,
  runtime_preview_launcher_enabled: false,
  preview_control_adapter: :memory,
  preview_proxy_enabled: false,
  preview_open_preflight: false,
  preview_surface_probe: false,
  # Off by default in the suite so preview-open tests are not perturbed by real
  # port probes; ScopedLocalServerTest opts in per-test via Application.put_env.
  preview_prefer_scoped_local_server: false,
  preview_pane_persistence_enabled: false,
  terminal_desktop_integration_enabled: false,
  # Sandbox the suite onto a dedicated tmux server (`-L devide_test`) so running
  # `mix test` on the devbox can never see or kill live sessions on the host's
  # default server. See DevIDE.Terminals.TmuxServer.
  tmux_server_label: "devide_test",
  # Disable authoritative-size debouncing in the suite (leading_ms: 0 makes
  # every change apply immediately) so the many existing resize tests keep
  # deterministic semantics; SessionOwner debounce tests opt back in per-test.
  terminal_owner_size_debounce: [leading_ms: 0],
  # Unrelated LiveView/pane tests must never write tool theme configs into the
  # real $HOME; dedicated ToolThemes tests re-enable this with a tmp
  # :tool_theme_home.
  tool_themes_enabled: false,
  signal_bus_journal_adapter: Jido.Signal.Journal.Adapters.InMemory
