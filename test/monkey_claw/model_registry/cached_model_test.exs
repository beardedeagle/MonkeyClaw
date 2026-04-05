defmodule MonkeyClaw.ModelRegistry.CachedModelTest do
  @moduledoc """
  Changeset and schema tests for the rewritten CachedModel.

  Runs with DataCase for SQLite sandbox isolation — no GenServer
  required at this layer.
  """

  use MonkeyClaw.DataCase, async: true

  alias MonkeyClaw.ModelRegistry.CachedModel

  describe "schema shape" do
    test "has the new top-level fields" do
      struct = %CachedModel{}
      assert Map.has_key?(struct, :backend)
      assert Map.has_key?(struct, :provider)
      assert Map.has_key?(struct, :source)
      assert Map.has_key?(struct, :refreshed_at)
      assert Map.has_key?(struct, :refreshed_mono)
      assert Map.has_key?(struct, :models)
    end

    test "rejects top-level model fields from the prior shape" do
      struct = %CachedModel{}
      refute Map.has_key?(struct, :model_id)
      refute Map.has_key?(struct, :display_name)
      refute Map.has_key?(struct, :capabilities)
    end
  end

  describe "changeset/2 required fields" do
    @valid_attrs %{
      backend: "claude",
      provider: "anthropic",
      source: "probe",
      refreshed_at: DateTime.utc_now(),
      refreshed_mono: System.monotonic_time(),
      models: [
        %{model_id: "claude-sonnet-4-5", display_name: "Claude Sonnet 4.5", capabilities: %{}}
      ]
    }

    test "valid attrs produce a valid changeset" do
      changeset = CachedModel.changeset(%CachedModel{}, @valid_attrs)
      assert changeset.valid?
    end

    for field <- [:backend, :provider, :source, :refreshed_at, :refreshed_mono] do
      test "requires #{field}" do
        attrs = Map.delete(@valid_attrs, unquote(field))
        changeset = CachedModel.changeset(%CachedModel{}, attrs)
        refute changeset.valid?
        assert errors_on(changeset)[unquote(field)]
      end
    end

    test "requires models to be present" do
      attrs = Map.delete(@valid_attrs, :models)
      changeset = CachedModel.changeset(%CachedModel{}, attrs)
      refute changeset.valid?
      assert errors_on(changeset)[:models]
    end

    test "each embedded model requires model_id and display_name" do
      attrs = %{@valid_attrs | models: [%{capabilities: %{}}]}
      changeset = CachedModel.changeset(%CachedModel{}, attrs)
      refute changeset.valid?
    end
  end
end
