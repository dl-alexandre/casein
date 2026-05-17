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
  pool_size: System.schedulers_online() * 2

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

# Default audit adapter in tests is in-memory; the Ecto adapter is exercised
# via DataCase tests that explicitly opt in.
config :dev_ide,
  audit_adapter: DevIDE.Audit.MemoryAdapter,
  workspace_state_adapter: DevIDE.Workspaces.State.MemoryAdapter,
  command_history_adapter: DevIDE.Commands.History.MemoryAdapter,
  runner_protocol_adapter: DevIDE.Runners.MemoryAdapter,
  runtime_orchestration_adapter: DevIDE.Runtimes.MemoryAdapter,
  artifact_store_adapter: DevIDE.Fleet.ArtifactStore.MemoryAdapter,
  # The integration source is used in the test suite because the existing
  # workspace flow tests assert on its HTTP-backed shape via Bypass mocks.
  # Tests that want the Local source override this.
  workspace_source: DevIDE.Integrations.Manager.WorkspaceSource
