defmodule MonkeyClaw.Repo do
  @moduledoc """
  Ecto repository for MonkeyClaw persistence.

  Backed by SQLite3 via `ecto_sqlite3`. All tables use `STRICT`
  mode (type enforcement at the storage layer) and `WITHOUT ROWID`
  (clustered B-tree on the binary_id primary key).

  ## SQLite3 Configuration

  PRAGMA settings are configured in `config/config.exs`:

    * `:journal_mode` — `:wal` (concurrent reads during writes)
    * `:synchronous` — `:normal` (safe with WAL, avoids full fsync)
    * `:foreign_keys` — `:on` (referential integrity enforcement)
    * `:cache_size` — `-64_000` (64 MB page cache)
    * `:temp_store` — `:memory` (temp tables in RAM)
    * `:busy_timeout` — `2_000` ms (graceful lock contention)
    * `:auto_vacuum` — `:incremental` (reclaim space without full rebuild)

  Per-environment database paths and pool settings live in
  `config/dev.exs`, `config/test.exs`, and `config/runtime.exs`.
  """

  use Ecto.Repo,
    otp_app: :monkey_claw,
    adapter: Ecto.Adapters.SQLite3
end
