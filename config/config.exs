# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :monkey_claw,
  env: config_env(),
  ecto_repos: [MonkeyClaw.Repo],
  generators: [timestamp_type: :utc_datetime_usec]

# SQLite3 PRAGMA configuration — shared across all environments.
# ecto_sqlite3 sets sensible defaults; we make them explicit here.
config :monkey_claw, MonkeyClaw.Repo,
  journal_mode: :wal,
  synchronous: :normal,
  foreign_keys: :on,
  cache_size: -64_000,
  temp_store: :memory,
  busy_timeout: 2_000,
  auto_vacuum: :incremental

# Configure the endpoint
config :monkey_claw, MonkeyClawWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: MonkeyClawWeb.ErrorHTML, json: MonkeyClawWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: MonkeyClaw.PubSub,
  live_view: [signing_salt: "O+pZ6FAJ"]

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :monkey_claw, MonkeyClaw.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  monkey_claw: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  monkey_claw: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Available AI models for the chat model selector.
# Each entry needs an :id (the model string sent to BeamAgent)
# and a :label (what the user sees in the dropdown).
config :monkey_claw, :available_models, [
  %{id: "claude-opus-4-6", label: "Opus 4.6"},
  %{id: "claude-sonnet-4-6", label: "Sonnet 4.6"},
  %{id: "claude-haiku-4-5-20251001", label: "Haiku 4.5"}
]

# Default model used when no assistant is configured on the workspace.
config :monkey_claw, :default_model, "claude-sonnet-4-6"

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
