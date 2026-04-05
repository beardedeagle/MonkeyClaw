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

    test "has no legacy top-level model fields" do
      struct = %CachedModel{}
      refute Map.has_key?(struct, :model_id)
      refute Map.has_key?(struct, :display_name)
      refute Map.has_key?(struct, :capabilities)
    end
  end
end
