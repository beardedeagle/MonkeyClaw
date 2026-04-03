defmodule MonkeyClaw.Webhooks.Verifiers.LinearTest do
  use ExUnit.Case, async: true

  alias MonkeyClaw.Webhooks.Security
  alias MonkeyClaw.Webhooks.Verifiers.Linear

  defp conn_with_headers(headers) do
    Enum.reduce(headers, Plug.Test.conn(:post, "/test", ""), fn {key, value}, conn ->
      Plug.Conn.put_req_header(conn, key, value)
    end)
  end

  # ── verify/3 ──────────────────────────────────────

  describe "verify/3" do
    setup do
      secret = "linear-webhook-secret"
      body = ~s({"action":"create","type":"Issue"})
      sig = Security.hmac_sha256_hex(secret, body)
      conn = conn_with_headers([{"linear-signature", sig}])
      %{secret: secret, body: body, conn: conn}
    end

    test "succeeds with valid signature", %{secret: secret, body: body, conn: conn} do
      assert :ok = Linear.verify(secret, conn, body)
    end

    test "fails with wrong secret", %{body: body, conn: conn} do
      assert {:error, :unauthorized} = Linear.verify("wrong", conn, body)
    end

    test "fails with tampered body", %{secret: secret, conn: conn} do
      assert {:error, :unauthorized} = Linear.verify(secret, conn, "tampered")
    end

    test "fails with missing header" do
      conn = conn_with_headers([])
      assert {:error, :unauthorized} = Linear.verify("secret", conn, "body")
    end

    test "fails with wrong signature length" do
      conn = conn_with_headers([{"linear-signature", "tooshort"}])
      assert {:error, :unauthorized} = Linear.verify("secret", conn, "body")
    end

    test "fails when signature has sha256= prefix (bare hex only)" do
      secret = "linear-webhook-secret"
      body = ~s({"action":"create"})
      sig = Security.hmac_sha256_hex(secret, body)
      conn = conn_with_headers([{"linear-signature", "sha256=#{sig}"}])
      assert {:error, :unauthorized} = Linear.verify(secret, conn, body)
    end
  end

  # ── extract_event_type/1 ──────────────────────────

  describe "extract_event_type/1" do
    test "returns event from header" do
      conn = conn_with_headers([{"linear-event", "Issue"}])
      assert {:ok, "Issue"} = Linear.extract_event_type(conn)
    end

    test "returns Comment event type" do
      conn = conn_with_headers([{"linear-event", "Comment"}])
      assert {:ok, "Comment"} = Linear.extract_event_type(conn)
    end

    test "defaults to unknown when absent" do
      conn = conn_with_headers([])
      assert {:ok, "unknown"} = Linear.extract_event_type(conn)
    end

    test "rejects empty event" do
      conn = conn_with_headers([{"linear-event", ""}])
      assert {:error, :invalid_event_type} = Linear.extract_event_type(conn)
    end

    test "accepts event at max length (255 bytes)" do
      event = String.duplicate("e", 255)
      conn = conn_with_headers([{"linear-event", event}])
      assert {:ok, ^event} = Linear.extract_event_type(conn)
    end

    test "rejects event exceeding 255 bytes" do
      conn = conn_with_headers([{"linear-event", String.duplicate("e", 256)}])
      assert {:error, :invalid_event_type} = Linear.extract_event_type(conn)
    end
  end

  # ── extract_delivery_id/1 ──────────────────────────

  describe "extract_delivery_id/1" do
    test "returns delivery UUID from header" do
      conn = conn_with_headers([{"linear-delivery", "abc-123"}])
      assert {:ok, "abc-123"} = Linear.extract_delivery_id(conn)
    end

    test "returns nil when absent" do
      conn = conn_with_headers([])
      assert {:ok, nil} = Linear.extract_delivery_id(conn)
    end

    test "rejects empty delivery id" do
      conn = conn_with_headers([{"linear-delivery", ""}])
      assert {:error, :invalid_delivery_id} = Linear.extract_delivery_id(conn)
    end

    test "accepts delivery id at max length (255 bytes)" do
      id = String.duplicate("d", 255)
      conn = conn_with_headers([{"linear-delivery", id}])
      assert {:ok, ^id} = Linear.extract_delivery_id(conn)
    end

    test "rejects delivery id exceeding 255 bytes" do
      conn = conn_with_headers([{"linear-delivery", String.duplicate("d", 256)}])
      assert {:error, :invalid_delivery_id} = Linear.extract_delivery_id(conn)
    end
  end
end
