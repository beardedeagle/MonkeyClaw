defmodule MonkeyClaw.Webhooks.EncryptedBinaryTest do
  use ExUnit.Case, async: true

  alias MonkeyClaw.Webhooks.EncryptedBinary

  describe "type/0" do
    test "returns :binary" do
      assert :binary = EncryptedBinary.type()
    end
  end

  describe "cast/1" do
    test "accepts non-empty binary" do
      assert {:ok, "hello"} = EncryptedBinary.cast("hello")
    end

    test "rejects empty binary" do
      assert :error = EncryptedBinary.cast("")
    end

    test "rejects non-binary values" do
      assert :error = EncryptedBinary.cast(123)
      assert :error = EncryptedBinary.cast(nil)
      assert :error = EncryptedBinary.cast([])
    end
  end

  describe "dump/1 and load/1" do
    test "round-trip preserves plaintext" do
      plaintext = "my-super-secret-signing-key-value"
      {:ok, ciphertext} = EncryptedBinary.dump(plaintext)
      {:ok, recovered} = EncryptedBinary.load(ciphertext)

      assert recovered == plaintext
    end

    test "produces different ciphertext for same plaintext (random IV)" do
      plaintext = "same-secret-value"
      {:ok, ct1} = EncryptedBinary.dump(plaintext)
      {:ok, ct2} = EncryptedBinary.dump(plaintext)

      assert ct1 != ct2
    end

    test "both produce valid round-trips despite different ciphertext" do
      plaintext = "round-trip-test"
      {:ok, ct1} = EncryptedBinary.dump(plaintext)
      {:ok, ct2} = EncryptedBinary.dump(plaintext)

      {:ok, p1} = EncryptedBinary.load(ct1)
      {:ok, p2} = EncryptedBinary.load(ct2)

      assert p1 == plaintext
      assert p2 == plaintext
    end

    test "detects tampered ciphertext (GCM integrity)" do
      plaintext = "tamper-detection-test"
      {:ok, ciphertext} = EncryptedBinary.dump(plaintext)

      # Flip a byte in the ciphertext portion (after 12-byte IV + 16-byte tag)
      <<iv::binary-12, tag::binary-16, ct_byte, rest::binary>> = ciphertext
      tampered = <<iv::binary-12, tag::binary-16, Bitwise.bxor(ct_byte, 0xFF), rest::binary>>

      assert :error = EncryptedBinary.load(tampered)
    end

    test "detects tampered IV" do
      plaintext = "iv-tamper-test"
      {:ok, ciphertext} = EncryptedBinary.dump(plaintext)

      <<iv_byte, rest::binary>> = ciphertext
      tampered = <<Bitwise.bxor(iv_byte, 0xFF), rest::binary>>

      assert :error = EncryptedBinary.load(tampered)
    end

    test "detects tampered tag" do
      plaintext = "tag-tamper-test"
      {:ok, ciphertext} = EncryptedBinary.dump(plaintext)

      <<iv::binary-12, tag_byte, rest::binary>> = ciphertext
      tampered = <<iv::binary-12, Bitwise.bxor(tag_byte, 0xFF), rest::binary>>

      assert :error = EncryptedBinary.load(tampered)
    end

    test "rejects truncated data (too short for IV + tag)" do
      assert :error = EncryptedBinary.load(<<0::8*10>>)
    end

    test "rejects empty binary on load" do
      assert :error = EncryptedBinary.load("")
    end
  end

  describe "dump/1 — invalid inputs" do
    test "rejects empty binary" do
      assert :error = EncryptedBinary.dump("")
    end

    test "rejects non-binary" do
      assert :error = EncryptedBinary.dump(nil)
      assert :error = EncryptedBinary.dump(42)
    end
  end

  describe "equal?/2" do
    test "equal plaintexts" do
      assert EncryptedBinary.equal?("same", "same")
    end

    test "different plaintexts" do
      refute EncryptedBinary.equal?("a", "b")
    end
  end
end
