defmodule MonkeyClaw.Crypto.PKCS12 do
  @moduledoc """
  Pure Elixir PKCS#12 encoder (RFC 7292).

  Encodes private keys and certificate chains into `.p12`/`.pfx` files
  using only OTP's `:crypto` and `:public_key` applications.
  No external dependencies. No shelling out to OpenSSL.

  Supports two encoding profiles:

    * `:modern`     — PBES2/AES-256-CBC + SHA-256 MAC (OpenSSL 3.x default)
    * `:legacy_des` — pbeWithSHAAnd3-KeyTripleDES-CBC (broad compat)

  ## Examples

      key = :public_key.generate_key({:rsa, 2048, 65537})
      # cert_der = DER-encoded X.509 certificate binary
      {:ok, pfx} = MonkeyClaw.Crypto.PKCS12.encode(key, [cert_der], "password")
      File.write!("bundle.p12", pfx)

  """

  require Logger
  require Record

  import MonkeyClaw.Crypto.PKCS12.DER

  alias MonkeyClaw.Crypto.PKCS12.KDF

  # -------------------------------------------------------------------
  # Record definitions for private key pattern matching
  # -------------------------------------------------------------------

  Record.defrecordp(
    :rsa_private_key,
    :RSAPrivateKey,
    Record.extract(:RSAPrivateKey, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecordp(
    :ec_private_key,
    :ECPrivateKey,
    Record.extract(:ECPrivateKey, from_lib: "public_key/include/public_key.hrl")
  )

  # -------------------------------------------------------------------
  # Types
  # -------------------------------------------------------------------

  @typedoc "Encryption profile for the PKCS#12 bundle."
  @type profile() :: :modern | :legacy_des

  @typedoc "Private key — RSA, EC, or raw DER-encoded PKCS#8 PrivateKeyInfo."
  @type private_key() :: :public_key.private_key() | binary()

  @typedoc "Error reasons from `encode/3` and `encode/4`."
  @type encode_error() ::
          :empty_cert_chain
          | {:iterations_too_low, term(), {:minimum, pos_integer()}}
          | {:mac_iterations_too_low, term(), {:minimum, pos_integer()}}
          | {:encode_failed, term()}

  @typedoc "MAC algorithm selection."
  @type mac_scheme() :: :legacy | :pbmac1

  @typedoc "Encoding option."
  @type option() ::
          {:profile, profile()}
          | {:iterations, pos_integer()}
          | {:mac_iterations, pos_integer()}
          | {:friendly_name, binary() | String.t()}
          | {:mac_scheme, mac_scheme()}

  # -------------------------------------------------------------------
  # OID Definitions
  # -------------------------------------------------------------------

  # PKCS#7 / CMS content types
  @oid_data {1, 2, 840, 113_549, 1, 7, 1}
  @oid_encrypted_data {1, 2, 840, 113_549, 1, 7, 6}

  # PKCS#12 bag types
  @oid_pkcs8_shrouded_key_bag {1, 2, 840, 113_549, 1, 12, 10, 1, 2}
  @oid_cert_bag {1, 2, 840, 113_549, 1, 12, 10, 1, 3}

  # Certificate types within CertBag
  @oid_x509_certificate {1, 2, 840, 113_549, 1, 9, 22, 1}

  # PKCS#9 attributes
  @oid_friendly_name {1, 2, 840, 113_549, 1, 9, 20}
  @oid_local_key_id {1, 2, 840, 113_549, 1, 9, 21}

  # PKCS#12 legacy PBE algorithms (Appendix B KDF based)
  @oid_pbe_sha_3des_3key {1, 2, 840, 113_549, 1, 12, 1, 3}

  # PKCS#5 v2.1
  @oid_pbes2 {1, 2, 840, 113_549, 1, 5, 13}
  @oid_pbkdf2 {1, 2, 840, 113_549, 1, 5, 12}
  @oid_pbmac1 {1, 2, 840, 113_549, 1, 5, 14}

  # Symmetric ciphers
  @oid_aes_256_cbc {2, 16, 840, 1, 101, 3, 4, 1, 42}

  # Hash / HMAC
  @oid_hmac_sha256 {1, 2, 840, 113_549, 2, 9}
  @oid_sha1 {1, 3, 14, 3, 2, 26}
  @oid_sha256 {2, 16, 840, 1, 101, 3, 4, 2, 1}

  # Key algorithm identifiers
  @oid_rsa_encryption {1, 2, 840, 113_549, 1, 1, 1}
  @oid_ec_public_key {1, 2, 840, 10_045, 2, 1}

  # -------------------------------------------------------------------
  # Public API
  # -------------------------------------------------------------------

  @doc """
  Encode a private key and certificate chain into a PKCS#12 binary
  using the `:modern` profile (PBES2/AES-256-CBC, SHA-256 MAC).
  """
  @spec encode(private_key(), [binary()], binary() | String.t()) ::
          {:ok, nonempty_binary()} | {:error, encode_error()}
  def encode(key, certs, password) do
    encode(key, certs, password, [])
  end

  @doc """
  Encode a private key and certificate chain into a PKCS#12 binary
  with explicit options.

  ## Options

    * `:profile` — `:modern | :legacy_des` (default: `:modern`)
    * `:iterations` — PBE iterations (default: 600,000 modern, 2,048 legacy)
    * `:mac_iterations` — MAC iterations (default: 2,048)
    * `:friendly_name` — optional display name attribute
    * `:mac_scheme` — `:legacy | :pbmac1` (default: `:legacy`)

  The `:modern` profile requires a minimum of 10,000 iterations.
  Legacy profiles emit a deprecation warning.
  """
  @spec encode(private_key(), [binary()], binary() | String.t(), [option()]) ::
          {:ok, nonempty_binary()} | {:error, encode_error()}
  def encode(key, certs, password, opts) when is_list(password) do
    encode(key, certs, List.to_string(password), opts)
  end

  def encode(key, certs, password, opts) when is_binary(password) do
    profile = Keyword.get(opts, :profile, :modern)
    iterations = Keyword.get(opts, :iterations, default_iterations(profile))
    mac_iterations = Keyword.get(opts, :mac_iterations, default_mac_iters(profile))
    mac_scheme = Keyword.get(opts, :mac_scheme, :legacy)
    friendly_name = Keyword.get(opts, :friendly_name)

    with :ok <- validate_inputs(certs, profile, iterations),
         :ok <- validate_mac_iterations(profile, mac_iterations) do
      warn_legacy_profile(profile)

      try do
        encode_pfx(key, certs, password, profile, iterations, mac_iterations, mac_scheme,
          friendly_name: friendly_name
        )
      catch
        :error, reason ->
          Logger.debug("pkcs12 encode failed: #{inspect(reason)}")
          {:error, {:encode_failed, reason}}
      end
    end
  end

  # Backward-compatible delegates to KDF module
  @doc false
  defdelegate pkcs12_kdf(hash_algo, id, password, salt, iterations, output_len), to: KDF

  @doc false
  defdelegate bmp_password(password), to: KDF

  # -------------------------------------------------------------------
  # Profile defaults
  # -------------------------------------------------------------------

  defp default_iterations(:modern), do: 600_000
  defp default_iterations(:legacy_des), do: 2_048

  defp default_mac_iters(:modern), do: 10_000
  defp default_mac_iters(:legacy_des), do: 2_048

  defp validate_inputs([], _profile, _iterations), do: {:error, :empty_cert_chain}

  defp validate_inputs(_certs, :modern, iterations) when iterations < 10_000,
    do: {:error, {:iterations_too_low, iterations, {:minimum, 10_000}}}

  defp validate_inputs(_certs, _profile, iterations) when iterations < 1,
    do: {:error, {:iterations_too_low, iterations, {:minimum, 1}}}

  defp validate_inputs(_certs, _profile, _iterations), do: :ok

  defp validate_mac_iterations(:modern, mac_iterations) when mac_iterations < 10_000,
    do: {:error, {:mac_iterations_too_low, mac_iterations, {:minimum, 10_000}}}

  defp validate_mac_iterations(_profile, _mac_iterations), do: :ok

  defp warn_legacy_profile(:legacy_des) do
    Logger.warning(
      "pkcs12: legacy_des profile uses 3DES which is deprecated by " <>
        "NIST (2024). Consider using the :modern profile."
    )
  end

  defp warn_legacy_profile(_), do: :ok

  # -------------------------------------------------------------------
  # PFX assembly
  # -------------------------------------------------------------------

  defp encode_pfx(key, certs, password, profile, iterations, mac_iterations, mac_scheme,
         friendly_name: friendly_name
       ) do
    key_info = encode_pkcs8_private_key_info(key)

    # SHA-256 fingerprint of end-entity cert for localKeyId
    [ee_cert_der | _] = certs
    local_key_id = :crypto.hash(:sha256, ee_cert_der)

    # Stage 1 — Build SafeBags
    key_bag =
      build_shrouded_key_bag(key_info, password, profile, iterations, local_key_id, friendly_name)

    cert_bags = build_cert_bags(certs, local_key_id, friendly_name)

    # Stage 2 — SafeContents
    key_safe_contents = der_sequence([key_bag])
    cert_safe_contents = der_sequence(cert_bags)

    # Stage 3 — AuthenticatedSafe ContentInfo entries
    # Certs: encrypted; Key: unencrypted (key already shrouded)
    encrypted_cert_ci =
      encrypt_safe_contents(cert_safe_contents, password, profile, iterations)

    key_ci =
      make_content_info(
        @oid_data,
        der_explicit(0, der_octet_string(key_safe_contents))
      )

    # Stage 4 — AuthenticatedSafe → PFX.authSafe
    auth_safe_der = der_sequence([encrypted_cert_ci, key_ci])

    auth_safe_ci =
      make_content_info(
        @oid_data,
        der_explicit(0, der_octet_string(auth_safe_der))
      )

    # Stage 5 — MAC over AuthenticatedSafe content bytes
    mac_data = compute_mac(auth_safe_der, password, profile, mac_iterations, mac_scheme)

    # PFX ::= SEQUENCE { version INTEGER(3), authSafe ContentInfo, macData MacData }
    pfx = der_sequence([der_integer(3), auth_safe_ci, mac_data])
    {:ok, pfx}
  end

  # -------------------------------------------------------------------
  # Private key handling
  # -------------------------------------------------------------------

  # Wrap a private key in PKCS#8 PrivateKeyInfo (unencrypted).
  defp encode_pkcs8_private_key_info(rsa_private_key() = key) do
    key_der = :public_key.der_encode(:RSAPrivateKey, key)
    alg_id = der_sequence([der_oid(@oid_rsa_encryption), der_null()])
    der_sequence([der_integer(0), alg_id, der_octet_string(key_der)])
  end

  defp encode_pkcs8_private_key_info(ec_private_key(parameters: {:namedCurve, curve_oid}) = key) do
    key_der = :public_key.der_encode(:ECPrivateKey, key)
    alg_id = der_sequence([der_oid(@oid_ec_public_key), der_oid(curve_oid)])
    der_sequence([der_integer(0), alg_id, der_octet_string(key_der)])
  end

  defp encode_pkcs8_private_key_info(bin) when is_binary(bin) do
    # Attempt to detect key type from DER and wrap accordingly.
    case safe_der_decode(:RSAPrivateKey, bin) do
      {:ok, key} -> encode_pkcs8_private_key_info(key)
      :error -> detect_ec_or_raw_key(bin)
    end
  end

  defp detect_ec_or_raw_key(bin) do
    case safe_der_decode(:ECPrivateKey, bin) do
      {:ok, key} -> encode_pkcs8_private_key_info(key)
      :error -> validate_raw_pkcs8(bin)
    end
  end

  defp validate_raw_pkcs8(<<0x30, _::binary>> = bin), do: bin
  defp validate_raw_pkcs8(_), do: :erlang.error({:invalid_private_key, :not_der_sequence})

  defp safe_der_decode(type, bin) do
    {:ok, :public_key.der_decode(type, bin)}
  rescue
    _ -> :error
  end

  # -------------------------------------------------------------------
  # SafeBag construction
  # -------------------------------------------------------------------

  defp build_shrouded_key_bag(
         key_info,
         password,
         profile,
         iterations,
         local_key_id,
         friendly_name
       ) do
    enc_key_info = encrypt_private_key(key_info, password, profile, iterations)
    attrs = build_attributes(local_key_id, friendly_name)

    # SafeBag ::= SEQUENCE { bagId OID, bagValue [0] EXPLICIT ANY, bagAttributes SET }
    der_sequence([
      der_oid(@oid_pkcs8_shrouded_key_bag),
      der_explicit(0, enc_key_info)
      | attrs
    ])
  end

  defp build_cert_bags([ee_cert | ca_certs], local_key_id, friendly_name) do
    ee_bag = build_single_cert_bag(ee_cert, build_attributes(local_key_id, friendly_name))
    ca_bags = Enum.map(ca_certs, &build_single_cert_bag(&1, []))
    [ee_bag | ca_bags]
  end

  defp build_single_cert_bag(cert_der, attrs) do
    # CertBag ::= SEQUENCE { certId OID(x509Certificate), certValue [0] EXPLICIT OCTET STRING }
    cert_bag =
      der_sequence([
        der_oid(@oid_x509_certificate),
        der_explicit(0, der_octet_string(cert_der))
      ])

    der_sequence([
      der_oid(@oid_cert_bag),
      der_explicit(0, cert_bag)
      | attrs
    ])
  end

  defp build_attributes(local_key_id, friendly_name) do
    key_id_attr =
      der_sequence([
        der_oid(@oid_local_key_id),
        der_set([der_octet_string(local_key_id)])
      ])

    case friendly_name do
      nil ->
        [der_set([key_id_attr])]

      name ->
        name_bin = if is_list(name), do: List.to_string(name), else: name

        name_attr =
          der_sequence([
            der_oid(@oid_friendly_name),
            der_set([der_bmp_string(name_bin)])
          ])

        [der_set([key_id_attr, name_attr])]
    end
  end

  # -------------------------------------------------------------------
  # Password-based encryption
  # -------------------------------------------------------------------

  defp encrypt_private_key(key_info, password, :modern, iterations) do
    pbes2_encrypt_to_epki(key_info, password, iterations)
  end

  # Legacy profile shrouds the private key with 3DES.
  defp encrypt_private_key(key_info, password, :legacy_des, iterations) do
    legacy_encrypt_to_epki(
      key_info,
      password,
      @oid_pbe_sha_3des_3key,
      :des_ede3_cbc,
      24,
      8,
      iterations
    )
  end

  # PBES2 encrypt: PBKDF2-HMAC-SHA256 + AES-256-CBC.
  defp pbes2_encrypt(plaintext, password, iterations) do
    salt = :crypto.strong_rand_bytes(32)
    iv = :crypto.strong_rand_bytes(16)
    key = :crypto.pbkdf2_hmac(:sha256, password, salt, iterations, 32)
    padded = KDF.pkcs7_pad(plaintext, 16)
    cipher_text = :crypto.crypto_one_time(:aes_256_cbc, key, iv, padded, true)

    # Build PBES2 AlgorithmIdentifier
    pbkdf2_params =
      der_sequence([
        der_octet_string(salt),
        der_integer(iterations),
        der_integer(32),
        der_sequence([der_oid(@oid_hmac_sha256), der_null()])
      ])

    pbkdf2_alg_id = der_sequence([der_oid(@oid_pbkdf2), pbkdf2_params])
    aes_alg_id = der_sequence([der_oid(@oid_aes_256_cbc), der_octet_string(iv)])
    pbes2_params = der_sequence([pbkdf2_alg_id, aes_alg_id])
    pbes2_alg_id = der_sequence([der_oid(@oid_pbes2), pbes2_params])
    {pbes2_alg_id, cipher_text}
  end

  # PBES2 encryption producing EncryptedPrivateKeyInfo.
  defp pbes2_encrypt_to_epki(plaintext, password, iterations) do
    {pbes2_alg_id, cipher_text} = pbes2_encrypt(plaintext, password, iterations)
    der_sequence([pbes2_alg_id, der_octet_string(cipher_text)])
  end

  # Legacy PBE encryption using PKCS#12 Appendix B KDF.
  defp legacy_encrypt_to_epki(plaintext, password, alg_oid, cipher, key_len, iv_len, iterations) do
    salt = :crypto.strong_rand_bytes(8)
    key = KDF.pkcs12_kdf(:sha, 1, password, salt, iterations, key_len)
    iv = KDF.pkcs12_kdf(:sha, 2, password, salt, iterations, iv_len)

    # DES-EDE3-CBC uses 8-byte blocks.
    padded = KDF.pkcs7_pad(plaintext, 8)
    cipher_text = :crypto.crypto_one_time(cipher, key, iv, padded, true)

    # AlgorithmIdentifier { algorithm OID, parameters SEQUENCE { salt, iterations } }
    pbe_params = der_sequence([der_octet_string(salt), der_integer(iterations)])
    alg_id = der_sequence([der_oid(alg_oid), pbe_params])
    der_sequence([alg_id, der_octet_string(cipher_text)])
  end

  # Encrypt SafeContents and wrap in an EncryptedData ContentInfo.
  defp encrypt_safe_contents(safe_contents, password, :modern, iterations) do
    {pbes2_alg_id, cipher_text} = pbes2_encrypt(safe_contents, password, iterations)
    build_encrypted_data_ci(pbes2_alg_id, cipher_text)
  end

  defp encrypt_safe_contents(safe_contents, password, :legacy_des, iterations) do
    salt = :crypto.strong_rand_bytes(8)
    key = KDF.pkcs12_kdf(:sha, 1, password, salt, iterations, 24)
    iv = KDF.pkcs12_kdf(:sha, 2, password, salt, iterations, 8)
    padded = KDF.pkcs7_pad(safe_contents, 8)
    cipher_text = :crypto.crypto_one_time(:des_ede3_cbc, key, iv, padded, true)

    pbe_params = der_sequence([der_octet_string(salt), der_integer(iterations)])
    alg_id = der_sequence([der_oid(@oid_pbe_sha_3des_3key), pbe_params])
    build_encrypted_data_ci(alg_id, cipher_text)
  end

  defp build_encrypted_data_ci(alg_id, cipher_text) do
    # [0] IMPLICIT OCTET STRING — tag 0x80 (context, primitive, tag 0)
    implicit_ct = der_implicit(0, cipher_text)
    enc_content_info = der_sequence([der_oid(@oid_data), alg_id, implicit_ct])
    enc_data = der_sequence([der_integer(0), enc_content_info])
    make_content_info(@oid_encrypted_data, der_explicit(0, enc_data))
  end

  # -------------------------------------------------------------------
  # MAC computation
  # -------------------------------------------------------------------

  defp compute_mac(auth_safe_der, password, _profile, mac_iterations, :pbmac1) do
    compute_mac_pbmac1(auth_safe_der, password, mac_iterations)
  end

  defp compute_mac(auth_safe_der, password, profile, mac_iterations, :legacy) do
    compute_mac_legacy(auth_safe_der, password, profile, mac_iterations)
  end

  # Legacy MAC using PKCS#12 Appendix B KDF + HMAC.
  defp compute_mac_legacy(auth_safe_der, password, profile, mac_iterations) do
    {hash_algo, hash_oid} =
      case profile do
        :modern -> {:sha256, @oid_sha256}
        :legacy_des -> {:sha, @oid_sha1}
      end

    mac_key_len = KDF.hash_output_size(hash_algo)
    salt = :crypto.strong_rand_bytes(mac_key_len)
    mac_key = KDF.pkcs12_kdf(hash_algo, 3, password, salt, mac_iterations, mac_key_len)
    digest = :crypto.mac(:hmac, hash_algo, mac_key, auth_safe_der)

    digest_alg_id = der_sequence([der_oid(hash_oid), der_null()])
    digest_info = der_sequence([digest_alg_id, der_octet_string(digest)])
    der_sequence([digest_info, der_octet_string(salt), der_integer(mac_iterations)])
  end

  # PBMAC1 MAC per RFC 9879.
  # Uses PBKDF2-HMAC-SHA256 for key derivation instead of the PKCS#12 KDF.
  # Password is UTF-8 encoded (NOT BMPString, no null terminator).
  # Salt is embedded in PBKDF2-params within the AlgorithmIdentifier.
  # MacData.macSalt is set to empty, MacData.iterations to 1.
  #
  # NOTE: Only readable by OpenSSL 3.4+ and Java 26+.
  defp compute_mac_pbmac1(auth_safe_der, password, mac_iterations) do
    key_len = 32
    salt = :crypto.strong_rand_bytes(32)

    # PBMAC1 uses UTF-8 password directly (not BMPString)
    mac_key = :crypto.pbkdf2_hmac(:sha256, password, salt, mac_iterations, key_len)
    digest = :crypto.mac(:hmac, :sha256, mac_key, auth_safe_der)

    # Build PBMAC1 AlgorithmIdentifier
    pbkdf2_params =
      der_sequence([
        der_octet_string(salt),
        der_integer(mac_iterations),
        der_integer(key_len),
        der_sequence([der_oid(@oid_hmac_sha256), der_null()])
      ])

    pbkdf2_alg_id = der_sequence([der_oid(@oid_pbkdf2), pbkdf2_params])
    hmac_alg_id = der_sequence([der_oid(@oid_hmac_sha256), der_null()])
    pbmac1_params = der_sequence([pbkdf2_alg_id, hmac_alg_id])
    pbmac1_alg_id = der_sequence([der_oid(@oid_pbmac1), pbmac1_params])

    # DigestInfo with PBMAC1 as the "algorithm"
    digest_info = der_sequence([pbmac1_alg_id, der_octet_string(digest)])

    # MacData: macSalt is empty, iterations is 1 (actual iterations in PBKDF2-params)
    der_sequence([digest_info, der_octet_string(<<>>), der_integer(1)])
  end

  # -------------------------------------------------------------------
  # ContentInfo helper
  # -------------------------------------------------------------------

  defp make_content_info(content_type, content) do
    der_sequence([der_oid(content_type), content])
  end
end
