defmodule MonkeyClaw.AgentBridge.TelemetryTest do
  use ExUnit.Case, async: true

  alias MonkeyClaw.AgentBridge.Telemetry, as: BridgeTelemetry

  setup do
    test_pid = self()
    handler_id = "telemetry-test-#{System.unique_integer([:positive])}"

    events = [
      [:monkey_claw, :agent_bridge, :session, :start],
      [:monkey_claw, :agent_bridge, :session, :stop],
      [:monkey_claw, :agent_bridge, :session, :exception],
      [:monkey_claw, :agent_bridge, :query, :start],
      [:monkey_claw, :agent_bridge, :query, :stop],
      [:monkey_claw, :agent_bridge, :query, :exception],
      [:monkey_claw, :agent_bridge, :event, :received]
    ]

    :telemetry.attach_many(
      handler_id,
      events,
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok
  end

  describe "session_start/1" do
    test "emits session start event and returns monotonic time" do
      metadata = %{session_id: "test-1", config: %{}}
      start_time = BridgeTelemetry.session_start(metadata)

      assert is_integer(start_time)

      assert_receive {:telemetry, [:monkey_claw, :agent_bridge, :session, :start],
                      %{system_time: sys_time}, ^metadata}

      assert is_integer(sys_time)
    end
  end

  describe "session_stop/2" do
    test "emits session stop event with non-negative duration" do
      start_time = System.monotonic_time()
      metadata = %{session_id: "test-1", reason: :normal}

      BridgeTelemetry.session_stop(start_time, metadata)

      assert_receive {:telemetry, [:monkey_claw, :agent_bridge, :session, :stop],
                      %{duration: duration}, ^metadata}

      assert is_integer(duration)
      assert duration >= 0
    end
  end

  describe "session_exception/2" do
    test "emits session exception event with duration" do
      start_time = System.monotonic_time()
      metadata = %{session_id: "test-1", kind: :crash, reason: :boom}

      BridgeTelemetry.session_exception(start_time, metadata)

      assert_receive {:telemetry, [:monkey_claw, :agent_bridge, :session, :exception],
                      %{duration: duration}, ^metadata}

      assert duration >= 0
    end
  end

  describe "query_start/1" do
    test "emits query start event and returns monotonic time" do
      metadata = %{session_id: "test-1"}
      start_time = BridgeTelemetry.query_start(metadata)

      assert is_integer(start_time)

      assert_receive {:telemetry, [:monkey_claw, :agent_bridge, :query, :start],
                      %{system_time: _}, ^metadata}
    end
  end

  describe "query_stop/2" do
    test "emits query stop event with duration" do
      start_time = System.monotonic_time()
      metadata = %{session_id: "test-1", message_count: 3}

      BridgeTelemetry.query_stop(start_time, metadata)

      assert_receive {:telemetry, [:monkey_claw, :agent_bridge, :query, :stop], %{duration: _},
                      ^metadata}
    end
  end

  describe "query_exception/2" do
    test "emits query exception event with duration" do
      start_time = System.monotonic_time()
      metadata = %{session_id: "test-1", kind: :error, reason: :timeout}

      BridgeTelemetry.query_exception(start_time, metadata)

      assert_receive {:telemetry, [:monkey_claw, :agent_bridge, :query, :exception],
                      %{duration: _}, ^metadata}
    end
  end

  describe "event_received/1" do
    test "emits event received with count of 1" do
      metadata = %{session_id: "test-1", event_type: :message}

      BridgeTelemetry.event_received(metadata)

      assert_receive {:telemetry, [:monkey_claw, :agent_bridge, :event, :received], %{count: 1},
                      ^metadata}
    end
  end
end
