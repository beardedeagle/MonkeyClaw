defmodule MonkeyClaw.Webhooks.Verifiers.DiscordTest do
  use ExUnit.Case, async: true

  alias MonkeyClaw.Webhooks.Verifiers.Discord

  defp conn_with_headers(headers) do
    Enum.reduce(headers, Plug.Test.conn(:post, "/test", ""), fn {key, value}, conn ->
      Plug.Conn.put_req_header(conn, key, value)
    end)
  end

  # Generate an Ed25519 keypair for testing.
  defp generate_ed25519_keypair do
    :crypto.generate_key(:eddsa, :ed25519)
  end

  defp sign_ed25519(private_key, message) do
    :crypto.sign(:eddsa, :none, message, [private_key, :ed25519])
  end

  # ── verify/3 ──────────────────────────────────────

  describe "verify/3" do
    setup do
      {public_key, private_key} = generate_ed25519_keypair()
      public_key_hex = Base.encode16(public_key, case: :lower)
      body = ~s({"type":1})
      timestamp = "1234567890"
      message = timestamp <> body
      signature = sign_ed25519(private_key, message)
      sig_hex = Base.encode16(signature, case: :lower)

      conn =
        conn_with_headers([
          {"x-signature-ed25519", sig_hex},
          {"x-signature-timestamp", timestamp}
        ])

      %{
        public_key_hex: public_key_hex,
        private_key: private_key,
        body: body,
        conn: conn
      }
    end

    test "succeeds with valid signature", %{
      public_key_hex: pk,
      body: body,
      conn: conn
    } do
      assert :ok = Discord.verify(pk, conn, body)
    end

    test "fails with wrong public key", %{body: body, conn: conn} do
      {other_pub, _} = generate_ed25519_keypair()
      other_hex = Base.encode16(other_pub, case: :lower)
      assert {:error, :unauthorized} = Discord.verify(other_hex, conn, body)
    end

    test "fails with tampered body", %{public_key_hex: pk, conn: conn} do
      assert {:error, :unauthorized} = Discord.verify(pk, conn, "tampered")
    end

    test "fails with missing signature header" do
      {pub, _} = generate_ed25519_keypair()
      pk_hex = Base.encode16(pub, case: :lower)
      conn = conn_with_headers([{"x-signature-timestamp", "123"}])
      assert {:error, :unauthorized} = Discord.verify(pk_hex, conn, "body")
    end

    test "fails with missing timestamp header" do
      {pub, _} = generate_ed25519_keypair()
      pk_hex = Base.encode16(pub, case: :lower)
      conn = conn_with_headers([{"x-signature-ed25519", String.duplicate("a", 128)}])
      assert {:error, :unauthorized} = Discord.verify(pk_hex, conn, "body")
    end

    test "fails with invalid hex public key" do
      conn =
        conn_with_headers([
          {"x-signature-ed25519", String.duplicate("a", 128)},
          {"x-signature-timestamp", "123"}
        ])

      assert {:error, :unauthorized} = Discord.verify("not-valid-hex!", conn, "body")
    end

    test "fails with wrong-length signature" do
      {pub, _} = generate_ed25519_keypair()
      pk_hex = Base.encode16(pub, case: :lower)

      conn =
        conn_with_headers([
          {"x-signature-ed25519", "tooshort"},
          {"x-signature-timestamp", "123"}
        ])

      assert {:error, :unauthorized} = Discord.verify(pk_hex, conn, "body")
    end

    test "fails with wrong-length public key hex" do
      conn =
        conn_with_headers([
          {"x-signature-ed25519", String.duplicate("a", 128)},
          {"x-signature-timestamp", "123"}
        ])

      # 30 bytes instead of 32 — structurally invalid
      short_key = Base.encode16(:crypto.strong_rand_bytes(30), case: :lower)
      assert {:error, :unauthorized} = Discord.verify(short_key, conn, "body")
    end
  end

  # ── extract_event_type/1 ──────────────────────────

  describe "extract_event_type/1" do
    test "returns gateway event name from t field" do
      conn = %{
        Plug.Test.conn(:post, "/test", "")
        | body_params: %{"t" => "MESSAGE_CREATE"}
      }

      assert {:ok, "MESSAGE_CREATE"} = Discord.extract_event_type(conn)
    end

    test "returns interaction type as string" do
      conn = %{
        Plug.Test.conn(:post, "/test", "")
        | body_params: %{"type" => 1}
      }

      assert {:ok, "1"} = Discord.extract_event_type(conn)
    end

    test "returns unknown when no type fields" do
      conn = %{Plug.Test.conn(:post, "/test", "") | body_params: %{}}
      assert {:ok, "unknown"} = Discord.extract_event_type(conn)
    end

    test "prefers t field over type field" do
      conn = %{
        Plug.Test.conn(:post, "/test", "")
        | body_params: %{"t" => "MESSAGE_CREATE", "type" => 0}
      }

      assert {:ok, "MESSAGE_CREATE"} = Discord.extract_event_type(conn)
    end
  end

  # ── extract_delivery_id/1 ──────────────────────────

  describe "extract_delivery_id/1" do
    test "returns id from body" do
      conn = %{
        Plug.Test.conn(:post, "/test", "")
        | body_params: %{"id" => "123456789"}
      }

      assert {:ok, "123456789"} = Discord.extract_delivery_id(conn)
    end

    test "returns nil when no id" do
      conn = %{Plug.Test.conn(:post, "/test", "") | body_params: %{}}
      assert {:ok, nil} = Discord.extract_delivery_id(conn)
    end
  end
end
