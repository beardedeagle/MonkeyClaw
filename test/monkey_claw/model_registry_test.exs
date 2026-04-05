defmodule MonkeyClaw.ModelRegistryTest do
  @moduledoc """
  Integration tests for the rewritten ModelRegistry.

  Runs serially (async: false) because ModelRegistry is a named
  singleton (__MODULE__) and owns the :monkey_claw_model_registry
  ETS table atom.
  """

  use MonkeyClaw.DataCase, async: false

  alias MonkeyClaw.ModelRegistry
  alias MonkeyClaw.ModelRegistry.CachedModel
  alias MonkeyClaw.ModelRegistry.EtsHeir
  alias MonkeyClaw.Repo

  describe "start_link/1 and lifecycle" do
    setup do
      original = Application.get_env(:monkey_claw, MonkeyClaw.ModelRegistry.Baseline)
      Application.put_env(:monkey_claw, MonkeyClaw.ModelRegistry.Baseline, entries: [])

      on_exit(fn ->
        if original,
          do: Application.put_env(:monkey_claw, MonkeyClaw.ModelRegistry.Baseline, original),
          else: Application.delete_env(:monkey_claw, MonkeyClaw.ModelRegistry.Baseline)
      end)

      :ok
    end

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
      original = Application.get_env(:monkey_claw, MonkeyClaw.ModelRegistry.Baseline)
      Application.put_env(:monkey_claw, MonkeyClaw.ModelRegistry.Baseline, entries: [])

      on_exit(fn ->
        if original,
          do: Application.put_env(:monkey_claw, MonkeyClaw.ModelRegistry.Baseline, original),
          else: Application.delete_env(:monkey_claw, MonkeyClaw.ModelRegistry.Baseline)
      end)

      start_supervised!(EtsHeir)

      start_supervised!(
        {ModelRegistry, [backends: [], default_interval_ms: :timer.hours(24)]},
        restart: :permanent
      )

      :ok
    end

    test "ETS table survives a ModelRegistry crash and claim round-trip succeeds" do
      tid_before = :ets.whereis(:monkey_claw_model_registry)
      assert tid_before != :undefined

      old_pid = Process.whereis(ModelRegistry)
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

  describe "boot sequence" do
    setup do
      Application.put_env(:monkey_claw, MonkeyClaw.ModelRegistry.Baseline,
        entries: [
          %{
            backend: "claude",
            provider: "anthropic",
            models: [
              %{
                model_id: "claude-sonnet-4-6",
                display_name: "Claude Sonnet 4.6",
                capabilities: %{}
              }
            ]
          }
        ]
      )

      on_exit(fn ->
        Application.delete_env(:monkey_claw, MonkeyClaw.ModelRegistry.Baseline)
      end)

      :ok
    end

    test "cold start with empty SQLite seeds baseline into ETS and SQLite" do
      start_supervised!(EtsHeir)

      registry_pid =
        start_supervised!({ModelRegistry, [backends: [], default_interval_ms: :timer.hours(24)]})

      # Shared-mode sandbox via DataCase (async: false) — no allow needed.
      # :sys.get_state gates on handle_continue(:load, _) draining.
      _state = :sys.get_state(registry_pid)

      models = ModelRegistry.list_for_backend("claude")
      assert length(models) == 1
      assert hd(models).model_id == "claude-sonnet-4-6"

      # SQLite should now contain the row too.
      rows = Repo.all(CachedModel)
      assert length(rows) == 1
    end

    test "warm start with existing SQLite row skips duplicate baseline seed" do
      start_supervised!(EtsHeir)

      registry_pid =
        start_supervised!({ModelRegistry, [backends: [], default_interval_ms: :timer.hours(24)]})

      # Shared-mode sandbox via DataCase (async: false) — no allow needed.
      # :sys.get_state gates on handle_continue(:load, _) draining.
      _state = :sys.get_state(registry_pid)

      assert length(ModelRegistry.list_for_backend("claude")) == 1
      row_count_before = Repo.aggregate(CachedModel, :count)

      # Stop and restart to exercise the warm path.
      stop_supervised!(ModelRegistry)

      registry_pid2 =
        start_supervised!({ModelRegistry, [backends: [], default_interval_ms: :timer.hours(24)]})

      # Shared-mode sandbox via DataCase (async: false) — no allow needed.
      # :sys.get_state gates on handle_continue(:load, _) draining.
      _state2 = :sys.get_state(registry_pid2)

      row_count_after = Repo.aggregate(CachedModel, :count)
      assert row_count_before == row_count_after
      assert length(ModelRegistry.list_for_backend("claude")) == 1
    end
  end

  describe "upsert/1 write funnel" do
    setup do
      original_baseline = Application.get_env(:monkey_claw, MonkeyClaw.ModelRegistry.Baseline)
      Application.put_env(:monkey_claw, MonkeyClaw.ModelRegistry.Baseline, entries: [])

      on_exit(fn ->
        if original_baseline do
          Application.put_env(:monkey_claw, MonkeyClaw.ModelRegistry.Baseline, original_baseline)
        else
          Application.delete_env(:monkey_claw, MonkeyClaw.ModelRegistry.Baseline)
        end
      end)

      start_supervised!(MonkeyClaw.ModelRegistry.EtsHeir)

      registry_pid =
        start_supervised!(
          {MonkeyClaw.ModelRegistry, [backends: [], default_interval_ms: :timer.hours(24)]}
        )

      # Gate on handle_continue(:load, _) completion before tests run assertions.
      _ = :sys.get_state(registry_pid)

      :ok
    end

    test "accepts valid writes and exposes them via read API" do
      now = DateTime.utc_now()
      mono = System.monotonic_time()

      writes = [
        %{
          backend: "claude",
          provider: "anthropic",
          source: "probe",
          refreshed_at: now,
          refreshed_mono: mono,
          models: [
            %{model_id: "claude-sonnet-4-6", display_name: "Claude Sonnet 4.6", capabilities: %{}}
          ]
        }
      ]

      assert {:ok, [_]} = MonkeyClaw.ModelRegistry.upsert(writes)
      assert [model] = MonkeyClaw.ModelRegistry.list_for_backend("claude")
      assert model.model_id == "claude-sonnet-4-6"
    end

    test "rejects stale writes when a newer version exists" do
      older = DateTime.add(DateTime.utc_now(), -10, :second)
      newer = DateTime.utc_now()
      mono_old = System.monotonic_time()
      mono_new = System.monotonic_time() + 1

      fresh = %{
        backend: "claude",
        provider: "anthropic",
        source: "probe",
        refreshed_at: newer,
        refreshed_mono: mono_new,
        models: [%{model_id: "fresh", display_name: "Fresh", capabilities: %{}}]
      }

      stale = %{
        fresh
        | refreshed_at: older,
          refreshed_mono: mono_old,
          models: [%{model_id: "stale", display_name: "Stale", capabilities: %{}}]
      }

      assert {:ok, [_]} = MonkeyClaw.ModelRegistry.upsert([fresh])
      assert {:ok, []} = MonkeyClaw.ModelRegistry.upsert([stale])

      [model] = MonkeyClaw.ModelRegistry.list_for_backend("claude")
      assert model.model_id == "fresh"
    end

    test "drops invalid writes with a log, applies the valid ones" do
      now = DateTime.utc_now()

      valid = %{
        backend: "claude",
        provider: "anthropic",
        source: "probe",
        refreshed_at: now,
        refreshed_mono: System.monotonic_time(),
        models: [%{model_id: "m", display_name: "M", capabilities: %{}}]
      }

      invalid = Map.put(valid, :backend, "BadBackend")

      assert {:ok, [_]} = MonkeyClaw.ModelRegistry.upsert([invalid, valid])
      assert [_] = MonkeyClaw.ModelRegistry.list_for_backend("claude")
    end

    test "fans out a single write with multiple providers into multiple rows" do
      now = DateTime.utc_now()
      mono = System.monotonic_time()

      writes = [
        %{
          backend: "copilot",
          provider: "openai",
          source: "probe",
          refreshed_at: now,
          refreshed_mono: mono,
          models: [%{model_id: "gpt-5", display_name: "GPT-5", capabilities: %{}}]
        },
        %{
          backend: "copilot",
          provider: "anthropic",
          source: "probe",
          refreshed_at: now,
          refreshed_mono: mono,
          models: [
            %{
              model_id: "claude-sonnet-4-6",
              display_name: "Claude Sonnet 4.6",
              capabilities: %{}
            }
          ]
        }
      ]

      assert {:ok, applied} = MonkeyClaw.ModelRegistry.upsert(writes)
      assert length(applied) == 2

      copilot_models = MonkeyClaw.ModelRegistry.list_for_backend("copilot")
      assert length(copilot_models) == 2
      assert Enum.any?(copilot_models, &(&1.provider == "openai"))
      assert Enum.any?(copilot_models, &(&1.provider == "anthropic"))
    end
  end

  # Poll until a new pid is registered for ModelRegistry (distinct from
  # old_pid). Bounded to 100 attempts × 10 ms = 1 second max wait.
  defp wait_for_new_registry(old_pid, attempts \\ 100)

  defp wait_for_new_registry(_old_pid, 0),
    do: flunk("ModelRegistry did not restart within 1 second")

  defp wait_for_new_registry(old_pid, attempts) do
    case Process.whereis(ModelRegistry) do
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
