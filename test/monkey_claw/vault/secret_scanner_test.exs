defmodule MonkeyClaw.Vault.SecretScannerTest do
  use ExUnit.Case

  alias MonkeyClaw.Extensions.Context
  alias MonkeyClaw.Vault.SecretScanner
  alias MonkeyClaw.Vault.SecretScannerPlug

  # ──────────────────────────────────────────────
  # Pattern detection
  # ──────────────────────────────────────────────

  describe "scan/2 — pattern detection" do
    test "detects AWS Access Key ID" do
      content = "Config: AKIAIOSFODNN7EXAMPLE here"
      assert {:ok, findings} = SecretScanner.scan(content)
      assert Enum.any?(findings, &(&1.label == "AWS_KEY"))
    end

    test "detects GitHub token (ghp_ prefix)" do
      content = "Using ghp_ABCDEFGHIJKLMNOPQRSTUVwxyz123456 for auth"
      assert {:ok, findings} = SecretScanner.scan(content)
      assert Enum.any?(findings, &(&1.label == "GITHUB_TOKEN"))
    end

    test "detects GitHub personal access token (github_pat_ prefix)" do
      content = "Token github_pat_ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890"
      assert {:ok, findings} = SecretScanner.scan(content)
      assert Enum.any?(findings, &(&1.label == "GITHUB_TOKEN"))
    end

    test "detects Slack bot token (xoxb- prefix)" do
      content = "xoxb-123456789012-1234567890-AbCdEfGhIjKl"
      assert {:ok, findings} = SecretScanner.scan(content)
      assert Enum.any?(findings, &(&1.label == "SLACK_TOKEN"))
    end

    test "detects Stripe secret key" do
      # Build the test key at runtime to avoid triggering GitHub push protection.
      # Our scanner regex matches sk_live_ or sk_test_ with 24-64 alnum chars.
      prefix = "sk_test_"
      suffix = String.duplicate("X", 24)
      content = prefix <> suffix
      assert {:ok, findings} = SecretScanner.scan(content)
      assert Enum.any?(findings, &(&1.label == "STRIPE_KEY"))
    end

    test "detects PEM private key header" do
      content = "-----BEGIN RSA PRIVATE KEY-----"
      assert {:ok, findings} = SecretScanner.scan(content)
      assert Enum.any?(findings, &(&1.label == "PRIVATE_KEY"))
    end

    test "detects OpenAI API key" do
      content = "sk-ABCDEFGHIJKLMNOPQRSTUVWXYZ12345678901234"
      assert {:ok, findings} = SecretScanner.scan(content)
      assert Enum.any?(findings, &(&1.label == "OPENAI_KEY"))
    end

    test "detects Anthropic API key" do
      content = "sk-ant-api03-ABCDEFGHIJKLMNOPQRSTUVWXYZ12345678901234"
      assert {:ok, findings} = SecretScanner.scan(content)
      assert Enum.any?(findings, &(&1.label == "ANTHROPIC_KEY"))
    end

    test "detects Google API key" do
      content = "AIzaSyABCDEFGHIJKLMNOPQRSTUVWXYZ1234567"
      assert {:ok, findings} = SecretScanner.scan(content)
      assert Enum.any?(findings, &(&1.label == "GOOGLE_KEY"))
    end

    test "detects password embedded in database URL" do
      content = "postgres://admin:supersecret123@localhost/db"
      assert {:ok, findings} = SecretScanner.scan(content)
      assert Enum.any?(findings, &(&1.label == "PASSWORD"))
    end

    test "returns empty findings for clean content" do
      assert {:ok, []} = SecretScanner.scan("Hello, this is a perfectly normal message.")
    end

    test "finding contains expected fields" do
      content = "AKIAIOSFODNN7EXAMPLE"
      assert {:ok, [finding | _]} = SecretScanner.scan(content)
      assert Map.has_key?(finding, :pattern)
      assert Map.has_key?(finding, :label)
      assert Map.has_key?(finding, :severity)
      assert Map.has_key?(finding, :start_byte)
      assert Map.has_key?(finding, :end_byte)
      assert Map.has_key?(finding, :match)
      assert finding.end_byte > finding.start_byte
    end
  end

  # ──────────────────────────────────────────────
  # Safety guards
  # ──────────────────────────────────────────────

  describe "scan/2 — safety guards" do
    test "returns {:error, :content_too_large} when content exceeds max_bytes" do
      oversized = String.duplicate("a", 100)
      assert {:error, :content_too_large} = SecretScanner.scan(oversized, max_bytes: 10)
    end

    test "returns {:error, :timeout} when scan exceeds timeout_ms" do
      # Build content that is under max_bytes but large enough that running
      # 14 regex patterns against it cannot complete in 1 ms.
      # 45_000 × 21 bytes = 945_000 bytes — safely under the 1 MiB default.
      large = String.duplicate("AKIAIOSFODNN7EXAMPLE ", 45_000)
      assert {:error, :timeout} = SecretScanner.scan(large, timeout_ms: 1)
    end
  end

  # ──────────────────────────────────────────────
  # Redaction
  # ──────────────────────────────────────────────

  describe "redact/2" do
    test "replaces matched secret with [REDACTED:LABEL]" do
      content = "key: AKIAIOSFODNN7EXAMPLE end"
      assert {:ok, findings} = SecretScanner.scan(content)
      redacted = SecretScanner.redact(content, findings)
      refute String.contains?(redacted, "AKIAIOSFODNN7EXAMPLE")
      assert String.contains?(redacted, "[REDACTED:AWS_KEY]")
    end

    test "returns original content unchanged when findings list is empty" do
      content = "No secrets here."
      assert SecretScanner.redact(content, []) == content
    end

    test "handles multiple secrets in the same content without corrupting offsets" do
      # Two distinct secrets — one near the start, one near the end.
      aws_key = "AKIAIOSFODNN7EXAMPLE"
      gh_token = "ghp_ABCDEFGHIJKLMNOPQRSTUVwxyz123456"
      content = "AWS: #{aws_key} and GitHub: #{gh_token}"

      assert {:ok, findings} = SecretScanner.scan(content)
      redacted = SecretScanner.redact(content, findings)

      refute String.contains?(redacted, aws_key)
      refute String.contains?(redacted, gh_token)
      assert String.contains?(redacted, "[REDACTED:AWS_KEY]")
      assert String.contains?(redacted, "[REDACTED:GITHUB_TOKEN]")
    end

    test "redact/2 preserves surrounding text outside matched secrets" do
      content = "before AKIAIOSFODNN7EXAMPLE after"
      assert {:ok, findings} = SecretScanner.scan(content)
      redacted = SecretScanner.redact(content, findings)
      assert String.starts_with?(redacted, "before ")
      assert String.ends_with?(redacted, " after")
    end
  end

  # ──────────────────────────────────────────────
  # scan_and_redact/2
  # ──────────────────────────────────────────────

  describe "scan_and_redact/2" do
    test "returns {:ok, redacted_content, count} when secrets are found" do
      content = "token: AKIAIOSFODNN7EXAMPLE"
      assert {:ok, redacted, count} = SecretScanner.scan_and_redact(content)
      assert count > 0
      refute String.contains?(redacted, "AKIAIOSFODNN7EXAMPLE")
    end

    test "returns {:ok, original_content, 0} when content is clean" do
      content = "Nothing sensitive here."
      assert {:ok, ^content, 0} = SecretScanner.scan_and_redact(content)
    end

    test "propagates {:error, :content_too_large}" do
      oversized = String.duplicate("x", 50)

      assert {:error, :content_too_large} =
               SecretScanner.scan_and_redact(oversized, max_bytes: 10)
    end
  end

  # ──────────────────────────────────────────────
  # SecretScannerPlug — init/1
  # ──────────────────────────────────────────────

  describe "SecretScannerPlug.init/1" do
    test "passes opts through unchanged" do
      opts = [timeout_ms: 200, max_bytes: 524_288]
      assert SecretScannerPlug.init(opts) == opts
    end

    test "passes empty opts through unchanged" do
      assert SecretScannerPlug.init([]) == []
    end
  end

  # ──────────────────────────────────────────────
  # SecretScannerPlug — call/2 :query_pre
  # ──────────────────────────────────────────────

  describe "SecretScannerPlug.call/2 with :query_pre event" do
    test "passes context through unchanged when prompt is clean" do
      ctx = build_query_pre_context("Tell me about Elixir.")
      result = SecretScannerPlug.call(ctx, [])
      assert result.data.prompt == "Tell me about Elixir."
      refute Map.has_key?(result.assigns, :secrets_redacted)
    end

    test "redacts secret in prompt and sets :secrets_redacted assign" do
      prompt = "Use this key: AKIAIOSFODNN7EXAMPLE"
      ctx = build_query_pre_context(prompt)
      result = SecretScannerPlug.call(ctx, [])
      refute String.contains?(result.data.prompt, "AKIAIOSFODNN7EXAMPLE")
      assert String.contains?(result.data.prompt, "[REDACTED:AWS_KEY]")
      assert result.assigns.secrets_redacted > 0
    end

    test "does not set :secrets_redacted when no secrets are found" do
      ctx = build_query_pre_context("What is OTP supervision?")
      result = SecretScannerPlug.call(ctx, [])
      refute Map.has_key?(result.assigns, :secrets_redacted)
    end

    test "redacts multiple secrets and counts them all" do
      prompt =
        "AWS key AKIAIOSFODNN7EXAMPLE and GitHub token ghp_ABCDEFGHIJKLMNOPQRSTUVwxyz123456"

      ctx = build_query_pre_context(prompt)
      result = SecretScannerPlug.call(ctx, [])
      assert result.assigns.secrets_redacted >= 2
      refute String.contains?(result.data.prompt, "AKIAIOSFODNN7EXAMPLE")
      refute String.contains?(result.data.prompt, "ghp_ABCDEFGHIJKLMNOPQRSTUVwxyz123456")
    end
  end

  # ──────────────────────────────────────────────
  # SecretScannerPlug — call/2 :query_post
  # ──────────────────────────────────────────────

  describe "SecretScannerPlug.call/2 with :query_post event" do
    test "redacts secret in last assistant message and sets :secrets_redacted" do
      messages = [
        %{role: "user", content: "What is my key?"},
        %{role: "assistant", content: "Your key is AKIAIOSFODNN7EXAMPLE"}
      ]

      ctx = build_query_post_context(messages)
      result = SecretScannerPlug.call(ctx, [])
      last_msg = List.last(result.data.messages)
      refute String.contains?(last_msg.content, "AKIAIOSFODNN7EXAMPLE")
      assert String.contains?(last_msg.content, "[REDACTED:AWS_KEY]")
      assert result.assigns.secrets_redacted > 0
    end

    test "passes context through unchanged when last assistant message is clean" do
      messages = [
        %{role: "user", content: "Hello"},
        %{role: "assistant", content: "Hello! How can I help you?"}
      ]

      ctx = build_query_post_context(messages)
      result = SecretScannerPlug.call(ctx, [])
      last_msg = List.last(result.data.messages)
      assert last_msg.content == "Hello! How can I help you?"
      refute Map.has_key?(result.assigns, :secrets_redacted)
    end

    test "passes context through unchanged when messages list is empty" do
      ctx = build_query_post_context([])
      result = SecretScannerPlug.call(ctx, [])
      assert result.data.messages == []
      refute Map.has_key?(result.assigns, :secrets_redacted)
    end

    test "does not redact when last message is a user message" do
      messages = [
        %{role: "assistant", content: "Some clean response"},
        %{role: "user", content: "Here is my key AKIAIOSFODNN7EXAMPLE"}
      ]

      ctx = build_query_post_context(messages)
      result = SecretScannerPlug.call(ctx, [])
      last_msg = List.last(result.data.messages)
      # Plug only redacts assistant messages; user message must be untouched.
      assert last_msg.content == "Here is my key AKIAIOSFODNN7EXAMPLE"
      refute Map.has_key?(result.assigns, :secrets_redacted)
    end
  end

  # ──────────────────────────────────────────────
  # SecretScannerPlug — call/2 unknown event
  # ──────────────────────────────────────────────

  describe "SecretScannerPlug.call/2 with unknown event" do
    test "passes context through unchanged for :session_starting event" do
      ctx = %Context{
        event: :session_starting,
        data: %{session_id: "sess-123", config: %{}},
        assigns: %{},
        halted: false,
        private: %{},
        timestamp: DateTime.utc_now()
      }

      result = SecretScannerPlug.call(ctx, [])
      assert result == ctx
    end

    test "passes context through unchanged for :workspace_created event" do
      ctx = %Context{
        event: :workspace_created,
        data: %{workspace: %{}},
        assigns: %{},
        halted: false,
        private: %{},
        timestamp: DateTime.utc_now()
      }

      result = SecretScannerPlug.call(ctx, [])
      assert result == ctx
    end
  end

  # ──────────────────────────────────────────────
  # Helpers
  # ──────────────────────────────────────────────

  defp build_query_pre_context(prompt) do
    %Context{
      event: :query_pre,
      data: %{prompt: prompt, workspace_id: "test-workspace-001"},
      assigns: %{},
      halted: false,
      private: %{},
      timestamp: DateTime.utc_now()
    }
  end

  defp build_query_post_context(messages) do
    %Context{
      event: :query_post,
      data: %{
        workspace_id: "test-workspace-001",
        prompt: "original prompt",
        messages: messages
      },
      assigns: %{},
      halted: false,
      private: %{},
      timestamp: DateTime.utc_now()
    }
  end
end
