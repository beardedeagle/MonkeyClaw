defmodule MonkeyClawWeb.ChatLive do
  @moduledoc """
  LiveView for the main chat interface.

  Provides a real-time chat UI with a sidebar for managing multiple
  conversations. Messages are sent through the `Conversation` workflow
  and displayed with markdown rendering and per-message token stats.

  Conversations are held in-memory for the duration of the LiveView
  session — no persistence layer yet.

  ## Routes

    * `/chat` — Default workspace, default model
    * `/chat/:workspace_id` — Specific workspace
    * `/chat?backend=claude` — Pre-selects a model matching the backend

  ## Flow

  1. On mount, resolves workspace from URL params (or finds/creates default)
  2. If a `backend` query param is present, pre-selects a matching model
  3. User submits a message via the chat form
  4. Message is dispatched asynchronously through
     `Conversation.stream_message/4`
  5. Streaming chunks are accumulated and displayed progressively
  6. Final response is appended to the message list when the stream completes
  7. First user message auto-titles the conversation in the sidebar

  ## Streaming

  Responses arrive as a stream of chunks via `AgentBridge.Session`.
  The LiveView accumulates raw text in `:stream_content` and sets
  `:streaming` to `true` once the first chunk arrives. The template
  renders the in-progress content separately from finalized messages.
  On stream completion, the accumulated content is converted to a
  permanent assistant message.
  """

  use MonkeyClawWeb, :live_view

  require Logger

  alias MonkeyClaw.AgentBridge
  alias MonkeyClaw.Assistants
  alias MonkeyClaw.Workflows.Conversation
  alias MonkeyClaw.Workspaces

  alias MonkeyClawWeb.ErrorFormatter

  @impl true
  def mount(params, _session, socket) do
    initial_convo = new_conversation()

    socket =
      socket
      |> assign(:conversations, %{initial_convo.id => initial_convo})
      |> assign(:conversation_order, [initial_convo.id])
      |> assign(:active_conversation_id, initial_convo.id)
      |> assign(:messages, [])
      |> assign(:loading, false)
      |> assign(:streaming, false)
      |> assign(:stream_content, "")
      |> assign(:stream_byte_size, 0)
      |> assign(:error, nil)
      |> assign(:page_title, "Chat")
      |> assign(:sent_at, nil)
      |> assign(:session_stats, initial_stats())
      |> assign(:available_models, available_models())
      |> assign(:sidebar_open, true)
      |> assign_workspace(params["workspace_id"])
      |> maybe_select_backend(params["backend"])

    {:ok, socket, layout: {MonkeyClawWeb.Layouts, :chat}}
  end

  # --- Events ---

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
        |> assign(:streaming, false)
        |> assign(:stream_content, "")
        |> assign(:stream_byte_size, 0)
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
        dispatch_stream(
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
    _ignore = maybe_set_backend_model(socket.assigns.workspace, model)
    {:noreply, assign(socket, :selected_model, model)}
  end

  def handle_event("select_model", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("dismiss_error", _params, socket) do
    {:noreply, assign(socket, :error, nil)}
  end

  def handle_event("new_conversation", _params, socket) do
    socket = persist_active_conversation(socket)
    convo = new_conversation()

    socket =
      socket
      |> update(:conversations, &Map.put(&1, convo.id, convo))
      |> update(:conversation_order, &[convo.id | &1])
      |> assign(:active_conversation_id, convo.id)
      |> assign(:messages, [])
      |> assign(:session_stats, initial_stats())
      |> assign(:loading, false)
      |> assign(:error, nil)

    {:noreply, socket}
  end

  def handle_event("switch_conversation", %{"id" => id}, socket) do
    if id == socket.assigns.active_conversation_id do
      {:noreply, socket}
    else
      socket = persist_active_conversation(socket)

      case Map.fetch(socket.assigns.conversations, id) do
        {:ok, convo} ->
          socket =
            socket
            |> assign(:active_conversation_id, id)
            |> assign(:messages, convo.messages)
            |> assign(:session_stats, convo.session_stats)
            |> assign(:loading, false)
            |> assign(:error, nil)

          {:noreply, socket}

        :error ->
          {:noreply, socket}
      end
    end
  end

  def handle_event("delete_conversation", %{"id" => id}, socket) do
    if map_size(socket.assigns.conversations) <= 1 do
      {:noreply, socket}
    else
      conversations = Map.delete(socket.assigns.conversations, id)
      order = Enum.reject(socket.assigns.conversation_order, &(&1 == id))

      socket =
        if id == socket.assigns.active_conversation_id do
          next_id = hd(order)
          next_convo = conversations[next_id]

          socket
          |> assign(:active_conversation_id, next_id)
          |> assign(:messages, next_convo.messages)
          |> assign(:session_stats, next_convo.session_stats)
        else
          socket
        end
        |> assign(:conversations, conversations)
        |> assign(:conversation_order, order)

      {:noreply, socket}
    end
  end

  def handle_event("toggle_sidebar", _params, socket) do
    {:noreply, update(socket, :sidebar_open, &(!&1))}
  end

  # --- Info handlers ---

  @impl true
  def handle_info({:ai_response, {:ok, %{messages: messages}}}, socket) do
    latency_ms = calculate_latency(socket.assigns[:sent_at])
    displayable = Enum.filter(messages, &displayable_message?/1)

    socket =
      case displayable do
        [] -> maybe_surface_error(socket, messages)
        _ -> apply_displayable_messages(socket, displayable, latency_ms)
      end
      |> assign(:loading, false)
      |> assign(:sent_at, nil)

    {:noreply, socket}
  end

  def handle_info({:ai_response, {:error, reason}}, socket) do
    socket =
      socket
      |> assign(:loading, false)
      |> assign(:streaming, false)
      |> assign(:stream_content, "")
      |> assign(:stream_byte_size, 0)
      |> assign(:error, ErrorFormatter.format(reason))

    {:noreply, socket}
  end

  # Maximum accumulated stream content size (2 MB). Prevents unbounded
  # memory growth from a runaway backend.
  @max_stream_content_bytes 2_000_000

  def handle_info({:stream_chunk, _session_id, chunk}, socket) do
    case extract_content(chunk) do
      content when is_binary(content) and byte_size(content) > 0 ->
        new_size = socket.assigns.stream_byte_size + byte_size(content)

        if new_size > @max_stream_content_bytes do
          # Cancel the backend stream task to free the session for new queries
          cancel_active_stream(socket)

          socket =
            socket
            |> assign(:loading, false)
            |> assign(:streaming, false)
            |> assign(:stream_content, "")
            |> assign(:stream_byte_size, 0)
            |> assign(:error, "Response exceeded maximum size limit.")

          {:noreply, socket}
        else
          # BEAM binary append is amortized O(1) for sequential appends
          # to the same binary (over-allocation optimization). Tracking
          # size separately lets us check the cap before concatenating.
          socket =
            socket
            |> assign(:streaming, true)
            |> assign(:stream_content, socket.assigns.stream_content <> content)
            |> assign(:stream_byte_size, new_size)

          {:noreply, socket}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info({:stream_done, _session_id}, socket) do
    content = socket.assigns.stream_content
    latency_ms = calculate_latency(socket.assigns[:sent_at])

    socket =
      if byte_size(content) > 0 do
        metadata = %{
          latency_ms: latency_ms,
          thinking: nil,
          input_tokens: nil,
          output_tokens: nil,
          cached_tokens: nil,
          thinking_tokens: nil,
          model: socket.assigns.selected_model
        }

        append_message(socket, :assistant, content, metadata)
      else
        socket
      end
      |> assign(:loading, false)
      |> assign(:streaming, false)
      |> assign(:stream_content, "")
      |> assign(:stream_byte_size, 0)
      |> assign(:sent_at, nil)

    {:noreply, socket}
  end

  def handle_info({:stream_error, _session_id, reason}, socket) do
    content = socket.assigns.stream_content

    # Preserve any partial content that arrived before the error
    socket =
      if is_binary(content) and byte_size(content) > 0 do
        latency_ms = calculate_latency(socket.assigns[:sent_at])

        metadata = %{
          latency_ms: latency_ms,
          thinking: nil,
          input_tokens: nil,
          output_tokens: nil,
          cached_tokens: nil,
          thinking_tokens: nil,
          model: socket.assigns.selected_model
        }

        append_message(socket, :assistant, content, metadata)
      else
        socket
      end
      |> assign(:loading, false)
      |> assign(:streaming, false)
      |> assign(:stream_content, "")
      |> assign(:stream_byte_size, 0)
      |> assign(:sent_at, nil)
      |> assign(:error, ErrorFormatter.format(reason))

    {:noreply, socket}
  end

  # --- Private ---

  # Cancel the active stream task on the backend to free the session.
  # Safe to call when no workspace or session exists.
  defp cancel_active_stream(socket) do
    with %{id: workspace_id} <- socket.assigns[:workspace] do
      AgentBridge.cancel_stream(workspace_id)
    end
  end

  defp assign_workspace(socket, nil), do: assign_workspace(socket)

  defp assign_workspace(socket, workspace_id) do
    case Workspaces.get_workspace(workspace_id) do
      {:ok, workspace} ->
        model = resolve_assistant_model(workspace)

        socket
        |> assign(:workspace, workspace)
        |> assign(:channel_name, "general")
        |> assign(:selected_model, model || default_model())

      {:error, :not_found} ->
        assign_workspace(socket)
    end
  end

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

  defp dispatch_stream(workspace_id, channel_name, message, opts) do
    lv = self()

    Task.start(fn ->
      result =
        Conversation.stream_message(
          workspace_id,
          channel_name,
          message,
          [{:stream_to, lv} | opts]
        )

      case result do
        {:ok, %{streaming: true}} ->
          :ok

        {:error, reason} ->
          send(lv, {:ai_response, {:error, reason}})
      end
    end)
  end

  # --- Conversation management ---

  defp new_conversation do
    %{
      id: Ecto.UUID.generate(),
      title: "New conversation",
      messages: [],
      session_stats: initial_stats(),
      created_at: DateTime.utc_now()
    }
  end

  defp initial_stats do
    %{
      total_input_tokens: 0,
      total_output_tokens: 0,
      total_cached_tokens: 0,
      total_thinking_tokens: 0,
      started_at: DateTime.utc_now(),
      message_count: 0,
      current_model: nil,
      working_dir: File.cwd!() |> Path.basename()
    }
  end

  defp persist_active_conversation(socket) do
    id = socket.assigns.active_conversation_id

    convo =
      socket.assigns.conversations[id]
      |> Map.merge(%{
        messages: socket.assigns.messages,
        session_stats: socket.assigns.session_stats
      })
      |> maybe_auto_title()

    update(socket, :conversations, &Map.put(&1, id, convo))
  end

  defp maybe_auto_title(
         %{title: "New conversation", messages: [%{role: :user, content: content} | _]} = convo
       )
       when is_binary(content) do
    title =
      content
      |> String.slice(0, 50)
      |> String.trim()

    title = if String.length(content) > 50, do: title <> "...", else: title
    %{convo | title: title}
  end

  defp maybe_auto_title(convo), do: convo

  # --- Message helpers ---

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

  # --- Content extraction ---

  defp extract_content(%{type: :assistant, content_blocks: blocks}) when is_list(blocks) do
    blocks
    |> Enum.filter(fn block -> Map.get(block, :type) == :text end)
    |> Enum.map_join("\n", fn block -> Map.get(block, :text, "") end)
  end

  defp extract_content(%{type: :text, content: content}) when is_binary(content), do: content
  defp extract_content(%{type: :result, content: content}) when is_binary(content), do: content
  defp extract_content(%{content: content}) when is_binary(content), do: content
  defp extract_content(_other), do: nil

  defp extract_thinking(%{type: :assistant, content_blocks: blocks}) when is_list(blocks) do
    thinking =
      blocks
      |> Enum.filter(fn block -> Map.get(block, :type) == :thinking end)
      |> Enum.map_join("\n", fn block -> Map.get(block, :thinking, "") end)

    if byte_size(thinking) > 0, do: thinking, else: nil
  end

  defp extract_thinking(_), do: nil

  defp displayable_message?(%{type: :assistant}), do: true
  defp displayable_message?(_), do: false

  # No assistant content — surface the first categorized error
  # from the message stream (e.g., rate_limit with retry_after).
  defp maybe_surface_error(socket, messages) do
    case Enum.find(messages, &ErrorFormatter.categorized_error?/1) do
      nil -> socket
      error -> assign(socket, :error, ErrorFormatter.format(error))
    end
  end

  defp apply_displayable_messages(socket, messages, latency_ms) do
    Enum.reduce(messages, socket, fn msg, acc ->
      apply_assistant_message(acc, msg, latency_ms)
    end)
  end

  defp apply_assistant_message(socket, msg, latency_ms) do
    case extract_content(msg) do
      content when is_binary(content) and byte_size(content) > 0 ->
        metadata = build_message_metadata(msg, latency_ms)
        append_message(socket, :assistant, content, metadata)

      _ ->
        socket
    end
  end

  defp build_message_metadata(msg, latency_ms) do
    usage = Map.get(msg, :usage, %{})

    cached =
      (Map.get(usage, "cache_read_input_tokens", 0) || 0) +
        (Map.get(usage, "cache_creation_input_tokens", 0) || 0)

    thinking_tokens = Map.get(usage, "thinking_tokens")

    %{
      latency_ms: latency_ms,
      input_tokens: Map.get(usage, "input_tokens"),
      output_tokens: Map.get(usage, "output_tokens"),
      cached_tokens: if(cached > 0, do: cached, else: nil),
      thinking_tokens: if(thinking_tokens && thinking_tokens > 0, do: thinking_tokens, else: nil),
      model: Map.get(msg, :model),
      thinking: extract_thinking(msg)
    }
  end

  # --- Formatting helpers (used by template) ---

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

  # --- Model selection ---

  defp resolve_assistant_model(%{assistant_id: nil}), do: nil

  defp resolve_assistant_model(%{assistant_id: id}) when is_binary(id) do
    case Assistants.get_assistant(id) do
      {:ok, %{model: model}} when is_binary(model) and byte_size(model) > 0 -> model
      _ -> nil
    end
  end

  defp maybe_select_backend(socket, nil), do: socket

  defp maybe_select_backend(socket, backend) when is_binary(backend) do
    case Enum.find(available_models(), fn m -> String.starts_with?(m.id, backend) end) do
      %{id: model_id} -> assign(socket, :selected_model, model_id)
      nil -> socket
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

  @doc false
  def conversation_title(conversations, id) do
    case Map.fetch(conversations, id) do
      {:ok, convo} -> convo.title
      :error -> "Unknown"
    end
  end

  @doc false
  def conversation_time(conversations, id) do
    case Map.fetch(conversations, id) do
      {:ok, convo} -> Calendar.strftime(convo.created_at, "%-I:%M %p")
      :error -> ""
    end
  end
end
