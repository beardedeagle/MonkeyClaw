defmodule MonkeyClaw.ModelRegistryE2ETest do
  @moduledoc """
  End-to-end test for the ModelRegistry: full supervision tree boot,
  read projections, on-demand refresh, and crash-restart continuity.

  Runs serially (async: false) because ModelRegistry is a named singleton
  and owns the :monkey_claw_model_registry ETS table atom.
  """

  use MonkeyClaw.DataCase, async: false

  alias MonkeyClaw.ModelRegistry
  alias MonkeyClaw.ModelRegistry.EtsHeir

  setup do
    original_baseline = Application.get_env(:monkey_claw, MonkeyClaw.ModelRegistry.Baseline)

    Application.put_env(:monkey_claw, MonkeyClaw.ModelRegistry.Baseline,
      entries: [
        %{
          backend: "claude",
          provider: "anthropic",
          models: [
            %{model_id: "baseline-sonnet", display_name: "Baseline Sonnet", capabilities: %{}}
          ]
        }
      ]
    )

    on_exit(fn ->
      case original_baseline do
        nil -> Application.delete_env(:monkey_claw, MonkeyClaw.ModelRegistry.Baseline)
        val -> Application.put_env(:monkey_claw, MonkeyClaw.ModelRegistry.Baseline, val)
      end
    end)

    start_supervised!(EtsHeir)

    registry_pid =
      start_supervised!(
        {ModelRegistry,
         [
           backends: ["claude"],
           backend_configs: %{
             "claude" => %{
               adapter: MonkeyClaw.AgentBridge.Backend.Test,
               list_models_response:
                 {:ok,
                  [
                    %{
                      provider: "anthropic",
                      model_id: "probe-sonnet",
                      display_name: "Probe Sonnet",
                      capabilities: %{}
                    }
                  ]}
             }
           },
           default_interval_ms: :timer.hours(24),
           startup_delay_ms: :timer.hours(24)
         ]}
      )

    # Gate on handle_continue(:load, _) draining before tests read ETS.
    _state = :sys.get_state(registry_pid)

    :ok
  end

  test "baseline is available before any probe runs" do
    models = ModelRegistry.list_for_backend("claude")
    assert Enum.any?(models, &(&1.model_id == "baseline-sonnet"))
  end

  test "on-demand refresh replaces baseline with probe result" do
    assert :ok = ModelRegistry.refresh("claude")
    models = ModelRegistry.list_for_backend("claude")
    assert Enum.any?(models, &(&1.model_id == "probe-sonnet"))
  end

  test "list_for_provider returns claude models tagged with anthropic" do
    assert :ok = ModelRegistry.refresh("claude")
    models = ModelRegistry.list_for_provider("anthropic")
    assert Enum.all?(models, &(&1.provider == "anthropic"))
    assert Enum.all?(models, &(&1.backend == "claude"))
  end

  test "crash + restart preserves cached rows via ETS heir" do
    assert :ok = ModelRegistry.refresh("claude")
    before = ModelRegistry.list_for_backend("claude")
    assert before != []

    pid = Process.whereis(ModelRegistry)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 500

    # Wait for supervisor to restart the process (deterministic polling).
    wait_until(
      fn ->
        new_pid = Process.whereis(ModelRegistry)
        is_pid(new_pid) and new_pid != pid
      end,
      100,
      "ModelRegistry did not restart within 1s after crash"
    )

    # Gate on handle_continue(:load, _) draining in the restarted process.
    _state = :sys.get_state(Process.whereis(ModelRegistry))

    after_crash = ModelRegistry.list_for_backend("claude")
    # Compare model_ids to avoid timestamp precision differences on reload.
    before_ids = Enum.map(before, & &1.model_id) |> Enum.sort()
    after_ids = Enum.map(after_crash, & &1.model_id) |> Enum.sort()
    assert after_ids == before_ids
  end

  # ── Helpers ──────────────────────────────────────

  # Poll until `fun.()` returns truthy. Mirrors the pattern in
  # model_registry_test.exs and session_model_hook_test.exs.
  defp wait_until(fun, attempts, msg) do
    cond do
      attempts == 0 -> flunk(msg)
      fun.() -> :ok
      true -> :timer.sleep(10) && wait_until(fun, attempts - 1, msg)
    end
  end
end
