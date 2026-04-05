defmodule MonkeyClaw.ModelRegistry.BaselineTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias MonkeyClaw.ModelRegistry.Baseline

  setup do
    original = Application.get_env(:monkey_claw, Baseline)
    on_exit(fn -> Application.put_env(:monkey_claw, Baseline, original) end)
    :ok
  end

  describe "all/0" do
    test "returns the configured entries list" do
      entries = [
        %{
          backend: "claude",
          provider: "anthropic",
          models: [
            %{model_id: "claude-sonnet-4-5", display_name: "Claude Sonnet 4.5", capabilities: %{}}
          ]
        }
      ]

      Application.put_env(:monkey_claw, Baseline, entries: entries)
      assert Baseline.all() == entries
    end

    test "returns empty list when not configured" do
      Application.put_env(:monkey_claw, Baseline, [])
      assert Baseline.all() == []
    end
  end

  describe "load!/0" do
    test "returns {:ok, entries} when every entry is structurally valid" do
      entries = [
        %{
          backend: "claude",
          provider: "anthropic",
          models: [%{model_id: "m1", display_name: "M1", capabilities: %{}}]
        },
        %{
          backend: "codex",
          provider: "openai",
          models: [%{model_id: "m2", display_name: "M2", capabilities: %{}}]
        }
      ]

      Application.put_env(:monkey_claw, Baseline, entries: entries)
      assert {:ok, ^entries} = Baseline.load!()
    end

    test "drops entries missing required keys, logs error, continues" do
      valid = %{
        backend: "claude",
        provider: "anthropic",
        models: [%{model_id: "m", display_name: "M", capabilities: %{}}]
      }

      invalid = %{backend: "oops"}

      Application.put_env(:monkey_claw, Baseline, entries: [invalid, valid])
      {:ok, result} = Baseline.load!()
      assert result == [valid]
    end

    test "drops entries where models is not a list" do
      bad = %{backend: "x", provider: "y", models: "nope"}
      Application.put_env(:monkey_claw, Baseline, entries: [bad])
      assert {:ok, []} = Baseline.load!()
    end

    test "drops non-map entries without crashing" do
      valid = %{
        backend: "claude",
        provider: "anthropic",
        models: [%{model_id: "m", display_name: "M", capabilities: %{}}]
      }

      entries = ["not a map", {:tuple, :form}, :atom, nil, valid]
      Application.put_env(:monkey_claw, Baseline, entries: entries)
      assert {:ok, [^valid]} = Baseline.load!()
    end
  end
end
