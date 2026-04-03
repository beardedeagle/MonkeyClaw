defmodule MonkeyClaw.Webhooks.Security do
  @moduledoc """
  Shared cryptographic utilities for webhook verification and
  source verifier dispatch.

  This module provides:

    * **Verifier dispatch** — `verifier_for/1` maps a source atom
      to its verification module
    * **HMAC computation** — Shared HMAC-SHA256 and HMAC-SHA1 used by
      multiple verifiers
    * **Constant-time comparison** — Prevents timing side-channel attacks
    * **Timestamp validation** — Shared freshness check for
      timestamp-aware signing schemes
    * **MonkeyClaw header utilities** — `compute_signature/3` and
      `build_signature_header/3` for the native signing format
    * **Payload hashing** — SHA-256 hash for audit logging

  Source-specific verification logic lives in
  `MonkeyClaw.Webhooks.Verifiers.*` modules implementing the
  `MonkeyClaw.Webhooks.Verifier` behaviour.

  ## Design

  This module is NOT a process. All functions are pure (no side effects)
  except for `System.os_time/1` in timestamp validation.
  """

  alias MonkeyClaw.Webhooks.Verifiers

  # Maximum age of a webhook signature before rejection (5 minutes).
  @timestamp_tolerance_seconds 300

  # ── Verifier Dispatch ──────────────────────────────────────

  @verifier_map %{
    generic: Verifiers.Generic,
    github: Verifiers.GitHub,
    gitlab: Verifiers.GitLab,
    slack: Verifiers.Slack,
    discord: Verifiers.Discord,
    bitbucket: Verifiers.Bitbucket,
    forgejo: Verifiers.Forgejo,
    stripe: Verifiers.Stripe,
    twilio: Verifiers.Twilio,
    linear: Verifiers.Linear,
    sentry: Verifiers.Sentry,
    pagerduty: Verifiers.PagerDuty,
    vercel: Verifiers.Vercel,
    netlify: Verifiers.Netlify,
    circleci: Verifiers.CircleCI,
    mattermost: Verifiers.Mattermost
  }

  @doc """
  Return the verifier module for a webhook source.

  Raises `ArgumentError` for unknown sources — this is a contract
  violation (the source enum on `WebhookEndpoint` constrains valid
  values at the schema level).

  ## Examples

      Security.verifier_for(:github)
      #=> MonkeyClaw.Webhooks.Verifiers.GitHub

      Security.verifier_for(:generic)
      #=> MonkeyClaw.Webhooks.Verifiers.Generic
  """
  @spec verifier_for(atom()) :: module()
  def verifier_for(source) when is_atom(source) do
    case Map.fetch(@verifier_map, source) do
      {:ok, module} ->
        module

      :error ->
        raise ArgumentError,
              "unknown webhook source #{inspect(source)}, " <>
                "expected one of: #{inspect(Map.keys(@verifier_map))}"
    end
  end

  # ── Shared Crypto ──────────────────────────────────────────

  @doc """
  Compute HMAC-SHA256 and return as lowercase hex string.

  Shared utility used by multiple verifier implementations.

  ## Examples

      Security.hmac_sha256_hex("secret", "body")
      #=> "f9e66e179b6747ae54108f82f8ade8b3c25d76fd30afde6c395822c530196169"
  """
  @spec hmac_sha256_hex(String.t(), iodata()) :: String.t()
  def hmac_sha256_hex(secret, message) when is_binary(secret) do
    :crypto.mac(:hmac, :sha256, secret, message)
    |> Base.encode16(case: :lower)
  end

  @doc """
  Compute HMAC-SHA1 and return as lowercase hex string.

  Used by verifiers for sources that sign with SHA1 (Vercel).

  ## Examples

      Security.hmac_sha1_hex("secret", "body")
      #=> "e02afb4a8e2..." (40 hex chars)
  """
  @spec hmac_sha1_hex(String.t(), iodata()) :: String.t()
  def hmac_sha1_hex(secret, message) when is_binary(secret) do
    :crypto.mac(:hmac, :sha, secret, message)
    |> Base.encode16(case: :lower)
  end

  @doc """
  Compute HMAC-SHA1 and return as Base64-encoded string.

  Used by verifiers for sources that use Base64 signatures (Twilio).

  ## Examples

      Security.hmac_sha1_base64("secret", "body")
      #=> "4GtuVf1..." (Base64 string)
  """
  @spec hmac_sha1_base64(String.t(), iodata()) :: String.t()
  def hmac_sha1_base64(secret, message) when is_binary(secret) do
    :crypto.mac(:hmac, :sha, secret, message)
    |> Base.encode64()
  end

  @doc """
  Constant-time string comparison to prevent timing attacks.

  Both values must be binaries. Returns `false` for different lengths
  without leaking which bytes differ.

  ## Examples

      Security.constant_time_compare("abc", "abc")
      #=> true

      Security.constant_time_compare("abc", "xyz")
      #=> false
  """
  @spec constant_time_compare(binary(), binary()) :: boolean()
  def constant_time_compare(a, b) when is_binary(a) and is_binary(b) do
    Plug.Crypto.secure_compare(a, b)
  end

  @doc """
  Validate that a timestamp is within the tolerance window.

  Returns `:ok` if the timestamp is within #{@timestamp_tolerance_seconds}
  seconds of the current time (past or future). Used by verifiers
  that include timestamps in their signing scheme (Generic, Slack).

  ## Examples

      Security.verify_timestamp(System.os_time(:second))
      #=> :ok

      Security.verify_timestamp(System.os_time(:second) - 600)
      #=> {:error, :expired_timestamp}
  """
  @spec verify_timestamp(integer()) :: :ok | {:error, :expired_timestamp}
  def verify_timestamp(timestamp) when is_integer(timestamp) do
    age = abs(System.os_time(:second) - timestamp)

    if age <= @timestamp_tolerance_seconds do
      :ok
    else
      {:error, :expired_timestamp}
    end
  end

  # ── MonkeyClaw Native Format ───────────────────────────────

  @doc """
  Compute the HMAC-SHA256 signature for a MonkeyClaw webhook payload.

  The signed message format is `"<timestamp>.<body>"`. This is the
  sender-side computation for the `:generic` source format.

  ## Examples

      timestamp = System.os_time(:second)
      signature = Security.compute_signature(secret, timestamp, body)
      header = "t=\#{timestamp},v1=\#{signature}"
  """
  @spec compute_signature(String.t(), integer(), binary()) :: String.t()
  def compute_signature(signing_secret, timestamp, raw_body)
      when is_binary(signing_secret) and is_integer(timestamp) and is_binary(raw_body) do
    hmac_sha256_hex(signing_secret, "#{timestamp}.#{raw_body}")
  end

  @doc """
  Build a complete MonkeyClaw signature header value.

  Format: `t=<timestamp>,v1=<hex_signature>`

  ## Examples

      Security.build_signature_header("secret", 1_234_567_890, "body")
      #=> "t=1234567890,v1=..."
  """
  @spec build_signature_header(String.t(), integer(), binary()) :: String.t()
  def build_signature_header(signing_secret, timestamp, raw_body) do
    signature = compute_signature(signing_secret, timestamp, raw_body)
    "t=#{timestamp},v1=#{signature}"
  end

  @doc """
  Compute the SHA-256 hash of a payload for audit logging.

  Returns a lowercase hex-encoded string.

  ## Examples

      Security.hash_payload("test")
      #=> "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"
  """
  @spec hash_payload(binary()) :: String.t()
  def hash_payload(raw_body) when is_binary(raw_body) do
    :crypto.hash(:sha256, raw_body)
    |> Base.encode16(case: :lower)
  end
end
