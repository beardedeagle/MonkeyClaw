defmodule MonkeyClaw.AgentBridge.SessionModelHookTest do
  @moduledoc """
  Integration tests for the authenticated post-start session hook that
  notifies ModelRegistry after a successful session start (spec C3).

  Runs serially (async: false) because ModelRegistry is a named singleton
  and owns the :monkey_claw_model_registry ETS table atom.
  """

  use MonkeyClaw.DataCase, async: false

  alias MonkeyClaw.AgentBridge.Backend
  alias MonkeyClaw.AgentBridge.Session
  alias MonkeyClaw.ModelRegistry
  alias MonkeyClaw.ModelRegistry.EtsHeir

  setup do
    original_baseline = Application.get_env(:monkey_claw, MonkeyClaw.ModelRegistry.Baseline)
    Application.put_env(:monkey_claw, MonkeyClaw.ModelRegistry.Baseline, entries: [])

    on_exit(fn ->
      case original_baseline do
        nil -> Application.delete_env(:monkey_claw, MonkeyClaw.ModelRegistry.Baseline)
        val -> Application.put_env(:monkey_claw, MonkeyClaw.ModelRegistry.Baseline, val)
      end
    end)

    start_supervised!(EtsHeir)

    start_supervised!(
      {ModelRegistry,
       [
         backends: [],
         default_interval_ms: :timer.hours(24),
         startup_delay_ms: :timer.hours(24)
       ]}
    )

    :ok
  end

  describe "session hook — happy path" do
    test "models land in registry after session start" do
      session_id = unique_session_id()

      config = %{
        id: session_id,
        backend: Backend.Test,
        session_opts: %{
          backend: :test,
          list_models_response:
            {:ok,
             [
               %{
                 provider: "anthropic",
                 model_id: "claude-sonnet-4-6",
                 display_name: "Claude Sonnet 4.6",
                 capabilities: %{}
               }
             ]}
        }
      }

      _pid = start_supervised!({Session, config})

      # Poll until the async Task fires the cast and ModelRegistry writes
      # the row. Bounded to 100 attempts × 10ms = 1 second.
      wait_until(
        fn ->
          Enum.any?(ModelRegistry.list_for_backend("test"), fn m ->
            m.model_id == "claude-sonnet-4-6"
          end)
        end,
        100,
        "session hook did not land claude-sonnet-4-6 in registry within 1s"
      )

      models = ModelRegistry.list_for_backend("test")
      assert models != []
      assert Enum.any?(models, fn m -> m.model_id == "claude-sonnet-4-6" end)
    end
  end

  describe "session hook — unregistered pid guard" do
    test "registry ignores cast from unregistered pid with debug log" do
      unregistered_payload = [
        %{
          backend: "claude",
          provider: "anthropic",
          source: "session",
          refreshed_at: DateTime.utc_now(),
          refreshed_mono: System.monotonic_time(),
          models: [%{model_id: "ghost", display_name: "Ghost", capabilities: %{}}]
        }
      ]

      GenServer.cast(ModelRegistry, {:session_hook, self(), unregistered_payload})
      :timer.sleep(50)

      assert ModelRegistry.list_for_backend("claude") == []
    end
  end

  # ──────────────────────────────────────────────
  # Helpers
  # ──────────────────────────────────────────────

  defp unique_session_id do
    "test-session-hook-#{System.unique_integer([:positive])}"
  end

  # Poll until `fun.()` returns truthy. Mirrors the pattern in
  # model_registry_test.exs to avoid flaky timing-based assertions.
  defp wait_until(fun, attempts, msg) do
    cond do
      attempts == 0 -> flunk(msg)
      fun.() -> :ok
      true -> :timer.sleep(10) && wait_until(fun, attempts - 1, msg)
    end
  end
end
