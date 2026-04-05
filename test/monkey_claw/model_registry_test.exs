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
      # Poll until ownership settles — give_away is async relative to
      # the pid being registered under __MODULE__.
      wait_for_ets_owner(:monkey_claw_model_registry, new_pid)
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
      Process.sleep(1)
      mono_new = System.monotonic_time()

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

  describe "tick handler and probe scheduling" do
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

      :ok
    end

    test "first tick dispatches probe tasks into in_flight map" do
      backend_configs = %{
        "test_be" => %{
          adapter: MonkeyClaw.AgentBridge.Backend.Test,
          list_models_delay_ms: 100
        }
      }

      start_supervised!(
        {MonkeyClaw.ModelRegistry,
         [
           backends: ["test_be"],
           backend_configs: backend_configs,
           default_interval_ms: 200,
           startup_delay_ms: 20
         ]}
      )

      # Wait long enough for the first tick to dispatch but not long
      # enough for the slow backend to finish. Inspect in_flight via
      # the sys:get_state introspection for test-only visibility.
      :timer.sleep(50)

      state = :sys.get_state(MonkeyClaw.ModelRegistry)
      assert map_size(state.in_flight) == 1
    end
  end

  describe "probe task result handling" do
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

      :ok
    end

    test "successful probe result lands in the cache via upsert" do
      backend_configs = %{
        "test_be" => %{
          adapter: MonkeyClaw.AgentBridge.Backend.Test,
          list_models_response:
            {:ok,
             [
               %{provider: "anthropic", model_id: "m1", display_name: "M1", capabilities: %{}}
             ]}
        }
      }

      start_supervised!(
        {MonkeyClaw.ModelRegistry,
         [
           backends: ["test_be"],
           backend_configs: backend_configs,
           default_interval_ms: :timer.hours(24),
           startup_delay_ms: 20
         ]}
      )

      wait_until(
        fn -> MonkeyClaw.ModelRegistry.list_for_backend("test_be") != [] end,
        100,
        "probe result never landed in cache"
      )

      models = MonkeyClaw.ModelRegistry.list_for_backend("test_be")
      assert [%{model_id: "m1", provider: "anthropic"}] = models
    end

    test "error probe result increments backoff and keeps stale cache" do
      backend_configs = %{
        "flaky_be" => %{
          adapter: MonkeyClaw.AgentBridge.Backend.Test,
          list_models_response: {:error, :upstream_down}
        }
      }

      start_supervised!(
        {MonkeyClaw.ModelRegistry,
         [
           backends: ["flaky_be"],
           backend_configs: backend_configs,
           default_interval_ms: :timer.hours(24),
           startup_delay_ms: 20
         ]}
      )

      wait_until(
        fn -> Map.has_key?(:sys.get_state(MonkeyClaw.ModelRegistry).backoff, "flaky_be") end,
        100,
        "backoff never applied for flaky_be"
      )

      state = :sys.get_state(MonkeyClaw.ModelRegistry)
      assert Map.has_key?(state.backoff, "flaky_be")
      assert state.backoff["flaky_be"] >= 5_000
    end

    test "crash in backend list_models is caught via DOWN with abnormal reason" do
      backend_configs = %{
        "crash_be" => %{
          adapter: MonkeyClaw.AgentBridge.Backend.Test,
          list_models_response: {:crash, "boom"}
        }
      }

      start_supervised!(
        {MonkeyClaw.ModelRegistry,
         [
           backends: ["crash_be"],
           backend_configs: backend_configs,
           default_interval_ms: :timer.hours(24),
           startup_delay_ms: 20
         ]}
      )

      wait_until(
        fn -> Map.has_key?(:sys.get_state(MonkeyClaw.ModelRegistry).backoff, "crash_be") end,
        100,
        "backoff never applied for crash_be after crash"
      )

      # Registry should still be alive.
      assert Process.alive?(Process.whereis(MonkeyClaw.ModelRegistry))

      state = :sys.get_state(MonkeyClaw.ModelRegistry)
      assert Map.has_key?(state.backoff, "crash_be")
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

  # Poll until the ETS table is owned by expected_pid. Bounded to
  # 100 attempts × 10 ms = 1 second max wait.
  defp wait_for_ets_owner(table, expected_pid, attempts \\ 100)

  defp wait_for_ets_owner(_table, _expected_pid, 0),
    do: flunk("ETS table did not transfer ownership within 1 second")

  defp wait_for_ets_owner(table, expected_pid, attempts) do
    case :ets.info(table, :owner) do
      ^expected_pid ->
        :ok

      _ ->
        :timer.sleep(10)
        wait_for_ets_owner(table, expected_pid, attempts - 1)
    end
  end

  # Poll until `fun.()` returns a truthy value, bounded to 100 × 10 ms = 1 second.
  defp wait_until(fun, attempts, msg) do
    cond do
      attempts == 0 -> flunk(msg)
      fun.() -> :ok
      true -> :timer.sleep(10) && wait_until(fun, attempts - 1, msg)
    end
  end

  describe "refresh/1 and refresh_all/0" do
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
      :ok
    end

    test "refresh/1 runs a synchronous probe and returns :ok" do
      backend_configs = %{
        "test_be" => %{
          adapter: MonkeyClaw.AgentBridge.Backend.Test,
          list_models_response:
            {:ok,
             [
               %{
                 provider: "anthropic",
                 model_id: "refreshed",
                 display_name: "R",
                 capabilities: %{}
               }
             ]}
        }
      }

      start_supervised!(
        {MonkeyClaw.ModelRegistry,
         [
           backends: ["test_be"],
           backend_configs: backend_configs,
           default_interval_ms: :timer.hours(24),
           startup_delay_ms: :timer.hours(24)
         ]}
      )

      assert :ok = MonkeyClaw.ModelRegistry.refresh("test_be")
      assert [%{model_id: "refreshed"}] = MonkeyClaw.ModelRegistry.list_for_backend("test_be")
    end

    test "refresh/1 returns {:error, reason} when backend returns an error" do
      backend_configs = %{
        "flaky" => %{
          adapter: MonkeyClaw.AgentBridge.Backend.Test,
          list_models_response: {:error, :boom}
        }
      }

      start_supervised!(
        {MonkeyClaw.ModelRegistry,
         [
           backends: ["flaky"],
           backend_configs: backend_configs,
           default_interval_ms: :timer.hours(24),
           startup_delay_ms: :timer.hours(24)
         ]}
      )

      assert {:error, :boom} = MonkeyClaw.ModelRegistry.refresh("flaky")
    end

    test "refresh_all/0 iterates every configured backend" do
      backend_configs = %{
        "a" => %{
          adapter: MonkeyClaw.AgentBridge.Backend.Test,
          list_models_response:
            {:ok,
             [%{provider: "anthropic", model_id: "a1", display_name: "A1", capabilities: %{}}]}
        },
        "b" => %{
          adapter: MonkeyClaw.AgentBridge.Backend.Test,
          list_models_response:
            {:ok, [%{provider: "openai", model_id: "b1", display_name: "B1", capabilities: %{}}]}
        }
      }

      start_supervised!(
        {MonkeyClaw.ModelRegistry,
         [
           backends: ["a", "b"],
           backend_configs: backend_configs,
           default_interval_ms: :timer.hours(24),
           startup_delay_ms: :timer.hours(24)
         ]}
      )

      assert :ok = MonkeyClaw.ModelRegistry.refresh_all()
      assert length(MonkeyClaw.ModelRegistry.list_for_backend("a")) == 1
      assert length(MonkeyClaw.ModelRegistry.list_for_backend("b")) == 1
    end

    test "refresh/1 returns {:error, {:malformed_probe_result, _}} when backend returns a non-contract shape" do
      backend_configs = %{
        "weird" => %{
          adapter: MonkeyClaw.AgentBridge.Backend.Test,
          list_models_response: {:ok, :not_a_list}
        }
      }

      start_supervised!(
        {MonkeyClaw.ModelRegistry,
         [
           backends: ["weird"],
           backend_configs: backend_configs,
           default_interval_ms: :timer.hours(24),
           startup_delay_ms: :timer.hours(24)
         ]}
      )

      assert {:error, {:malformed_probe_result, {:ok, :not_a_list}}} =
               MonkeyClaw.ModelRegistry.refresh("weird")
    end
  end
end
