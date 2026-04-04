defmodule MonkeyClaw.Vault.SecretScanner do
  @moduledoc """
  Regex-based secret detection and redaction for content flowing
  through the extension pipeline.

  SecretScanner scans arbitrary text for 14 categories of secrets —
  API keys, tokens, private keys, passwords, and webhook URLs — and
  can redact discovered values with opaque `[REDACTED:LABEL]`
  placeholders. Used by `SecretScannerPlug` on both inbound prompts
  (`:query_pre`) and outbound assistant responses (`:query_post`)
  to prevent secret leakage in either direction.

  ## Security Properties

    * All 14 regex patterns are pre-compiled at module load time as
      module attributes, eliminating per-call compilation overhead.
    * Scanning is bounded by a configurable `max_bytes` limit (default
      1 MiB) to prevent resource exhaustion on pathological inputs.
    * Scanning runs inside a `Task` with a configurable `timeout_ms`
      (default 100 ms). If the task exceeds the timeout it is shut
      down and `{:error, :timeout}` is returned, preventing slow
      regexes from blocking the caller.
    * Redaction processes findings in reverse byte-offset order so
      that replacing earlier matches does not invalidate the offsets
      of later ones.

  ## Usage

      iex> {:ok, findings} = MonkeyClaw.Vault.SecretScanner.scan("token: sk-abc123...")
      iex> redacted = MonkeyClaw.Vault.SecretScanner.redact(content, findings)
      iex> {:ok, redacted, count} = MonkeyClaw.Vault.SecretScanner.scan_and_redact(content)

  ## Design

  This is NOT a process. All functions are pure or side-effect-free
  (modulo `Task` for timeout). No state, no GenServer, no supervision
  required.
  """

  @type severity :: :critical | :high | :medium

  @type finding :: %{
          pattern: String.t(),
          label: String.t(),
          severity: severity(),
          start_byte: non_neg_integer(),
          end_byte: non_neg_integer(),
          match: String.t()
        }

  @default_timeout_ms 100
  @default_max_bytes 1_048_576

  # ── Pre-compiled pattern definitions ────────────────────────────

  @patterns [
    %{
      name: "AWS_ACCESS_KEY_ID",
      pattern: Regex.compile!("\\b(A[SK]IA[A-Z0-9]{16})\\b"),
      label: "AWS_KEY",
      severity: :high
    },
    %{
      name: "AWS_SECRET_ACCESS_KEY",
      pattern:
        Regex.compile!(
          "(?i)(?:aws[_\\-]?secret[_\\-]?access[_\\-]?key|aws[_\\-]?secret)\\s*[:=]\\s*([A-Za-z0-9\\/+=]{40})"
        ),
      label: "AWS_SECRET",
      severity: :critical
    },
    %{
      name: "GITHUB_TOKEN",
      pattern: Regex.compile!("\\b(gh[pocs]_[A-Za-z0-9_]{20,80})\\b"),
      label: "GITHUB_TOKEN",
      severity: :high
    },
    %{
      name: "GITHUB_PAT",
      pattern: Regex.compile!("\\b(github_pat_[A-Za-z0-9_]{20,120})\\b"),
      label: "GITHUB_TOKEN",
      severity: :high
    },
    %{
      name: "SLACK_TOKEN",
      pattern: Regex.compile!("\\b(xox[bpas]-[A-Za-z0-9\\-]{10,64})\\b"),
      label: "SLACK_TOKEN",
      severity: :high
    },
    %{
      name: "STRIPE_KEY",
      pattern: Regex.compile!("\\b(sk_(?:live|test)_[A-Za-z0-9]{24,64})\\b"),
      label: "STRIPE_KEY",
      severity: :critical
    },
    %{
      name: "PRIVATE_KEY",
      pattern:
        Regex.compile!("-----BEGIN\\s+(?:RSA\\s+|EC\\s+|DSA\\s+|OPENSSH\\s+)?PRIVATE\\s+KEY-----"),
      label: "PRIVATE_KEY",
      severity: :critical
    },
    %{
      name: "OPENAI_KEY",
      pattern: Regex.compile!("\\b(sk-[A-Za-z0-9]{32,})\\b"),
      label: "OPENAI_KEY",
      severity: :high
    },
    %{
      name: "ANTHROPIC_KEY",
      pattern: Regex.compile!("\\b(sk-ant-[A-Za-z0-9\\-]{32,})\\b"),
      label: "ANTHROPIC_KEY",
      severity: :high
    },
    %{
      name: "GENERIC_API_KEY",
      pattern:
        Regex.compile!(
          "(?i)(?:api[_\\-]?key|apikey)\\s*[:=]\\s*[\"']?([A-Za-z0-9_\\-]{20,})[\"']?"
        ),
      label: "API_KEY",
      severity: :medium
    },
    %{
      name: "BEARER_TOKEN",
      pattern:
        Regex.compile!(
          "(?i)(?:authorization|bearer)\\s*[:=]?\\s*(?:bearer\\s+)?([A-Za-z0-9_\\-.]{20,})"
        ),
      label: "BEARER_TOKEN",
      severity: :medium
    },
    %{
      name: "PASSWORD_URL",
      pattern: Regex.compile!("://[^:]+:([^@]{8,})@"),
      label: "PASSWORD",
      severity: :high
    },
    %{
      name: "GOOGLE_API_KEY",
      pattern: Regex.compile!("\\b(AIza[A-Za-z0-9_\\-]{35})\\b"),
      label: "GOOGLE_KEY",
      severity: :high
    },
    %{
      name: "SLACK_WEBHOOK",
      pattern:
        Regex.compile!(
          "https://hooks\\.slack\\.com/services/T[A-Z0-9]{8,}/B[A-Z0-9]{8,}/[A-Za-z0-9]{20,}"
        ),
      label: "SLACK_WEBHOOK",
      severity: :high
    }
  ]

  # ── Public API ───────────────────────────────────────────────────

  @doc """
  Scan `content` for secrets.

  Runs all 14 patterns against `content` and returns a list of
  findings. Each finding includes the pattern name, label, severity,
  byte offsets, and the matched string.

  ## Options

    * `:timeout_ms` — Maximum milliseconds for the scan task
      (default: #{@default_timeout_ms}).
    * `:max_bytes` — Maximum byte size of `content` to accept
      (default: #{@default_max_bytes}). Content exceeding this limit
      returns `{:error, :content_too_large}` immediately without
      spawning a task.

  ## Return values

    * `{:ok, findings}` — Scan completed; `findings` may be empty.
    * `{:error, :content_too_large}` — `content` exceeds `max_bytes`.
    * `{:error, :timeout}` — Scan exceeded `timeout_ms`.
    * `{:error, :scan_crashed}` — Scan task exited abnormally.
  """
  @spec scan(String.t(), keyword()) ::
          {:ok, [finding()]}
          | {:error, :content_too_large}
          | {:error, :timeout}
          | {:error, :scan_crashed}
  def scan(content, opts \\ []) when is_binary(content) and is_list(opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)

    if byte_size(content) > max_bytes do
      {:error, :content_too_large}
    else
      task = Task.async(fn -> run_scan(content) end)

      case Task.yield(task, timeout_ms) do
        {:ok, findings} ->
          {:ok, findings}

        {:exit, _reason} ->
          {:error, :scan_crashed}

        nil ->
          _ = Task.shutdown(task, :brutal_kill)
          {:error, :timeout}
      end
    end
  end

  @doc """
  Redact all `findings` from `content`.

  Replaces each matched secret with `[REDACTED:LABEL]`. Findings are
  processed in reverse byte-offset order so that substituting a match
  does not shift the byte positions of earlier matches.

  Returns the redacted string. If `findings` is empty the original
  `content` is returned unchanged.
  """
  @spec redact(String.t(), [finding()]) :: String.t()
  def redact(content, findings) when is_binary(content) and is_list(findings) do
    findings
    |> Enum.sort_by(& &1.start_byte, :desc)
    |> Enum.reduce(content, fn finding, acc ->
      placeholder = "[REDACTED:#{finding.label}]"
      binary_replace(acc, finding.start_byte, finding.end_byte, placeholder)
    end)
  end

  @doc """
  Scan `content` for secrets and return a redacted copy.

  Convenience function that calls `scan/2` then `redact/2`.

  ## Options

  Accepts the same options as `scan/2`.

  ## Return values

    * `{:ok, redacted_content, finding_count}` — Scan completed.
      `redacted_content` has all secrets replaced with
      `[REDACTED:LABEL]` placeholders. `finding_count` is the
      number of secrets found (0 when content is clean).
    * `{:error, :content_too_large}` — Content exceeds `max_bytes`.
    * `{:error, :timeout}` — Scan exceeded `timeout_ms`.
  """
  @spec scan_and_redact(String.t(), keyword()) ::
          {:ok, String.t(), non_neg_integer()}
          | {:error, :content_too_large}
          | {:error, :timeout}
  def scan_and_redact(content, opts \\ []) when is_binary(content) and is_list(opts) do
    case scan(content, opts) do
      {:ok, findings} ->
        redacted = redact(content, findings)
        {:ok, redacted, length(findings)}

      {:error, _} = error ->
        error
    end
  end

  # ── Private ──────────────────────────────────────────────────────

  @spec run_scan(String.t()) :: [finding()]
  defp run_scan(content) do
    Enum.flat_map(@patterns, fn pattern_def ->
      scan_pattern(content, pattern_def)
    end)
  end

  @spec scan_pattern(String.t(), map()) :: [finding()]
  defp scan_pattern(content, %{name: name, pattern: regex, label: label, severity: severity}) do
    regex
    |> Regex.scan(content, return: :index)
    |> Enum.map(fn [{start, length} | _captures] ->
      matched = binary_part(content, start, length)

      %{
        pattern: name,
        label: label,
        severity: severity,
        start_byte: start,
        end_byte: start + length,
        match: matched
      }
    end)
  end

  @spec binary_replace(String.t(), non_neg_integer(), non_neg_integer(), String.t()) :: String.t()
  defp binary_replace(content, start_byte, end_byte, replacement) do
    prefix = binary_part(content, 0, start_byte)
    suffix_start = end_byte
    suffix_length = byte_size(content) - suffix_start
    suffix = binary_part(content, suffix_start, suffix_length)
    prefix <> replacement <> suffix
  end
end
