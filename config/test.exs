import Config

# ---------------------------------------------------------------------------
# Ambient operator CASEIN_* scrub (#248)
#
# Must run here — not only in test_helper.exs — because `mix test` starts the
# application *before* evaluating test_helper, and boot paths
# (Deployment.Registry, HostMode, WorkspaceTokens, …) still read System.get_env
# for CASEIN_INSTANCE_UUID / CASEIN_HTTP_SOCKET / CASEIN_ON_DEVBOX / tokens /
# worktree roots. A paired-agent shell exports ~70 of these; leaving them in
# place reds unrelated tests on a shared box while CI stays green.
#
# Keep-list mirrors Casein.Test.AmbientEnv (test/support cannot be required
# from config/). test_helper.exs re-runs the same scrub via AmbientEnv so the
# keep-list has a single code owner + hermetic tests.
# ---------------------------------------------------------------------------
keep_exact = MapSet.new(["CASEIN_REPO_ADAPTER", "CASEIN_TEST_TMPDIR"])
keep_prefixes = ["CASEIN_GATE_", "CASEIN_TEST_"]

for {key, _value} <- System.get_env() do
  if String.starts_with?(key, "CASEIN_") and
       not MapSet.member?(keep_exact, key) and
       not Enum.any?(keep_prefixes, &String.starts_with?(key, &1)) do
    System.delete_env(key)
  end
end

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
# Every per-run test resource is keyed by System.pid(). MIX_TEST_PARTITION remains
# a CI sharding suffix in resource names; it is never the run-isolation key.
test_run_suffix = "#{System.get_env("MIX_TEST_PARTITION")}_#{System.pid()}"

sqlite_repo? =
  System.get_env("CASEIN_REPO_ADAPTER", "postgres")
  |> String.downcase()
  |> then(&(&1 in ["sqlite", "sqlite3"]))

if sqlite_repo? do
  config :casein, Casein.Repo,
    database:
      System.get_env("DATABASE_PATH") ||
        Path.expand(
          "../casein_test#{test_run_suffix}.sqlite3",
          System.tmp_dir!()
        ),
    pool: Ecto.Adapters.SQL.Sandbox,
    journal_mode: :delete,
    pool_size: 1,
    busy_timeout: 5_000
else
  config :casein, Casein.Repo,
    username: "postgres",
    password: "postgres",
    hostname: "localhost",
    database: "casein_test#{test_run_suffix}",
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
config :casein, CaseinWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "e3sJqbYf9MMz/gVAO91o1GceiKitJjXdk1wN/H1D+rLQfTimNa/OrBAYumnJ4ijM",
  server: false

config :casein,
       :origin_identity_secret,
       "e3sJqbYf9MMz/gVAO91o1GceiKitJjXdk1wN/H1D+rLQfTimNa/OrBAYumnJ4ijM"

# Sandbox every tmux invocation onto a dedicated server (`tmux -L casein_test`)
# so the live tmux integration tests can never see, create, kill, or reconcile
# sessions on another server — on the devbox the prod release (`casein`) and the
# :4000 dev server (`casein_dev`) also run here. Each env gets its own label so
# the servers stay isolated; resolved by Casein.Terminals.TmuxServer.
# `test/test_helper.exs` further suffixes this with the OS pid so two suites
# running at once on the same box do not reap each other's server.
config :casein, :tmux_server_label, "casein_test"
# Never spawn the host tmux keepalive anchor during the test suite.
config :casein, :tmux_host_anchor, false
# The control-plane reconciler has focused unit tests; keep the application
# boot in the suite from scanning the shared fake tmux server on a timer.
config :casein, :control_plane_reconcile_ms, nil

config :casein, :fleet_snapshot,
  interval_ms: 3_600_000,
  budget_ms: 4_000,
  refresh_on_start: false

# Keep test scrollback spill out of the real ~/.casein/tmux-scrollback.
# ScrollbackArchive defaults to $HOME/.casein/tmux-scrollback, which is the
# archive the *production* server reseeds from after a crash (see
# docs/subsystems/tmux_crash_recovery.md). The suite creates and kills real
# tmux sessions, so an unsandboxed run spills one .scrollback file per test
# session into that dir and never reaps them: on the devbox it had grown to
# 10,679 files / 488 MB, of which 10,548 were test session names. That is both
# unbounded disk growth and production recovery state written by tests.
# Keyed by OS pid for the same reason as :deployment_instance_dir below —
# concurrent agent test runs on the devbox share MIX_TEST_PARTITION "0", so a
# partition-keyed dir would be shared across suites.
config :casein,
       :tmux_scrollback_archive_dir,
       Path.join(System.tmp_dir!(), "casein-test-scrollback-#{System.pid()}")

# Keep test-boot deployment heartbeats out of the real /run/casein/instances.
# Devbox terminals inherit CASEIN_INSTANCE_UUID from the canary that spawned
# them, so an unsandboxed `mix test` boot would overwrite that live canary's
# heartbeat with the test VM's pid — the deploy then reads a dead pid, drops
# the record as stale, and never drains the still-running canary.
# Keyed by OS pid, not MIX_TEST_PARTITION: concurrent agent test runs on the
# devbox share partition "0" and inherit the same CASEIN_INSTANCE_UUID, so a
# shared dir would trip the registry's ownership guard across suites.
config :casein,
       :deployment_instance_dir,
       Path.join(System.tmp_dir!(), "casein-test-instances-#{System.pid()}")

