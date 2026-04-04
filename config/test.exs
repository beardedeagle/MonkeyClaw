import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :monkey_claw, MonkeyClaw.Repo,
  database: Path.expand("../monkey_claw_test.db", __DIR__),
  # SQLite allows one writer at a time. Fewer pool connections means
  # fewer concurrent writers contending for the single write lock.
  # pool_size: 2 balances async test parallelism with contention
  # avoidance on slow CI runners (GitHub Actions).
  pool_size: 2,
  pool: Ecto.Adapters.SQL.Sandbox,
  # SQLite busy_timeout must be LESS than ExUnit's test timeout (120s)
  # to prevent cascade failures. If busy_timeout > test timeout,
  # ExUnit kills the test process while the connection is still
  # busy-waiting, leaving orphaned connections that block the pool.
  # Layer order: busy_timeout (90s) < ExUnit timeout (120s) < ownership_timeout (180s).
  busy_timeout: 90_000,
  timeout: 90_000,
  ownership_timeout: 180_000

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :monkey_claw, MonkeyClawWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "Ho55hK3AbP5jt9x0wm2VZ6Ts0TbDrBfZ/JdKWdJUwmwcjhqVAuq/iupKNfGZmm87",
  live_view: [signing_salt: "monkey_claw_test_salt"],
  session_signing_salt: "monkey_claw_test_session_salt",
  server: false

# In test we don't send emails
config :monkey_claw, MonkeyClaw.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Disable background GenServers that interfere with sandbox isolation.
# Tests that need these use start_supervised! explicitly.
config :monkey_claw, :start_notification_router, false
config :monkey_claw, :start_scheduler, false
config :monkey_claw, :start_observer, false
config :monkey_claw, :start_model_registry, false

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
