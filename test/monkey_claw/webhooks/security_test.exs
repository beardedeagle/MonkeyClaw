defmodule MonkeyClaw.Webhooks.SecurityTest do
  use ExUnit.Case, async: true

  alias MonkeyClaw.Webhooks.Security
  alias MonkeyClaw.Webhooks.Verifiers

  # ── verifier_for/1 ──────────────────────────────

  describe "verifier_for/1" do
    test "returns Generic for :generic" do
      assert Security.verifier_for(:generic) == Verifiers.Generic
    end

    test "returns GitHub for :github" do
      assert Security.verifier_for(:github) == Verifiers.GitHub
    end

    test "returns GitLab for :gitlab" do
      assert Security.verifier_for(:gitlab) == Verifiers.GitLab
    end

    test "returns Slack for :slack" do
      assert Security.verifier_for(:slack) == Verifiers.Slack
    end

    test "returns Discord for :discord" do
      assert Security.verifier_for(:discord) == Verifiers.Discord
    end

    test "returns Bitbucket for :bitbucket" do
      assert Security.verifier_for(:bitbucket) == Verifiers.Bitbucket
    end

    test "returns Forgejo for :forgejo" do
      assert Security.verifier_for(:forgejo) == Verifiers.Forgejo
    end

    test "raises ArgumentError for unknown source" do
      assert_raise ArgumentError, ~r/unknown webhook source/, fn ->
        Security.verifier_for(:unknown)
      end
    end
  end

  # ── hmac_sha256_hex/2 ────────────────────────────

  describe "hmac_sha256_hex/2" do
    test "produces 64-character lowercase hex string" do
      result = Security.hmac_sha256_hex("secret", "message")
      assert byte_size(result) == 64
      assert result =~ ~r/^[0-9a-f]{64}$/
    end

    test "produces consistent results" do
      a = Security.hmac_sha256_hex("secret", "message")
      b = Security.hmac_sha256_hex("secret", "message")
      assert a == b
    end

    test "differs with different secrets" do
      a = Security.hmac_sha256_hex("secret-a", "message")
      b = Security.hmac_sha256_hex("secret-b", "message")
      assert a != b
    end

    test "differs with different messages" do
      a = Security.hmac_sha256_hex("secret", "message-a")
      b = Security.hmac_sha256_hex("secret", "message-b")
      assert a != b
    end
  end

  # ── constant_time_compare/2 ──────────────────────

  describe "constant_time_compare/2" do
    test "returns true for equal strings" do
      assert Security.constant_time_compare("abc", "abc")
    end

    test "returns false for different strings" do
      refute Security.constant_time_compare("abc", "xyz")
    end

    test "returns false for different lengths" do
      refute Security.constant_time_compare("abc", "abcd")
    end

    test "returns true for empty strings" do
      assert Security.constant_time_compare("", "")
    end
  end

  # ── verify_timestamp/1 ──────────────────────────

  describe "verify_timestamp/1" do
    test "accepts current timestamp" do
      assert :ok = Security.verify_timestamp(System.os_time(:second))
    end

    test "accepts timestamp within tolerance (4 minutes ago)" do
      assert :ok = Security.verify_timestamp(System.os_time(:second) - 240)
    end

    test "rejects timestamp beyond tolerance (10 minutes ago)" do
      assert {:error, :expired_timestamp} =
               Security.verify_timestamp(System.os_time(:second) - 600)
    end

    test "rejects future timestamp beyond tolerance" do
      assert {:error, :expired_timestamp} =
               Security.verify_timestamp(System.os_time(:second) + 600)
    end
  end

  # ── compute_signature/3 ──────────────────────────

  describe "compute_signature/3" do
    test "produces consistent results for same inputs" do
      sig1 = Security.compute_signature("secret", 12_345, "body")
      sig2 = Security.compute_signature("secret", 12_345, "body")
      assert sig1 == sig2
    end

    test "differs with different secrets" do
      sig1 = Security.compute_signature("secret-a", 12_345, "body")
      sig2 = Security.compute_signature("secret-b", 12_345, "body")
      assert sig1 != sig2
    end

    test "differs with different timestamps" do
      sig1 = Security.compute_signature("secret", 12_345, "body")
      sig2 = Security.compute_signature("secret", 12_346, "body")
      assert sig1 != sig2
    end

    test "differs with different bodies" do
      sig1 = Security.compute_signature("secret", 12_345, "body-a")
      sig2 = Security.compute_signature("secret", 12_345, "body-b")
      assert sig1 != sig2
    end

    test "returns 64-character lowercase hex string (SHA-256)" do
      sig = Security.compute_signature("secret", 12_345, "body")
      assert byte_size(sig) == 64
      assert sig =~ ~r/^[0-9a-f]{64}$/
    end
  end

  # ── build_signature_header/3 ──────────────────────

  describe "build_signature_header/3" do
    test "formats as t=<timestamp>,v1=<hex_signature>" do
      header = Security.build_signature_header("secret", 12_345, "body")
      assert header =~ ~r/^t=12345,v1=[0-9a-f]{64}$/
    end

    test "header verifies against Generic verifier" do
      secret = "test-secret"
      timestamp = System.os_time(:second)
      body = ~s({"data":"value"})
      header = Security.build_signature_header(secret, timestamp, body)

      conn =
        Plug.Test.conn(:post, "/test", "")
        |> Plug.Conn.put_req_header("x-monkeyclaw-signature", header)

      assert :ok = Verifiers.Generic.verify(secret, conn, body)
    end
  end

  # ── hash_payload/1 ────────────────────────────

  describe "hash_payload/1" do
    test "produces 64-character lowercase hex SHA-256" do
      hash = Security.hash_payload("test-payload")
      assert byte_size(hash) == 64
      assert hash =~ ~r/^[0-9a-f]{64}$/
    end

    test "produces consistent results" do
      assert Security.hash_payload("x") == Security.hash_payload("x")
    end

    test "produces different hashes for different inputs" do
      assert Security.hash_payload("a") != Security.hash_payload("b")
    end

    test "handles empty payload" do
      hash = Security.hash_payload("")
      assert byte_size(hash) == 64
    end
  end
end
