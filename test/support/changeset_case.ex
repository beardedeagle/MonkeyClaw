defmodule MonkeyClaw.ChangesetCase do
  @moduledoc """
  Shared helpers for pure changeset tests.

  Use this case template when testing Ecto schema changesets
  without database access. Provides the `errors_on/1` helper
  without the overhead of SQL sandbox setup.

  For tests that need database access, use `MonkeyClaw.DataCase`
  instead — it includes the same `errors_on/1` helper plus
  sandbox management.

  ## Usage

      use MonkeyClaw.ChangesetCase, async: true
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import MonkeyClaw.ChangesetCase
    end
  end

  @doc """
  Transforms changeset errors into a map of messages.

  ## Examples

      changeset = MySchema.changeset(%MySchema{}, %{name: ""})
      assert "can't be blank" in errors_on(changeset).name
  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
