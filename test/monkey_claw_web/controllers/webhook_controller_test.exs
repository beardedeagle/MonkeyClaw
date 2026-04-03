defmodule MonkeyClawWeb.WebhookControllerTest do
  use MonkeyClawWeb.ConnCase

  import MonkeyClaw.Factory

  alias MonkeyClaw.Webhooks
  alias MonkeyClaw.Webhooks.RateLimiter
  alias MonkeyClaw.Webhooks.Security

  # Drain async dispatch tasks before sandbox teardown to prevent
  # SQLite3 write lock contention between tests. on_exit callbacks
  # run in LIFO order, so this executes before the sandbox owner
  # is stopped (registered after setup_sandbox in ConnCase).
  setup do
    on_exit(fn ->
      MonkeyClaw.TaskSupervisor
      |> Supervisor.which_children()
      |> Enum.each(fn
        {_, pid, _, _} when is_pid(pid) ->
          ref = Process.monitor(pid)

          receive do
            {:DOWN, ^ref, :process, ^pid, _} -> :ok
          after
            5_000 -> :ok
          end

        _ ->
          :ok
      end)
    end)
  end

  # ── Test Helpers ──────────────────────────────

  # Build a properly signed webhook request with all required headers.
  # The payload is JSON-encoded, signed with HMAC-SHA256, and sent as
  # a POST to the webhook endpoint URL.
  @spec signed_request(Plug.Conn.t(), map(), map(), keyword()) :: Plug.Conn.t()
  defp signed_request(conn, endpoint, payload, opts \\ []) do
    body = Jason.encode!(payload)
    timestamp = Keyword.get(opts, :timestamp, System.os_time(:second))
    secret = Keyword.get(opts, :secret, endpoint.signing_secret)
    event_type = Keyword.get(opts, :event_type, "test.event")
    idempotency_key = Keyword.get(opts, :idempotency_key, nil)

    signature_header = Security.build_signature_header(secret, timestamp, body)

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-monkeyclaw-signature", signature_header)
      |> put_req_header("x-monkeyclaw-event", event_type)

    conn =
      if idempotency_key do
        put_req_header(conn, "x-monkeyclaw-idempotency-key", idempotency_key)
      else
        conn
      end

    post(conn, ~p"/api/webhooks/#{endpoint.id}", body)
  end

  setup do
    RateLimiter.reset_all()
    :ok
  end

  # ──────────────────────────────────────────────
  # Successful Delivery
  # ──────────────────────────────────────────────

  describe "POST /api/webhooks/:endpoint_id — success" do
    test "returns 202 Accepted with delivery_id", %{conn: conn} do
      workspace = insert_workspace!()
      endpoint = insert_webhook_endpoint!(workspace)

      conn = signed_request(conn, endpoint, %{"action" => "push", "ref" => "main"})

      assert %{"status" => "accepted", "delivery_id" => delivery_id} = json_response(conn, 202)
      assert is_binary(delivery_id)
    end

    test "records delivery in database", %{conn: conn} do
      workspace = insert_workspace!()
      endpoint = insert_webhook_endpoint!(workspace)

      signed_request(conn, endpoint, %{"data" => "value"})

      deliveries = Webhooks.list_deliveries(endpoint.id)
      assert length(deliveries) == 1
      delivery = hd(deliveries)
      # Status may be :accepted (initial) or :failed/:processed if the async
      # dispatch task ran before this query. Both are valid — this test
      # verifies the delivery was *recorded*, not the dispatch outcome.
      assert delivery.status in [:accepted, :processed, :failed]
      assert delivery.event_type == "test.event"
    end

    test "records payload hash in delivery", %{conn: conn} do
      workspace = insert_workspace!()
      endpoint = insert_webhook_endpoint!(workspace)
      payload = %{"action" => "created"}

      signed_request(conn, endpoint, payload)

      [delivery] = Webhooks.list_deliveries(endpoint.id)
      expected_hash = Security.hash_payload(Jason.encode!(payload))
      assert delivery.payload_hash == expected_hash
    end

    test "records remote_ip in delivery", %{conn: conn} do
      workspace = insert_workspace!()
      endpoint = insert_webhook_endpoint!(workspace)

      signed_request(conn, endpoint, %{})

      [delivery] = Webhooks.list_deliveries(endpoint.id)
      assert is_binary(delivery.remote_ip)
    end
  end

  # ──────────────────────────────────────────────
  # Endpoint Lookup — 404
  # ──────────────────────────────────────────────

  describe "POST /api/webhooks/:endpoint_id — endpoint not found" do
    test "returns 404 for non-existent endpoint", %{conn: conn} do
      fake_id = Ecto.UUID.generate()
      body = Jason.encode!(%{})

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-monkeyclaw-signature", "t=123,v1=#{String.duplicate("a", 64)}")
        |> post(~p"/api/webhooks/#{fake_id}", body)

      assert %{"error" => "not found"} = json_response(conn, 404)
    end

    test "returns 404 for paused endpoint (anti-enumeration)", %{conn: conn} do
      workspace = insert_workspace!()
      endpoint = insert_webhook_endpoint!(workspace)
      {:ok, _paused} = Webhooks.pause_endpoint(endpoint)

      conn = signed_request(conn, endpoint, %{})

      assert %{"error" => "not found"} = json_response(conn, 404)
    end

    test "returns 404 for revoked endpoint (anti-enumeration)", %{conn: conn} do
      workspace = insert_workspace!()
      endpoint = insert_webhook_endpoint!(workspace)
      {:ok, _revoked} = Webhooks.revoke_endpoint(endpoint)

      conn = signed_request(conn, endpoint, %{})

      assert %{"error" => "not found"} = json_response(conn, 404)
    end

    test "paused and non-existent return identical responses", %{conn: conn} do
      workspace = insert_workspace!()
      endpoint = insert_webhook_endpoint!(workspace)
      {:ok, _paused} = Webhooks.pause_endpoint(endpoint)

      paused_resp =
        conn
        |> signed_request(endpoint, %{})
        |> json_response(404)

      fake_resp =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-monkeyclaw-signature", "t=123,v1=#{String.duplicate("b", 64)}")
        |> post(~p"/api/webhooks/#{Ecto.UUID.generate()}", Jason.encode!(%{}))
        |> json_response(404)

      assert paused_resp == fake_resp
    end
  end

  # ──────────────────────────────────────────────
  # Content-Type Validation — 415
  # ──────────────────────────────────────────────

  describe "POST /api/webhooks/:endpoint_id — content type" do
    test "returns 415 for non-JSON content type", %{conn: conn} do
      workspace = insert_workspace!()
      endpoint = insert_webhook_endpoint!(workspace)
      body = "plain text body"
      timestamp = System.os_time(:second)
      sig = Security.build_signature_header(endpoint.signing_secret, timestamp, body)

      conn =
        conn
        |> put_req_header("content-type", "text/plain")
        |> put_req_header("x-monkeyclaw-signature", sig)
        |> post(~p"/api/webhooks/#{endpoint.id}", body)

      assert %{"error" => "unsupported media type"} = json_response(conn, 415)
    end
  end

  # ──────────────────────────────────────────────
  # Signature Verification — 401
  # ──────────────────────────────────────────────

  describe "POST /api/webhooks/:endpoint_id — authentication" do
    test "returns 401 for invalid HMAC signature", %{conn: conn} do
      workspace = insert_workspace!()
      endpoint = insert_webhook_endpoint!(workspace)

      conn = signed_request(conn, endpoint, %{}, secret: "completely-wrong-secret")

      assert %{"error" => "unauthorized"} = json_response(conn, 401)
    end

    test "returns 401 for expired timestamp", %{conn: conn} do
      workspace = insert_workspace!()
      endpoint = insert_webhook_endpoint!(workspace)

      # 10 minutes ago — beyond the 5-minute tolerance
      conn = signed_request(conn, endpoint, %{}, timestamp: System.os_time(:second) - 600)

      assert %{"error" => "unauthorized"} = json_response(conn, 401)
    end

    test "returns 401 for missing signature header", %{conn: conn} do
      workspace = insert_workspace!()
      endpoint = insert_webhook_endpoint!(workspace)

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/webhooks/#{endpoint.id}", Jason.encode!(%{}))

      assert %{"error" => "unauthorized"} = json_response(conn, 401)
    end

    test "returns 401 for invalid idempotency key (empty string)", %{conn: conn} do
      workspace = insert_workspace!()
      endpoint = insert_webhook_endpoint!(workspace)
      body = Jason.encode!(%{})
      timestamp = System.os_time(:second)
      sig = Security.build_signature_header(endpoint.signing_secret, timestamp, body)

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-monkeyclaw-signature", sig)
        |> put_req_header("x-monkeyclaw-event", "test")
        |> put_req_header("x-monkeyclaw-idempotency-key", "")
        |> post(~p"/api/webhooks/#{endpoint.id}", body)

      assert %{"error" => "unauthorized"} = json_response(conn, 401)
    end
  end

  # ──────────────────────────────────────────────
  # Replay Detection — idempotent 202
  # ──────────────────────────────────────────────

  describe "POST /api/webhooks/:endpoint_id — replay detection" do
    test "returns 202 with 'already processed' for replay", %{conn: conn} do
      workspace = insert_workspace!()
      endpoint = insert_webhook_endpoint!(workspace)

      # First request with idempotency key
      signed_request(conn, endpoint, %{}, idempotency_key: "replay-key-001")

      # Replay with the same key
      conn2 = signed_request(conn, endpoint, %{}, idempotency_key: "replay-key-001")

      assert %{"status" => "accepted", "note" => "already processed"} = json_response(conn2, 202)
    end

    test "different idempotency keys are not replays", %{conn: conn} do
      workspace = insert_workspace!()
      endpoint = insert_webhook_endpoint!(workspace)

      signed_request(conn, endpoint, %{}, idempotency_key: "key-a")
      conn2 = signed_request(conn, endpoint, %{}, idempotency_key: "key-b")

      assert %{"status" => "accepted", "delivery_id" => _} = json_response(conn2, 202)
    end
  end

  # ──────────────────────────────────────────────
  # Rate Limiting — 429
  # ──────────────────────────────────────────────

  describe "POST /api/webhooks/:endpoint_id — rate limiting" do
    test "returns 429 with Retry-After header when rate limited", %{conn: conn} do
      workspace = insert_workspace!()
      endpoint = insert_webhook_endpoint!(workspace, %{rate_limit_per_minute: 1})

      # First request succeeds
      conn1 = signed_request(conn, endpoint, %{})
      assert json_response(conn1, 202)

      # Second request exceeds rate limit
      conn2 = signed_request(conn, endpoint, %{})

      assert %{"error" => "rate limit exceeded"} = json_response(conn2, 429)
      assert get_resp_header(conn2, "retry-after") == ["60"]
    end
  end

  # ──────────────────────────────────────────────
  # Event Filtering — 422
  # ──────────────────────────────────────────────

  describe "POST /api/webhooks/:endpoint_id — event filtering" do
    test "returns 422 for disallowed event type", %{conn: conn} do
      workspace = insert_workspace!()

      endpoint =
        insert_webhook_endpoint!(workspace, %{
          allowed_events: %{"push" => true, "release" => true}
        })

      conn = signed_request(conn, endpoint, %{}, event_type: "issue")

      assert %{"error" => "unprocessable entity"} = json_response(conn, 422)
    end

    test "accepts allowed event type", %{conn: conn} do
      workspace = insert_workspace!()

      endpoint =
        insert_webhook_endpoint!(workspace, %{
          allowed_events: %{"push" => true}
        })

      conn = signed_request(conn, endpoint, %{}, event_type: "push")

      assert %{"status" => "accepted"} = json_response(conn, 202)
    end

    test "accepts any event when allowed_events is empty", %{conn: conn} do
      workspace = insert_workspace!()
      endpoint = insert_webhook_endpoint!(workspace, %{allowed_events: %{}})

      conn = signed_request(conn, endpoint, %{}, event_type: "anything.goes")

      assert %{"status" => "accepted"} = json_response(conn, 202)
    end

    test "returns 422 for invalid event type header (empty)", %{conn: conn} do
      workspace = insert_workspace!()
      endpoint = insert_webhook_endpoint!(workspace)
      body = Jason.encode!(%{})
      timestamp = System.os_time(:second)
      sig = Security.build_signature_header(endpoint.signing_secret, timestamp, body)

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-monkeyclaw-signature", sig)
        |> put_req_header("x-monkeyclaw-event", "")
        |> post(~p"/api/webhooks/#{endpoint.id}", body)

      assert %{"error" => "unprocessable entity"} = json_response(conn, 422)
    end
  end

  # ──────────────────────────────────────────────
  # Error Response Opacity
  # ──────────────────────────────────────────────

  describe "error response opacity" do
    test "error responses contain no internal details", %{conn: conn} do
      workspace = insert_workspace!()
      endpoint = insert_webhook_endpoint!(workspace)

      # Test 401 response body
      resp =
        conn
        |> signed_request(endpoint, %{}, secret: "wrong")
        |> json_response(401)

      assert resp == %{"error" => "unauthorized"}
      refute Map.has_key?(resp, "endpoint_id")
      refute Map.has_key?(resp, "reason")
      refute Map.has_key?(resp, "details")
    end
  end

  # ──────────────────────────────────────────────
  # Rejected Delivery Audit Trail
  # ──────────────────────────────────────────────

  describe "POST /api/webhooks/:endpoint_id — rejected delivery audit" do
    test "records rejected delivery for invalid signature", %{conn: conn} do
      workspace = insert_workspace!()
      endpoint = insert_webhook_endpoint!(workspace)

      signed_request(conn, endpoint, %{}, secret: "completely-wrong-secret")

      deliveries = Webhooks.list_deliveries(endpoint.id)
      assert length(deliveries) == 1
      delivery = hd(deliveries)
      assert delivery.status == :rejected
      assert delivery.rejection_reason == "unauthorized"
      assert is_binary(delivery.payload_hash)
      assert is_binary(delivery.remote_ip)
    end

    test "records rejected delivery for wrong content type", %{conn: conn} do
      workspace = insert_workspace!()
      endpoint = insert_webhook_endpoint!(workspace)
      body = "plain text"
      timestamp = System.os_time(:second)
      sig = Security.build_signature_header(endpoint.signing_secret, timestamp, body)

      conn
      |> put_req_header("content-type", "text/plain")
      |> put_req_header("x-monkeyclaw-signature", sig)
      |> post(~p"/api/webhooks/#{endpoint.id}", body)

      deliveries = Webhooks.list_deliveries(endpoint.id)
      assert length(deliveries) == 1
      assert hd(deliveries).status == :rejected
      assert hd(deliveries).rejection_reason == "invalid_content_type"
    end

    test "records rejected delivery for disallowed event type", %{conn: conn} do
      workspace = insert_workspace!()

      endpoint =
        insert_webhook_endpoint!(workspace, %{
          allowed_events: %{"push" => true}
        })

      signed_request(conn, endpoint, %{}, event_type: "issue")

      deliveries = Webhooks.list_deliveries(endpoint.id)
      assert length(deliveries) == 1
      assert hd(deliveries).status == :rejected
      assert hd(deliveries).rejection_reason == "event_not_allowed"
    end

    test "records rejected delivery for rate limit exceeded", %{conn: conn} do
      workspace = insert_workspace!()
      endpoint = insert_webhook_endpoint!(workspace, %{rate_limit_per_minute: 1})

      # First request succeeds (accepted)
      signed_request(conn, endpoint, %{})

      # Second request rate-limited (rejected)
      signed_request(conn, endpoint, %{})

      deliveries = Webhooks.list_deliveries(endpoint.id)
      assert length(deliveries) == 2
      rejected = Enum.find(deliveries, &(&1.status == :rejected))
      assert rejected != nil
      assert rejected.rejection_reason == "rate_limited"
    end

    test "does not record delivery for non-existent endpoint", %{conn: conn} do
      fake_id = Ecto.UUID.generate()
      body = Jason.encode!(%{})

      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-monkeyclaw-signature", "t=123,v1=#{String.duplicate("a", 64)}")
      |> post(~p"/api/webhooks/#{fake_id}", body)

      assert Webhooks.list_deliveries(fake_id) == []
    end

    test "replay does not create additional delivery", %{conn: conn} do
      workspace = insert_workspace!()
      endpoint = insert_webhook_endpoint!(workspace)

      # First request
      signed_request(conn, endpoint, %{}, idempotency_key: "replay-audit-001")

      # Replay with same key
      signed_request(conn, endpoint, %{}, idempotency_key: "replay-audit-001")

      # Only the original delivery exists
      deliveries = Webhooks.list_deliveries(endpoint.id)
      assert length(deliveries) == 1
      assert hd(deliveries).status in [:accepted, :processed, :failed]
    end
  end
end
