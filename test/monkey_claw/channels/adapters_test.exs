defmodule MonkeyClaw.Channels.AdaptersTest do
  use MonkeyClaw.DataCase

  alias MonkeyClaw.Channels.Adapters.Discord
  alias MonkeyClaw.Channels.Adapters.Slack
  alias MonkeyClaw.Channels.Adapters.Telegram
  alias MonkeyClaw.Channels.Adapters.Web

  # ──────────────────────────────────────────────
  # Adapter.for_type/1
  # ──────────────────────────────────────────────

  describe "Adapter.for_type/1" do
    alias MonkeyClaw.Channels.Adapter

    test "resolves known adapter types" do
      assert {:ok, Slack} = Adapter.for_type(:slack)
      assert {:ok, Discord} = Adapter.for_type(:discord)
      assert {:ok, Telegram} = Adapter.for_type(:telegram)
      assert {:ok, Web} = Adapter.for_type(:web)
    end

    test "rejects unknown adapter type" do
      assert {:error, :unknown_adapter} = Adapter.for_type(:unknown)
    end
  end

  # ──────────────────────────────────────────────
  # Web Adapter
  # ──────────────────────────────────────────────

  describe "Web adapter" do
    test "validate_config always succeeds" do
      assert :ok = Web.validate_config(%{})
      assert :ok = Web.validate_config(%{"anything" => "goes"})
    end

    test "persistent? returns false" do
      refute Web.persistent?()
    end

    test "send_message returns :ok" do
      assert :ok = Web.send_message(%{}, %{content: "test"})
    end

    test "parse_inbound returns error (web uses LiveView, not webhooks)" do
      assert {:error, :not_applicable} = Web.parse_inbound(%{}, "{}")
    end

    test "verify_request returns :ok" do
      assert :ok = Web.verify_request(%{}, %{}, "")
    end
  end

  # ──────────────────────────────────────────────
  # Slack Adapter — validate_config
  # ──────────────────────────────────────────────

  describe "Slack validate_config/1" do
    test "accepts valid config" do
      config = %{
        "bot_token" => "xoxb-test-token",
        "signing_secret" => "test-secret",
        "channel_id" => "C0123456789"
      }

      assert :ok = Slack.validate_config(config)
    end

    test "rejects missing bot_token" do
      config = %{
        "signing_secret" => "test-secret",
        "channel_id" => "C0123456789"
      }

      assert {:error, "missing required config: " <> _} = Slack.validate_config(config)
    end

    test "rejects missing signing_secret" do
      config = %{
        "bot_token" => "xoxb-test-token",
        "channel_id" => "C0123456789"
      }

      assert {:error, "missing required config: " <> _} = Slack.validate_config(config)
    end

    test "rejects missing channel_id" do
      config = %{
        "bot_token" => "xoxb-test-token",
        "signing_secret" => "test-secret"
      }

      assert {:error, "missing required config: " <> _} = Slack.validate_config(config)
    end
  end

  # ──────────────────────────────────────────────
  # Slack Adapter — parse_inbound
  # ──────────────────────────────────────────────

  describe "Slack parse_inbound/2" do
    test "handles url_verification challenge" do
      body =
        Jason.encode!(%{
          "type" => "url_verification",
          "challenge" => "test-challenge-value"
        })

      assert {:ok, %{challenge: %{"challenge" => "test-challenge-value"}}} =
               Slack.parse_inbound(%Plug.Conn{}, body)
    end

    test "parses message event" do
      body =
        Jason.encode!(%{
          "event" => %{
            "type" => "message",
            "text" => "Hello agent",
            "user" => "U123",
            "channel" => "C456",
            "ts" => "1234567890.123456"
          }
        })

      assert {:ok, message} = Slack.parse_inbound(%Plug.Conn{}, body)
      assert message.content == "Hello agent"
      assert message.external_id == "1234567890.123456"
      assert message.metadata.user == "U123"
    end

    test "rejects bot messages to prevent loops" do
      body =
        Jason.encode!(%{
          "event" => %{
            "type" => "message",
            "text" => "Bot response",
            "bot_id" => "B123"
          }
        })

      assert {:error, :bot_message} = Slack.parse_inbound(%Plug.Conn{}, body)
    end

    test "rejects invalid JSON" do
      assert {:error, :invalid_json} = Slack.parse_inbound(%Plug.Conn{}, "not json")
    end
  end

  # ──────────────────────────────────────────────
  # Slack Adapter — persistent?
  # ──────────────────────────────────────────────

  describe "Slack persistent?/0" do
    test "returns false (webhook-based)" do
      refute Slack.persistent?()
    end
  end

  # ──────────────────────────────────────────────
  # Discord Adapter — validate_config
  # ──────────────────────────────────────────────

  describe "Discord validate_config/1" do
    test "accepts valid config" do
      config = %{
        "bot_token" => "test-bot-token",
        "application_id" => "123456789",
        "public_key" => String.duplicate("ab", 32),
        "channel_id" => "987654321"
      }

      assert :ok = Discord.validate_config(config)
    end

    test "rejects missing public_key" do
      config = %{
        "bot_token" => "test-bot-token",
        "application_id" => "123456789",
        "channel_id" => "987654321"
      }

      assert {:error, "missing required config: " <> _} = Discord.validate_config(config)
    end
  end

  # ──────────────────────────────────────────────
  # Discord Adapter — parse_inbound
  # ──────────────────────────────────────────────

  describe "Discord parse_inbound/2" do
    test "handles PING verification" do
      body = Jason.encode!(%{"type" => 1})

      assert {:ok, %{challenge: %{"type" => 1}}} =
               Discord.parse_inbound(%Plug.Conn{}, body)
    end

    test "parses APPLICATION_COMMAND" do
      body =
        Jason.encode!(%{
          "type" => 2,
          "id" => "int-123",
          "token" => "int-token",
          "data" => %{
            "options" => [%{"value" => "search for cats"}]
          },
          "member" => %{"user" => %{"username" => "tester"}},
          "guild_id" => "guild-1",
          "channel_id" => "chan-1"
        })

      assert {:ok, message} = Discord.parse_inbound(%Plug.Conn{}, body)
      assert message.content =~ "search for cats"
      assert message.external_id == "int-123"
    end
  end

  # ──────────────────────────────────────────────
  # Discord Adapter — persistent?
  # ──────────────────────────────────────────────

  describe "Discord persistent?/0" do
    test "returns false (webhook-based interactions)" do
      refute Discord.persistent?()
    end
  end

  # ──────────────────────────────────────────────
  # Telegram Adapter — validate_config
  # ──────────────────────────────────────────────

  describe "Telegram validate_config/1" do
    test "accepts valid config" do
      config = %{
        "bot_token" => "123456:ABC-DEF",
        "chat_id" => "789",
        "secret_token" => "my-secret"
      }

      assert :ok = Telegram.validate_config(config)
    end

    test "rejects missing bot_token" do
      config = %{
        "chat_id" => "789",
        "secret_token" => "my-secret"
      }

      assert {:error, "missing required config: " <> _} = Telegram.validate_config(config)
    end
  end

  # ──────────────────────────────────────────────
  # Telegram Adapter — parse_inbound
  # ──────────────────────────────────────────────

  describe "Telegram parse_inbound/2" do
    test "parses message update" do
      body =
        Jason.encode!(%{
          "message" => %{
            "message_id" => 42,
            "text" => "Hello from Telegram",
            "from" => %{
              "id" => 12_345,
              "first_name" => "Test",
              "username" => "tester"
            },
            "chat" => %{"id" => 789}
          }
        })

      assert {:ok, message} = Telegram.parse_inbound(%Plug.Conn{}, body)
      assert message.content == "Hello from Telegram"
      assert message.external_id == "42"
    end

    test "rejects update without message" do
      body = Jason.encode!(%{"update_id" => 12_345})

      assert {:error, :unsupported_update} = Telegram.parse_inbound(%Plug.Conn{}, body)
    end

    test "rejects message without text" do
      body =
        Jason.encode!(%{
          "message" => %{
            "message_id" => 42,
            "photo" => [%{"file_id" => "abc"}]
          }
        })

      assert {:error, :unsupported_message_type} = Telegram.parse_inbound(%Plug.Conn{}, body)
    end
  end

  # ──────────────────────────────────────────────
  # Telegram Adapter — persistent?
  # ──────────────────────────────────────────────

  describe "Telegram persistent?/0" do
    test "returns false (webhook-based)" do
      refute Telegram.persistent?()
    end
  end
end
