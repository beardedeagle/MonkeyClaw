defmodule MonkeyClaw.Webhooks.Verifiers.CircleCITest do
  use ExUnit.Case, async: true

  alias MonkeyClaw.Webhooks.Security
  alias MonkeyClaw.Webhooks.Verifiers.CircleCI

  defp conn_with_headers(headers, body \\ "") do
    Enum.reduce(headers, Plug.Test.conn(:post, "/test", body), fn {key, value}, conn ->
      Plug.Conn.put_req_header(conn, key, value)
    end)
  end

  defp conn_with_body_params(params) do
    conn = Plug.Test.conn(:post, "/test", "")
    Map.put(conn, :body_params, params)
  end

  # ── verify/3 ──────────────────────────────────────

  describe "verify/3" do
    setup do
      secret = "circleci-webhook-secret"
      body = ~s({"id":"event-123","type":"workflow-completed"})
      sig = Security.hmac_sha256_hex(secret, body)
      conn = conn_with_headers([{"circleci-signature", "v1=#{sig}"}])
      %{secret: secret, body: body, conn: conn, sig: sig}
    end

    test "succeeds with valid signature", %{secret: secret, body: body, conn: conn} do
      assert :ok = CircleCI.verify(secret, conn, body)
    end

    test "fails with wrong secret", %{body: body, conn: conn} do
      assert {:error, :unauthorized} = CircleCI.verify("wrong-secret", conn, body)
    end

    test "fails with tampered body", %{secret: secret, conn: conn} do
      assert {:error, :unauthorized} = CircleCI.verify(secret, conn, "tampered")
    end

    test "fails with missing header" do
      conn = conn_with_headers([])
      assert {:error, :unauthorized} = CircleCI.verify("secret", conn, "body")
    end

    test "fails without v1= prefix" do
      conn = conn_with_headers([{"circleci-signature", String.duplicate("a", 64)}])
      assert {:error, :unauthorized} = CircleCI.verify("secret", conn, "body")
    end

    test "fails with wrong signature length" do
      conn = conn_with_headers([{"circleci-signature", "v1=tooshort"}])
      assert {:error, :unauthorized} = CircleCI.verify("secret", conn, "body")
    end

    test "succeeds when v1 is the first of multiple comma-separated entries", %{
      secret: secret,
      body: body,
      sig: sig
    } do
      conn =
        conn_with_headers([{"circleci-signature", "v1=#{sig},v2=#{String.duplicate("b", 64)}"}])

      assert :ok = CircleCI.verify(secret, conn, body)
    end

    test "succeeds when v1 is not the first comma-separated entry", %{
      secret: secret,
      body: body,
      sig: sig
    } do
      conn =
        conn_with_headers([{"circleci-signature", "v2=#{String.duplicate("b", 64)},v1=#{sig}"}])

      assert :ok = CircleCI.verify(secret, conn, body)
    end

    test "fails when only non-v1 entries are present" do
      conn = conn_with_headers([{"circleci-signature", "v2=#{String.duplicate("c", 64)}"}])
      assert {:error, :unauthorized} = CircleCI.verify("secret", conn, "body")
    end
  end

  # ── extract_event_type/1 ──────────────────────────

  describe "extract_event_type/1" do
    test "returns event from header" do
      conn = conn_with_headers([{"circleci-event-type", "workflow-completed"}])
      assert {:ok, "workflow-completed"} = CircleCI.extract_event_type(conn)
    end

    test "returns job-completed event from header" do
      conn = conn_with_headers([{"circleci-event-type", "job-completed"}])
      assert {:ok, "job-completed"} = CircleCI.extract_event_type(conn)
    end

    test "defaults to unknown when absent" do
      conn = conn_with_headers([])
      assert {:ok, "unknown"} = CircleCI.extract_event_type(conn)
    end

    test "rejects empty event" do
      conn = conn_with_headers([{"circleci-event-type", ""}])
      assert {:error, :invalid_event_type} = CircleCI.extract_event_type(conn)
    end

    test "accepts event at max length (512 bytes)" do
      event = String.duplicate("e", 512)
      conn = conn_with_headers([{"circleci-event-type", event}])
      assert {:ok, ^event} = CircleCI.extract_event_type(conn)
    end

    test "rejects event exceeding 512 bytes" do
      conn = conn_with_headers([{"circleci-event-type", String.duplicate("e", 513)}])
      assert {:error, :invalid_event_type} = CircleCI.extract_event_type(conn)
    end
  end

  # ── extract_delivery_id/1 ──────────────────────────

  describe "extract_delivery_id/1" do
    test "returns id from body params" do
      conn = conn_with_body_params(%{"id" => "event-abc-123"})
      assert {:ok, "event-abc-123"} = CircleCI.extract_delivery_id(conn)
    end

    test "returns nil when id is absent from body" do
      conn = conn_with_body_params(%{})
      assert {:ok, nil} = CircleCI.extract_delivery_id(conn)
    end

    test "returns nil when body params are empty" do
      conn = conn_with_headers([])
      assert {:ok, nil} = CircleCI.extract_delivery_id(conn)
    end

    test "returns error when id is not a string" do
      conn = conn_with_body_params(%{"id" => 12_345})
      assert {:error, :invalid_delivery_id} = CircleCI.extract_delivery_id(conn)
    end

    test "returns error when id is an empty string" do
      conn = conn_with_body_params(%{"id" => ""})
      assert {:error, :invalid_delivery_id} = CircleCI.extract_delivery_id(conn)
    end
  end
end
