defmodule MonkeyClaw.Webhooks.Verifiers.Mattermost do
  @moduledoc """
  Verifier for Mattermost outgoing webhook tokens.

  Mattermost uses a plain shared token rather than HMAC signing.
  The token is sent in the POST request body field `token` and compared
  against the endpoint's signing secret in constant time. The raw body
  is not used for verification.

  ## Body Fields

    * `token` — Required. Plain-text secret token
    * `trigger_word` — Event type (the word that triggered the outgoing webhook)
    * `post_id` — Unique ID of the triggering post (used as delivery ID)

  ## Security Note

  Mattermost's scheme is weaker than HMAC-based signing because the
  full secret is transmitted in every request body in plaintext.
  MonkeyClaw enforces TLS for all webhook endpoints, mitigating the
  plaintext exposure risk. Constant-time comparison prevents timing
  attacks against the token value.

  Reference: https://developers.mattermost.com/integrate/webhooks/outgoing/
  """

  @behaviour MonkeyClaw.Webhooks.Verifier

  alias MonkeyClaw.Webhooks.Security

  @max_field_length 255

  # ── verify ─────────────────────────────────────────────────

  @impl true
  @spec verify(String.t(), Plug.Conn.t(), binary()) :: :ok | {:error, :unauthorized}
  def verify(secret, conn, _raw_body)
      when is_binary(secret) and byte_size(secret) > 0 do
    case conn.body_params do
      %{"token" => token} when is_binary(token) and byte_size(token) > 0 ->
        if Security.constant_time_compare(token, secret) do
          :ok
        else
          {:error, :unauthorized}
        end

      _ ->
        {:error, :unauthorized}
    end
  end

  # ── extract_event_type ─────────────────────────────────────

  @impl true
  @spec extract_event_type(Plug.Conn.t()) :: {:ok, String.t()} | {:error, :invalid_event_type}
  def extract_event_type(conn) do
    case conn.body_params do
      %{"trigger_word" => word}
      when is_binary(word) and byte_size(word) > 0 and
             byte_size(word) <= @max_field_length ->
        {:ok, word}

      %{"trigger_word" => _} ->
        {:error, :invalid_event_type}

      _ ->
        {:ok, "unknown"}
    end
  end

  # ── extract_delivery_id ────────────────────────────────────

  @impl true
  @spec extract_delivery_id(Plug.Conn.t()) :: {:ok, String.t() | nil}
  def extract_delivery_id(conn) do
    case conn.body_params do
      %{"post_id" => id} when is_binary(id) and byte_size(id) > 0 ->
        {:ok, id}

      _ ->
        {:ok, nil}
    end
  end
end
