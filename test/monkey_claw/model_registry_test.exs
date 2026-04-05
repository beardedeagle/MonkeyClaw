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

  describe "ETS heir crash survival" do
    setup do
      start_supervised!(MonkeyClaw.ModelRegistry.EtsHeir)

      start_supervised!(
        {MonkeyClaw.ModelRegistry, [backends: [], default_interval_ms: :timer.hours(24)]},
        restart: :permanent
      )

      :ok
    end

    test "ETS table survives a ModelRegistry crash and claim round-trip succeeds" do
      tid_before = :ets.whereis(:monkey_claw_model_registry)
      assert tid_before != :undefined

      old_pid = Process.whereis(MonkeyClaw.ModelRegistry)
      ref = Process.monitor(old_pid)
      Process.exit(old_pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^old_pid, :killed}, 500

      # ExUnit supervisor restarts the registry (restart: :permanent).
      # Poll until a new pid is registered, proving the restart occurred.
      new_pid = wait_for_new_registry(old_pid)

      assert new_pid != old_pid

      # Table must still be alive after the crash.
      assert :ets.whereis(:monkey_claw_model_registry) != :undefined

      # The new registry must own the ETS table, proving the claim
      # round-trip (EtsHeir → give_away → new registry) succeeded.
      assert :ets.info(:monkey_claw_model_registry, :owner) == new_pid
    end
  end

  # Poll until a new pid is registered for ModelRegistry (distinct from
  # old_pid). Bounded to 100 attempts × 10 ms = 1 second max wait.
  defp wait_for_new_registry(old_pid, attempts \\ 100)

  defp wait_for_new_registry(_old_pid, 0),
    do: flunk("ModelRegistry did not restart within 1 second")

  defp wait_for_new_registry(old_pid, attempts) do
    case Process.whereis(MonkeyClaw.ModelRegistry) do
      nil ->
        :timer.sleep(10)
        wait_for_new_registry(old_pid, attempts - 1)

      ^old_pid ->
        :timer.sleep(10)
        wait_for_new_registry(old_pid, attempts - 1)

      new_pid when is_pid(new_pid) ->
        new_pid
    end
  end
end
