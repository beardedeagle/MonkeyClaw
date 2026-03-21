defmodule MonkeyClaw.PKCS12TestHelper do
  @moduledoc false
  # Self-signed certificate generation for PKCS12 tests.
  # Uses only OTP's :public_key — no external dependencies.

  require Record

  Record.defrecordp(
    :rsa_private_key,
    :RSAPrivateKey,
    Record.extract(:RSAPrivateKey, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecordp(
    :rsa_public_key,
    :RSAPublicKey,
    Record.extract(:RSAPublicKey, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecordp(
    :ec_private_key,
    :ECPrivateKey,
    Record.extract(:ECPrivateKey, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecordp(
    :ec_point,
    :ECPoint,
    Record.extract(:ECPoint, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecordp(
    :certificate,
    :Certificate,
    Record.extract(:Certificate, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecordp(
    :tbs_certificate,
    :TBSCertificate,
    Record.extract(:TBSCertificate, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecordp(
    :algorithm_identifier,
    :AlgorithmIdentifier,
    Record.extract(:AlgorithmIdentifier, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecordp(
    :validity,
    :Validity,
    Record.extract(:Validity, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecordp(
    :subject_public_key_info,
    :SubjectPublicKeyInfo,
    Record.extract(:SubjectPublicKeyInfo, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecordp(
    :attr_type_and_value,
    :AttributeTypeAndValue,
    Record.extract(:AttributeTypeAndValue, from_lib: "public_key/include/public_key.hrl")
  )

  @doc "Generate an RSA-2048 key pair."
  def generate_rsa_key do
    :public_key.generate_key({:rsa, 2048, 65_537})
  end

  @doc "Generate an EC secp256r1 key pair."
  def generate_ec_key do
    :public_key.generate_key({:namedCurve, :secp256r1})
  end

  @doc "Create a self-signed X.509 certificate for an RSA key."
  def make_self_signed_cert(rsa_private_key(modulus: n, publicExponent: e) = key) do
    pub_key = rsa_public_key(modulus: n, publicExponent: e)

    tbs =
      build_tbs_certificate(
        # sha256WithRSAEncryption
        {1, 2, 840, 113_549, 1, 1, 11},
        pub_key,
        :rsa
      )

    tbs_der = :public_key.der_encode(:TBSCertificate, tbs)
    signature = :public_key.sign(tbs_der, :sha256, key)

    cert =
      certificate(
        tbsCertificate: tbs,
        signatureAlgorithm:
          algorithm_identifier(
            algorithm: {1, 2, 840, 113_549, 1, 1, 11},
            parameters: asn1_der_null()
          ),
        signature: signature
      )

    :public_key.der_encode(:Certificate, cert)
  end

  @doc "Create a self-signed X.509 certificate for an EC key."
  def make_self_signed_cert_ec(
        ec_private_key(parameters: {:namedCurve, curve}, publicKey: pub_key_bin) = key
      ) do
    point = ensure_binary(pub_key_bin)
    tbs = build_tbs_certificate_ec(curve, point)
    tbs_der = :public_key.der_encode(:TBSCertificate, tbs)
    signature = :public_key.sign(tbs_der, :sha256, key)

    cert =
      certificate(
        tbsCertificate: tbs,
        signatureAlgorithm:
          algorithm_identifier(
            # ecdsa-with-SHA256
            algorithm: {1, 2, 840, 10_045, 4, 3, 2},
            parameters: :asn1_NOVALUE
          ),
        signature: signature
      )

    :public_key.der_encode(:Certificate, cert)
  end

  @doc "Check if openssl is available in PATH."
  def openssl_available? do
    case System.find_executable("openssl") do
      nil -> false
      _ -> true
    end
  end

  @doc "Verify a .p12 file with openssl."
  def verify_with_openssl(pfx_path, password) do
    {output, exit_code} =
      System.cmd(
        "openssl",
        [
          "pkcs12",
          "-in",
          pfx_path,
          "-info",
          "-passin",
          "pass:#{password}",
          "-noout"
        ],
        stderr_to_stdout: true
      )

    case exit_code do
      0 ->
        {:ok, output}

      _ ->
        # Try with -legacy flag for older OpenSSL
        {output2, exit_code2} =
          System.cmd(
            "openssl",
            [
              "pkcs12",
              "-in",
              pfx_path,
              "-info",
              "-passin",
              "pass:#{password}",
              "-noout",
              "-legacy"
            ],
            stderr_to_stdout: true
          )

        case exit_code2 do
          0 -> {:ok, output2}
          _ -> {:error, output <> "\n" <> output2}
        end
    end
  end

  # --- Internal ---

  defp build_tbs_certificate(sig_alg_oid, pub_key, :rsa) do
    serial = :binary.decode_unsigned(:crypto.strong_rand_bytes(16))
    dn = make_dn("PKCS12 Test Certificate")

    tbs_certificate(
      version: :v3,
      serialNumber: serial,
      signature:
        algorithm_identifier(
          algorithm: sig_alg_oid,
          parameters: asn1_der_null()
        ),
      issuer: dn,
      validity:
        validity(
          notBefore: {:utcTime, ~c"250101000000Z"},
          notAfter: {:utcTime, ~c"350101000000Z"}
        ),
      subject: dn,
      subjectPublicKeyInfo:
        subject_public_key_info(
          algorithm:
            algorithm_identifier(
              # rsaEncryption
              algorithm: {1, 2, 840, 113_549, 1, 1, 1},
              parameters: asn1_der_null()
            ),
          subjectPublicKey: :public_key.der_encode(:RSAPublicKey, pub_key)
        ),
      extensions: :asn1_NOVALUE
    )
  end

  defp build_tbs_certificate_ec(curve, point) do
    serial = :binary.decode_unsigned(:crypto.strong_rand_bytes(16))
    dn = make_dn("PKCS12 EC Test Certificate")

    tbs_certificate(
      version: :v3,
      serialNumber: serial,
      signature:
        algorithm_identifier(
          # ecdsa-with-SHA256
          algorithm: {1, 2, 840, 10_045, 4, 3, 2},
          parameters: :asn1_NOVALUE
        ),
      issuer: dn,
      validity:
        validity(
          notBefore: {:utcTime, ~c"250101000000Z"},
          notAfter: {:utcTime, ~c"350101000000Z"}
        ),
      subject: dn,
      subjectPublicKeyInfo:
        subject_public_key_info(
          algorithm:
            algorithm_identifier(
              # ecPublicKey
              algorithm: {1, 2, 840, 10_045, 2, 1},
              parameters: ec_alg_params(curve)
            ),
          subjectPublicKey: point
        ),
      extensions: :asn1_NOVALUE
    )
  end

  # OTP 28 uses PKIX1Explicit-2009 with information object sets
  defp asn1_der_null do
    case otp_release() do
      v when v >= 28 -> {:asn1_OPENTYPE, <<5, 0>>}
      _ -> <<5, 0>>
    end
  end

  # EC algorithm parameters: OTP 28 wants {namedCurve, OID}
  defp ec_alg_params(curve) do
    case otp_release() do
      v when v >= 28 -> {:namedCurve, curve}
      _ -> :public_key.der_encode(:EcpkParameters, {:namedCurve, curve})
    end
  end

  # OTP 28 uses PKIX1Explicit-2009 where X520CommonName is a CHOICE type
  defp make_dn(common_name) do
    value =
      case otp_release() do
        v when v >= 28 -> {:utf8String, common_name}
        _ -> <<0x0C, byte_size(common_name), common_name::binary>>
      end

    {:rdnSequence,
     [
       [
         attr_type_and_value(
           # commonName
           type: {2, 5, 4, 3},
           value: value
         )
       ]
     ]}
  end

  defp ensure_binary(bin) when is_binary(bin), do: bin
  defp ensure_binary(list) when is_list(list), do: :erlang.list_to_binary(list)

  defp otp_release do
    :erlang.system_info(:otp_release) |> List.to_integer()
  end
end
