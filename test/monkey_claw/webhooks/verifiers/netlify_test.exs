defmodule MonkeyClaw.Webhooks.Verifiers.NetlifyTest do
  use ExUnit.Case, async: true

  alias MonkeyClaw.Webhooks.Security
  alias MonkeyClaw.Webhooks.Verifiers.Netlify

  # ── JWT construction helpers ───────────────────────────────

  defp base64url_encode(data) do
    data
    |> Base.encode64(padding: false)
    |> String.replace("+", "-")
    |> String.replace("/", "_")
  end

  defp build_jwt(secret, header_claims, payload_claims) do
    header_json = Jason.encode!(header_claims)
    payload_json = Jason.encode!(payload_claims)

    header_b64 = base64url_encode(header_json)
    payload_b64 = base64url_encode(payload_json)

    signing_input = "#{header_b64}.#{payload_b64}"
    sig_bytes = :crypto.mac(:hmac, :sha256, secret, signing_input)
    sig_b64 = base64url_encode(sig_bytes)

    "#{header_b64}.#{payload_b64}.#{sig_b64}"
  end

  defp build_valid_jwt(secret, body) do
    body_hash = Security.hash_payload(body)

    build_jwt(
      secret,
      %{"alg" => "HS256", "typ" => "JWT"},
      %{"iss" => "netlify", "sha256" => body_hash}
    )
  end

  defp conn_with(headers) do
    Enum.reduce(headers, Plug.Test.conn(:post, "/test", ""), fn {key, value}, acc ->
      Plug.Conn.put_req_header(acc, key, value)
    end)
  end

  # ── verify/3 ──────────────────────────────────────

  describe "verify/3" do
    setup do
      secret = "netlify-webhook-secret"
      body = ~s({"event":"deploy_created","id":"dep_123"})
      token = build_valid_jwt(secret, body)
      conn = conn_with([{"x-webhook-signature", token}])
      %{secret: secret, body: body, token: token, conn: conn}
    end

    test "succeeds with valid JWT", %{secret: secret, body: body, conn: conn} do
      assert :ok = Netlify.verify(secret, conn, body)
    end

    test "fails with wrong secret", %{token: token, body: body} do
      conn = conn_with([{"x-webhook-signature", token}])
      assert {:error, :unauthorized} = Netlify.verify("wrong-secret", conn, body)
    end

    test "fails with tampered body", %{secret: secret, conn: conn} do
      assert {:error, :unauthorized} = Netlify.verify(secret, conn, "tampered-body")
    end

    test "fails with missing header", %{secret: secret, body: body} do
      conn = conn_with([])
      assert {:error, :unauthorized} = Netlify.verify(secret, conn, body)
    end

    test "fails with malformed JWT (only two segments)", %{secret: secret, body: body} do
      conn = conn_with([{"x-webhook-signature", "header.payload"}])
      assert {:error, :unauthorized} = Netlify.verify(secret, conn, body)
    end

    test "fails with malformed JWT (not base64url)", %{secret: secret, body: body} do
      conn = conn_with([{"x-webhook-signature", "!!!.!!!.!!!"}])
      assert {:error, :unauthorized} = Netlify.verify(secret, conn, body)
    end

    test "fails with wrong issuer", %{secret: secret, body: body} do
      body_hash = Security.hash_payload(body)

      token =
        build_jwt(
          secret,
          %{"alg" => "HS256", "typ" => "JWT"},
          %{"iss" => "notnetlify", "sha256" => body_hash}
        )

      conn = conn_with([{"x-webhook-signature", token}])
      assert {:error, :unauthorized} = Netlify.verify(secret, conn, body)
    end

    test "fails with wrong algorithm in header", %{secret: secret, body: body} do
      body_hash = Security.hash_payload(body)

      token =
        build_jwt(
          secret,
          %{"alg" => "RS256", "typ" => "JWT"},
          %{"iss" => "netlify", "sha256" => body_hash}
        )

      conn = conn_with([{"x-webhook-signature", token}])
      assert {:error, :unauthorized} = Netlify.verify(secret, conn, body)
    end

    test "fails when sha256 claim is missing from payload", %{secret: secret, body: body} do
      token =
        build_jwt(
          secret,
          %{"alg" => "HS256", "typ" => "JWT"},
          %{"iss" => "netlify"}
        )

      conn = conn_with([{"x-webhook-signature", token}])
      assert {:error, :unauthorized} = Netlify.verify(secret, conn, body)
    end

    test "fails with header exceeding max length", %{secret: secret, body: body} do
      conn = conn_with([{"x-webhook-signature", String.duplicate("a", 2049)}])
      assert {:error, :unauthorized} = Netlify.verify(secret, conn, body)
    end
  end

  # ── extract_event_type/1 ──────────────────────────

  describe "extract_event_type/1" do
    test "always returns unknown (URL-routed, no event type header)" do
      conn = conn_with([])
      assert {:ok, "unknown"} = Netlify.extract_event_type(conn)
    end

    test "returns unknown even when headers are present" do
      conn = conn_with([{"x-webhook-signature", "some.token.value"}])
      assert {:ok, "unknown"} = Netlify.extract_event_type(conn)
    end
  end

  # ── extract_delivery_id/1 ──────────────────────────

  describe "extract_delivery_id/1" do
    test "always returns nil (no delivery ID header)" do
      conn = conn_with([])
      assert {:ok, nil} = Netlify.extract_delivery_id(conn)
    end

    test "returns nil even when headers are present" do
      conn = conn_with([{"x-webhook-signature", "some.token.value"}])
      assert {:ok, nil} = Netlify.extract_delivery_id(conn)
    end
  end
end
