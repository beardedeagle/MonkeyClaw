defmodule MonkeyClaw.Crypto.PKCS12.DERTest do
  use ExUnit.Case, async: true

  alias MonkeyClaw.Crypto.PKCS12.DER

  describe "der_sequence/1" do
    test "encodes empty sequence" do
      assert <<0x30, 0>> = DER.der_sequence([])
    end

    test "encodes sequence with elements" do
      inner = DER.der_null()
      result = DER.der_sequence([inner])
      assert <<0x30, 2, 0x05, 0>> = result
    end
  end

  describe "der_set/1" do
    test "encodes empty set" do
      assert <<0x31, 0>> = DER.der_set([])
    end

    test "encodes set with elements" do
      inner = DER.der_null()
      result = DER.der_set([inner])
      assert <<0x31, 2, 0x05, 0>> = result
    end
  end

  describe "der_octet_string/1" do
    test "encodes empty binary" do
      assert <<0x04, 0>> = DER.der_octet_string(<<>>)
    end

    test "encodes binary data" do
      assert <<0x04, 3, 1, 2, 3>> = DER.der_octet_string(<<1, 2, 3>>)
    end

    test "encodes binary with length >= 128 using long form" do
      data = :binary.copy(<<0xAA>>, 200)
      result = DER.der_octet_string(data)
      # Tag 0x04, length 0x81 0xC8 (long form: 1 length byte, value 200)
      assert <<0x04, 0x81, 200, rest::binary>> = result
      assert byte_size(rest) == 200
    end
  end

  describe "der_integer/1" do
    test "encodes zero" do
      assert <<0x02, 1, 0>> = DER.der_integer(0)
    end

    test "encodes small positive integer" do
      assert <<0x02, 1, 42>> = DER.der_integer(42)
    end

    test "encodes integer with high bit set (adds padding)" do
      # 128 = 0x80, high bit set, needs 0x00 prefix
      assert <<0x02, 2, 0, 128>> = DER.der_integer(128)
    end

    test "encodes multi-byte integer" do
      assert <<0x02, 2, 1, 0>> = DER.der_integer(256)
    end

    test "encodes large integer" do
      result = DER.der_integer(65_537)
      # 65537 = 0x010001
      assert <<0x02, 3, 1, 0, 1>> = result
    end
  end

  describe "der_null/0" do
    test "encodes NULL" do
      assert <<0x05, 0>> = DER.der_null()
    end
  end

  describe "der_oid/1" do
    test "encodes simple OID" do
      # SHA-1: 1.3.14.3.2.26
      result = DER.der_oid({1, 3, 14, 3, 2, 26})
      assert <<0x06, _len, _rest::binary>> = result
      # First two components: 1*40 + 3 = 43 = 0x2B
      assert <<0x06, _, 0x2B, _::binary>> = result
    end

    test "encodes OID with high-value sub-identifier" do
      # AES-256-CBC: 2.16.840.1.101.3.4.1.42
      result = DER.der_oid({2, 16, 840, 1, 101, 3, 4, 1, 42})
      assert <<0x06, _len, _rest::binary>> = result
    end

    test "encodes rsaEncryption OID" do
      # 1.2.840.113549.1.1.1
      result = DER.der_oid({1, 2, 840, 113_549, 1, 1, 1})
      assert <<0x06, _len, _rest::binary>> = result
    end
  end

  describe "der_explicit/2" do
    test "wraps content with explicit tag [0]" do
      inner = DER.der_null()
      result = DER.der_explicit(0, inner)
      # Tag 0xA0 (context-specific, constructed, tag 0)
      assert <<0xA0, 2, 0x05, 0>> = result
    end

    test "wraps content with explicit tag [1]" do
      inner = DER.der_null()
      result = DER.der_explicit(1, inner)
      assert <<0xA1, 2, 0x05, 0>> = result
    end
  end

  describe "der_implicit/2" do
    test "wraps content with implicit tag [0]" do
      result = DER.der_implicit(0, <<1, 2, 3>>)
      # Tag 0x80 (context-specific, primitive, tag 0)
      assert <<0x80, 3, 1, 2, 3>> = result
    end
  end

  describe "der_bmp_string/1" do
    test "encodes ASCII string as BMPString" do
      result = DER.der_bmp_string("test")
      # "test" in UTF-16BE: 0x0074 0x0065 0x0073 0x0074
      # No null terminator for display strings
      assert <<0x1E, 8, 0, ?t, 0, ?e, 0, ?s, 0, ?t>> = result
    end

    test "encodes empty string" do
      assert <<0x1E, 0>> = DER.der_bmp_string("")
    end
  end

  describe "length encoding" do
    test "short form for lengths < 128" do
      data = :binary.copy(<<0>>, 127)
      result = DER.der_octet_string(data)
      assert <<0x04, 127, _::binary>> = result
    end

    test "long form for lengths >= 128" do
      data = :binary.copy(<<0>>, 128)
      result = DER.der_octet_string(data)
      # 128 = 0x80, encoded as 0x81 0x80 (1 length byte, value 128)
      assert <<0x04, 0x81, 128, _::binary>> = result
    end

    test "long form for lengths >= 256" do
      data = :binary.copy(<<0>>, 300)
      result = DER.der_octet_string(data)
      # 300 = 0x012C, encoded as 0x82 0x01 0x2C (2 length bytes)
      assert <<0x04, 0x82, 1, 0x2C, _::binary>> = result
    end
  end
end
