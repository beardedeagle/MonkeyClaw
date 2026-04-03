defmodule MonkeyClaw.Webhooks.Verifiers.GenericTest do
  use ExUnit.Case, async: true

  alias MonkeyClaw.Webhooks.Security
  alias MonkeyClaw.Webhooks.Verifiers.Generic

  defp conn_with_headers(headers) do
    Enum.reduce(headers, Plug.Test.conn(:post, "/test", ""), fn {key, value}, conn ->
      Plug.Conn.put_req_header(conn, key, value)
    end)
  end

  # ── verify/3 ──────────────────────────────────────

  describe "verify/3" do
    setup do
      secret = "test-signing-secret-32-bytes-long"
      body = ~s({"event":"push","ref":"refs/heads/main"})
      timestamp = System.os_time(:second)
      signature = Security.compute_signature(secret, timestamp, body)
      header = "t=#{timestamp},v1=#{signature}"
      conn = conn_with_headers([{"x-monkeyclaw-signature", header}])
      %{secret: secret, body: body, conn: conn}
    end

    test "succeeds with valid signature", %{secret: secret, body: body, conn: conn} do
      assert :ok = Generic.verify(secret, conn, body)
    end

    test "fails with wrong secret", %{body: body, conn: conn} do
      assert {:error, :unauthorized} =
               Generic.verify("completely-wrong-secret!!", conn, body)
    end

    test "fails with tampered body", %{secret: secret, conn: conn} do
      assert {:error, :unauthorized} =
               Generic.verify(secret, conn, "tampered-body-content")
    end

    test "fails with expired timestamp (10 minutes ago)" do
      secret = "test-secret"
      body = "body"
      old_timestamp = System.os_time(:second) - 600
      sig = Security.compute_signature(secret, old_timestamp, body)
      header = "t=#{old_timestamp},v1=#{sig}"
      conn = conn_with_headers([{"x-monkeyclaw-signature", header}])

      assert {:error, :unauthorized} = Generic.verify(secret, conn, body)
    end

    test "fails with future timestamp beyond tolerance" do
      secret = "test-secret"
      body = "body"
      future_ts = System.os_time(:second) + 600
      sig = Security.compute_signature(secret, future_ts, body)
      header = "t=#{future_ts},v1=#{sig}"
      conn = conn_with_headers([{"x-monkeyclaw-signature", header}])

      assert {:error, :unauthorized} = Generic.verify(secret, conn, body)
    end

    test "accepts timestamp within tolerance window" do
      secret = "test-secret"
      body = "body"
      # 4 minutes ago — within the 5-minute window
      recent_ts = System.os_time(:second) - 240
      sig = Security.compute_signature(secret, recent_ts, body)
      header = "t=#{recent_ts},v1=#{sig}"
      conn = conn_with_headers([{"x-monkeyclaw-signature", header}])

      assert :ok = Generic.verify(secret, conn, body)
    end

    test "fails with missing signature header" do
      conn = conn_with_headers([])
      assert {:error, :unauthorized} = Generic.verify("secret", conn, "body")
    end

    test "fails with malformed header — missing v1 component" do
      conn = conn_with_headers([{"x-monkeyclaw-signature", "t=12345"}])
      assert {:error, :unauthorized} = Generic.verify("secret", conn, "body")
    end

    test "fails with malformed header — non-integer timestamp" do
      header = "t=abc,v1=#{String.duplicate("a", 64)}"
      conn = conn_with_headers([{"x-monkeyclaw-signature", header}])

      assert {:error, :unauthorized} = Generic.verify("secret", conn, "body")
    end

    test "fails with signature of wrong length" do
      conn = conn_with_headers([{"x-monkeyclaw-signature", "t=12345,v1=tooshort"}])
      assert {:error, :unauthorized} = Generic.verify("secret", conn, "body")
    end

    test "all failures return identical :unauthorized (no information leakage)" do
      secret = "secret"
      body = "body"

      header = Security.build_signature_header("wrong", System.os_time(:second), body)

      wrong_secret =
        Generic.verify(secret, conn_with_headers([{"x-monkeyclaw-signature", header}]), body)

      missing = Generic.verify(secret, conn_with_headers([]), body)

      malformed =
        Generic.verify(secret, conn_with_headers([{"x-monkeyclaw-signature", "garbage"}]), body)

      assert wrong_secret == {:error, :unauthorized}
      assert missing == {:error, :unauthorized}
      assert malformed == {:error, :unauthorized}
    end
  end

  # ── extract_event_type/1 ──────────────────────────

  describe "extract_event_type/1" do
    test "returns event type when present" do
      conn = conn_with_headers([{"x-monkeyclaw-event", "push"}])
      assert {:ok, "push"} = Generic.extract_event_type(conn)
    end

    test "defaults to 'unknown' when absent" do
      conn = conn_with_headers([])
      assert {:ok, "unknown"} = Generic.extract_event_type(conn)
    end

    test "rejects empty event type" do
      conn = conn_with_headers([{"x-monkeyclaw-event", ""}])
      assert {:error, :invalid_event_type} = Generic.extract_event_type(conn)
    end

    test "accepts event at max length (255 bytes)" do
      event = String.duplicate("e", 255)
      conn = conn_with_headers([{"x-monkeyclaw-event", event}])
      assert {:ok, ^event} = Generic.extract_event_type(conn)
    end

    test "rejects event exceeding 255 bytes" do
      long = String.duplicate("e", 256)
      conn = conn_with_headers([{"x-monkeyclaw-event", long}])
      assert {:error, :invalid_event_type} = Generic.extract_event_type(conn)
    end
  end

  # ── extract_delivery_id/1 ──────────────────────────

  describe "extract_delivery_id/1" do
    test "returns key when present and valid" do
      conn = conn_with_headers([{"x-monkeyclaw-idempotency-key", "abc-123-def"}])
      assert {:ok, "abc-123-def"} = Generic.extract_delivery_id(conn)
    end

    test "returns nil when absent" do
      conn = conn_with_headers([])
      assert {:ok, nil} = Generic.extract_delivery_id(conn)
    end

    test "rejects empty key" do
      conn = conn_with_headers([{"x-monkeyclaw-idempotency-key", ""}])
      assert {:error, :invalid_delivery_id} = Generic.extract_delivery_id(conn)
    end

    test "accepts key at max length (255 bytes)" do
      key = String.duplicate("k", 255)
      conn = conn_with_headers([{"x-monkeyclaw-idempotency-key", key}])
      assert {:ok, ^key} = Generic.extract_delivery_id(conn)
    end

    test "rejects key exceeding 255 bytes" do
      long = String.duplicate("k", 256)
      conn = conn_with_headers([{"x-monkeyclaw-idempotency-key", long}])
      assert {:error, :invalid_delivery_id} = Generic.extract_delivery_id(conn)
    end
  end
end
