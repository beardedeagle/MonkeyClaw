# Increase default test timeout for slow CI runners (Elixir 1.17/OTP 27).
# SQLite busy_timeout (90s) must expire BEFORE ExUnit kills the test
# process, or orphaned connections block the pool and cascade failures.
ExUnit.start(timeout: 120_000)
Ecto.Adapters.SQL.Sandbox.mode(MonkeyClaw.Repo, :manual)
