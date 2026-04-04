defmodule MonkeyClaw.Vault.EncryptedField do
  @moduledoc """
  Custom Ecto type that transparently encrypts/decrypts string values.

  Used for vault token fields (`access_token`, `refresh_token`) where
  automatic encryption on write and decryption on read is desirable.

  NOT used for vault secrets — those use explicit encrypt/decrypt via
  `MonkeyClaw.Vault.Crypto` to prevent accidental plaintext exposure
  through Ecto preloads or inspect output.

  ## Wire Format

  Delegates to `MonkeyClaw.Vault.Crypto` which stores:

      <<iv::12-bytes, tag::16-bytes, ciphertext::rest>>

  ## Design

  This is an Ecto custom type, not a process. It hooks into Ecto's
  `dump/1` (encrypt before storage) and `load/1` (decrypt after read)
  callbacks.
  """

  use Ecto.Type

  alias MonkeyClaw.Vault.Crypto

  @impl true
  def type, do: :binary

  @impl true
  def cast(value) when is_binary(value) and byte_size(value) > 0, do: {:ok, value}
  def cast(nil), do: {:ok, nil}
  def cast(_), do: :error

  @impl true
  def dump(nil), do: {:ok, nil}

  def dump(value) when is_binary(value) and byte_size(value) > 0 do
    case Crypto.encrypt(value) do
      {:ok, ciphertext} -> {:ok, ciphertext}
      {:error, _} -> :error
    end
  end

  def dump(_), do: :error

  @impl true
  def load(nil), do: {:ok, nil}

  def load(ciphertext) when is_binary(ciphertext) do
    case Crypto.decrypt(ciphertext) do
      {:ok, plaintext} -> {:ok, plaintext}
      {:error, _} -> :error
    end
  end

  def load(_), do: :error

  @impl true
  def equal?(a, b), do: a == b
end
