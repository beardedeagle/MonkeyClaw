defmodule MonkeyClaw.Webhooks.SecurityTest do
  use ExUnit.Case, async: true

  alias MonkeyClaw.Webhooks.Security

  # Build a test conn with specific headers set.
  defp conn_with_headers(headers) do
    Enum.reduce(headers, Plug.Test.conn(:post, "/test", ""), fn {key, value}, conn ->
      Plug.Conn.put_req_header(conn, key, value)
    end)
  end

  # ── verify_request/3 ──────────────────────────

  describe "verify_request/3" do
    setup do
      secret = "test-signing-secret-32-bytes-long"
      body = ~s({"event":"push","ref":"refs/heads/main"})
      timestamp = System.os_time(:second)
      signature = Security.compute_signature(secret, timestamp, body)
      header = "t=#{timestamp},v1=#{signature}"

      conn = conn_with_headers([{"x-monkeyclaw-signature", header}])

      %{secret: secret, body: body, timestamp: timestamp, conn: conn}
    end

    test "succeeds with valid signature", %{secret: secret, body: body, conn: conn} do
      assert :ok = Security.verify_request(secret, conn, body)
    end

    test "fails with wrong secret", %{body: body, conn: conn} do
      assert {:error, :unauthorized} =
               Security.verify_request("completely-wrong-secret!!", conn, body)
    end

    test "fails with tampered body", %{secret: secret, conn: conn} do
      assert {:error, :unauthorized} =
               Security.verify_request(secret, conn, "tampered-body-content")
    end

    test "fails with expired timestamp (10 minutes ago)" do
      secret = "test-secret"
      body = "body"
      old_timestamp = System.os_time(:second) - 600
      signature = Security.compute_signature(secret, old_timestamp, body)
      header = "t=#{old_timestamp},v1=#{signature}"

      conn = conn_with_headers([{"x-monkeyclaw-signature", header}])
      assert {:error, :unauthorized} = Security.verify_request(secret, conn, body)
    end

    test "fails with future timestamp beyond tolerance" do
      secret = "test-secret"
      body = "body"
      future_timestamp = System.os_time(:second) + 600
      signature = Security.compute_signature(secret, future_timestamp, body)
      header = "t=#{future_timestamp},v1=#{signature}"

      conn = conn_with_headers([{"x-monkeyclaw-signature", header}])
      assert {:error, :unauthorized} = Security.verify_request(secret, conn, body)
    end

    test "accepts timestamp within tolerance window" do
      secret = "test-secret"
      body = "body"
      # 4 minutes ago — within the 5-minute window
      recent_timestamp = System.os_time(:second) - 240
      signature = Security.compute_signature(secret, recent_timestamp, body)
      header = "t=#{recent_timestamp},v1=#{signature}"

      conn = conn_with_headers([{"x-monkeyclaw-signature", header}])
      assert :ok = Security.verify_request(secret, conn, body)
    end

    test "fails with missing signature header" do
      conn = conn_with_headers([])
      assert {:error, :unauthorized} = Security.verify_request("secret", conn, "body")
    end

    test "fails with malformed header — missing v1 component" do
      conn = conn_with_headers([{"x-monkeyclaw-signature", "t=12_345"}])
      assert {:error, :unauthorized} = Security.verify_request("secret", conn, "body")
    end

    test "fails with malformed header — non-integer timestamp" do
      conn =
        conn_with_headers([{"x-monkeyclaw-signature", "t=abc,v1=#{String.duplicate("a", 64)}"}])

      assert {:error, :unauthorized} = Security.verify_request("secret", conn, "body")
    end

    test "fails with signature of wrong length" do
      conn = conn_with_headers([{"x-monkeyclaw-signature", "t=12_345,v1=tooshort"}])
      assert {:error, :unauthorized} = Security.verify_request("secret", conn, "body")
    end

    test "all failures return identical :unauthorized (no information leakage)" do
      # Wrong secret, expired, missing header, malformed — all return the same error
      secret = "secret"
      body = "body"

      wrong_secret_result =
        Security.verify_request(
          "wrong",
          conn_with_headers([
            {"x-monkeyclaw-signature",
             Security.build_signature_header(secret, System.os_time(:second), body)}
          ]),
          body
        )

      missing_result = Security.verify_request(secret, conn_with_headers([]), body)

      malformed_result =
        Security.verify_request(
          secret,
          conn_with_headers([{"x-monkeyclaw-signature", "garbage"}]),
          body
        )

      assert wrong_secret_result == {:error, :unauthorized}
      assert missing_result == {:error, :unauthorized}
      assert malformed_result == {:error, :unauthorized}
    end
  end

  # ── extract_idempotency_key/1 ─────────────────

  describe "extract_idempotency_key/1" do
    test "returns key when present and valid" do
      conn = conn_with_headers([{"x-monkeyclaw-idempotency-key", "abc-123-def"}])
      assert {:ok, "abc-123-def"} = Security.extract_idempotency_key(conn)
    end

    test "returns nil when absent" do
      conn = conn_with_headers([])
      assert {:ok, nil} = Security.extract_idempotency_key(conn)
    end

    test "rejects empty key" do
      conn = conn_with_headers([{"x-monkeyclaw-idempotency-key", ""}])
      assert {:error, :invalid_idempotency_key} = Security.extract_idempotency_key(conn)
    end

    test "accepts key at max length (255 bytes)" do
      key = String.duplicate("k", 255)
      conn = conn_with_headers([{"x-monkeyclaw-idempotency-key", key}])
      assert {:ok, ^key} = Security.extract_idempotency_key(conn)
    end

    test "rejects key exceeding 255 bytes" do
      long_key = String.duplicate("k", 256)
      conn = conn_with_headers([{"x-monkeyclaw-idempotency-key", long_key}])
      assert {:error, :invalid_idempotency_key} = Security.extract_idempotency_key(conn)
    end
  end

  # ── extract_event_type/1 ──────────────────────

  describe "extract_event_type/1" do
    test "returns event type when present" do
      conn = conn_with_headers([{"x-monkeyclaw-event", "push"}])
      assert {:ok, "push"} = Security.extract_event_type(conn)
    end

    test "defaults to 'unknown' when absent" do
      conn = conn_with_headers([])
      assert {:ok, "unknown"} = Security.extract_event_type(conn)
    end

    test "rejects empty event type" do
      conn = conn_with_headers([{"x-monkeyclaw-event", ""}])
      assert {:error, :invalid_event_type} = Security.extract_event_type(conn)
    end

    test "accepts event type at max length (255 bytes)" do
      event = String.duplicate("e", 255)
      conn = conn_with_headers([{"x-monkeyclaw-event", event}])
      assert {:ok, ^event} = Security.extract_event_type(conn)
    end

    test "rejects event type exceeding 255 bytes" do
      long_event = String.duplicate("e", 256)
      conn = conn_with_headers([{"x-monkeyclaw-event", long_event}])
      assert {:error, :invalid_event_type} = Security.extract_event_type(conn)
    end
  end

  # ── compute_signature/3 ──────────────────────

  describe "compute_signature/3" do
    test "produces consistent results for same inputs" do
      sig1 = Security.compute_signature("secret", 12_345, "body")
      sig2 = Security.compute_signature("secret", 12_345, "body")
      assert sig1 == sig2
    end

    test "differs with different secrets" do
      sig1 = Security.compute_signature("secret-a", 12_345, "body")
      sig2 = Security.compute_signature("secret-b", 12_345, "body")
      assert sig1 != sig2
    end

    test "differs with different timestamps" do
      sig1 = Security.compute_signature("secret", 12_345, "body")
      sig2 = Security.compute_signature("secret", 12_346, "body")
      assert sig1 != sig2
    end

    test "differs with different bodies" do
      sig1 = Security.compute_signature("secret", 12_345, "body-a")
      sig2 = Security.compute_signature("secret", 12_345, "body-b")
      assert sig1 != sig2
    end

    test "returns 64-character lowercase hex string (SHA-256)" do
      sig = Security.compute_signature("secret", 12_345, "body")
      assert byte_size(sig) == 64
      assert sig =~ ~r/^[0-9a-f]{64}$/
    end
  end

  # ── build_signature_header/3 ──────────────────

  describe "build_signature_header/3" do
    test "formats as t=<timestamp>,v1=<hex_signature>" do
      header = Security.build_signature_header("secret", 12_345, "body")
      assert header =~ ~r/^t=12345,v1=[0-9a-f]{64}$/
    end

    test "header verifies against same inputs" do
      secret = "test-secret"
      timestamp = System.os_time(:second)
      body = ~s({"data":"value"})
      header = Security.build_signature_header(secret, timestamp, body)

      conn = conn_with_headers([{"x-monkeyclaw-signature", header}])
      assert :ok = Security.verify_request(secret, conn, body)
    end
  end

  # ── hash_payload/1 ────────────────────────────

  describe "hash_payload/1" do
    test "produces 64-character lowercase hex SHA-256" do
      hash = Security.hash_payload("test-payload")
      assert byte_size(hash) == 64
      assert hash =~ ~r/^[0-9a-f]{64}$/
    end

    test "produces consistent results" do
      assert Security.hash_payload("x") == Security.hash_payload("x")
    end

    test "produces different hashes for different inputs" do
      assert Security.hash_payload("a") != Security.hash_payload("b")
    end

    test "handles empty payload" do
      hash = Security.hash_payload("")
      assert byte_size(hash) == 64
    end
  end
end
