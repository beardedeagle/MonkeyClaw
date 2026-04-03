defmodule MonkeyClaw.Webhooks.Verifiers.TwilioTest do
  use ExUnit.Case, async: true

  alias MonkeyClaw.Webhooks.Security
  alias MonkeyClaw.Webhooks.Verifiers.Twilio

  defp base_conn(path \\ "/webhooks/receive/endpoint-id", body \\ "") do
    conn = Plug.Test.conn(:post, path, body)
    %{conn | scheme: :https, host: "example.com", port: 443}
  end

  defp conn_with_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {key, value}, acc ->
      Plug.Conn.put_req_header(acc, key, value)
    end)
  end

  defp sign(secret, url, body) do
    Security.hmac_sha1_base64(secret, url <> body)
  end

  # ── verify/3 ──────────────────────────────────────

  describe "verify/3" do
    setup do
      secret = "twilio-auth-token"
      body = ~s({"From":"+15005550006"})
      url = "https://example.com/webhooks/receive/endpoint-id"
      sig = sign(secret, url, body)
      conn = base_conn() |> conn_with_headers([{"x-twilio-signature", sig}])
      %{secret: secret, body: body, conn: conn}
    end

    test "succeeds with valid signature and standard HTTPS port", %{
      secret: secret,
      body: body,
      conn: conn
    } do
      assert :ok = Twilio.verify(secret, conn, body)
    end

    test "fails with wrong secret", %{body: body, conn: conn} do
      assert {:error, :unauthorized} = Twilio.verify("wrong-secret", conn, body)
    end

    test "fails with tampered body", %{secret: secret, conn: conn} do
      assert {:error, :unauthorized} = Twilio.verify(secret, conn, "tampered")
    end

    test "fails with missing signature header" do
      conn = base_conn()
      assert {:error, :unauthorized} = Twilio.verify("secret", conn, "body")
    end

    test "fails with empty signature header" do
      conn = base_conn() |> conn_with_headers([{"x-twilio-signature", ""}])
      assert {:error, :unauthorized} = Twilio.verify("secret", conn, "body")
    end

    test "fails with signature exceeding max header length" do
      conn =
        base_conn()
        |> conn_with_headers([{"x-twilio-signature", String.duplicate("a", 256)}])

      assert {:error, :unauthorized} = Twilio.verify("secret", conn, "body")
    end
  end

  # ── URL reconstruction ─────────────────────────────

  describe "verify/3 URL reconstruction" do
    test "omits port 443 for HTTPS" do
      secret = "secret"
      body = "body"
      url = "https://example.com/webhooks/receive/endpoint-id"
      sig = sign(secret, url, body)

      conn =
        %{base_conn() | scheme: :https, host: "example.com", port: 443}
        |> conn_with_headers([{"x-twilio-signature", sig}])

      assert :ok = Twilio.verify(secret, conn, body)
    end

    test "omits port 80 for HTTP" do
      secret = "secret"
      body = "body"
      url = "http://example.com/webhooks/receive/endpoint-id"
      sig = sign(secret, url, body)

      conn =
        %{base_conn() | scheme: :http, host: "example.com", port: 80}
        |> conn_with_headers([{"x-twilio-signature", sig}])

      assert :ok = Twilio.verify(secret, conn, body)
    end

    test "includes non-standard port in URL" do
      secret = "secret"
      body = "body"
      url = "https://example.com:8443/webhooks/receive/endpoint-id"
      sig = sign(secret, url, body)

      conn =
        %{base_conn() | scheme: :https, host: "example.com", port: 8443}
        |> conn_with_headers([{"x-twilio-signature", sig}])

      assert :ok = Twilio.verify(secret, conn, body)
    end

    test "includes query string when present" do
      secret = "secret"
      body = "body"
      url = "https://example.com/webhooks/receive/endpoint-id?foo=bar"
      sig = sign(secret, url, body)

      conn =
        Plug.Test.conn(:post, "/webhooks/receive/endpoint-id?foo=bar", body)
        |> then(&%{&1 | scheme: :https, host: "example.com", port: 443})
        |> conn_with_headers([{"x-twilio-signature", sig}])

      assert :ok = Twilio.verify(secret, conn, body)
    end

    test "fails when URL does not match due to wrong port in signed message" do
      secret = "secret"
      body = "body"
      # Signed with port 8443 in URL, but conn has port 443
      url = "https://example.com:8443/webhooks/receive/endpoint-id"
      sig = sign(secret, url, body)

      conn =
        %{base_conn() | scheme: :https, host: "example.com", port: 443}
        |> conn_with_headers([{"x-twilio-signature", sig}])

      assert {:error, :unauthorized} = Twilio.verify(secret, conn, body)
    end
  end

  # ── extract_event_type/1 ──────────────────────────

  describe "extract_event_type/1" do
    test "always returns unknown regardless of headers" do
      conn = base_conn()
      assert {:ok, "unknown"} = Twilio.extract_event_type(conn)
    end

    test "returns unknown even with unrelated headers" do
      conn = base_conn() |> conn_with_headers([{"x-twilio-signature", "sig"}])
      assert {:ok, "unknown"} = Twilio.extract_event_type(conn)
    end
  end

  # ── extract_delivery_id/1 ──────────────────────────

  describe "extract_delivery_id/1" do
    test "always returns nil regardless of headers" do
      conn = base_conn()
      assert {:ok, nil} = Twilio.extract_delivery_id(conn)
    end

    test "returns nil even with unrelated headers" do
      conn = base_conn() |> conn_with_headers([{"x-twilio-signature", "sig"}])
      assert {:ok, nil} = Twilio.extract_delivery_id(conn)
    end
  end
end
