import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
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

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :dev_ide, DevIdeWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "e3sJqbYf9MMz/gVAO91o1GceiKitJjXdk1wN/H1D+rLQfTimNa/OrBAYumnJ4ijM",
  server: false

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
  audit_adapter: DevIDE.Audit.MemoryAdapter,
  workspace_state_adapter: DevIDE.Workspaces.State.MemoryAdapter,
  runtimes_adapter: DevIDE.Runtimes.MemoryAdapter,
  # The integration source is used in the test suite because the existing
  # workspace flow tests assert on its HTTP-backed shape via Bypass mocks.
  # Tests that want the Local source override this.
  workspace_source: DevIDE.Integrations.Manager.WorkspaceSource,
  preview_control_adapter: :memory,
  # Sandbox the suite onto a dedicated tmux server (`-L devide_test`) so running
  # `mix test` on the devbox can never see or kill live sessions on the host's
  # default server. See DevIDE.Terminals.TmuxServer.
  tmux_server_label: "devide_test"
