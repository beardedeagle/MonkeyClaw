defmodule MonkeyClaw.Webhooks.Verifiers.Netlify do
  @moduledoc """
  Verifier for Netlify webhook signatures.

  Netlify signs webhook payloads using JWS (JSON Web Signature) with
  the HS256 (HMAC-SHA256) algorithm. The full JWT token is delivered
  in the `x-webhook-signature` header.

  ## Headers

    * `x-webhook-signature` — Required. A full JWT token with three
      Base64URL-encoded segments: `header.payload.signature`

  ## JWT Claims

    * `iss` — Must be `"netlify"`
    * `sha256` — Hex-encoded SHA-256 hash of the raw request body

  ## Signed Message

  The HMAC-SHA256 is computed over `"<header_b64>.<payload_b64>"` —
  the first two dot-separated segments of the JWT, exactly as they
  appear in the token (before decoding). The signing key is the
  webhook's signing secret.

  ## Event and Delivery ID

  Netlify is URL-routed — one endpoint per event type. No event type
  header is provided; `extract_event_type/1` always returns
  `{:ok, "unknown"}`. No delivery ID is provided; `extract_delivery_id/1`
  always returns `{:ok, nil}`.

  ## Security Properties

    * Constant-time comparison on both the HMAC and body hash prevents
      timing side-channel attacks
    * All failure modes return `{:error, :unauthorized}` — no
      information leakage
    * Header length is bounded to prevent abuse

  Reference: https://docs.netlify.com/deploy/deploy-notifications/
  """

  @behaviour MonkeyClaw.Webhooks.Verifier

  alias MonkeyClaw.Webhooks.Security

  @signature_header "x-webhook-signature"

  # JWTs include Base64URL-encoded JSON plus HMAC — 2048 is generous.
  @max_header_length 2048

  # ── verify ─────────────────────────────────────────────────

  @impl true
  @spec verify(String.t(), Plug.Conn.t(), binary()) :: :ok | {:error, :unauthorized}
  def verify(secret, conn, raw_body)
      when is_binary(secret) and byte_size(secret) > 0 and is_binary(raw_body) do
    with {:ok, token} <- extract_token(conn),
         {:ok, body_hash_claim} <- decode_jwt(secret, token),
         expected_hash = Security.hash_payload(raw_body),
         true <- Security.constant_time_compare(expected_hash, body_hash_claim) do
      :ok
    else
      _ -> {:error, :unauthorized}
    end
  end

  # ── extract_event_type ─────────────────────────────────────

  @impl true
  @spec extract_event_type(Plug.Conn.t()) :: {:ok, String.t()}
  def extract_event_type(_conn) do
    {:ok, "unknown"}
  end

  # ── extract_delivery_id ────────────────────────────────────

  @impl true
  @spec extract_delivery_id(Plug.Conn.t()) :: {:ok, nil}
  def extract_delivery_id(_conn) do
    {:ok, nil}
  end

  # ── Private ────────────────────────────────────────────────

  @spec extract_token(Plug.Conn.t()) :: {:ok, String.t()} | {:error, :missing_signature}
  defp extract_token(conn) do
    case Plug.Conn.get_req_header(conn, @signature_header) do
      [token]
      when is_binary(token) and byte_size(token) > 0 and
             byte_size(token) <= @max_header_length ->
        {:ok, token}

      _ ->
        {:error, :missing_signature}
    end
  end

  @doc false
  @spec decode_jwt(String.t(), String.t()) :: {:ok, String.t()} | {:error, :invalid_jwt}
  defp decode_jwt(secret, token) do
    case String.split(token, ".") do
      [header_b64, payload_b64, sig_b64] ->
        with {:ok, _alg} <- verify_jwt_header(header_b64),
             {:ok, body_hash_claim} <- verify_jwt_payload(payload_b64),
             :ok <- verify_jwt_signature(secret, header_b64, payload_b64, sig_b64) do
          {:ok, body_hash_claim}
        end

      _ ->
        {:error, :invalid_jwt}
    end
  end

  @spec verify_jwt_header(String.t()) :: {:ok, String.t()} | {:error, :invalid_jwt}
  defp verify_jwt_header(header_b64) do
    with {:ok, json} <- base64url_decode(header_b64),
         {:ok, %{"alg" => "HS256"}} <- Jason.decode(json) do
      {:ok, "HS256"}
    else
      _ -> {:error, :invalid_jwt}
    end
  end

  @spec verify_jwt_payload(String.t()) :: {:ok, String.t()} | {:error, :invalid_jwt}
  defp verify_jwt_payload(payload_b64) do
    with {:ok, json} <- base64url_decode(payload_b64),
         {:ok, %{"iss" => "netlify", "sha256" => hash}} when is_binary(hash) <-
           Jason.decode(json) do
      {:ok, hash}
    else
      _ -> {:error, :invalid_jwt}
    end
  end

  @spec verify_jwt_signature(String.t(), String.t(), String.t(), String.t()) ::
          :ok | {:error, :invalid_jwt}
  defp verify_jwt_signature(secret, header_b64, payload_b64, sig_b64) do
    case base64url_decode(sig_b64) do
      {:ok, sig_bytes} ->
        computed = :crypto.mac(:hmac, :sha256, secret, "#{header_b64}.#{payload_b64}")

        if Security.constant_time_compare(computed, sig_bytes) do
          :ok
        else
          {:error, :invalid_jwt}
        end

      _ ->
        {:error, :invalid_jwt}
    end
  end

  @spec base64url_decode(String.t()) :: {:ok, binary()} | {:error, :invalid_base64url}
  defp base64url_decode(input) do
    standard =
      input
      |> String.replace("-", "+")
      |> String.replace("_", "/")
      |> pad_base64()

    case Base.decode64(standard) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, :invalid_base64url}
    end
  end

  @spec pad_base64(String.t()) :: String.t()
  defp pad_base64(str) do
    case rem(byte_size(str), 4) do
      0 -> str
      2 -> str <> "=="
      3 -> str <> "="
      _ -> str
    end
  end
end
