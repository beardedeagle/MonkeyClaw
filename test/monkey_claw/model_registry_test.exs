defmodule MonkeyClaw.ModelRegistryTest do
  @moduledoc """
  Integration tests for the rewritten ModelRegistry.

  Runs serially (async: false) because ModelRegistry is a named
  singleton (__MODULE__) and owns the :monkey_claw_model_registry
  ETS table atom.
  """

  use MonkeyClaw.DataCase, async: false

  alias MonkeyClaw.ModelRegistry

  describe "start_link/1 and lifecycle" do
    test "starts under __MODULE__ and creates the ETS table" do
      start_supervised!({ModelRegistry, [backends: [], default_interval_ms: :timer.hours(24)]})
      assert Process.whereis(ModelRegistry) |> is_pid()
      assert :ets.whereis(:monkey_claw_model_registry) != :undefined
    end

    test "initial reads return empty collections on an empty SQLite + empty baseline" do
      start_supervised!({ModelRegistry, [backends: [], default_interval_ms: :timer.hours(24)]})
      assert ModelRegistry.list_for_backend("claude") == []
      assert ModelRegistry.list_for_provider("anthropic") == []
      assert ModelRegistry.list_all_by_backend() == %{}
      assert ModelRegistry.list_all_by_provider() == %{}
    end

    test "survives unexpected messages" do
      start_supervised!({ModelRegistry, [backends: [], default_interval_ms: :timer.hours(24)]})
      pid = Process.whereis(ModelRegistry)
      send(pid, :random_garbage)
      :timer.sleep(20)
      assert Process.alive?(pid)
    end
  end
end
