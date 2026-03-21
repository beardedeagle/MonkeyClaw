defmodule MonkeyClaw.Crypto.PKCS12.DER do
  @moduledoc """
  Self-contained DER encoding helpers for PKCS#12.

  Minimal ASN.1 DER encoder covering the subset of types needed
  by PKCS#12 structures. No dependency on OTP's ASN.1 compiler.
  The PKCS#12 structures are simple enough that hand-encoding
  is clearer than a compile-time `asn1ct` step.
  """

  import Bitwise

  # -------------------------------------------------------------------
  # Public API — DER type constructors
  # -------------------------------------------------------------------

  @doc "Encode a list of DER elements as a SEQUENCE."
  @spec der_sequence([binary()]) :: binary()
  def der_sequence(elements) do
    content = IO.iodata_to_binary(elements)
    der_constructed(0x30, content)
  end

  @doc "Encode a list of DER elements as a SET."
  @spec der_set([binary()]) :: binary()
  def der_set(elements) do
    content = IO.iodata_to_binary(elements)
    der_constructed(0x31, content)
  end

  @doc "Encode a binary as an OCTET STRING."
  @spec der_octet_string(binary()) :: nonempty_binary()
  def der_octet_string(bin) do
    der_primitive(0x04, bin)
  end

  @doc "Encode a non-negative integer."
  @spec der_integer(non_neg_integer()) :: nonempty_binary()
  def der_integer(0), do: <<0x02, 1, 0>>

  def der_integer(n) when n > 0 do
    bin = :binary.encode_unsigned(n, :big)

    # If high bit set, prepend 0x00 to keep positive
    padded =
      case bin do
        <<1::1, _::7, _::binary>> -> <<0, bin::binary>>
        _ -> bin
      end

    der_primitive(0x02, padded)
  end

  @doc "Encode a DER NULL value."
  @spec der_null() :: <<_::16>>
  def der_null, do: <<0x05, 0>>

  @doc "Encode an OID tuple as a DER OBJECT IDENTIFIER."
  @spec der_oid(tuple()) :: nonempty_binary()
  def der_oid(oid) do
    components = Tuple.to_list(oid)
    encoded = encode_oid_components(components)
    der_primitive(0x06, encoded)
  end

  @doc "Wrap content in a context-specific EXPLICIT tag."
  @spec der_explicit(non_neg_integer(), binary()) :: binary()
  def der_explicit(tag, content) do
    der_constructed(bor(0xA0, tag), content)
  end

  @doc "Wrap content in a context-specific IMPLICIT tag."
  @spec der_implicit(non_neg_integer(), binary()) :: binary()
  def der_implicit(tag, content) do
    # Context-specific, primitive (for OCTET STRING replacement)
    der_primitive(bor(0x80, tag), content)
  end

  @doc "Encode a UTF-8 binary as a BMPString (UTF-16BE)."
  @spec der_bmp_string(binary()) :: binary()
  def der_bmp_string(utf8_bin) do
    # BMPString for display strings — no null terminator.
    # Uses :unicode to correctly handle multi-byte UTF-8 codepoints.
    bmp = :unicode.characters_to_binary(utf8_bin, :utf8, {:utf16, :big})
    der_primitive(0x1E, bmp)
  end

  # -------------------------------------------------------------------
  # Internal — Low-level TLV encoding
  # -------------------------------------------------------------------

  defp der_constructed(tag, content) do
    <<tag, encode_der_length(byte_size(content))::binary, content::binary>>
  end

  defp der_primitive(tag, content) do
    <<tag, encode_der_length(byte_size(content))::binary, content::binary>>
  end

  defp encode_der_length(len) when len < 128, do: <<len>>

  defp encode_der_length(len) do
    bytes = :binary.encode_unsigned(len, :big)
    <<bor(128, byte_size(bytes)), bytes::binary>>
  end

  # -------------------------------------------------------------------
  # Internal — OID encoding
  # -------------------------------------------------------------------

  defp encode_oid_components([first, second | rest]) do
    first_val = first * 40 + second
    rest_encoded = Enum.map(rest, &encode_oid_subidentifier/1)
    IO.iodata_to_binary([encode_oid_subidentifier(first_val) | rest_encoded])
  end

  defp encode_oid_subidentifier(n) when n < 128, do: <<n>>

  defp encode_oid_subidentifier(n) do
    encode_oid_subidentifier_high(n, <<>>)
  end

  defp encode_oid_subidentifier_high(0, acc), do: acc

  defp encode_oid_subidentifier_high(n, acc) do
    byte = band(n, 0x7F)
    high_bit = if acc == <<>>, do: 0, else: 1

    encode_oid_subidentifier_high(
      bsr(n, 7),
      <<high_bit::1, byte::7, acc::binary>>
    )
  end
end
