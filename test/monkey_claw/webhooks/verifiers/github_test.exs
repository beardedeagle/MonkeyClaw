defmodule MonkeyClaw.Webhooks.Verifiers.GitHubTest do
  use ExUnit.Case, async: true

  alias MonkeyClaw.Webhooks.Security
  alias MonkeyClaw.Webhooks.Verifiers.GitHub

  defp conn_with_headers(headers) do
    Enum.reduce(headers, Plug.Test.conn(:post, "/test", ""), fn {key, value}, conn ->
      Plug.Conn.put_req_header(conn, key, value)
    end)
  end

  # ── verify/3 ──────────────────────────────────────

  describe "verify/3" do
    setup do
      secret = "github-webhook-secret"
      body = ~s({"action":"push"})
      sig = Security.hmac_sha256_hex(secret, body)
      conn = conn_with_headers([{"x-hub-signature-256", "sha256=#{sig}"}])
      %{secret: secret, body: body, conn: conn}
    end

    test "succeeds with valid signature", %{secret: secret, body: body, conn: conn} do
      assert :ok = GitHub.verify(secret, conn, body)
    end

    test "fails with wrong secret", %{body: body, conn: conn} do
      assert {:error, :unauthorized} = GitHub.verify("wrong", conn, body)
    end

    test "fails with tampered body", %{secret: secret, conn: conn} do
      assert {:error, :unauthorized} = GitHub.verify(secret, conn, "tampered")
    end

    test "fails with missing header" do
      conn = conn_with_headers([])
      assert {:error, :unauthorized} = GitHub.verify("secret", conn, "body")
    end

    test "fails without sha256= prefix" do
      conn = conn_with_headers([{"x-hub-signature-256", String.duplicate("a", 64)}])
      assert {:error, :unauthorized} = GitHub.verify("secret", conn, "body")
    end

    test "fails with wrong signature length" do
      conn = conn_with_headers([{"x-hub-signature-256", "sha256=tooshort"}])
      assert {:error, :unauthorized} = GitHub.verify("secret", conn, "body")
    end
  end

  # ── extract_event_type/1 ──────────────────────────

  describe "extract_event_type/1" do
    test "returns event from header" do
      conn = conn_with_headers([{"x-github-event", "push"}])
      assert {:ok, "push"} = GitHub.extract_event_type(conn)
    end

    test "defaults to unknown when absent" do
      conn = conn_with_headers([])
      assert {:ok, "unknown"} = GitHub.extract_event_type(conn)
    end

    test "rejects empty event" do
      conn = conn_with_headers([{"x-github-event", ""}])
      assert {:error, :invalid_event_type} = GitHub.extract_event_type(conn)
    end

    test "accepts event at max length (255 bytes)" do
      event = String.duplicate("e", 255)
      conn = conn_with_headers([{"x-github-event", event}])
      assert {:ok, ^event} = GitHub.extract_event_type(conn)
    end

    test "rejects event exceeding 255 bytes" do
      conn = conn_with_headers([{"x-github-event", String.duplicate("e", 256)}])
      assert {:error, :invalid_event_type} = GitHub.extract_event_type(conn)
    end
  end

  # ── extract_delivery_id/1 ──────────────────────────

  describe "extract_delivery_id/1" do
    test "returns delivery UUID from header" do
      conn = conn_with_headers([{"x-github-delivery", "abc-123"}])
      assert {:ok, "abc-123"} = GitHub.extract_delivery_id(conn)
    end

    test "returns nil when absent" do
      conn = conn_with_headers([])
      assert {:ok, nil} = GitHub.extract_delivery_id(conn)
    end

    test "rejects empty delivery id" do
      conn = conn_with_headers([{"x-github-delivery", ""}])
      assert {:error, :invalid_delivery_id} = GitHub.extract_delivery_id(conn)
    end

    test "accepts delivery id at max length (255 bytes)" do
      id = String.duplicate("d", 255)
      conn = conn_with_headers([{"x-github-delivery", id}])
      assert {:ok, ^id} = GitHub.extract_delivery_id(conn)
    end

    test "rejects delivery id exceeding 255 bytes" do
      conn = conn_with_headers([{"x-github-delivery", String.duplicate("d", 256)}])
      assert {:error, :invalid_delivery_id} = GitHub.extract_delivery_id(conn)
    end
  end
end
