defmodule MonkeyClaw.ModelRegistry.ProviderLogRedactionTest do
  @moduledoc """
  Verifies Provider.sanitize_for_log/1 routes inspected terms through
  SecretScanner so credentials embedded in upstream error bodies or
  Req error structs cannot leak into Logger output (spec I8,
  Security Invariant 4).
  """

  use ExUnit.Case, async: true

  alias MonkeyClaw.ModelRegistry.Provider

  describe "sanitize_for_log/1" do
    test "redacts anthropic API keys from binary terms" do
      raw = "unexpected auth echo: sk-ant-api03-VERYSECRETKEY1234567890ABCDEFGH1234567890"
      sanitized = Provider.sanitize_for_log(raw)

      refute sanitized =~ "VERYSECRETKEY1234567890"
      assert sanitized =~ "REDACTED"
    end

    test "redacts secret-shaped content inside a nested term via inspect" do
      term = %{
        status: 401,
        body: %{"error" => "invalid key: sk-ant-api03-LEAKEDKEY1234567890ABCDEFGH1234567890"}
      }

      sanitized = Provider.sanitize_for_log(term)

      refute sanitized =~ "LEAKEDKEY1234567890"
      assert sanitized =~ "REDACTED"
    end

    test "passes through terms that contain no secrets" do
      sanitized = Provider.sanitize_for_log({:timeout, :econnrefused})
      # inspect form of the tuple is preserved
      assert sanitized =~ "timeout"
      assert sanitized =~ "econnrefused"
    end

    test "returns a string for any term" do
      assert is_binary(Provider.sanitize_for_log(nil))
      assert is_binary(Provider.sanitize_for_log(42))
      assert is_binary(Provider.sanitize_for_log("plain"))
      assert is_binary(Provider.sanitize_for_log(%{}))
    end
  end
end
