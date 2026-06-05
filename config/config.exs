# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :dev_ide,
  # ETS tables used across processes (terminal fast-path, workspace access cache).
  # :public in test so channel/LiveView tests can share tables; :protected in prod.
  ets_table_access: :protected,
  ecto_repos: [DevIde.Repo],
  generators: [timestamp_type: :utc_datetime],
  audit_adapter: DevIDE.Audit.EctoAdapter,
  workspace_state_adapter: DevIDE.Workspaces.State.EctoAdapter,
  command_history_adapter: DevIDE.Commands.History.EctoAdapter,
  runner_protocol_adapter: DevIDE.Runners.EctoAdapter,
  runtime_orchestration_adapter: DevIDE.Runtimes.EctoAdapter,
  artifact_store_adapter: DevIDE.Fleet.ArtifactStore.RepoAdapter

# Configure the endpoint
config :dev_ide, DevIdeWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: DevIdeWeb.ErrorHTML, json: DevIdeWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: DevIde.PubSub,
  live_view: [signing_salt: "Emi+CmP2"]

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :dev_ide, DevIde.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  dev_ide: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  dev_ide: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
