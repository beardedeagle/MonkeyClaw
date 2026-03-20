defmodule MonkeyClaw.DataCase do
  @moduledoc """
  Test case template for tests that access the database.

  Sets up the Ecto SQL sandbox so each test runs in an
  isolated transaction that is rolled back automatically.

  For pure changeset tests that do not need database access,
  prefer `MonkeyClaw.ChangesetCase` — it provides the same
  `errors_on/1` helper without sandbox overhead.

  ## Usage

      use MonkeyClaw.DataCase, async: true
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias MonkeyClaw.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import MonkeyClaw.ChangesetCase
      import MonkeyClaw.DataCase
    end
  end

  setup tags do
    MonkeyClaw.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.
  """
  def setup_sandbox(tags) do
    alias Ecto.Adapters.SQL.Sandbox

    pid = Sandbox.start_owner!(MonkeyClaw.Repo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
  end
end
