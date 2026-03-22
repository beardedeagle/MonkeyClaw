defmodule MonkeyClawWeb.ChatLive do
  @moduledoc """
  LiveView for the main chat interface.

  Provides a real-time chat UI that sends messages through the
  `Conversation` workflow and displays AI responses. Messages
  are held in LiveView assigns for the duration of the session —
  no persistence layer yet.

  ## Flow

  1. On mount, finds or creates a default workspace
  2. User submits a message via the chat form
  3. Message is dispatched asynchronously through
     `Conversation.send_message/4`
  4. Response is appended to the message list when it arrives

  ## Error Handling

  Backend errors (no session, rate limited, extension halted) are
  caught and displayed as dismissible alerts. The chat remains
  functional — users can retry after resolving the issue.
  """

  use MonkeyClawWeb, :live_view

  require Logger

  alias MonkeyClaw.AgentBridge
  alias MonkeyClaw.Assistants
  alias MonkeyClaw.Workflows.Conversation
  alias MonkeyClaw.Workspaces

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:messages, [])
      |> assign(:loading, false)
      |> assign(:error, nil)
      |> assign(:page_title, "Chat")
      |> assign(:sent_at, nil)
      |> assign(:session_stats, %{
        total_input_tokens: 0,
        total_output_tokens: 0,
        total_cached_tokens: 0,
        total_thinking_tokens: 0,
        started_at: DateTime.utc_now(),
        message_count: 0,
        current_model: nil,
        working_dir: File.cwd!() |> Path.basename()
      })
      |> assign(:available_models, available_models())
      |> assign_workspace()

    {:ok, socket, layout: {MonkeyClawWeb.Layouts, :chat}}
  end

  @impl true
  def handle_event("send_message", %{"message" => message}, socket) do
    message = String.trim(message)

    if message == "" do
      {:noreply, socket}
    else
      socket =
        socket
        |> append_message(:user, message)
        |> assign(:loading, true)
        |> assign(:error, nil)
        |> assign(:sent_at, System.monotonic_time(:millisecond))
        |> push_event("clear-input", %{})

      query_opts =
        if model = socket.assigns.selected_model do
          [model: model]
        else
          []
        end

      _ignore =
        dispatch_query(
          socket.assigns.workspace.id,
          socket.assigns.channel_name,
          message,
          query_opts
        )

      {:noreply, socket}
    end
  end

  def handle_event("select_model", %{"model" => model}, socket)
      when is_binary(model) and byte_size(model) > 0 do
    # Change the model on the live session. set_model sends a
    # control message to the BeamAgent gen_statem; the per-query
    # model override in query_opts acts as a fallback.
    _ignore = maybe_set_backend_model(socket.assigns.workspace, model)
    {:noreply, assign(socket, :selected_model, model)}
  end

  def handle_event("select_model", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("dismiss_error", _params, socket) do
    {:noreply, assign(socket, :error, nil)}
  end

  @impl true
  def handle_info({:ai_response, {:ok, %{messages: messages}}}, socket) do
    latency_ms = calculate_latency(socket.assigns[:sent_at])

    socket =
      messages
      |> Enum.filter(&displayable_message?/1)
      |> Enum.reduce(socket, fn msg, acc ->
        case extract_content(msg) do
          content when is_binary(content) and byte_size(content) > 0 ->
            usage = Map.get(msg, :usage, %{})

            cached =
              (Map.get(usage, "cache_read_input_tokens", 0) || 0) +
                (Map.get(usage, "cache_creation_input_tokens", 0) || 0)

            thinking_tokens = Map.get(usage, "thinking_tokens")

            metadata = %{
              latency_ms: latency_ms,
              input_tokens: Map.get(usage, "input_tokens"),
              output_tokens: Map.get(usage, "output_tokens"),
              cached_tokens: if(cached > 0, do: cached, else: nil),
              thinking_tokens:
                if(thinking_tokens && thinking_tokens > 0, do: thinking_tokens, else: nil),
              model: Map.get(msg, :model),
              thinking: extract_thinking(msg)
            }

            append_message(acc, :assistant, content, metadata)

          _ ->
            acc
        end
      end)
      |> assign(:loading, false)
      |> assign(:sent_at, nil)

    {:noreply, socket}
  end

  def handle_info({:ai_response, {:error, reason}}, socket) do
    socket =
      socket
      |> assign(:loading, false)
      |> assign(:error, format_error(reason))

    {:noreply, socket}
  end

  # --- Private ---

  defp assign_workspace(socket) do
    case find_or_create_default_workspace() do
      {:ok, workspace} ->
        model = resolve_assistant_model(workspace)

        socket
        |> assign(:workspace, workspace)
        |> assign(:channel_name, "general")
        |> assign(:selected_model, model || default_model())

      {:error, _reason} ->
        socket
        |> assign(:workspace, nil)
        |> assign(:channel_name, nil)
        |> assign(:selected_model, default_model())
        |> assign(:error, "Failed to initialize workspace.")
    end
  end

  defp find_or_create_default_workspace do
    case Workspaces.list_workspaces() do
      [workspace | _] -> {:ok, workspace}
      [] -> Workspaces.create_workspace(%{name: "Default"})
    end
  end

  defp maybe_set_backend_model(nil, _model), do: :ok

  defp maybe_set_backend_model(workspace, model) do
    Task.start(fn ->
      case AgentBridge.set_model(workspace.id, model) do
        {:ok, _} -> :ok
        {:error, reason} -> Logger.warning("set_model failed: #{inspect(reason)}")
      end
    end)
  end

  defp dispatch_query(workspace_id, channel_name, message, opts) do
    lv = self()

    Task.start(fn ->
      result = Conversation.send_message(workspace_id, channel_name, message, opts)
      send(lv, {:ai_response, result})
    end)
  end

  defp append_message(socket, :assistant, content, metadata) when is_binary(content) do
    message = %{
      id: System.unique_integer([:positive]),
      role: :assistant,
      content: MonkeyClawWeb.Markdown.render(content),
      thinking: metadata.thinking,
      timestamp: DateTime.utc_now(),
      latency_ms: metadata.latency_ms,
      input_tokens: metadata.input_tokens,
      output_tokens: metadata.output_tokens,
      cached_tokens: metadata.cached_tokens,
      thinking_tokens: metadata.thinking_tokens,
      model: metadata.model
    }

    socket
    |> update(:messages, &(&1 ++ [message]))
    |> update(:session_stats, fn stats ->
      %{
        stats
        | total_input_tokens: stats.total_input_tokens + (metadata.input_tokens || 0),
          total_output_tokens: stats.total_output_tokens + (metadata.output_tokens || 0),
          total_cached_tokens: stats.total_cached_tokens + (metadata.cached_tokens || 0),
          total_thinking_tokens: stats.total_thinking_tokens + (metadata.thinking_tokens || 0),
          message_count: stats.message_count + 1,
          current_model: metadata.model || stats.current_model
      }
    end)
  end

  defp append_message(socket, role, content) do
    message = %{
      id: System.unique_integer([:positive]),
      role: role,
      content: content,
      thinking: nil,
      timestamp: DateTime.utc_now(),
      latency_ms: nil,
      input_tokens: nil,
      output_tokens: nil,
      cached_tokens: nil,
      thinking_tokens: nil,
      model: nil
    }

    update(socket, :messages, &(&1 ++ [message]))
  end

  # Assistant messages carry content_blocks (parsed by BeamAgent).
  # Extract text blocks and join them.
  defp extract_content(%{type: :assistant, content_blocks: blocks}) when is_list(blocks) do
    blocks
    |> Enum.filter(fn block -> Map.get(block, :type) == :text end)
    |> Enum.map_join("\n", fn block -> Map.get(block, :text, "") end)
  end

  # Text and result messages have a top-level content binary.
  defp extract_content(%{type: :text, content: content}) when is_binary(content), do: content
  defp extract_content(%{type: :result, content: content}) when is_binary(content), do: content

  # Fallback for any message with binary content.
  defp extract_content(%{content: content}) when is_binary(content), do: content
  defp extract_content(_other), do: nil

  # Extract thinking blocks from assistant content_blocks.
  # Returns the joined thinking text or nil if no thinking blocks.
  defp extract_thinking(%{type: :assistant, content_blocks: blocks}) when is_list(blocks) do
    thinking =
      blocks
      |> Enum.filter(fn block -> Map.get(block, :type) == :thinking end)
      |> Enum.map_join("\n", fn block -> Map.get(block, :thinking, "") end)

    if byte_size(thinking) > 0, do: thinking, else: nil
  end

  defp extract_thinking(_), do: nil

  # Only display user-facing message types. Filter out protocol
  # internals (system init, control messages, tool use, etc.).
  # :assistant has the full content (including tool output) via
  # content_blocks. :result is a summary that may truncate.
  defp displayable_message?(%{type: :assistant}), do: true
  defp displayable_message?(_), do: false

  defp format_error({:workspace_not_found, _id}), do: "Workspace not found."

  defp format_error({:session_start_failed, reason}),
    do: "Session failed to start: #{inspect(reason)}"

  defp format_error({:thread_start_failed, reason}),
    do: "Thread failed to start: #{inspect(reason)}"

  defp format_error({:halted, _ctx}), do: "Request blocked by an extension hook."
  defp format_error(:rate_limited), do: "Rate limited — please wait a moment."
  defp format_error(reason), do: "Something went wrong: #{inspect(reason)}"

  # --- Formatting Helpers ---

  @doc false
  def format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%-I:%M %p")
  def format_time(_), do: ""

  @doc false
  def format_latency(nil), do: nil
  def format_latency(ms) when ms < 1000, do: "#{ms}ms"
  def format_latency(ms), do: "#{Float.round(ms / 1000, 1)}s"

  @doc false
  def format_tokens(nil), do: nil
  def format_tokens(0), do: nil

  def format_tokens(n) when is_integer(n) and n >= 10_000,
    do: "#{Float.round(n / 1000, 1)}k"

  def format_tokens(n) when is_integer(n), do: Integer.to_string(n)

  @doc false
  def format_model(nil), do: nil

  def format_model(model) when is_binary(model) do
    model
    |> String.replace("claude-", "")
    |> String.replace(~r/-\d{8}$/, "")
  end

  @doc false
  def format_total_tokens(%{
        total_input_tokens: inp,
        total_output_tokens: out,
        total_thinking_tokens: think
      }) do
    format_tokens(inp + out + think)
  end

  defp calculate_latency(nil), do: nil
  defp calculate_latency(sent_at), do: System.monotonic_time(:millisecond) - sent_at

  # --- Model Selection Helpers ---

  defp resolve_assistant_model(%{assistant_id: nil}), do: nil

  defp resolve_assistant_model(%{assistant_id: id}) when is_binary(id) do
    case Assistants.get_assistant(id) do
      {:ok, %{model: model}} when is_binary(model) and byte_size(model) > 0 -> model
      _ -> nil
    end
  end

  defp default_model do
    Application.get_env(:monkey_claw, :default_model, "claude-sonnet-4-6")
  end

  defp available_models do
    Application.get_env(:monkey_claw, :available_models, [
      %{id: "claude-opus-4-6", label: "Opus 4.6"},
      %{id: "claude-sonnet-4-6", label: "Sonnet 4.6"},
      %{id: "claude-haiku-4-5-20251001", label: "Haiku 4.5"}
    ])
  end
end
