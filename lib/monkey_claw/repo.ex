defmodule MonkeyClaw.Repo do
  use Ecto.Repo,
    otp_app: :monkey_claw,
    adapter: Ecto.Adapters.SQLite3
end
