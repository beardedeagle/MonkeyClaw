defmodule MonkeyClaw.Channels.Dispatcher do
  @moduledoc """
  Routes messages bi-directionally between channel adapters and AgentBridge.

  ## Inbound Flow (Platform → Agent)

  1. Webhook controller receives request from external platform
  2. Adapter verifies and parses the payload
  3. Dispatcher records the message and sends it to AgentBridge
  4. AgentBridge processes the query and returns a response
  5. Dispatcher sends the response back through the adapter

  ## Outbound Flow (Agent → Platform)

  1. Agent produces output (query response, notification, etc.)
  2. Dispatcher receives the event via PubSub or direct call
  3. Dispatcher resolves enabled channels for the workspace
  4. Each adapter sends the message to its platform

  ## Design

  This is a stateless function module, NOT a process. It coordinates
  the data flow between adapters, AgentBridge, and the Channels context
  using function calls and supervised tasks for async delivery.
  """

  require Logger

  alias MonkeyClaw.Channels
  alias MonkeyClaw.Channels.{Adapter, ChannelConfig, Telemetry}
  alias MonkeyClaw.Workflows.Conversation

  @doc """
  Handle an inbound message from an external platform.

  Verifies the request, parses the payload, records the message,
  and dispatches it to the agent. The agent's response is sent back
  through the same adapter asynchronously.

  Returns `{:ok, :accepted}` on success or `{:error, reason}` on failure.
  """
  @spec handle_inbound(ChannelConfig.t(), Plug.Conn.t(), binary()) ::
          {:ok, :accepted} | {:ok, :challenge, map()} | {:error, term()}
  def handle_inbound(%ChannelConfig{} = config, conn, raw_body)
      when is_binary(raw_body) do
    with {:ok, adapter_mod} <- Adapter.for_type(config.adapter_type),
         :ok <- adapter_mod.verify_request(config.config, conn, raw_body),
         {:ok, message} <- adapter_mod.parse_inbound(conn, raw_body) do
      handle_parsed_inbound(config, adapter_mod, message)
    end
  end

  @doc """
  Handle a pre-parsed inbound message from a persistent connection.

  Unlike `handle_inbound/3`, this bypasses HTTP request verification and
  payload parsing — persistent connections handle authentication at connect
  time and parse messages internally.
  """
  @spec handle_persistent_message(ChannelConfig.t(), map()) ::
          {:ok, :accepted} | {:ok, :challenge, map()}
  def handle_persistent_message(%ChannelConfig{} = config, message) when is_map(message) do
    handle_parsed_inbound(config, nil, message)
  end

  @doc """
  Deliver a message to all enabled channels for a workspace.

  Used for outbound delivery — when the agent produces output that
  should be sent to external platforms. Delivery happens asynchronously
  via supervised tasks.
  """
  @spec deliver_to_channels(String.t(), String.t()) :: :ok
  def deliver_to_channels(workspace_id, content) when is_binary(workspace_id) do
    configs = Channels.list_enabled_configs(workspace_id)
    message = %{content: content, metadata: %{}, external_id: nil}

    Enum.each(configs, fn config ->
      deliver_async(config, message)
    end)
  end

  @doc """
  Deliver a message to a specific channel.

  Used when targeting a single adapter (e.g., responding to an inbound
  message on the same channel).
  """
  @spec deliver_to_channel(ChannelConfig.t(), map()) :: :ok | {:error, term()}
  def deliver_to_channel(%ChannelConfig{} = config, message) when is_map(message) do
    with {:ok, adapter_mod} <- Adapter.for_type(config.adapter_type) do
      case adapter_mod.send_message(config.config, message) do
        :ok ->
          record_outbound(config, message)
          :ok

        {:error, reason} = error ->
          Telemetry.delivery_failed(%{
            adapter_type: config.adapter_type,
            workspace_id: config.workspace_id,
            reason: reason
          })

          error
      end
    end
  end

  # ── Private ───────────────────────────────────────────────────

  defp handle_parsed_inbound(_config, _adapter_mod, %{challenge: challenge}) do
    {:ok, :challenge, challenge}
  end

  defp handle_parsed_inbound(config, _adapter_mod, message) do
    Telemetry.message_inbound(%{
      adapter_type: config.adapter_type,
      workspace_id: config.workspace_id,
      channel_config_id: config.id
    })

    _ =
      Channels.record_message(config, %{
        direction: :inbound,
        content: message.content,
        metadata: message.metadata,
        external_id: message.external_id
      })

    _ = dispatch_to_agent_async(config, message)
    {:ok, :accepted}
  end

  defp dispatch_to_agent_async(%ChannelConfig{} = config, message) do
    Task.Supervisor.start_child(MonkeyClaw.TaskSupervisor, fn ->
      channel_label = "#{config.adapter_type}:#{config.name}"

      case Conversation.send_message(
             config.workspace_id,
             channel_label,
             message.content,
             []
           ) do
        {:ok, %{messages: messages}} ->
          response_text = extract_assistant_response(messages)

          response_message = %{
            content: response_text,
            metadata: %{in_reply_to: message.external_id},
            external_id: nil
          }

          deliver_to_channel(config, response_message)

        {:error, reason} ->
          Logger.warning("Channel dispatch failed for #{channel_label}: #{inspect(reason)}")
      end
    end)
  end

  defp extract_assistant_response(messages) when is_list(messages) do
    messages
    |> Enum.filter(fn
      %{role: "assistant"} -> true
      %{"role" => "assistant"} -> true
      _ -> false
    end)
    |> List.last()
    |> case do
      %{content: content} when is_binary(content) -> content
      %{"content" => content} when is_binary(content) -> content
      _ -> "(no response)"
    end
  end

  defp deliver_async(%ChannelConfig{} = config, message) do
    Task.Supervisor.start_child(MonkeyClaw.TaskSupervisor, fn ->
      deliver_to_channel(config, message)
    end)
  end

  defp record_outbound(%ChannelConfig{} = config, message) do
    Telemetry.message_outbound(%{
      adapter_type: config.adapter_type,
      workspace_id: config.workspace_id,
      channel_config_id: config.id
    })

    Telemetry.delivery_success(%{
      adapter_type: config.adapter_type,
      workspace_id: config.workspace_id
    })

    _ =
      Channels.record_message(config, %{
        direction: :outbound,
        content: message.content,
        metadata: message.metadata,
        external_id: message.external_id
      })

    :ok
  end
end
