defmodule MonkeyClaw.Vault.CryptoTest do
  use MonkeyClaw.DataCase

  alias MonkeyClaw.Vault.Crypto

  # ──────────────────────────────────────────────
  # encrypt/1
  # ──────────────────────────────────────────────

  describe "encrypt/1" do
    test "returns {:ok, ciphertext} for valid plaintext" do
      assert {:ok, ciphertext} = Crypto.encrypt("my-secret-value")
      assert is_binary(ciphertext)
    end

    test "produces ciphertext longer than the plaintext (IV + tag overhead)" do
      plaintext = "secret"
      {:ok, ciphertext} = Crypto.encrypt(plaintext)
      # Wire format: 12 bytes IV + 16 bytes tag + ciphertext
      assert byte_size(ciphertext) == byte_size(plaintext) + 12 + 16
    end

    test "produces different ciphertext for same plaintext (random IV)" do
      plaintext = "same-plaintext"
      {:ok, ct1} = Crypto.encrypt(plaintext)
      {:ok, ct2} = Crypto.encrypt(plaintext)
      refute ct1 == ct2
    end

    test "returns {:error, :invalid_input} for empty string" do
      assert {:error, :invalid_input} = Crypto.encrypt("")
    end

    test "returns {:error, :invalid_input} for non-binary integer" do
      assert {:error, :invalid_input} = Crypto.encrypt(42)
    end

    test "returns {:error, :invalid_input} for non-binary atom" do
      assert {:error, :invalid_input} = Crypto.encrypt(:my_secret)
    end

    test "returns {:error, :invalid_input} for nil" do
      assert {:error, :invalid_input} = Crypto.encrypt(nil)
    end

    test "returns {:error, :invalid_input} for list" do
      assert {:error, :invalid_input} = Crypto.encrypt(["a", "b"])
    end
  end

  # ──────────────────────────────────────────────
  # decrypt/1
  # ──────────────────────────────────────────────

  describe "decrypt/1" do
    test "round-trip returns original plaintext" do
      plaintext = "super-secret-api-key"
      {:ok, ciphertext} = Crypto.encrypt(plaintext)
      assert {:ok, ^plaintext} = Crypto.decrypt(ciphertext)
    end

    test "round-trip works for binary with special characters" do
      plaintext = "sk-ant-api03-Abc123!@#$%^&*()_+-=[]{}|;':\",./<>?"
      {:ok, ciphertext} = Crypto.encrypt(plaintext)
      assert {:ok, ^plaintext} = Crypto.decrypt(ciphertext)
    end

    test "round-trip works for long values" do
      plaintext = String.duplicate("a", 4096)
      {:ok, ciphertext} = Crypto.encrypt(plaintext)
      assert {:ok, ^plaintext} = Crypto.decrypt(ciphertext)
    end

    test "returns {:error, :decryption_failed} for corrupted ciphertext" do
      {:ok, ciphertext} = Crypto.encrypt("secret")
      # Flip a byte in the ciphertext portion (after IV + tag)
      <<iv::binary-size(12), tag::binary-size(16), ct::binary>> = ciphertext
      corrupted_ct = flip_first_byte(ct)
      corrupted = <<iv::binary, tag::binary, corrupted_ct::binary>>
      assert {:error, :decryption_failed} = Crypto.decrypt(corrupted)
    end

    test "returns {:error, :decryption_failed} for corrupted tag" do
      {:ok, ciphertext} = Crypto.encrypt("secret")
      <<iv::binary-size(12), tag::binary-size(16), ct::binary>> = ciphertext
      corrupted_tag = flip_first_byte(tag)
      corrupted = <<iv::binary, corrupted_tag::binary, ct::binary>>
      assert {:error, :decryption_failed} = Crypto.decrypt(corrupted)
    end

    test "returns {:error, :invalid_input} or {:error, :decryption_failed} for truncated data" do
      # Too short to even contain IV + tag
      truncated = <<1, 2, 3, 4, 5>>
      result = Crypto.decrypt(truncated)
      assert result in [{:error, :invalid_input}, {:error, :decryption_failed}]
    end

    test "returns {:error, :invalid_input} for empty binary" do
      assert {:error, :invalid_input} = Crypto.decrypt(<<>>)
    end

    test "returns {:error, :invalid_input} for non-binary" do
      assert {:error, :invalid_input} = Crypto.decrypt(nil)
    end

    test "returns {:error, :invalid_input} for integer" do
      assert {:error, :invalid_input} = Crypto.decrypt(42)
    end

    test "returns {:error, :decryption_failed} for random bytes of sufficient length" do
      random_bytes = :crypto.strong_rand_bytes(50)
      assert {:error, :decryption_failed} = Crypto.decrypt(random_bytes)
    end
  end

  # ──────────────────────────────────────────────
  # clear_key_cache/0
  # ──────────────────────────────────────────────

  describe "clear_key_cache/0" do
    test "returns :ok" do
      assert :ok = Crypto.clear_key_cache()
    end

    test "is idempotent — returns :ok even when cache is already empty" do
      Crypto.clear_key_cache()
      assert :ok = Crypto.clear_key_cache()
    end

    test "subsequent encrypt still works after cache clear (key re-derived)" do
      Crypto.clear_key_cache()
      plaintext = "still-works-after-cache-clear"
      assert {:ok, ciphertext} = Crypto.encrypt(plaintext)
      assert {:ok, ^plaintext} = Crypto.decrypt(ciphertext)
    end

    test "ciphertext encrypted before cache clear decrypts correctly after" do
      plaintext = "encrypted-before-clear"
      {:ok, ciphertext} = Crypto.encrypt(plaintext)
      Crypto.clear_key_cache()
      assert {:ok, ^plaintext} = Crypto.decrypt(ciphertext)
    end
  end

  # ── Private Helpers ──────────────────────────

  # Flip the first byte of a binary to simulate corruption.
  defp flip_first_byte(<<byte, rest::binary>>), do: <<Bitwise.bxor(byte, 0xFF), rest::binary>>
  defp flip_first_byte(<<>>), do: <<0xFF>>
end
