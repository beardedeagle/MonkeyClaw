defmodule MonkeyClaw.Webhooks.Dispatcher do
  @moduledoc """
  Routes verified webhook events to agent workflows.

  After a webhook passes all security checks and is recorded in the
  delivery log, the Dispatcher formats the event data as an agent
  prompt and sends it through the standard Conversation workflow.
  This ensures extension hooks (recall, skills, user modeling) fire
  on webhook-triggered messages.

  ## Dispatch Flow

    1. Format the webhook event into a structured agent prompt
    2. Send through `Conversation.send_message/4` with a dedicated
       `"webhook:<endpoint_name>"` channel
    3. Update the delivery record with the processing result

  ## Async Execution

  `dispatch_async/4` runs dispatch in a supervised task under
  `MonkeyClaw.TaskSupervisor`. The webhook controller returns
  `202 Accepted` immediately — the agent processes the event
  in the background.

  ## Design

  This module is NOT a process. It is a stateless function module.
  Async execution is provided by `Task.Supervisor`, not by this module.
  """

  require Logger

  alias MonkeyClaw.Webhooks
  alias MonkeyClaw.Webhooks.WebhookDelivery
  alias MonkeyClaw.Webhooks.WebhookEndpoint
  alias MonkeyClaw.Workflows.Conversation

  @doc """
  Dispatch a webhook event asynchronously.

  Starts a supervised task that formats the event and sends it
  through the Conversation workflow. Returns `{:ok, pid}` for
  the background task.

  The delivery record is updated with `:processed` on success
  or `:failed` on error.
  """
  @spec dispatch_async(WebhookEndpoint.t(), String.t(), map(), WebhookDelivery.t()) ::
          {:ok, pid()}
  def dispatch_async(
        %WebhookEndpoint{} = endpoint,
        event_type,
        payload,
        %WebhookDelivery{} = delivery
      )
      when is_binary(event_type) and is_map(payload) do
    {:ok, pid} =
      Task.Supervisor.start_child(MonkeyClaw.TaskSupervisor, fn ->
        dispatch(endpoint, event_type, payload, delivery)
      end)

    {:ok, pid}
  end

  @doc """
  Dispatch a webhook event synchronously.

  Formats the event, sends it through the Conversation workflow,
  and updates the delivery record. Returns `:ok` on success or
  `{:error, reason}` on failure.

  Primarily used by `dispatch_async/4`. Can be called directly
  for testing or when synchronous processing is needed.
  """
  @spec dispatch(WebhookEndpoint.t(), String.t(), map(), WebhookDelivery.t()) ::
          :ok | {:error, term()}
  def dispatch(
        %WebhookEndpoint{} = endpoint,
        event_type,
        payload,
        %WebhookDelivery{} = delivery
      )
      when is_binary(event_type) and is_map(payload) do
    prompt = format_prompt(endpoint, event_type, payload)
    channel_name = webhook_channel_name(endpoint)

    :telemetry.execute(
      [:monkey_claw, :webhook, :dispatched],
      %{count: 1},
      %{endpoint_id: endpoint.id, event_type: event_type}
    )

    case Conversation.send_message(endpoint.workspace_id, channel_name, prompt) do
      {:ok, _result} ->
        Logger.info(
          "Webhook dispatched: endpoint=#{endpoint.id} event=#{event_type} delivery=#{delivery.id}"
        )

        _result =
          Webhooks.update_delivery(delivery, %{
            status: :processed,
            processed_at: DateTime.utc_now()
          })

        :ok

      {:error, reason} ->
        Logger.warning(
          "Webhook dispatch failed: endpoint=#{endpoint.id} event=#{event_type} reason=#{inspect(reason)}"
        )

        _result =
          Webhooks.update_delivery(delivery, %{
            status: :failed,
            rejection_reason: format_error(reason)
          })

        {:error, reason}
    end
  end

  # ── Private — Prompt Formatting ─────────────────────────────

  @spec format_prompt(WebhookEndpoint.t(), String.t(), map()) :: String.t()
  defp format_prompt(%WebhookEndpoint{} = endpoint, event_type, payload) do
    payload_text = format_payload(payload)

    """
    [Webhook received]
    Source: #{endpoint.name} (#{endpoint.source})
    Event: #{event_type}
    Time: #{DateTime.utc_now() |> DateTime.to_iso8601()}

    Payload:
    #{payload_text}\
    """
    |> String.trim()
  end

  @spec format_payload(map()) :: String.t()
  defp format_payload(payload) when map_size(payload) == 0, do: "(empty)"

  defp format_payload(payload) do
    case Jason.encode(payload, pretty: true) do
      {:ok, json} -> json
      {:error, _} -> inspect(payload, pretty: true, limit: 1000)
    end
  end

  # Each webhook endpoint gets its own conversation channel to keep
  # webhook conversations isolated from user-initiated chat.
  @spec webhook_channel_name(WebhookEndpoint.t()) :: String.t()
  defp webhook_channel_name(%WebhookEndpoint{name: name}) do
    "webhook:#{name}"
  end

  @spec format_error(term()) :: String.t()
  defp format_error(reason) do
    reason
    |> inspect(limit: 200)
    |> String.slice(0, 500)
  end
end
