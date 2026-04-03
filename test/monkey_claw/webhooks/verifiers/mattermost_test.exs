defmodule MonkeyClaw.Webhooks.Verifiers.MattermostTest do
  use ExUnit.Case, async: true

  alias MonkeyClaw.Webhooks.Verifiers.Mattermost

  defp conn_with_body(body_params) do
    %{Plug.Test.conn(:post, "/test", "") | body_params: body_params}
  end

  # ── verify/3 ──────────────────────────────────────

  describe "verify/3" do
    test "succeeds with matching token" do
      secret = "mattermost-token-secret"
      conn = conn_with_body(%{"token" => secret})
      assert :ok = Mattermost.verify(secret, conn, "body")
    end

    test "fails with wrong token" do
      conn = conn_with_body(%{"token" => "wrong"})
      assert {:error, :unauthorized} = Mattermost.verify("correct", conn, "body")
    end

    test "fails with missing token field" do
      conn = conn_with_body(%{})
      assert {:error, :unauthorized} = Mattermost.verify("secret", conn, "body")
    end

    test "fails with empty token field" do
      conn = conn_with_body(%{"token" => ""})
      assert {:error, :unauthorized} = Mattermost.verify("secret", conn, "body")
    end

    test "ignores raw_body (not used in Mattermost scheme)" do
      secret = "token"
      conn = conn_with_body(%{"token" => secret})
      assert :ok = Mattermost.verify(secret, conn, "any-body")
      assert :ok = Mattermost.verify(secret, conn, "different-body")
    end
  end

  # ── extract_event_type/1 ──────────────────────────

  describe "extract_event_type/1" do
    test "returns event from trigger_word" do
      conn = conn_with_body(%{"trigger_word" => "alert"})
      assert {:ok, "alert"} = Mattermost.extract_event_type(conn)
    end

    test "defaults to unknown when trigger_word absent" do
      conn = conn_with_body(%{})
      assert {:ok, "unknown"} = Mattermost.extract_event_type(conn)
    end

    test "accepts trigger_word at max length (255 bytes)" do
      word = String.duplicate("w", 255)
      conn = conn_with_body(%{"trigger_word" => word})
      assert {:ok, ^word} = Mattermost.extract_event_type(conn)
    end

    test "rejects trigger_word exceeding 255 bytes" do
      conn = conn_with_body(%{"trigger_word" => String.duplicate("w", 256)})
      assert {:error, :invalid_event_type} = Mattermost.extract_event_type(conn)
    end

    test "rejects empty trigger_word" do
      conn = conn_with_body(%{"trigger_word" => ""})
      assert {:error, :invalid_event_type} = Mattermost.extract_event_type(conn)
    end
  end

  # ── extract_delivery_id/1 ──────────────────────────

  describe "extract_delivery_id/1" do
    test "returns post_id as delivery ID" do
      conn = conn_with_body(%{"post_id" => "abc123xyz"})
      assert {:ok, "abc123xyz"} = Mattermost.extract_delivery_id(conn)
    end

    test "returns nil when post_id absent" do
      conn = conn_with_body(%{})
      assert {:ok, nil} = Mattermost.extract_delivery_id(conn)
    end

    test "returns error when post_id is empty string" do
      conn = conn_with_body(%{"post_id" => ""})
      assert {:error, :invalid_delivery_id} = Mattermost.extract_delivery_id(conn)
    end
  end
end
