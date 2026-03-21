defmodule MonkeyClawWeb.Plugs.MTLSAuditTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias MonkeyClawWeb.Plugs.MTLSAudit

  # Generate a real test certificate at compile time using x509.
  # No mocks — real crypto, real DER parsing.
  @test_key X509.PrivateKey.new_ec(:secp256r1)
  @test_cert X509.Certificate.self_signed(@test_key, "/CN=Test Client",
               template: :root_ca,
               validity: 1
             )
  @test_der X509.Certificate.to_der(@test_cert)

  describe "extract_metadata/1" do
    test "extracts CN, serial, and fingerprint from a valid DER cert" do
      assert {:ok, metadata} = MTLSAudit.extract_metadata(@test_der)

      assert metadata.cn == "Test Client"
      assert is_integer(metadata.serial)
      assert metadata.serial > 0
      assert byte_size(metadata.fingerprint) == 32
      assert metadata.fingerprint == :crypto.hash(:sha256, @test_der)
    end

    test "returns error for invalid DER" do
      assert {:error, _reason} = MTLSAudit.extract_metadata(<<0, 1, 2, 3>>)
    end

    test "returns error for empty binary" do
      assert {:error, _reason} = MTLSAudit.extract_metadata(<<>>)
    end

    test "fingerprint is SHA-256 of raw DER bytes" do
      {:ok, metadata} = MTLSAudit.extract_metadata(@test_der)
      expected = :crypto.hash(:sha256, @test_der)
      assert metadata.fingerprint == expected
    end
  end

  describe "call/2 — missing cert in dev" do
    test "assigns nil client_cert and continues" do
      conn =
        conn(:get, "/")
        |> MTLSAudit.call(MTLSAudit.init(env: :dev))

      refute conn.halted
      assert conn.assigns[:client_cert] == nil
    end
  end

  describe "call/2 — missing cert in prod" do
    test "halts with 403" do
      conn =
        conn(:get, "/")
        |> MTLSAudit.call(MTLSAudit.init(env: :prod))

      assert conn.halted
      assert conn.status == 403
    end
  end

  describe "call/2 — missing cert in test" do
    test "assigns nil client_cert and continues (same as dev)" do
      conn =
        conn(:get, "/")
        |> MTLSAudit.call(MTLSAudit.init(env: :test))

      refute conn.halted
      assert conn.assigns[:client_cert] == nil
    end
  end
end
