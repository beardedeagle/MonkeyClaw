defmodule MonkeyClaw.Webhooks.EncryptedBinary do
  @moduledoc """
  Custom Ecto type that transparently encrypts/decrypts binary values.

  Used for storing webhook signing secrets at rest. Values are
  encrypted with AES-256-GCM using a key derived from the
  application's `secret_key_base`. Each write uses a fresh random
  IV, so the ciphertext differs even for identical plaintexts.

  ## Wire Format

  The stored binary is:

      <<iv::12-bytes, tag::16-bytes, ciphertext::rest>>

  ## Key Derivation

  The encryption key is derived deterministically from `secret_key_base`
  using SHA-256 with a domain-specific salt. This ensures webhook
  secrets are encrypted with a key that is:

    * unique to this application purpose (domain separator)
    * derived from the same root secret as session signing
    * 256 bits (matching AES-256 key length)

  ## Security Properties

    * **Confidentiality** — AES-256-GCM authenticated encryption
    * **Integrity** — GCM tag detects tampering
    * **Uniqueness** — Random 96-bit IV per encryption
    * **Key isolation** — Domain-separated from other secret_key_base uses
  """

  use Ecto.Type

  @iv_bytes 12
  @tag_bytes 16
  @aad "MonkeyClaw.Webhooks.EncryptedBinary.v1"

  @impl true
  def type, do: :binary

  @impl true
  def cast(value) when is_binary(value) and byte_size(value) > 0, do: {:ok, value}
  def cast(_), do: :error

  @impl true
  def dump(value) when is_binary(value) and byte_size(value) > 0 do
    key = encryption_key()
    iv = :crypto.strong_rand_bytes(@iv_bytes)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, value, @aad, @tag_bytes, true)

    {:ok, <<iv::binary-size(@iv_bytes), tag::binary-size(@tag_bytes), ciphertext::binary>>}
  end

  def dump(_), do: :error

  @impl true
  def load(<<iv::binary-size(@iv_bytes), tag::binary-size(@tag_bytes), ciphertext::binary>>) do
    key = encryption_key()

    case :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ciphertext, @aad, tag, false) do
      plaintext when is_binary(plaintext) -> {:ok, plaintext}
      :error -> :error
    end
  end

  def load(_), do: :error

  @impl true
  def equal?(a, b), do: a == b

  # Derive a 256-bit encryption key from the application's secret_key_base.
  # The domain prefix ensures this key is unique to webhook secret storage,
  # preventing key reuse across different application subsystems.
  @spec encryption_key() :: <<_::256>>
  defp encryption_key do
    endpoint_config = Application.fetch_env!(:monkey_claw, MonkeyClawWeb.Endpoint)
    secret_key_base = Keyword.fetch!(endpoint_config, :secret_key_base)
    :crypto.hash(:sha256, "MonkeyClaw.Webhooks.SigningSecret:" <> secret_key_base)
  end
end
