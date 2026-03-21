import Config

# Configure your database
config :monkey_claw, MonkeyClaw.Repo,
  database: Path.expand("../monkey_claw_dev.db", __DIR__),
  pool_size: 5,
  stacktrace: true,
  show_sensitive_data_on_connection_error: true

# For development, we disable any cache and enable
# debugging and code reloading.
#
# The watchers configuration can be used to run external
# watchers to your application. For example, we can use it
# to bundle .js and .css sources.
config :monkey_claw, MonkeyClawWeb.Endpoint,
  # Binding to loopback ipv4 address prevents access from other machines.
  # Change to `ip: {0, 0, 0, 0}` to allow access from other machines.
  http: [ip: {127, 0, 0, 1}],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "sU1pjiz2thsMCeCNN3H509MEH2DTLGSMwHnqIzKfM4BwgJKL1g10+i5cG/bLMl1n",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:monkey_claw, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:monkey_claw, ~w(--watch)]}
  ]

# ## mTLS Development Mode
#
# To enable mTLS in development, first generate certificates:
#
#     mix monkey_claw.gen.certs
#
# Then replace the `http:` config above with:
#
#     https: [
#       port: 4001,
#       cipher_suite: :strong,
#       versions: [:"tlsv1.3"],
#       certfile: "priv/cert/server.pem",
#       keyfile: "priv/cert/server-key.pem",
#       cacertfile: "priv/cert/ca.pem",
#       verify: :verify_peer,
#       fail_if_no_peer_cert: true,
#       depth: 3
#     ],
#
# Import the generated priv/cert/client.p12 into your browser
# to authenticate. The password is printed when you run the gen task.

# Reload browser tabs when matching files change.
config :monkey_claw, MonkeyClawWeb.Endpoint,
  live_reload: [
    web_console_logger: true,
    patterns: [
      # Static assets, except user uploads
      ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
      # Gettext translations
      ~r"priv/gettext/.*\.po$"E,
      # Router, Controllers, LiveViews and LiveComponents
      ~r"lib/monkey_claw_web/router\.ex$"E,
      ~r"lib/monkey_claw_web/(controllers|live|components)/.*\.(ex|heex)$"E
    ]
  ]

# Enable dev routes for dashboard and mailbox
config :monkey_claw, dev_routes: true

# Do not include metadata nor timestamps in development logs
config :logger, :default_formatter, format: "[$level] $message\n"

# Set a higher stacktrace during development. Avoid configuring such
# in production as building large stacktraces may be expensive.
config :phoenix, :stacktrace_depth, 20

# Initialize plugs at runtime for faster development compilation
config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  # Include debug annotations and locations in rendered markup.
  # Changing this configuration will require mix clean and a full recompile.
  debug_heex_annotations: true,
  debug_attributes: true,
  # Enable helpful, but potentially expensive runtime checks
  enable_expensive_runtime_checks: true

# Disable swoosh api client as it is only required for production adapters.
config :swoosh, :api_client, false
