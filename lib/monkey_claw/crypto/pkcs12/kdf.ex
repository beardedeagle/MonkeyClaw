defmodule MonkeyClaw.Crypto.PKCS12.KDF do
  @moduledoc """
  PKCS#12 key derivation, password encoding, and padding utilities.

  Implements the PKCS#12 Appendix B Key Derivation Function (RFC 7292),
  BMPString password encoding, PKCS#7 padding, and hash metadata.
  """

  import Bitwise

  # -------------------------------------------------------------------
  # PKCS#12 Appendix B Key Derivation Function (RFC 7292, Appendix B)
  # -------------------------------------------------------------------

  @doc """
  Derive key material using the PKCS#12 Appendix B KDF.

  This is distinct from PBKDF1/PBKDF2. It uses a diversifier byte (ID)
  to derive different types of key material from the same password:

    * ID=1 — encryption/decryption keys
    * ID=2 — initialization vectors
    * ID=3 — MAC keys

  Required for legacy PBE algorithms and for MAC computation even when
  using modern PBES2 encryption.
  """
  @spec pkcs12_kdf(hash_algo(), 1..3, binary(), binary(), pos_integer(), pos_integer()) ::
          binary()
  def pkcs12_kdf(hash_algo, id, password, salt, iterations, output_len) do
    v = hash_block_size(hash_algo)
    u = hash_output_size(hash_algo)
    d = :binary.copy(<<id::8>>, v)
    s = pad_or_empty(salt, v)
    p = pad_or_empty(bmp_password(password), v)
    i = <<s::binary, p::binary>>
    c = ceil_div(output_len, u)

    {result, _final_i} =
      Enum.reduce(1..c//1, {<<>>, i}, fn _round, {acc, ii} ->
        ai = iterate_hash(hash_algo, <<d::binary, ii::binary>>, iterations)
        # Steps 6B-6C: adjust I for next round (only matters when C > 1)
        b = pad_or_truncate(ai, v)
        new_i = adjust_i_blocks(ii, b, v)
        {<<acc::binary, ai::binary>>, new_i}
      end)

    :binary.part(result, 0, output_len)
  end

  # -------------------------------------------------------------------
  # BMPString password encoding
  # -------------------------------------------------------------------

  @doc """
  Encode a password as BMPString (UTF-16 big-endian) with null terminator.

  Per RFC 7292, passwords are encoded as BMPString — each codepoint
  becomes two bytes (big-endian), with a trailing 0x0000 terminator.
  Empty passwords produce an empty binary (not a null terminator).
  """
  @spec bmp_password(binary()) :: binary()
  def bmp_password(<<>>), do: <<>>

  def bmp_password(password) do
    codepoints = :unicode.characters_to_list(password, :utf8)
    chars = for cp <- codepoints, into: <<>>, do: <<cp::16-big>>
    <<chars::binary, 0::16>>
  end

  # -------------------------------------------------------------------
  # PKCS#7 padding
  # -------------------------------------------------------------------

  @doc "Apply PKCS#7 padding to a binary."
  @spec pkcs7_pad(binary(), pos_integer()) :: binary()
  def pkcs7_pad(data, block_size) do
    pad_len = block_size - rem(byte_size(data), block_size)
    padding = :binary.copy(<<pad_len>>, pad_len)
    <<data::binary, padding::binary>>
  end

  # -------------------------------------------------------------------
  # Hash metadata
  # -------------------------------------------------------------------

  @typedoc "Supported hash algorithms for PKCS#12 KDF."
  @type hash_algo() :: :sha | :sha256 | :sha384 | :sha512

  @doc "Return the internal block size of a hash algorithm (in bytes)."
  @spec hash_block_size(hash_algo()) :: 64 | 128
  def hash_block_size(:sha), do: 64
  def hash_block_size(:sha256), do: 64
  def hash_block_size(:sha384), do: 128
  def hash_block_size(:sha512), do: 128

  @doc "Return the output size of a hash algorithm (in bytes)."
  @spec hash_output_size(hash_algo()) :: 20 | 32 | 48 | 64
  def hash_output_size(:sha), do: 20
  def hash_output_size(:sha256), do: 32
  def hash_output_size(:sha384), do: 48
  def hash_output_size(:sha512), do: 64

  # -------------------------------------------------------------------
  # Arithmetic utility
  # -------------------------------------------------------------------

  @doc "Ceiling integer division."
  @spec ceil_div(non_neg_integer(), pos_integer()) :: non_neg_integer()
  def ceil_div(a, b), do: div(a + b - 1, b)

  # -------------------------------------------------------------------
  # Internal helpers
  # -------------------------------------------------------------------

  defp iterate_hash(algo, data, 1), do: :crypto.hash(algo, data)

  defp iterate_hash(algo, data, n) when n > 1 do
    iterate_hash(algo, :crypto.hash(algo, data), n - 1)
  end

  defp pad_or_empty(<<>>, _block_size), do: <<>>

  defp pad_or_empty(data, block_size) do
    len = byte_size(data)
    padded_len = block_size * ceil_div(len, block_size)
    copies = :binary.copy(data, ceil_div(padded_len, len))
    :binary.part(copies, 0, padded_len)
  end

  defp pad_or_truncate(data, len) do
    data_len = byte_size(data)
    copies = :binary.copy(data, ceil_div(len, data_len))
    :binary.part(copies, 0, len)
  end

  defp adjust_i_blocks(i, b, v), do: adjust_i_blocks(i, b, v, <<>>)

  defp adjust_i_blocks(<<>>, _b, _v, acc), do: acc

  defp adjust_i_blocks(i, b, v, acc) do
    <<block::binary-size(v), rest::binary>> = i
    block_int = :binary.decode_unsigned(block, :big)
    b_int = :binary.decode_unsigned(b, :big)
    modulus = bsl(1, v * 8)
    sum = rem(block_int + b_int + 1, modulus)
    new_block = <<sum::integer-size(v)-unit(8)>>
    adjust_i_blocks(rest, b, v, <<acc::binary, new_block::binary>>)
  end
end
