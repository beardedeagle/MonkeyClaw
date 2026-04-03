defmodule MonkeyClaw.Webhooks.Verifier do
  @moduledoc """
  Behaviour for webhook source verification.

  Each webhook source (GitHub, Slack, GitLab, etc.) implements this
  behaviour to define how incoming requests are authenticated and
  how event metadata is extracted from source-specific headers.

  ## Callbacks

    * `verify/3` — Authenticate the request using the source's
      signature scheme (HMAC-SHA256, Ed25519, token comparison, etc.)
    * `extract_event_type/1` — Extract the event type from
      source-specific headers or body
    * `extract_delivery_id/1` — Extract the unique delivery/request
      ID for replay detection

  ## Security Contract

  All verifier implementations MUST:

    * Return `{:error, :unauthorized}` for any authentication failure
    * Use constant-time comparison for secrets and signatures
    * Never leak error details (same error for all failure modes)
    * Validate header lengths to prevent abuse

  ## Built-in Verifiers

    * `MonkeyClaw.Webhooks.Verifiers.Generic` — MonkeyClaw native
      (Stripe-inspired `t=<ts>,v1=<hmac>`)
    * `MonkeyClaw.Webhooks.Verifiers.GitHub` — HMAC-SHA256, body only
    * `MonkeyClaw.Webhooks.Verifiers.GitLab` — Plain token comparison
    * `MonkeyClaw.Webhooks.Verifiers.Slack` — Versioned HMAC-SHA256
    * `MonkeyClaw.Webhooks.Verifiers.Discord` — Ed25519 public-key
    * `MonkeyClaw.Webhooks.Verifiers.Bitbucket` — HMAC-SHA256, body only
    * `MonkeyClaw.Webhooks.Verifiers.Forgejo` — HMAC-SHA256, body only
      (also supports Gitea and Codeberg)

  ## Design

  This is NOT a process. Verifiers are stateless modules with pure
  functions (except for timestamp checks that read system time).
  """

  @type conn :: Plug.Conn.t()

  @doc """
  Verify the request's signature or authentication token.

  Returns `:ok` on success, `{:error, :unauthorized}` on any failure.
  The error is intentionally opaque — callers must not distinguish
  between failure modes.
  """
  @callback verify(secret :: String.t(), conn :: conn(), raw_body :: binary()) ::
              :ok | {:error, :unauthorized}

  @doc """
  Extract the event type from request headers or body.

  Returns the event type string, or `"unknown"` if the source does
  not provide one. Returns `{:error, :invalid_event_type}` only for
  malformed values (empty string, exceeds length limit).
  """
  @callback extract_event_type(conn :: conn()) ::
              {:ok, String.t()} | {:error, :invalid_event_type}

  @doc """
  Extract the delivery/request ID for replay detection.

  Sources that provide unique delivery IDs (GitHub, Bitbucket,
  Forgejo) return them here for use as idempotency keys. Sources
  without delivery IDs return `{:ok, nil}`.
  """
  @callback extract_delivery_id(conn :: conn()) ::
              {:ok, String.t() | nil} | {:error, :invalid_delivery_id}
end
