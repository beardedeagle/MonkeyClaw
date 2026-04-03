defmodule MonkeyClaw.Webhooks.Verifiers.PagerDutyTest do
  use ExUnit.Case, async: true

  alias MonkeyClaw.Webhooks.Security
  alias MonkeyClaw.Webhooks.Verifiers.PagerDuty

  defp conn_with_headers(headers, body_params \\ %{}) do
    conn =
      Enum.reduce(headers, Plug.Test.conn(:post, "/test", ""), fn {key, value}, acc ->
        Plug.Conn.put_req_header(acc, key, value)
      end)

    %{conn | body_params: body_params}
  end

  # ── verify/3 ──────────────────────────────────────

  describe "verify/3" do
    setup do
      secret = "pagerduty-webhook-secret"
      body = ~s({"event":{"event_type":"incident.triggered"}})
      sig = Security.hmac_sha256_hex(secret, body)
      conn = conn_with_headers([{"x-pagerduty-signature", "v1=#{sig}"}])
      %{secret: secret, body: body, conn: conn}
    end

    test "succeeds with valid signature", %{secret: secret, body: body, conn: conn} do
      assert :ok = PagerDuty.verify(secret, conn, body)
    end

    test "fails with wrong secret", %{body: body, conn: conn} do
      assert {:error, :unauthorized} = PagerDuty.verify("wrong", conn, body)
    end

    test "fails with tampered body", %{secret: secret, conn: conn} do
      assert {:error, :unauthorized} = PagerDuty.verify(secret, conn, "tampered")
    end

    test "fails with missing header" do
      conn = conn_with_headers([])
      assert {:error, :unauthorized} = PagerDuty.verify("secret", conn, "body")
    end

    test "fails without v1= prefix" do
      conn = conn_with_headers([{"x-pagerduty-signature", String.duplicate("a", 64)}])
      assert {:error, :unauthorized} = PagerDuty.verify("secret", conn, "body")
    end

    test "fails with wrong signature length after v1= prefix" do
      conn = conn_with_headers([{"x-pagerduty-signature", "v1=tooshort"}])
      assert {:error, :unauthorized} = PagerDuty.verify("secret", conn, "body")
    end
  end

  # ── extract_event_type/1 ──────────────────────────

  describe "extract_event_type/1" do
    test "returns event type from nested body params" do
      conn = conn_with_headers([], %{"event" => %{"event_type" => "incident.triggered"}})
      assert {:ok, "incident.triggered"} = PagerDuty.extract_event_type(conn)
    end

    test "returns pagey.ping event type" do
      conn = conn_with_headers([], %{"event" => %{"event_type" => "pagey.ping"}})
      assert {:ok, "pagey.ping"} = PagerDuty.extract_event_type(conn)
    end

    test "defaults to unknown when event key is absent" do
      conn = conn_with_headers([], %{})
      assert {:ok, "unknown"} = PagerDuty.extract_event_type(conn)
    end

    test "defaults to unknown when event_type is nil" do
      conn = conn_with_headers([], %{"event" => %{"event_type" => nil}})
      assert {:ok, "unknown"} = PagerDuty.extract_event_type(conn)
    end

    test "defaults to unknown when event map is absent" do
      conn = conn_with_headers([], %{"other" => "data"})
      assert {:ok, "unknown"} = PagerDuty.extract_event_type(conn)
    end

    test "rejects empty event_type string" do
      conn = conn_with_headers([], %{"event" => %{"event_type" => ""}})
      assert {:error, :invalid_event_type} = PagerDuty.extract_event_type(conn)
    end

    test "accepts event type at max length (255 bytes)" do
      event = String.duplicate("e", 255)
      conn = conn_with_headers([], %{"event" => %{"event_type" => event}})
      assert {:ok, ^event} = PagerDuty.extract_event_type(conn)
    end

    test "rejects event type exceeding 255 bytes" do
      conn = conn_with_headers([], %{"event" => %{"event_type" => String.duplicate("e", 256)}})
      assert {:error, :invalid_event_type} = PagerDuty.extract_event_type(conn)
    end
  end

  # ── extract_delivery_id/1 ──────────────────────────

  describe "extract_delivery_id/1" do
    test "returns delivery UUID from x-webhook-id header" do
      conn = conn_with_headers([{"x-webhook-id", "550e8400-e29b-41d4-a716-446655440000"}])
      assert {:ok, "550e8400-e29b-41d4-a716-446655440000"} = PagerDuty.extract_delivery_id(conn)
    end

    test "returns nil when absent" do
      conn = conn_with_headers([])
      assert {:ok, nil} = PagerDuty.extract_delivery_id(conn)
    end

    test "rejects empty delivery id" do
      conn = conn_with_headers([{"x-webhook-id", ""}])
      assert {:error, :invalid_delivery_id} = PagerDuty.extract_delivery_id(conn)
    end

    test "accepts delivery id at max length (255 bytes)" do
      id = String.duplicate("d", 255)
      conn = conn_with_headers([{"x-webhook-id", id}])
      assert {:ok, ^id} = PagerDuty.extract_delivery_id(conn)
    end

    test "rejects delivery id exceeding 255 bytes" do
      conn = conn_with_headers([{"x-webhook-id", String.duplicate("d", 256)}])
      assert {:error, :invalid_delivery_id} = PagerDuty.extract_delivery_id(conn)
    end
  end
end
