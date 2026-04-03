defmodule MonkeyClaw.Webhooks.Verifiers.GitLab do
  @moduledoc """
  Verifier for GitLab webhook tokens.

  GitLab uses a simple shared secret token rather than HMAC signing.
  The token is sent in the `X-Gitlab-Token` header and compared
  against the endpoint's signing secret in constant time.

  ## Headers

    * `X-Gitlab-Token` — Required. Plain-text secret token
    * `X-Gitlab-Event` — Event type (e.g., `Push Hook`, `Merge Request Hook`)

  ## Security Note

  GitLab's scheme is weaker than HMAC-based signing because the
  full secret is sent in every request header. MonkeyClaw enforces
  TLS for all webhook endpoints, mitigating the plaintext exposure
  risk. Constant-time comparison prevents timing attacks against
  the token value.

  Reference: https://docs.gitlab.com/ee/user/project/integrations/webhooks.html
  """

  @behaviour MonkeyClaw.Webhooks.Verifier

  alias MonkeyClaw.Webhooks.Security

  @token_header "x-gitlab-token"
  @event_header "x-gitlab-event"

  @max_header_length 255

  # ── verify ─────────────────────────────────────────────────

  @impl true
  def verify(secret, conn, _raw_body)
      when is_binary(secret) and byte_size(secret) > 0 do
    case Plug.Conn.get_req_header(conn, @token_header) do
      [token] when is_binary(token) and byte_size(token) > 0 ->
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
  def extract_event_type(conn) do
    case Plug.Conn.get_req_header(conn, @event_header) do
      [event]
      when is_binary(event) and byte_size(event) > 0 and
             byte_size(event) <= @max_header_length ->
        {:ok, event}

      [] ->
        {:ok, "unknown"}

      _ ->
        {:error, :invalid_event_type}
    end
  end

  # ── extract_delivery_id ────────────────────────────────────

  @impl true
  def extract_delivery_id(_conn) do
    # GitLab does not provide a unique per-delivery ID header.
    {:ok, nil}
  end
end
