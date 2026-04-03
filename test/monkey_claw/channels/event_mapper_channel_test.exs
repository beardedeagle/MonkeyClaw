defmodule MonkeyClaw.Channels.EventMapperChannelTest do
  use MonkeyClaw.DataCase

  alias MonkeyClaw.Notifications.EventMapper

  # ──────────────────────────────────────────────
  # Channel inbound event
  # ──────────────────────────────────────────────

  describe "channel.message.inbound" do
    test "maps inbound message to notification attrs" do
      workspace_id = Ecto.UUID.generate()
      config_id = Ecto.UUID.generate()

      assert {:ok, attrs} =
               EventMapper.map_event(
                 [:monkey_claw, :channel, :message, :inbound],
                 %{},
                 %{
                   adapter_type: :slack,
                   workspace_id: workspace_id,
                   channel_config_id: config_id
                 }
               )

      assert attrs.workspace_id == workspace_id
      assert attrs.category == :channel
      assert attrs.severity == :info
      assert attrs.title =~ "slack"
      assert attrs.source_id == config_id
      assert attrs.source_type == "channel"
    end
  end

  # ──────────────────────────────────────────────
  # Channel outbound event
  # ──────────────────────────────────────────────

  describe "channel.message.outbound" do
    test "maps outbound message to notification attrs" do
      workspace_id = Ecto.UUID.generate()
      config_id = Ecto.UUID.generate()

      assert {:ok, attrs} =
               EventMapper.map_event(
                 [:monkey_claw, :channel, :message, :outbound],
                 %{},
                 %{
                   adapter_type: :telegram,
                   workspace_id: workspace_id,
                   channel_config_id: config_id
                 }
               )

      assert attrs.workspace_id == workspace_id
      assert attrs.category == :channel
      assert attrs.severity == :info
      assert attrs.title =~ "telegram"
    end
  end

  # ──────────────────────────────────────────────
  # Channel delivery failed event
  # ──────────────────────────────────────────────

  describe "channel.delivery.failed" do
    test "maps delivery failure to error notification" do
      workspace_id = Ecto.UUID.generate()

      assert {:ok, attrs} =
               EventMapper.map_event(
                 [:monkey_claw, :channel, :delivery, :failed],
                 %{},
                 %{
                   adapter_type: :discord,
                   workspace_id: workspace_id,
                   reason: :timeout
                 }
               )

      assert attrs.workspace_id == workspace_id
      assert attrs.category == :channel
      assert attrs.severity == :error
      assert attrs.title =~ "discord"
      assert attrs.metadata["reason"] =~ "timeout"
    end
  end

  # ──────────────────────────────────────────────
  # Agent activity events
  # ──────────────────────────────────────────────

  describe "agent_bridge.query.stop" do
    test "maps query completion to notification" do
      session_id = Ecto.UUID.generate()

      assert {:ok, attrs} =
               EventMapper.map_event(
                 [:monkey_claw, :agent_bridge, :query, :stop],
                 %{duration: 1_000_000},
                 %{session_id: session_id}
               )

      assert attrs.workspace_id == session_id
      assert attrs.category == :session
      assert attrs.severity == :info
      assert attrs.title == "Agent query completed"
      assert attrs.metadata["duration_ms"]
    end
  end

  describe "agent_bridge.stream.stop" do
    test "maps stream completion to notification" do
      session_id = Ecto.UUID.generate()

      assert {:ok, attrs} =
               EventMapper.map_event(
                 [:monkey_claw, :agent_bridge, :stream, :stop],
                 %{duration: 2_000_000},
                 %{session_id: session_id}
               )

      assert attrs.workspace_id == session_id
      assert attrs.category == :session
      assert attrs.severity == :info
      assert attrs.title == "Agent response complete"
    end
  end

  # ──────────────────────────────────────────────
  # Catch-all
  # ──────────────────────────────────────────────

  describe "unknown events" do
    test "returns :skip for unrecognized events" do
      assert :skip =
               EventMapper.map_event(
                 [:monkey_claw, :unknown, :event],
                 %{},
                 %{}
               )
    end
  end
end
