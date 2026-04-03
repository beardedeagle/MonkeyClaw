defmodule MonkeyClaw.Webhooks.Verifiers.GitLabTest do
  use ExUnit.Case, async: true

  alias MonkeyClaw.Webhooks.Verifiers.GitLab

  defp conn_with_headers(headers) do
    Enum.reduce(headers, Plug.Test.conn(:post, "/test", ""), fn {key, value}, conn ->
      Plug.Conn.put_req_header(conn, key, value)
    end)
  end

  # ── verify/3 ──────────────────────────────────────

  describe "verify/3" do
    test "succeeds with matching token" do
      secret = "gitlab-token-secret"
      conn = conn_with_headers([{"x-gitlab-token", secret}])
      assert :ok = GitLab.verify(secret, conn, "body")
    end

    test "fails with wrong token" do
      conn = conn_with_headers([{"x-gitlab-token", "wrong"}])
      assert {:error, :unauthorized} = GitLab.verify("correct", conn, "body")
    end

    test "fails with missing token header" do
      conn = conn_with_headers([])
      assert {:error, :unauthorized} = GitLab.verify("secret", conn, "body")
    end

    test "ignores raw_body (not used in GitLab scheme)" do
      secret = "token"
      conn = conn_with_headers([{"x-gitlab-token", secret}])
      assert :ok = GitLab.verify(secret, conn, "any-body")
      assert :ok = GitLab.verify(secret, conn, "different-body")
    end

    test "fails with empty token header" do
      conn = conn_with_headers([{"x-gitlab-token", ""}])
      assert {:error, :unauthorized} = GitLab.verify("secret", conn, "body")
    end
  end

  # ── extract_event_type/1 ──────────────────────────

  describe "extract_event_type/1" do
    test "returns event from header" do
      conn = conn_with_headers([{"x-gitlab-event", "Push Hook"}])
      assert {:ok, "Push Hook"} = GitLab.extract_event_type(conn)
    end

    test "defaults to unknown when absent" do
      conn = conn_with_headers([])
      assert {:ok, "unknown"} = GitLab.extract_event_type(conn)
    end

    test "accepts event at max length (255 bytes)" do
      event = String.duplicate("e", 255)
      conn = conn_with_headers([{"x-gitlab-event", event}])
      assert {:ok, ^event} = GitLab.extract_event_type(conn)
    end

    test "rejects event exceeding 255 bytes" do
      conn = conn_with_headers([{"x-gitlab-event", String.duplicate("e", 256)}])
      assert {:error, :invalid_event_type} = GitLab.extract_event_type(conn)
    end
  end

  # ── extract_delivery_id/1 ──────────────────────────

  describe "extract_delivery_id/1" do
    test "always returns nil (GitLab has no delivery ID)" do
      conn = conn_with_headers([{"x-gitlab-event", "Push Hook"}])
      assert {:ok, nil} = GitLab.extract_delivery_id(conn)
    end

    test "returns nil even with empty conn" do
      conn = conn_with_headers([])
      assert {:ok, nil} = GitLab.extract_delivery_id(conn)
    end
  end
end
