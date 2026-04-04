defmodule MonkeyClaw.Vault.Crypto do
  @moduledoc """
  AES-256-GCM authenticated encryption for vault secrets.

  Provides encrypt/decrypt functions using a key derived from the
  BEAM VM cookie via HKDF-SHA256. The cookie serves as the root
  secret — it already exists in every BEAM deployment and is
  controlled by the operator.

  ## Wire Format

  The encrypted binary is:

      <<iv::12-bytes, tag::16-bytes, ciphertext::rest>>

  ## Key Derivation

  The encryption key is derived from the node cookie using
  HKDF-SHA256 (RFC 5869):

    1. **Extract** — `PRK = HMAC-SHA256(salt, cookie)`
    2. **Expand** — `OKM = HMAC-SHA256(PRK, info || 0x01)`

  The derived key is cached in `:persistent_term` for fast
  read-heavy access without per-process GC pressure.

  ## Security Properties

    * **Confidentiality** — AES-256-GCM authenticated encryption
    * **Integrity** — GCM tag detects tampering
    * **Uniqueness** — Fresh random 96-bit IV per encryption
    * **Key isolation** — Domain-separated from other cookie uses via HKDF info
    * **No plaintext in logs** — encrypt/decrypt operate on raw binaries

  ## Future

  The key derivation source is designed to be swappable. MVP uses
  the BEAM cookie; future versions can source from OS keyring
  (macOS Keychain) or environment variables without changing the
  encryption format.
  """

  @iv_bytes 12
  @tag_bytes 16
  @aad "MonkeyClaw.Vault.Crypto:v1"
  @hkdf_salt "MonkeyClaw.Vault"
  @hkdf_info "MonkeyClaw.Vault.Crypto:v1"
  @persistent_term_key {__MODULE__, :derived_key}

  @doc """
  Encrypt a plaintext binary.

  Returns `{:ok, ciphertext}` where ciphertext is the wire-format
  binary `<<iv, tag, encrypted_data>>`, or `{:error, reason}` on
  failure.

  Each call uses a fresh random IV, so encrypting the same plaintext
  twice produces different ciphertexts.

  ## Examples

      iex> {:ok, ciphertext} = MonkeyClaw.Vault.Crypto.encrypt("my-secret")
      iex> is_binary(ciphertext)
      true
  """
  @spec encrypt(binary()) :: {:ok, binary()} | {:error, :invalid_input | :encryption_failed}
  def encrypt(plaintext) when is_binary(plaintext) and byte_size(plaintext) > 0 do
    key = derived_key()
    iv = :crypto.strong_rand_bytes(@iv_bytes)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, @aad, @tag_bytes, true)

    {:ok, <<iv::binary-size(@iv_bytes), tag::binary-size(@tag_bytes), ciphertext::binary>>}
  rescue
    _ -> {:error, :encryption_failed}
  end

  def encrypt(_), do: {:error, :invalid_input}

  @doc """
  Decrypt a ciphertext binary produced by `encrypt/1`.

  Returns `{:ok, plaintext}` on success, or `{:error, reason}` if
  the ciphertext is malformed, the key is wrong, or the data has
  been tampered with.

  ## Examples

      iex> {:ok, ct} = MonkeyClaw.Vault.Crypto.encrypt("secret")
      iex> {:ok, "secret"} = MonkeyClaw.Vault.Crypto.decrypt(ct)
  """
  @spec decrypt(binary()) :: {:ok, binary()} | {:error, :invalid_input | :decryption_failed}
  def decrypt(<<iv::binary-size(@iv_bytes), tag::binary-size(@tag_bytes), ciphertext::binary>>) do
    key = derived_key()

    case :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ciphertext, @aad, tag, false) do
      plaintext when is_binary(plaintext) -> {:ok, plaintext}
      :error -> {:error, :decryption_failed}
    end
  rescue
    _ -> {:error, :decryption_failed}
  end

  def decrypt(_), do: {:error, :invalid_input}

  @doc """
  Clear the cached derived key.

  Forces re-derivation on the next encrypt/decrypt call. Useful
  for testing or after a cookie change.
  """
  @spec clear_key_cache() :: :ok
  def clear_key_cache do
    :persistent_term.erase(@persistent_term_key)
    :ok
  rescue
    ArgumentError -> :ok
  end

  # ── Private ─────────────────────────────────────────────────

  # Returns the cached 256-bit derived key, deriving it on first access.
  @spec derived_key() :: <<_::256>>
  defp derived_key do
    case :persistent_term.get(@persistent_term_key, nil) do
      nil ->
        key = derive_key_from_cookie()
        :persistent_term.put(@persistent_term_key, key)
        key

      key ->
        key
    end
  end

  # HKDF-SHA256 (RFC 5869) key derivation from the BEAM node cookie.
  #
  # OTP's :crypto module does not export an HKDF function, so we
  # implement the two-step construction manually:
  #
  #   1. Extract: PRK = HMAC-SHA256(salt, IKM)
  #   2. Expand:  OKM = HMAC-SHA256(PRK, info || 0x01)
  #
  # Since AES-256 needs exactly 32 bytes and SHA-256 outputs 32 bytes,
  # only one expand iteration is needed.
  @spec derive_key_from_cookie() :: <<_::256>>
  defp derive_key_from_cookie do
    cookie = Node.get_cookie() |> Atom.to_string()

    # Step 1: Extract — concentrate entropy into a pseudorandom key
    prk = :crypto.mac(:hmac, :sha256, @hkdf_salt, cookie)

    # Step 2: Expand — derive the output key material
    # For L=32 (AES-256), N=ceil(32/32)=1, so T(1) = HMAC(PRK, info || 0x01)
    :crypto.mac(:hmac, :sha256, prk, @hkdf_info <> <<1>>)
  end
end
