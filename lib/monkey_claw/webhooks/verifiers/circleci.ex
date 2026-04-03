defmodule MonkeyClaw.Webhooks.Verifiers.CircleCI do
  @moduledoc """
  Verifier for CircleCI webhook signatures.

  CircleCI signs webhook payloads with HMAC-SHA256 using the webhook's
  signing secret. The signature is sent in the `circleci-signature`
  header as a comma-separated list of versioned components, e.g.
  `v1=<hex_hmac_sha256>`. Only the `v1` component is used for
  verification; additional components in the list are ignored.

  ## Headers

    * `circleci-signature` — Required. Comma-separated versioned
      signatures, e.g. `v1=<hex_hmac_sha256>`
    * `circleci-event-type` — Event type (e.g., `"workflow-completed"`,
      `"job-completed"`). Defaults to `"unknown"` if absent.

  ## Delivery ID

  CircleCI does not send a delivery ID header. The unique identifier
  for each event is the `id` field in the JSON body.

  ## Signed Message

  The raw request body is signed directly — no timestamp component.
  CircleCI does not include timestamp-based freshness; replay
  protection relies on the unique event `id` in the body.

  Reference: https://circleci.com/docs/guides/integration/outbound-webhooks/
  """

  @behaviour MonkeyClaw.Webhooks.Verifier

  alias MonkeyClaw.Webhooks.Security

  @signature_header "circleci-signature"
  @event_header "circleci-event-type"

  @max_header_length 512

  # ── verify ─────────────────────────────────────────────────

  @impl true
  @spec verify(String.t(), Plug.Conn.t(), binary()) :: :ok | {:error, :unauthorized}
  def verify(secret, conn, raw_body)
      when is_binary(secret) and byte_size(secret) > 0 and is_binary(raw_body) do
    with {:ok, provided} <- extract_signature(conn),
         expected = Security.hmac_sha256_hex(secret, raw_body),
         true <- Security.constant_time_compare(expected, provided) do
      :ok
    else
      _ -> {:error, :unauthorized}
    end
  end

  # ── extract_event_type ─────────────────────────────────────

  @impl true
  @spec extract_event_type(Plug.Conn.t()) ::
          {:ok, String.t()} | {:error, :invalid_event_type}
  def extract_event_type(conn) do
    case Plug.Conn.get_req_header(conn, @event_header) do
      [] ->
        {:ok, "unknown"}

      [event_type]
      when is_binary(event_type) and byte_size(event_type) > 0 and
             byte_size(event_type) <= @max_header_length ->
        {:ok, event_type}

      _ ->
        {:error, :invalid_event_type}
    end
  end

  # ── extract_delivery_id ────────────────────────────────────

  @impl true
  @spec extract_delivery_id(Plug.Conn.t()) :: {:ok, String.t() | nil}
  def extract_delivery_id(conn) do
    case conn.body_params do
      %{"id" => id} when is_binary(id) and byte_size(id) > 0 ->
        {:ok, id}

      _ ->
        {:ok, nil}
    end
  end

  # ── Private ────────────────────────────────────────────────

  @spec extract_signature(Plug.Conn.t()) ::
          {:ok, String.t()} | {:error, :missing_signature}
  defp extract_signature(conn) do
    case Plug.Conn.get_req_header(conn, @signature_header) do
      [header]
      when is_binary(header) and byte_size(header) > 0 and
             byte_size(header) <= @max_header_length ->
        parse_v1_signature(header)

      _ ->
        {:error, :missing_signature}
    end
  end

  @spec parse_v1_signature(String.t()) ::
          {:ok, String.t()} | {:error, :missing_signature}
  defp parse_v1_signature(header) do
    result =
      header
      |> String.split(",")
      |> Enum.find_value(fn part ->
        case String.trim(part) do
          "v1=" <> hex_sig when byte_size(hex_sig) == 64 -> hex_sig
          _ -> nil
        end
      end)

    case result do
      nil -> {:error, :missing_signature}
      hex_sig -> {:ok, hex_sig}
    end
  end
end
