defmodule MonkeyClaw.Webhooks.Verifiers.StripeTest do
  use ExUnit.Case, async: true

  alias MonkeyClaw.Webhooks.Security
  alias MonkeyClaw.Webhooks.Verifiers.Stripe

  defp build_signature(secret, timestamp, body) do
    Security.hmac_sha256_hex(secret, "#{timestamp}.#{body}")
  end

  defp conn_with_signature(header_value, body_params \\ %{}) do
    conn = Plug.Test.conn(:post, "/stripe", "")
    conn = Plug.Conn.put_req_header(conn, "stripe-signature", header_value)
    %{conn | body_params: body_params}
  end

  defp conn_without_signature(body_params \\ %{}) do
    conn = Plug.Test.conn(:post, "/stripe", "")
    %{conn | body_params: body_params}
  end

  # ── verify/3 ──────────────────────────────────────

  describe "verify/3" do
    setup do
      secret = "whsec_test-signing-secret-stripe"
      body = ~s({"type":"payment_intent.succeeded","id":"evt_1234"})
      timestamp = System.os_time(:second)
      signature = build_signature(secret, timestamp, body)
      header = "t=#{timestamp},v1=#{signature}"
      conn = conn_with_signature(header)
      %{secret: secret, body: body, conn: conn}
    end

    test "succeeds with valid signature", %{secret: secret, body: body, conn: conn} do
      assert :ok = Stripe.verify(secret, conn, body)
    end

    test "fails with wrong secret", %{body: body, conn: conn} do
      assert {:error, :unauthorized} = Stripe.verify("wrong-secret-entirely!!", conn, body)
    end

    test "fails with tampered body", %{secret: secret, conn: conn} do
      assert {:error, :unauthorized} = Stripe.verify(secret, conn, "tampered-body-content")
    end

    test "fails with expired timestamp (10 minutes ago)" do
      secret = "whsec_test-secret"
      body = ~s({"type":"charge.succeeded"})
      old_timestamp = System.os_time(:second) - 600
      sig = build_signature(secret, old_timestamp, body)
      conn = conn_with_signature("t=#{old_timestamp},v1=#{sig}")

      assert {:error, :unauthorized} = Stripe.verify(secret, conn, body)
    end

    test "fails with future timestamp beyond tolerance" do
      secret = "whsec_test-secret"
      body = ~s({"type":"charge.succeeded"})
      future_ts = System.os_time(:second) + 600
      sig = build_signature(secret, future_ts, body)
      conn = conn_with_signature("t=#{future_ts},v1=#{sig}")

      assert {:error, :unauthorized} = Stripe.verify(secret, conn, body)
    end

    test "accepts timestamp within tolerance window" do
      secret = "whsec_test-secret"
      body = ~s({"type":"charge.succeeded"})
      # 4 minutes ago — within the 5-minute window
      recent_ts = System.os_time(:second) - 240
      sig = build_signature(secret, recent_ts, body)
      conn = conn_with_signature("t=#{recent_ts},v1=#{sig}")

      assert :ok = Stripe.verify(secret, conn, body)
    end

    test "fails with missing stripe-signature header" do
      conn = conn_without_signature()
      assert {:error, :unauthorized} = Stripe.verify("secret", conn, "body")
    end

    test "fails with malformed header — missing v1 component" do
      conn = conn_with_signature("t=12345")
      assert {:error, :unauthorized} = Stripe.verify("secret", conn, "body")
    end

    test "fails with malformed header — non-integer timestamp" do
      header = "t=abc,v1=#{String.duplicate("a", 64)}"
      conn = conn_with_signature(header)
      assert {:error, :unauthorized} = Stripe.verify("secret", conn, "body")
    end

    test "fails with signature of wrong length" do
      conn = conn_with_signature("t=12345,v1=tooshort")
      assert {:error, :unauthorized} = Stripe.verify("secret", conn, "body")
    end

    test "all failures return identical :unauthorized (no information leakage)" do
      secret = "secret"
      body = "body"
      timestamp = System.os_time(:second)
      wrong_sig = build_signature("wrong-secret", timestamp, body)

      wrong_secret =
        Stripe.verify(
          secret,
          conn_with_signature("t=#{timestamp},v1=#{wrong_sig}"),
          body
        )

      missing = Stripe.verify(secret, conn_without_signature(), body)

      malformed = Stripe.verify(secret, conn_with_signature("garbage"), body)

      assert wrong_secret == {:error, :unauthorized}
      assert missing == {:error, :unauthorized}
      assert malformed == {:error, :unauthorized}
    end
  end

  # ── extract_event_type/1 ──────────────────────────

  describe "extract_event_type/1" do
    test "returns event type from body params" do
      conn = conn_without_signature(%{"type" => "payment_intent.succeeded"})
      assert {:ok, "payment_intent.succeeded"} = Stripe.extract_event_type(conn)
    end

    test "returns 'unknown' when type field is absent" do
      conn = conn_without_signature(%{})
      assert {:ok, "unknown"} = Stripe.extract_event_type(conn)
    end

    test "returns 'unknown' when body_params has no type key" do
      conn = conn_without_signature(%{"id" => "evt_123"})
      assert {:ok, "unknown"} = Stripe.extract_event_type(conn)
    end

    test "rejects empty event type" do
      conn = conn_without_signature(%{"type" => ""})
      assert {:error, :invalid_event_type} = Stripe.extract_event_type(conn)
    end

    test "accepts event type at max length (255 bytes)" do
      event = String.duplicate("e", 255)
      conn = conn_without_signature(%{"type" => event})
      assert {:ok, ^event} = Stripe.extract_event_type(conn)
    end

    test "rejects event type exceeding 255 bytes" do
      long = String.duplicate("e", 256)
      conn = conn_without_signature(%{"type" => long})
      assert {:error, :invalid_event_type} = Stripe.extract_event_type(conn)
    end
  end

  # ── extract_delivery_id/1 ──────────────────────────

  describe "extract_delivery_id/1" do
    test "returns event ID from body params" do
      conn = conn_without_signature(%{"id" => "evt_1234abcd"})
      assert {:ok, "evt_1234abcd"} = Stripe.extract_delivery_id(conn)
    end

    test "returns nil when id field is absent" do
      conn = conn_without_signature(%{})
      assert {:ok, nil} = Stripe.extract_delivery_id(conn)
    end

    test "returns nil when body_params has no id key" do
      conn = conn_without_signature(%{"type" => "charge.succeeded"})
      assert {:ok, nil} = Stripe.extract_delivery_id(conn)
    end

    test "rejects empty id" do
      conn = conn_without_signature(%{"id" => ""})
      assert {:error, :invalid_delivery_id} = Stripe.extract_delivery_id(conn)
    end

    test "accepts id at max length (255 bytes)" do
      id = String.duplicate("k", 255)
      conn = conn_without_signature(%{"id" => id})
      assert {:ok, ^id} = Stripe.extract_delivery_id(conn)
    end

    test "rejects id exceeding 255 bytes" do
      long = String.duplicate("k", 256)
      conn = conn_without_signature(%{"id" => long})
      assert {:error, :invalid_delivery_id} = Stripe.extract_delivery_id(conn)
    end
  end
end
