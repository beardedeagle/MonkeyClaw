defmodule MonkeyClaw.Webhooks.Verifiers.VercelTest do
  use ExUnit.Case, async: true

  alias MonkeyClaw.Webhooks.Security
  alias MonkeyClaw.Webhooks.Verifiers.Vercel

  defp conn_with(headers, body_params \\ %{}) do
    conn =
      Enum.reduce(headers, Plug.Test.conn(:post, "/test", ""), fn {key, value}, acc ->
        Plug.Conn.put_req_header(acc, key, value)
      end)

    %{conn | body_params: body_params}
  end

  # ── verify/3 ──────────────────────────────────────

  describe "verify/3" do
    setup do
      secret = "vercel-webhook-secret"
      body = ~s({"type":"deployment.created","id":"evt_123"})
      sig = Security.hmac_sha1_hex(secret, body)
      conn = conn_with([{"x-vercel-signature", sig}])
      %{secret: secret, body: body, conn: conn, sig: sig}
    end

    test "succeeds with valid signature", %{secret: secret, body: body, conn: conn} do
      assert :ok = Vercel.verify(secret, conn, body)
    end

    test "fails with wrong secret", %{body: body, conn: conn} do
      assert {:error, :unauthorized} = Vercel.verify("wrong", conn, body)
    end

    test "fails with tampered body", %{secret: secret, conn: conn} do
      assert {:error, :unauthorized} = Vercel.verify(secret, conn, "tampered")
    end

    test "fails with missing header" do
      conn = conn_with([])
      assert {:error, :unauthorized} = Vercel.verify("secret", conn, "body")
    end

    test "fails with wrong signature length (64 chars — SHA256 length)" do
      conn = conn_with([{"x-vercel-signature", String.duplicate("a", 64)}])
      assert {:error, :unauthorized} = Vercel.verify("secret", conn, "body")
    end

    test "fails with wrong signature length (too short)" do
      conn = conn_with([{"x-vercel-signature", String.duplicate("a", 20)}])
      assert {:error, :unauthorized} = Vercel.verify("secret", conn, "body")
    end
  end

  # ── extract_event_type/1 ──────────────────────────

  describe "extract_event_type/1" do
    test "returns event type from body" do
      conn = conn_with([], %{"type" => "deployment.created"})
      assert {:ok, "deployment.created"} = Vercel.extract_event_type(conn)
    end

    test "defaults to unknown when absent" do
      conn = conn_with([], %{})
      assert {:ok, "unknown"} = Vercel.extract_event_type(conn)
    end

    test "rejects empty event type" do
      conn = conn_with([], %{"type" => ""})
      assert {:error, :invalid_event_type} = Vercel.extract_event_type(conn)
    end

    test "accepts event type at max length (255 bytes)" do
      event = String.duplicate("e", 255)
      conn = conn_with([], %{"type" => event})
      assert {:ok, ^event} = Vercel.extract_event_type(conn)
    end

    test "rejects event type exceeding 255 bytes" do
      conn = conn_with([], %{"type" => String.duplicate("e", 256)})
      assert {:error, :invalid_event_type} = Vercel.extract_event_type(conn)
    end
  end

  # ── extract_delivery_id/1 ──────────────────────────

  describe "extract_delivery_id/1" do
    test "returns delivery ID from body" do
      conn = conn_with([], %{"id" => "evt_abc123"})
      assert {:ok, "evt_abc123"} = Vercel.extract_delivery_id(conn)
    end

    test "returns nil when absent" do
      conn = conn_with([], %{})
      assert {:ok, nil} = Vercel.extract_delivery_id(conn)
    end

    test "rejects empty delivery id" do
      conn = conn_with([], %{"id" => ""})
      assert {:error, :invalid_delivery_id} = Vercel.extract_delivery_id(conn)
    end

    test "accepts delivery id at max length (255 bytes)" do
      id = String.duplicate("d", 255)
      conn = conn_with([], %{"id" => id})
      assert {:ok, ^id} = Vercel.extract_delivery_id(conn)
    end

    test "rejects delivery id exceeding 255 bytes" do
      conn = conn_with([], %{"id" => String.duplicate("d", 256)})
      assert {:error, :invalid_delivery_id} = Vercel.extract_delivery_id(conn)
    end
  end
end
