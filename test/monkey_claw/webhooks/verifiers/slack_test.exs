defmodule MonkeyClaw.Webhooks.Verifiers.SlackTest do
  use ExUnit.Case, async: true

  alias MonkeyClaw.Webhooks.Security
  alias MonkeyClaw.Webhooks.Verifiers.Slack

  defp conn_with_headers(headers) do
    Enum.reduce(headers, Plug.Test.conn(:post, "/test", ""), fn {key, value}, conn ->
      Plug.Conn.put_req_header(conn, key, value)
    end)
  end

  defp build_slack_conn(secret, body, timestamp) do
    message = "v0:#{timestamp}:#{body}"
    sig = Security.hmac_sha256_hex(secret, message)

    conn_with_headers([
      {"x-slack-signature", "v0=#{sig}"},
      {"x-slack-request-timestamp", Integer.to_string(timestamp)}
    ])
  end

  # ── verify/3 ──────────────────────────────────────

  describe "verify/3" do
    setup do
      secret = "slack-signing-secret"
      body = ~s({"token":"xoxb"})
      timestamp = System.os_time(:second)
      conn = build_slack_conn(secret, body, timestamp)
      %{secret: secret, body: body, conn: conn}
    end

    test "succeeds with valid signature", %{secret: secret, body: body, conn: conn} do
      assert :ok = Slack.verify(secret, conn, body)
    end

    test "fails with wrong secret", %{body: body, conn: conn} do
      assert {:error, :unauthorized} = Slack.verify("wrong", conn, body)
    end

    test "fails with tampered body", %{secret: secret, conn: conn} do
      assert {:error, :unauthorized} = Slack.verify(secret, conn, "tampered")
    end

    test "fails with expired timestamp" do
      secret = "secret"
      body = "body"
      old_ts = System.os_time(:second) - 600
      conn = build_slack_conn(secret, body, old_ts)
      assert {:error, :unauthorized} = Slack.verify(secret, conn, body)
    end

    test "fails with missing signature header" do
      conn = conn_with_headers([{"x-slack-request-timestamp", "123"}])
      assert {:error, :unauthorized} = Slack.verify("secret", conn, "body")
    end

    test "fails with missing timestamp header" do
      sig = String.duplicate("a", 64)
      conn = conn_with_headers([{"x-slack-signature", "v0=#{sig}"}])
      assert {:error, :unauthorized} = Slack.verify("secret", conn, "body")
    end

    test "fails with non-integer timestamp" do
      sig = String.duplicate("a", 64)

      conn =
        conn_with_headers([
          {"x-slack-signature", "v0=#{sig}"},
          {"x-slack-request-timestamp", "not-a-number"}
        ])

      assert {:error, :unauthorized} = Slack.verify("secret", conn, "body")
    end

    test "fails without v0= prefix" do
      conn =
        conn_with_headers([
          {"x-slack-signature", String.duplicate("a", 64)},
          {"x-slack-request-timestamp", "123"}
        ])

      assert {:error, :unauthorized} = Slack.verify("secret", conn, "body")
    end
  end

  # ── extract_event_type/1 ──────────────────────────

  describe "extract_event_type/1" do
    test "returns nested event.type from body" do
      conn = %{
        Plug.Test.conn(:post, "/test", "")
        | body_params: %{"event" => %{"type" => "message"}}
      }

      assert {:ok, "message"} = Slack.extract_event_type(conn)
    end

    test "falls back to top-level type" do
      conn = %{
        Plug.Test.conn(:post, "/test", "")
        | body_params: %{"type" => "url_verification"}
      }

      assert {:ok, "url_verification"} = Slack.extract_event_type(conn)
    end

    test "returns unknown when no type fields" do
      conn = %{Plug.Test.conn(:post, "/test", "") | body_params: %{}}
      assert {:ok, "unknown"} = Slack.extract_event_type(conn)
    end
  end

  # ── extract_delivery_id/1 ──────────────────────────

  describe "extract_delivery_id/1" do
    test "returns event_id from body" do
      conn = %{
        Plug.Test.conn(:post, "/test", "")
        | body_params: %{"event_id" => "Ev123ABC"}
      }

      assert {:ok, "Ev123ABC"} = Slack.extract_delivery_id(conn)
    end

    test "returns nil when no event_id" do
      conn = %{Plug.Test.conn(:post, "/test", "") | body_params: %{}}
      assert {:ok, nil} = Slack.extract_delivery_id(conn)
    end
  end
end
