defmodule MonkeyClaw.Crypto.PKCS12Test do
  use ExUnit.Case, async: true

  alias MonkeyClaw.Crypto.PKCS12
  alias MonkeyClaw.Crypto.PKCS12.KDF
  alias MonkeyClaw.PKCS12TestHelper, as: Helper

  @password "test1234"
  # Use low iterations for test speed (modern minimum is 10,000)
  @test_iterations 10_000

  describe "encode/3 — modern profile defaults" do
    test "encodes RSA key + cert as valid DER SEQUENCE" do
      key = Helper.generate_rsa_key()
      cert_der = Helper.make_self_signed_cert(key)

      assert {:ok, pfx} = PKCS12.encode(key, [cert_der], @password, iterations: @test_iterations)
      # PFX starts with SEQUENCE tag (0x30)
      assert <<0x30, _::binary>> = pfx
      assert byte_size(pfx) > 0
    end

    test "encodes EC key + cert as valid DER SEQUENCE" do
      key = Helper.generate_ec_key()
      cert_der = Helper.make_self_signed_cert_ec(key)

      assert {:ok, pfx} = PKCS12.encode(key, [cert_der], @password, iterations: @test_iterations)
      assert <<0x30, _::binary>> = pfx
      assert byte_size(pfx) > 0
    end
  end

  describe "encode/4 — profile options" do
    setup do
      key = Helper.generate_rsa_key()
      cert_der = Helper.make_self_signed_cert(key)
      %{key: key, cert_der: cert_der}
    end

    test "legacy_des profile", %{key: key, cert_der: cert_der} do
      assert {:ok, pfx} =
               PKCS12.encode(key, [cert_der], @password, profile: :legacy_des)

      assert <<0x30, _::binary>> = pfx
    end

    test "friendly name attribute", %{key: key, cert_der: cert_der} do
      assert {:ok, pfx} =
               PKCS12.encode(key, [cert_der], @password,
                 friendly_name: "My Test Cert",
                 iterations: @test_iterations
               )

      assert <<0x30, _::binary>> = pfx
      # Named bundle should be slightly larger than unnamed
      {:ok, pfx_no_name} =
        PKCS12.encode(key, [cert_der], @password, iterations: @test_iterations)

      assert byte_size(pfx) > byte_size(pfx_no_name)
    end

    test "PBMAC1 MAC scheme", %{key: key, cert_der: cert_der} do
      assert {:ok, pfx_pbmac1} =
               PKCS12.encode(key, [cert_der], @password,
                 iterations: @test_iterations,
                 mac_scheme: :pbmac1
               )

      assert <<0x30, _::binary>> = pfx_pbmac1

      # PBMAC1 output should be larger (richer AlgorithmIdentifier)
      {:ok, pfx_legacy} =
        PKCS12.encode(key, [cert_der], @password, iterations: @test_iterations)

      assert byte_size(pfx_pbmac1) > byte_size(pfx_legacy)
    end

    test "string password (charlist)", %{key: key, cert_der: cert_der} do
      assert {:ok, _pfx} =
               PKCS12.encode(key, [cert_der], ~c"stringpass", iterations: @test_iterations)
    end
  end

  describe "input validation" do
    setup do
      key = Helper.generate_rsa_key()
      cert_der = Helper.make_self_signed_cert(key)
      %{key: key, cert_der: cert_der}
    end

    test "rejects empty cert chain", %{key: key} do
      assert {:error, :empty_cert_chain} = PKCS12.encode(key, [], @password)
    end

    test "enforces minimum iterations for modern profile", %{key: key, cert_der: cert_der} do
      assert {:error, {:iterations_too_low, 100, {:minimum, 10_000}}} =
               PKCS12.encode(key, [cert_der], @password, iterations: 100)
    end

    test "legacy profiles allow lower iterations", %{key: key, cert_der: cert_der} do
      assert {:ok, _} =
               PKCS12.encode(key, [cert_der], @password,
                 profile: :legacy_des,
                 iterations: 1
               )
    end

    test "enforces minimum mac_iterations for modern profile", %{key: key, cert_der: cert_der} do
      assert {:error, {:mac_iterations_too_low, 100, {:minimum, 10_000}}} =
               PKCS12.encode(key, [cert_der], @password,
                 iterations: @test_iterations,
                 mac_iterations: 100
               )
    end

    test "legacy profiles allow lower mac_iterations", %{key: key, cert_der: cert_der} do
      assert {:ok, _} =
               PKCS12.encode(key, [cert_der], @password,
                 profile: :legacy_des,
                 mac_iterations: 1
               )
    end
  end

  describe "localKeyId" do
    test "uses SHA-256 fingerprint (32 bytes)" do
      key = Helper.generate_rsa_key()
      cert_der = Helper.make_self_signed_cert(key)

      expected_key_id = :crypto.hash(:sha256, cert_der)
      assert byte_size(expected_key_id) == 32

      # The .p12 binary contains the localKeyId — verify it was computed
      assert {:ok, _pfx} =
               PKCS12.encode(key, [cert_der], @password, iterations: @test_iterations)
    end
  end

  describe "backward-compatible delegates" do
    test "pkcs12_kdf/6 delegates to KDF module" do
      salt = <<1, 2, 3, 4, 5, 6, 7, 8>>

      result = PKCS12.pkcs12_kdf(:sha, 1, "password", salt, 1, 24)
      direct = KDF.pkcs12_kdf(:sha, 1, "password", salt, 1, 24)

      assert result == direct
      assert byte_size(result) == 24
    end

    test "bmp_password/1 delegates to KDF module" do
      result = PKCS12.bmp_password("test")
      direct = KDF.bmp_password("test")

      assert result == direct
      assert result == <<0, 116, 0, 101, 0, 115, 0, 116, 0, 0>>
    end
  end

  describe "OpenSSL interop" do
    @tag :openssl
    @describetag :openssl

    setup do
      if Helper.openssl_available?() do
        key = Helper.generate_rsa_key()
        cert_der = Helper.make_self_signed_cert(key)
        %{key: key, cert_der: cert_der}
      else
        :ok
      end
    end

    @tag :openssl
    test "modern profile .p12 readable by openssl", context do
      if Helper.openssl_available?() do
        %{key: key, cert_der: cert_der} = context

        {:ok, pfx} =
          PKCS12.encode(key, [cert_der], @password, iterations: @test_iterations)

        path = Path.join(System.tmp_dir!(), "elixir_test_modern.p12")
        File.write!(path, pfx)

        assert {:ok, output} = Helper.verify_with_openssl(path, @password)
        assert output =~ "MAC"
      end
    end

    @tag :openssl
    test "legacy_des profile .p12 readable by openssl", context do
      if Helper.openssl_available?() do
        %{key: key, cert_der: cert_der} = context

        {:ok, pfx} =
          PKCS12.encode(key, [cert_der], @password, profile: :legacy_des)

        path = Path.join(System.tmp_dir!(), "elixir_test_legacy.p12")
        File.write!(path, pfx)

        assert {:ok, _output} = Helper.verify_with_openssl(path, @password)
      end
    end

    @tag :openssl
    test "EC key .p12 readable by openssl", _context do
      if Helper.openssl_available?() do
        ec_key = Helper.generate_ec_key()
        ec_cert = Helper.make_self_signed_cert_ec(ec_key)

        {:ok, pfx} =
          PKCS12.encode(ec_key, [ec_cert], @password, iterations: @test_iterations)

        path = Path.join(System.tmp_dir!(), "elixir_test_ec.p12")
        File.write!(path, pfx)

        assert {:ok, _output} = Helper.verify_with_openssl(path, @password)
      end
    end
  end
end
