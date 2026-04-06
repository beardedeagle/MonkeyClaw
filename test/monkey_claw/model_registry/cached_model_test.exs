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

  describe "changeset/2 top-level value constraints" do
    @constraint_attrs %{
      backend: "claude",
      provider: "anthropic",
      source: "probe",
      refreshed_at: DateTime.utc_now(),
      refreshed_mono: System.monotonic_time(),
      models: [%{model_id: "m", display_name: "M", capabilities: %{}}]
    }

    test "rejects backend with uppercase" do
      cs = CachedModel.changeset(%CachedModel{}, %{@constraint_attrs | backend: "Claude"})
      refute cs.valid?
      assert errors_on(cs)[:backend]
    end

    test "rejects backend starting with digit" do
      cs = CachedModel.changeset(%CachedModel{}, %{@constraint_attrs | backend: "1claude"})
      refute cs.valid?
      assert errors_on(cs)[:backend]
    end

    test "rejects provider with hyphen" do
      cs = CachedModel.changeset(%CachedModel{}, %{@constraint_attrs | provider: "anthro-pic"})
      refute cs.valid?
      assert errors_on(cs)[:provider]
    end

    test "rejects backend longer than 64 bytes" do
      long = String.duplicate("a", 65)
      cs = CachedModel.changeset(%CachedModel{}, %{@constraint_attrs | backend: long})
      refute cs.valid?
      assert errors_on(cs)[:backend]
    end

    test "rejects empty backend" do
      cs = CachedModel.changeset(%CachedModel{}, %{@constraint_attrs | backend: ""})
      refute cs.valid?
      assert errors_on(cs)[:backend]
    end

    test "rejects unknown source" do
      cs = CachedModel.changeset(%CachedModel{}, %{@constraint_attrs | source: "other"})
      refute cs.valid?
      assert errors_on(cs)[:source]
    end

    for source <- ["baseline", "probe", "session"] do
      test "accepts source=#{source}" do
        cs = CachedModel.changeset(%CachedModel{}, %{@constraint_attrs | source: unquote(source)})
        assert cs.valid?
      end
    end
  end

  describe "changeset/2 embedded model constraints" do
    @embed_attrs %{
      backend: "claude",
      provider: "anthropic",
      source: "probe",
      refreshed_at: DateTime.utc_now(),
      refreshed_mono: System.monotonic_time(),
      models: [
        %{model_id: "claude-sonnet-4-5", display_name: "Claude Sonnet 4.5", capabilities: %{}}
      ]
    }

    test "rejects >500 embedded models" do
      too_many =
        Enum.map(1..501, fn i ->
          %{model_id: "m-#{i}", display_name: "M #{i}", capabilities: %{}}
        end)

      cs = CachedModel.changeset(%CachedModel{}, %{@embed_attrs | models: too_many})
      refute cs.valid?
      assert errors_on(cs)[:models]
    end

    test "accepts exactly 500 embedded models" do
      exact =
        Enum.map(1..500, fn i ->
          %{model_id: "m-#{i}", display_name: "M #{i}", capabilities: %{}}
        end)

      cs = CachedModel.changeset(%CachedModel{}, %{@embed_attrs | models: exact})
      assert cs.valid?
    end

    test "rejects model_id longer than 256 bytes" do
      long = String.duplicate("a", 257)
      models = [%{model_id: long, display_name: "D", capabilities: %{}}]
      cs = CachedModel.changeset(%CachedModel{}, %{@embed_attrs | models: models})
      refute cs.valid?
    end

    test "rejects non-UTF8 model_id" do
      models = [%{model_id: <<0xFF, 0xFE>>, display_name: "D", capabilities: %{}}]
      cs = CachedModel.changeset(%CachedModel{}, %{@embed_attrs | models: models})
      refute cs.valid?
    end

    test "rejects model_id with control chars" do
      models = [%{model_id: "bad\x00id", display_name: "D", capabilities: %{}}]
      cs = CachedModel.changeset(%CachedModel{}, %{@embed_attrs | models: models})
      refute cs.valid?
    end

    test "accepts ASCII allowed punctuation" do
      models = [
        %{model_id: "claude-sonnet-4.5:preview", display_name: "Claude", capabilities: %{}}
      ]

      cs = CachedModel.changeset(%CachedModel{}, %{@embed_attrs | models: models})
      assert cs.valid?
    end

    test "accepts non-ASCII unicode letters" do
      models = [
        %{model_id: "claude-日本-α1", display_name: "Claude 日本語 модель", capabilities: %{}}
      ]

      cs = CachedModel.changeset(%CachedModel{}, %{@embed_attrs | models: models})
      assert cs.valid?
    end

    test "rejects capabilities larger than 8 KiB when encoded" do
      giant = %{blob: String.duplicate("x", 9_000)}
      models = [%{model_id: "m", display_name: "M", capabilities: giant}]
      cs = CachedModel.changeset(%CachedModel{}, %{@embed_attrs | models: models})
      refute cs.valid?
    end
  end
end
