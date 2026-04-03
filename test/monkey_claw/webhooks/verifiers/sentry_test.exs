defmodule MonkeyClaw.Webhooks.Verifiers.SentryTest do
  use ExUnit.Case, async: true

  alias MonkeyClaw.Webhooks.Security
  alias MonkeyClaw.Webhooks.Verifiers.Sentry

  # Build a conn with the given headers. Uses an empty string body so
  # that body_params defaults to %{} — individual tests set body_params
  # explicitly when needed.
  defp conn_with_headers(headers, body_params \\ %{}) do
    base = Plug.Test.conn(:post, "/test", "")
    base = %{base | body_params: body_params}

    Enum.reduce(headers, base, fn {key, value}, conn ->
      Plug.Conn.put_req_header(conn, key, value)
    end)
  end

  # Sign the re-serialized JSON of body_params — matching Sentry's
  # server-side behaviour exactly.
  defp sentry_signature(secret, body_params) do
    message = Jason.encode!(body_params)
    Security.hmac_sha256_hex(secret, message)
  end

  # ── verify/3 ──────────────────────────────────────

  describe "verify/3" do
    setup do
      secret = "sentry-client-secret"
      body_params = %{"action" => "created", "data" => %{"issue" => %{"id" => "123"}}}
      sig = sentry_signature(secret, body_params)

      conn =
        conn_with_headers(
          [{"sentry-hook-signature", sig}],
          body_params
        )

      # Simulate a raw body that differs from the re-serialized JSON
      # (e.g., extra whitespace, different key ordering).
      raw_body = ~s(  { "data": {"issue":{"id":"123"}}, "action":  "created" }  )

      %{secret: secret, body_params: body_params, sig: sig, conn: conn, raw_body: raw_body}
    end

    test "succeeds when signature matches re-serialized JSON", %{
      secret: secret,
      conn: conn,
      raw_body: raw_body
    } do
      assert :ok = Sentry.verify(secret, conn, raw_body)
    end

    test "CRITICAL: raw body with different whitespace fails when signed directly", %{
      secret: secret,
      body_params: body_params,
      raw_body: raw_body
    } do
      # Sign the raw bytes (not re-serialized) — this is what a naive
      # verifier would do, and it must NOT match Sentry's scheme.
      raw_sig = Security.hmac_sha256_hex(secret, raw_body)
      conn = conn_with_headers([{"sentry-hook-signature", raw_sig}], body_params)
      assert {:error, :unauthorized} = Sentry.verify(secret, conn, raw_body)
    end

    test "CRITICAL: re-serialized JSON succeeds even when raw body differs", %{
      secret: secret,
      body_params: body_params,
      raw_body: raw_body
    } do
      # Confirm that only the re-serialized JSON path passes.
      json_sig = sentry_signature(secret, body_params)
      conn = conn_with_headers([{"sentry-hook-signature", json_sig}], body_params)
      assert :ok = Sentry.verify(secret, conn, raw_body)
    end

    test "fails with wrong secret", %{body_params: body_params, sig: sig, raw_body: raw_body} do
      conn = conn_with_headers([{"sentry-hook-signature", sig}], body_params)
      assert {:error, :unauthorized} = Sentry.verify("wrong-secret", conn, raw_body)
    end

    test "fails when body_params differ from what was signed", %{
      secret: secret,
      sig: sig,
      raw_body: raw_body
    } do
      # body_params on the conn differs from the params used to compute sig
      tampered = %{"action" => "deleted"}
      conn = conn_with_headers([{"sentry-hook-signature", sig}], tampered)
      assert {:error, :unauthorized} = Sentry.verify(secret, conn, raw_body)
    end

    test "fails with missing signature header", %{
      secret: secret,
      body_params: body_params,
      raw_body: raw_body
    } do
      conn = conn_with_headers([], body_params)
      assert {:error, :unauthorized} = Sentry.verify(secret, conn, raw_body)
    end

    test "fails with signature of wrong length (too short)", %{
      body_params: body_params,
      raw_body: raw_body
    } do
      conn = conn_with_headers([{"sentry-hook-signature", "tooshort"}], body_params)
      assert {:error, :unauthorized} = Sentry.verify("secret", conn, raw_body)
    end

    test "fails with signature of wrong length (too long)", %{
      body_params: body_params,
      raw_body: raw_body
    } do
      long_sig = String.duplicate("a", 65)
      conn = conn_with_headers([{"sentry-hook-signature", long_sig}], body_params)
      assert {:error, :unauthorized} = Sentry.verify("secret", conn, raw_body)
    end

    test "succeeds with empty body_params map", %{raw_body: raw_body} do
      secret = "empty-body-secret"
      body_params = %{}
      sig = sentry_signature(secret, body_params)
      conn = conn_with_headers([{"sentry-hook-signature", sig}], body_params)
      assert :ok = Sentry.verify(secret, conn, raw_body)
    end
  end

  # ── extract_event_type/1 ──────────────────────────

  describe "extract_event_type/1" do
    test "returns event type from sentry-hook-resource header" do
      conn = conn_with_headers([{"sentry-hook-resource", "issue"}])
      assert {:ok, "issue"} = Sentry.extract_event_type(conn)
    end

    test "returns event_alert type" do
      conn = conn_with_headers([{"sentry-hook-resource", "event_alert"}])
      assert {:ok, "event_alert"} = Sentry.extract_event_type(conn)
    end

    test "defaults to unknown when header absent" do
      conn = conn_with_headers([])
      assert {:ok, "unknown"} = Sentry.extract_event_type(conn)
    end

    test "rejects empty event type" do
      conn = conn_with_headers([{"sentry-hook-resource", ""}])
      assert {:error, :invalid_event_type} = Sentry.extract_event_type(conn)
    end

    test "accepts event type at max length (255 bytes)" do
      event = String.duplicate("e", 255)
      conn = conn_with_headers([{"sentry-hook-resource", event}])
      assert {:ok, ^event} = Sentry.extract_event_type(conn)
    end

    test "rejects event type exceeding 255 bytes" do
      conn = conn_with_headers([{"sentry-hook-resource", String.duplicate("e", 256)}])
      assert {:error, :invalid_event_type} = Sentry.extract_event_type(conn)
    end
  end

  # ── extract_delivery_id/1 ──────────────────────────

  describe "extract_delivery_id/1" do
    test "returns delivery id from request-id header" do
      conn = conn_with_headers([{"request-id", "req-abc-123"}])
      assert {:ok, "req-abc-123"} = Sentry.extract_delivery_id(conn)
    end

    test "returns nil when header absent" do
      conn = conn_with_headers([])
      assert {:ok, nil} = Sentry.extract_delivery_id(conn)
    end

    test "rejects empty delivery id" do
      conn = conn_with_headers([{"request-id", ""}])
      assert {:error, :invalid_delivery_id} = Sentry.extract_delivery_id(conn)
    end

    test "accepts delivery id at max length (255 bytes)" do
      id = String.duplicate("d", 255)
      conn = conn_with_headers([{"request-id", id}])
      assert {:ok, ^id} = Sentry.extract_delivery_id(conn)
    end

    test "rejects delivery id exceeding 255 bytes" do
      conn = conn_with_headers([{"request-id", String.duplicate("d", 256)}])
      assert {:error, :invalid_delivery_id} = Sentry.extract_delivery_id(conn)
    end
  end
end
