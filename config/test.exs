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
  config :dev_ide, DevIde.Repo,
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
  config :dev_ide, DevIde.Repo,
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

# Sandbox every tmux invocation onto a dedicated server (`tmux -L devide_test`)
# so the live tmux integration tests can never see, create, kill, or reconcile
# sessions on another server — on the devbox the prod release (`devide`) and the
# :4000 dev server (`devide_dev`) also run here. Each env gets its own label so
# the servers stay isolated; resolved by DevIDE.Terminals.TmuxServer.
config :dev_ide, :tmux_server_label, "devide_test"

# Keep runtime-minted workspace tokens (DevIDE.Agents.WorkspaceTokens) out of
# the real ~/.devide store when tests exercise the materializer/pane env.
config :dev_ide,
       :workspace_tokens_store,
       Path.join(
         System.tmp_dir!(),
         "devide-test-workspace-tokens-#{System.get_env("MIX_TEST_PARTITION") || "0"}.json"
       )

# In test we don't send emails
config :dev_ide, DevIde.Mailer, adapter: Swoosh.Adapters.Test

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
  workspace_state_adapter: DevIDE.Workspaces.State.MemoryAdapter,
  runtimes_adapter: DevIDE.Runtimes.MemoryAdapter,
  forward_auth: false,
  admins: [],
  on_devbox: false,
  manager_req_options: [plug: {Req.Test, DevIDE.Integrations.Manager.Client}],
  device_link_ttl_seconds: 3_600,
  device_link_reaper_enabled: false,
  # The integration source is used in the test suite because the existing
  # workspace flow tests assert on its HTTP-backed shape via Bypass mocks.
  # Tests that want the Local source override this.
  workspace_source: DevIDE.WorkspaceSource.Manager,
  runtime_preview_launcher_enabled: false,
  preview_control_adapter: :memory,
  preview_proxy_enabled: false,
  preview_open_preflight: false,
  preview_pane_persistence_enabled: false,
  terminal_desktop_integration_enabled: false,
  # Sandbox the suite onto a dedicated tmux server (`-L devide_test`) so running
  # `mix test` on the devbox can never see or kill live sessions on the host's
  # default server. See DevIDE.Terminals.TmuxServer.
  tmux_server_label: "devide_test",
  # Unrelated LiveView/pane tests must never write tool theme configs into the
  # real $HOME; dedicated ToolThemes tests re-enable this with a tmp
  # :tool_theme_home.
  tool_themes_enabled: false
