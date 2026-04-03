defmodule MonkeyClaw.ChannelsTest do
  use MonkeyClaw.DataCase

  alias MonkeyClaw.Channels
  alias MonkeyClaw.Channels.ChannelConfig
  alias MonkeyClaw.Channels.ChannelMessage

  import MonkeyClaw.Factory

  # ──────────────────────────────────────────────
  # create_config/2
  # ──────────────────────────────────────────────

  describe "create_config/2" do
    test "creates web channel config within workspace" do
      workspace = insert_workspace!()

      {:ok, config} =
        Channels.create_config(workspace, %{
          name: "Web Chat",
          adapter_type: :web,
          config: %{}
        })

      assert %ChannelConfig{} = config
      assert config.workspace_id == workspace.id
      assert config.adapter_type == :web
      assert config.name == "Web Chat"
      assert config.enabled == true
      assert config.status == :disconnected
    end

    test "creates slack channel config with adapter-specific config" do
      workspace = insert_workspace!()

      {:ok, config} =
        Channels.create_config(workspace, %{
          name: "Team Slack",
          adapter_type: :slack,
          config: %{
            "bot_token" => "xoxb-test-token",
            "signing_secret" => "test-secret",
            "channel_id" => "C0123456789"
          }
        })

      assert config.adapter_type == :slack
      assert config.config["bot_token"] == "xoxb-test-token"
      assert config.config["channel_id"] == "C0123456789"
    end

    test "rejects missing name" do
      workspace = insert_workspace!()

      {:error, changeset} =
        Channels.create_config(workspace, %{
          adapter_type: :web,
          config: %{}
        })

      assert errors_on(changeset).name
    end

    test "rejects missing adapter_type" do
      workspace = insert_workspace!()

      {:error, changeset} =
        Channels.create_config(workspace, %{
          name: "Missing type",
          config: %{}
        })

      assert errors_on(changeset).adapter_type
    end

    test "rejects invalid adapter_type" do
      workspace = insert_workspace!()

      {:error, changeset} =
        Channels.create_config(workspace, %{
          name: "Bad type",
          adapter_type: :invalid,
          config: %{}
        })

      assert errors_on(changeset).adapter_type
    end

    test "enforces unique name per workspace" do
      workspace = insert_workspace!()
      _ = insert_channel_config!(workspace, %{name: "unique-name"})

      {:error, changeset} =
        Channels.create_config(workspace, %{
          name: "unique-name",
          adapter_type: :web,
          config: %{}
        })

      assert errors_on(changeset).name
    end
  end

  # ──────────────────────────────────────────────
  # get_config/1
  # ──────────────────────────────────────────────

  describe "get_config/1" do
    test "returns config by ID" do
      workspace = insert_workspace!()
      config = insert_channel_config!(workspace)

      assert {:ok, found} = Channels.get_config(config.id)
      assert found.id == config.id
    end

    test "returns error for nonexistent ID" do
      assert {:error, :not_found} = Channels.get_config(Ecto.UUID.generate())
    end
  end

  # ──────────────────────────────────────────────
  # list_configs/1
  # ──────────────────────────────────────────────

  describe "list_configs/1" do
    test "lists configs for a workspace" do
      workspace = insert_workspace!()
      _ = insert_channel_config!(workspace, %{name: "First"})
      _ = insert_channel_config!(workspace, %{name: "Second"})

      configs = Channels.list_configs(workspace.id)
      assert length(configs) == 2
    end

    test "does not return configs from other workspaces" do
      workspace1 = insert_workspace!()
      workspace2 = insert_workspace!()
      _ = insert_channel_config!(workspace1, %{name: "WS1 Config"})
      _ = insert_channel_config!(workspace2, %{name: "WS2 Config"})

      configs = Channels.list_configs(workspace1.id)
      assert length(configs) == 1
      assert hd(configs).name == "WS1 Config"
    end
  end

  # ──────────────────────────────────────────────
  # list_enabled_configs/1
  # ──────────────────────────────────────────────

  describe "list_enabled_configs/1" do
    test "only returns enabled configs" do
      workspace = insert_workspace!()
      _ = insert_channel_config!(workspace, %{name: "Enabled", enabled: true})
      _ = insert_channel_config!(workspace, %{name: "Disabled", enabled: false})

      configs = Channels.list_enabled_configs(workspace.id)
      assert length(configs) == 1
      assert hd(configs).name == "Enabled"
    end
  end

  # ──────────────────────────────────────────────
  # update_config/2
  # ──────────────────────────────────────────────

  describe "update_config/2" do
    test "updates config name" do
      workspace = insert_workspace!()
      config = insert_channel_config!(workspace, %{name: "Original"})

      {:ok, updated} = Channels.update_config(config, %{name: "Updated"})
      assert updated.name == "Updated"
    end

    test "updates enabled status" do
      workspace = insert_workspace!()
      config = insert_channel_config!(workspace, %{enabled: true})

      {:ok, updated} = Channels.update_config(config, %{enabled: false})
      assert updated.enabled == false
    end
  end

  # ──────────────────────────────────────────────
  # delete_config/1
  # ──────────────────────────────────────────────

  describe "delete_config/1" do
    test "deletes a config" do
      workspace = insert_workspace!()
      config = insert_channel_config!(workspace)

      {:ok, _} = Channels.delete_config(config)
      assert {:error, :not_found} = Channels.get_config(config.id)
    end
  end

  # ──────────────────────────────────────────────
  # update_status/2
  # ──────────────────────────────────────────────

  describe "update_status/2" do
    test "updates connection status" do
      workspace = insert_workspace!()
      config = insert_channel_config!(workspace)

      assert config.status == :disconnected
      {:ok, updated} = Channels.update_status(config, :connected)
      assert updated.status == :connected
    end
  end

  # ──────────────────────────────────────────────
  # record_message/2
  # ──────────────────────────────────────────────

  describe "record_message/2" do
    test "records an inbound message" do
      workspace = insert_workspace!()
      config = insert_channel_config!(workspace)

      {:ok, message} =
        Channels.record_message(config, %{
          direction: :inbound,
          content: "Hello from Slack"
        })

      assert %ChannelMessage{} = message
      assert message.channel_config_id == config.id
      assert message.workspace_id == workspace.id
      assert message.direction == :inbound
      assert message.content == "Hello from Slack"
    end

    test "records an outbound message with metadata" do
      workspace = insert_workspace!()
      config = insert_channel_config!(workspace)

      {:ok, message} =
        Channels.record_message(config, %{
          direction: :outbound,
          content: "Agent response",
          metadata: %{"reply_to" => "msg-123"},
          external_id: "ext-456"
        })

      assert message.direction == :outbound
      assert message.metadata["reply_to"] == "msg-123"
      assert message.external_id == "ext-456"
    end

    test "rejects missing direction" do
      workspace = insert_workspace!()
      config = insert_channel_config!(workspace)

      {:error, changeset} =
        Channels.record_message(config, %{content: "No direction"})

      assert errors_on(changeset).direction
    end
  end

  # ──────────────────────────────────────────────
  # list_messages/2
  # ──────────────────────────────────────────────

  describe "list_messages/2" do
    test "lists messages for a channel config" do
      workspace = insert_workspace!()
      config = insert_channel_config!(workspace)

      {:ok, _} = Channels.record_message(config, %{direction: :inbound, content: "One"})
      {:ok, _} = Channels.record_message(config, %{direction: :outbound, content: "Two"})

      messages = Channels.list_messages(config.id)
      assert length(messages) == 2
    end

    test "orders messages most recent first" do
      workspace = insert_workspace!()
      config = insert_channel_config!(workspace)

      {:ok, _} = Channels.record_message(config, %{direction: :inbound, content: "First"})
      {:ok, _} = Channels.record_message(config, %{direction: :inbound, content: "Second"})

      [newest | _] = Channels.list_messages(config.id)
      assert newest.content == "Second"
    end
  end

  # ──────────────────────────────────────────────
  # PubSub
  # ──────────────────────────────────────────────

  describe "PubSub" do
    test "subscribe and receive channel events" do
      workspace = insert_workspace!()
      :ok = Channels.subscribe(workspace.id)

      Phoenix.PubSub.broadcast(
        MonkeyClaw.PubSub,
        "channels:#{workspace.id}",
        {:channel_message, :inbound, "test"}
      )

      assert_receive {:channel_message, :inbound, "test"}
    end
  end
end