# Submit confirmation polls a live pane and deliberately sleeps between Enter
# presses. Production waits ~1.2s per attempt; a suite that paid that per send
# would add minutes. The timings are the only thing shortened — the confirmation
# logic itself is exercised as-is, with tests injecting a :capture function.
config :casein, :pane_submit,
  settle_ms: 0,
  retry_settle_ms: 0,
  poll_ms: 1,
  attempt_timeout_ms: 5

# Never probe the Caddy admin API (http://localhost:2019) from tests.
# Casein.Deployment.Health.status/1 is reached by /api/workspaces/:id/status,
# pane mutations, and template export (all call Export.status first). On the
# contended devbox that real HTTP GET times out and retries (~7s), making those
# endpoint tests flaky. Health tests inject :caddy_config explicitly, so this
# only neutralizes the un-injected controller path.
config :casein, :caddy_admin_probe, false

# Neutralize SessionOwner.superseded?/0 in tests. It compares the inherited
# CASEIN_HTTP_SOCKET against whatever /run/casein/current.sock resolves to;
# devbox test VMs inherit a real CASEIN_HTTP_SOCKET from the spawning canary, so
# without this every test owner would read as "superseded" and stop asserting
# tmux sizes. Point the seam at a path that isn't a symlink → read_link fails →
# not superseded. The dedicated superseded? test overrides this with a temp
# symlink it controls.
config :casein,
       :deployment_current_socket,
       Path.join(System.tmp_dir!(), "casein-test-no-current-#{System.pid()}.sock")

# Keep runtime-minted workspace tokens (Casein.Agents.WorkspaceTokens) out of
# the real ~/.casein store when tests exercise the materializer/pane env.
config :casein,
       :workspace_tokens_store,
       Path.join(
         System.tmp_dir!(),
         "casein-test-workspace-tokens-#{test_run_suffix}.json"
       )

# In test we don't send emails
config :casein, Casein.Mailer, adapter: Swoosh.Adapters.Test

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

config :casein, CaseinWeb.Plugs.McpRateLimit,
  scale_ms: 60_000,
  limit: 120

config :casein,
  ets_table_access: :public,
  # Tests mutate repos and re-inspect the same cwd within one run; a cached
  # read would make those assertions order-dependent.
  git_inspector_cache_ttl_ms: 0,
  # Default audit adapter in tests is in-memory; the Ecto adapter is exercised
  # via DataCase tests that explicitly opt in.
  audit_adapter: Casein.Audit.MemoryAdapter,
  agent_events_adapter: Casein.Agents.AgentEvents.MemoryAdapter,
  grok_acp_auto_attach: false,
  codex_store_adapter: Casein.Codex.Store.MemoryAdapter,
  workspace_state_adapter: Casein.Workspaces.State.MemoryAdapter,
  runtimes_adapter: Casein.Runtimes.MemoryAdapter,
  forward_auth: false,
  admins: [],
  on_devbox: false,
  manager_req_options: [plug: {Req.Test, Casein.Integrations.Manager.Client}],
  device_link_ttl_seconds: 3_600,
  device_link_reaper_enabled: false,
  attention_history_sweeper_enabled: false,
  runtime_reaper_enabled: false,
  runtime_reaper_dry_run: true,
  # Keep scheduled reaper tests isolated from real host agent worktrees.
  agent_worktree_roots: [Path.join(System.tmp_dir!(), "casein-test-agent-worktrees")],
  workspace_reconciler_enabled: false,
  workspace_reconciler_dry_run: true,
  # UserObserver/channel processes outlive individual SQL sandbox clients. The
  # persistence contract is enabled explicitly by its non-async DataCase tests;
  # ordinary channel tests exercise the same pure projection without letting a
  # long-lived process retain a sandbox checkout.
  mobile_attention_store_enabled: false,
  # The integration source is used in the test suite because the existing
  # workspace flow tests assert on its HTTP-backed shape via HTTPStub servers.
  # Tests that want the Local source override this.
  workspace_source: Casein.WorkspaceSource.Manager,
  runtime_preview_launcher_enabled: false,
  # Metadata/allocation tests must not depend on live host preview listeners.
  # The system probe itself has focused real-socket coverage.
  runtime_preview_port_probe: Casein.Test.PreviewPortProbe,
  preview_control_adapter: :memory,
  preview_proxy_enabled: false,
  preview_open_preflight: false,
  preview_surface_probe: false,
  # Off by default in the suite so preview-open tests are not perturbed by real
  # port probes; ScopedLocalServerTest opts in per-test via Application.put_env.
  preview_prefer_scoped_local_server: false,
  preview_pane_persistence_enabled: false,
  terminal_desktop_integration_enabled: false,
  # Sandbox the suite onto a dedicated tmux server (`-L casein_test`) so running
  # `mix test` on the devbox can never see or kill live sessions on the host's
  # default server. See Casein.Terminals.TmuxServer.
  tmux_server_label: "casein_test",
  # Disable authoritative-size debouncing in the suite (leading_ms: 0 makes
  # every change apply immediately) so the many existing resize tests keep
  # deterministic semantics; SessionOwner debounce tests opt back in per-test.
  terminal_owner_size_debounce: [leading_ms: 0],
  # Unrelated LiveView/pane tests must never write tool theme configs into the
  # real $HOME; dedicated ToolThemes tests re-enable this with a tmp
  # :tool_theme_home.
  tool_themes_enabled: false,
  signal_bus_journal_adapter: Jido.Signal.Journal.Adapters.InMemory
