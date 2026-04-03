defmodule MonkeyClaw.Webhooks.Verifiers.ForgejoTest do
  use ExUnit.Case, async: true

  alias MonkeyClaw.Webhooks.Security
  alias MonkeyClaw.Webhooks.Verifiers.Forgejo

  defp conn_with_headers(headers) do
    Enum.reduce(headers, Plug.Test.conn(:post, "/test", ""), fn {key, value}, conn ->
      Plug.Conn.put_req_header(conn, key, value)
    end)
  end

  # ── verify/3 ──────────────────────────────────────

  describe "verify/3" do
    setup do
      secret = "forgejo-secret"
      body = ~s({"ref":"refs/heads/main"})
      sig = Security.hmac_sha256_hex(secret, body)
      %{secret: secret, body: body, sig: sig}
    end

    test "succeeds with forgejo signature header", %{secret: s, body: b, sig: sig} do
      conn = conn_with_headers([{"x-forgejo-signature", sig}])
      assert :ok = Forgejo.verify(s, conn, b)
    end

    test "falls back to gitea signature header", %{secret: s, body: b, sig: sig} do
      conn = conn_with_headers([{"x-gitea-signature", sig}])
      assert :ok = Forgejo.verify(s, conn, b)
    end

    test "prefers forgejo over gitea when both present", %{secret: s, body: b, sig: sig} do
      conn =
        conn_with_headers([
          {"x-forgejo-signature", sig},
          {"x-gitea-signature", String.duplicate("0", 64)}
        ])

      assert :ok = Forgejo.verify(s, conn, b)
    end

    test "fails with wrong secret", %{body: b, sig: sig} do
      conn = conn_with_headers([{"x-forgejo-signature", sig}])
      assert {:error, :unauthorized} = Forgejo.verify("wrong", conn, b)
    end

    test "fails with tampered body", %{secret: s, sig: sig} do
      conn = conn_with_headers([{"x-forgejo-signature", sig}])
      assert {:error, :unauthorized} = Forgejo.verify(s, conn, "tampered")
    end

    test "fails with missing header" do
      conn = conn_with_headers([])
      assert {:error, :unauthorized} = Forgejo.verify("secret", conn, "body")
    end

    test "fails with wrong signature length" do
      conn = conn_with_headers([{"x-forgejo-signature", "tooshort"}])
      assert {:error, :unauthorized} = Forgejo.verify("secret", conn, "body")
    end
  end

  # ── extract_event_type/1 ──────────────────────────

  describe "extract_event_type/1" do
    test "returns forgejo event type" do
      conn = conn_with_headers([{"x-forgejo-event", "push"}])
      assert {:ok, "push"} = Forgejo.extract_event_type(conn)
    end

    test "falls back to gitea event header" do
      conn = conn_with_headers([{"x-gitea-event", "push"}])
      assert {:ok, "push"} = Forgejo.extract_event_type(conn)
    end

    test "defaults to unknown when absent" do
      conn = conn_with_headers([])
      assert {:ok, "unknown"} = Forgejo.extract_event_type(conn)
    end

    test "accepts event at max length (255 bytes)" do
      event = String.duplicate("e", 255)
      conn = conn_with_headers([{"x-forgejo-event", event}])
      assert {:ok, ^event} = Forgejo.extract_event_type(conn)
    end

    test "rejects event exceeding 255 bytes" do
      conn = conn_with_headers([{"x-forgejo-event", String.duplicate("e", 256)}])
      assert {:error, :invalid_event_type} = Forgejo.extract_event_type(conn)
    end
  end

  # ── extract_delivery_id/1 ──────────────────────────

  describe "extract_delivery_id/1" do
    test "returns forgejo delivery UUID" do
      conn = conn_with_headers([{"x-forgejo-delivery", "uuid-123"}])
      assert {:ok, "uuid-123"} = Forgejo.extract_delivery_id(conn)
    end

    test "falls back to gitea delivery header" do
      conn = conn_with_headers([{"x-gitea-delivery", "uuid-456"}])
      assert {:ok, "uuid-456"} = Forgejo.extract_delivery_id(conn)
    end

    test "returns nil when absent" do
      conn = conn_with_headers([])
      assert {:ok, nil} = Forgejo.extract_delivery_id(conn)
    end

    test "accepts delivery id at max length (255 bytes)" do
      id = String.duplicate("d", 255)
      conn = conn_with_headers([{"x-forgejo-delivery", id}])
      assert {:ok, ^id} = Forgejo.extract_delivery_id(conn)
    end

    test "rejects delivery id exceeding 255 bytes" do
      conn = conn_with_headers([{"x-forgejo-delivery", String.duplicate("d", 256)}])
      assert {:error, :invalid_delivery_id} = Forgejo.extract_delivery_id(conn)
    end
  end
end
