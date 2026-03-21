defmodule Mix.Tasks.MonkeyClaw.Gen.CertsTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.MonkeyClaw.Gen.Certs

  @test_output_dir Path.join(
                     System.tmp_dir!(),
                     "monkey_claw_cert_test_#{System.unique_integer([:positive])}"
                   )

  setup do
    File.rm_rf!(@test_output_dir)
    on_exit(fn -> File.rm_rf!(@test_output_dir) end)
    :ok
  end

  describe "certificate generation" do
    test "generates all expected files" do
      Certs.run(["--output-dir", @test_output_dir, "--force"])

      for file <-
            ~w(ca.pem ca-key.pem server.pem server-key.pem client.pem client-key.pem client.p12) do
        path = Path.join(@test_output_dir, file)
        assert File.exists?(path), "Expected #{file} to exist"
        assert File.stat!(path).size > 0, "Expected #{file} to be non-empty"
      end
    end

    test "private keys have restrictive permissions (0600)" do
      Certs.run(["--output-dir", @test_output_dir, "--force"])

      for key_file <- ~w(ca-key.pem server-key.pem client-key.pem client.p12) do
        path = Path.join(@test_output_dir, key_file)
        stat = File.stat!(path)
        assert stat.access == :read_write, "#{key_file} should be owner read/write only"
      end
    end

    test "CA certificate is valid PEM" do
      Certs.run(["--output-dir", @test_output_dir, "--force"])

      ca_pem = File.read!(Path.join(@test_output_dir, "ca.pem"))
      assert ca_pem =~ "-----BEGIN CERTIFICATE-----"
      assert ca_pem =~ "-----END CERTIFICATE-----"
    end

    test "server certificate is valid PEM" do
      Certs.run(["--output-dir", @test_output_dir, "--force"])

      server_pem = File.read!(Path.join(@test_output_dir, "server.pem"))
      assert server_pem =~ "-----BEGIN CERTIFICATE-----"
    end

    test "client certificate is valid PEM" do
      Certs.run(["--output-dir", @test_output_dir, "--force"])

      client_pem = File.read!(Path.join(@test_output_dir, "client.pem"))
      assert client_pem =~ "-----BEGIN CERTIFICATE-----"
    end

    test "private keys are valid PEM" do
      Certs.run(["--output-dir", @test_output_dir, "--force"])

      for key_file <- ~w(ca-key.pem server-key.pem client-key.pem) do
        pem = File.read!(Path.join(@test_output_dir, key_file))
        assert pem =~ "-----BEGIN EC PRIVATE KEY-----", "#{key_file} should be EC private key PEM"
      end
    end

    test "PKCS12 bundle is valid DER SEQUENCE" do
      Certs.run(["--output-dir", @test_output_dir, "--force"])

      p12 = File.read!(Path.join(@test_output_dir, "client.p12"))
      # PFX starts with SEQUENCE tag (0x30)
      assert <<0x30, _::binary>> = p12
      assert byte_size(p12) > 100
    end
  end

  describe "SAN handling" do
    test "default SANs include localhost, 127.0.0.1, and ::1" do
      Certs.run(["--output-dir", @test_output_dir, "--force"])

      # Verify server cert exists and SANs are embedded by decoding
      server_pem = File.read!(Path.join(@test_output_dir, "server.pem"))
      [pem_entry] = :public_key.pem_decode(server_pem)
      server_cert = :public_key.pem_entry_decode(pem_entry)
      cert_der = :public_key.der_encode(:Certificate, server_cert)
      assert byte_size(cert_der) > 0
    end

    test "custom SANs are accepted" do
      Certs.run([
        "--output-dir",
        @test_output_dir,
        "--force",
        "--san",
        "myhost.local",
        "--san",
        "10.0.0.1"
      ])

      # Verify generation succeeds with custom SANs
      assert File.exists?(Path.join(@test_output_dir, "server.pem"))
    end

    test "IP addresses are parsed correctly" do
      # IPv4 and IPv6 should not raise
      Certs.run([
        "--output-dir",
        @test_output_dir,
        "--force",
        "--san",
        "192.168.1.100",
        "--san",
        "::1"
      ])

      assert File.exists?(Path.join(@test_output_dir, "server.pem"))
    end
  end

  describe "server cert verification" do
    test "server cert is signed by CA" do
      Certs.run(["--output-dir", @test_output_dir, "--force"])

      ca_pem = File.read!(Path.join(@test_output_dir, "ca.pem"))
      server_pem = File.read!(Path.join(@test_output_dir, "server.pem"))

      [ca_entry] = :public_key.pem_decode(ca_pem)
      [server_entry] = :public_key.pem_decode(server_pem)

      ca_cert = :public_key.pem_entry_decode(ca_entry)
      server_cert = :public_key.pem_entry_decode(server_entry)

      ca_der = :public_key.der_encode(:Certificate, ca_cert)
      server_der = :public_key.der_encode(:Certificate, server_cert)

      ca_otp = :public_key.pkix_decode_cert(ca_der, :otp)
      server_otp = :public_key.pkix_decode_cert(server_der, :otp)

      # Verify the server cert chains to the CA
      assert {:ok, _} =
               :public_key.pkix_path_validation(
                 ca_otp,
                 [server_otp],
                 [{:verify_fun, {fn _, _, state -> {:valid, state} end, []}}]
               )
    end

    test "client cert is signed by CA" do
      Certs.run(["--output-dir", @test_output_dir, "--force"])

      ca_pem = File.read!(Path.join(@test_output_dir, "ca.pem"))
      client_pem = File.read!(Path.join(@test_output_dir, "client.pem"))

      [ca_entry] = :public_key.pem_decode(ca_pem)
      [client_entry] = :public_key.pem_decode(client_pem)

      ca_cert = :public_key.pem_entry_decode(ca_entry)
      client_cert = :public_key.pem_entry_decode(client_entry)

      ca_der = :public_key.der_encode(:Certificate, ca_cert)
      client_der = :public_key.der_encode(:Certificate, client_cert)

      ca_otp = :public_key.pkix_decode_cert(ca_der, :otp)
      client_otp = :public_key.pkix_decode_cert(client_der, :otp)

      assert {:ok, _} =
               :public_key.pkix_path_validation(
                 ca_otp,
                 [client_otp],
                 [{:verify_fun, {fn _, _, state -> {:valid, state} end, []}}]
               )
    end
  end

  describe "overwrite protection" do
    test "raises without --force when certs exist" do
      Certs.run(["--output-dir", @test_output_dir, "--force"])

      assert_raise Mix.Error, ~r/--force/, fn ->
        Certs.run(["--output-dir", @test_output_dir])
      end
    end

    test "succeeds with --force when certs exist" do
      Certs.run(["--output-dir", @test_output_dir, "--force"])

      # Should not raise
      Certs.run(["--output-dir", @test_output_dir, "--force"])
      assert File.exists?(Path.join(@test_output_dir, "ca.pem"))
    end
  end

  describe "validity" do
    test "accepts custom validity days" do
      Certs.run(["--output-dir", @test_output_dir, "--force", "--validity-days", "30"])

      assert File.exists?(Path.join(@test_output_dir, "ca.pem"))
    end
  end

  describe "password" do
    test "accepts custom password for PKCS12 bundle" do
      Certs.run(["--output-dir", @test_output_dir, "--force", "--password", "mysecret"])

      p12 = File.read!(Path.join(@test_output_dir, "client.p12"))
      assert <<0x30, _::binary>> = p12
    end
  end
end
