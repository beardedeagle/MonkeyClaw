defmodule MonkeyClaw.AgentBridge.CliResolverTest do
  use ExUnit.Case, async: true

  alias MonkeyClaw.AgentBridge.CliResolver

  describe "resolve/1" do
    test "preserves explicit cli_path" do
      opts = %{backend: :claude, cli_path: "/custom/path/claude"}
      assert CliResolver.resolve(opts) == opts
    end

    test "does not override non-empty cli_path" do
      opts = %{backend: :claude, cli_path: "/opt/bin/claude"}
      resolved = CliResolver.resolve(opts)
      assert resolved.cli_path == "/opt/bin/claude"
    end

    test "ignores empty cli_path and attempts resolution" do
      # Empty string cli_path should trigger resolution, not short-circuit
      opts = %{backend: :claude, cli_path: ""}
      resolved = CliResolver.resolve(opts)

      # On CI the binary may not be installed — assert based on actual availability
      case CliResolver.find_binary("claude") do
        {:ok, path} -> assert resolved.cli_path == path
        :not_found -> assert resolved == opts
      end
    end

    test "passes through opts for unknown backends" do
      opts = %{backend: :unknown_thing, foo: "bar"}
      assert CliResolver.resolve(opts) == opts
    end

    test "passes through opts without backend key" do
      opts = %{model: "opus"}
      assert CliResolver.resolve(opts) == opts
    end

    test "passes through HTTP-based backends unchanged" do
      opts = %{backend: :opencode, base_url: "http://localhost:4096"}
      assert CliResolver.resolve(opts) == opts
    end

    test "resolves a binary that exists in PATH" do
      # "elixir" should be in PATH in any Elixir test environment
      assert {:ok, path} = CliResolver.find_binary("elixir")
      assert is_binary(path)
      assert String.ends_with?(path, "elixir")
    end

    test "returns :not_found for nonexistent binary" do
      assert :not_found = CliResolver.find_binary("definitely_not_a_real_binary_xyz_123")
    end
  end

  describe "find_binary/1" do
    test "finds elixir in PATH" do
      assert {:ok, path} = CliResolver.find_binary("elixir")
      assert File.regular?(path)
    end

    test "finds mix in PATH" do
      assert {:ok, path} = CliResolver.find_binary("mix")
      assert File.regular?(path)
    end

    test "returns :not_found for missing binary" do
      assert :not_found = CliResolver.find_binary("zzz_nonexistent_bin_zzz")
    end
  end

  describe "binary_for_backend/1" do
    test "returns binary name for CLI backends" do
      assert CliResolver.binary_for_backend(:claude) == "claude"
      assert CliResolver.binary_for_backend(:codex) == "codex"
      assert CliResolver.binary_for_backend(:gemini) == "gemini"
      assert CliResolver.binary_for_backend(:copilot) == "copilot"
    end

    test "returns nil for HTTP backends" do
      assert CliResolver.binary_for_backend(:opencode) == nil
    end

    test "returns nil for unknown backends" do
      assert CliResolver.binary_for_backend(:nope) == nil
    end
  end
end
