defmodule MonkeyClawWeb.ChannelWebhookController do
  @moduledoc """
  HTTP controller for receiving inbound channel webhook deliveries.

  Routes incoming POST requests from external platforms (Slack, Discord,
  Telegram) through the channel adapter's verification and parsing
  pipeline:

    1. Channel config lookup (enabled only)
    2. Adapter resolution
    3. Request signature verification (adapter-specific)
    4. Inbound message parsing (adapter-specific)
    5. Dispatch to agent via `Dispatcher.handle_inbound/3`

  ## Verification Challenge Support

  Some platforms (Slack URL verification, Discord PING) require an
  immediate response during webhook setup. The controller detects
  challenge responses from `Dispatcher.handle_inbound/3` and returns
  them directly with the appropriate content type.

  ## Error Response Design

  Error responses are deliberately opaque to prevent information leakage:

    * **404** — Config not found, disabled, or unknown adapter
    * **401** — Signature verification failed
    * **422** — Could not parse inbound message
    * **500** — Internal processing error

  ## Design

  This is a standard Phoenix controller. It is NOT a process. Each
  request runs in the Bandit connection process.
  """

  use MonkeyClawWeb, :controller

  require Logger

  alias MonkeyClaw.Channels
  alias MonkeyClaw.Channels.Dispatcher
  alias MonkeyClawWeb.Plugs.CacheBodyReader

  @doc """
  Receive and process an inbound channel webhook delivery.

  Looks up the channel config, verifies the request signature via the
  adapter, and dispatches the parsed message to the agent workflow.
  """
  @spec receive(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def receive(conn, %{"channel_config_id" => config_id}) do
    with {:config, {:ok, config}} <- {:config, Channels.get_config(config_id)},
         {:enabled, true} <- {:enabled, config.enabled} do
      raw_body = CacheBodyReader.get_raw_body(conn)

      # Pass the full conn to the dispatcher — adapters use
      # Plug.Conn.get_req_header/2 for signature verification.
      case Dispatcher.handle_inbound(config, conn, raw_body) do
        {:ok, :accepted} ->
          conn
          |> put_status(:accepted)
          |> json(%{status: "accepted"})

        {:ok, :challenge, challenge_response} ->
          # Platform verification challenge (e.g., Slack url_verification)
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!(challenge_response))

        {:error, :verification_failed} ->
          conn
          |> put_status(:unauthorized)
          |> json(%{error: "unauthorized"})

        {:error, :parse_failed} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: "unprocessable"})

        {:error, reason} ->
          Logger.warning(
            "Channel webhook processing failed for config #{config_id}: #{inspect(reason)}"
          )

          conn
          |> put_status(:internal_server_error)
          |> json(%{error: "internal_error"})
      end
    else
      {:config, {:error, :not_found}} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "not_found"})

      {:enabled, false} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "not_found"})
    end
  end
end
