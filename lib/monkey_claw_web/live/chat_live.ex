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
  alias MonkeyClaw.Sessions
  alias MonkeyClaw.Workflows.Conversation
  alias MonkeyClaw.Workspaces

  alias MonkeyClawWeb.ErrorFormatter

  @impl true
  def mount(params, _session, socket) do
    socket =
      socket
      |> assign(:loading, false)
      |> assign(:streaming, false)
      |> assign(:stream_content, "")
      |> assign(:stream_byte_size, 0)
      |> assign(:stream_usage, nil)
      |> assign(:error, nil)
      |> assign(:page_title, "Chat")
      |> assign(:sent_at, nil)
      |> assign(:available_models, available_models())
      |> assign(:sidebar_open, true)
      |> assign(:session_history, [])
      |> assign(:viewing_history_id, nil)
      |> assign_workspace(params["workspace_id"])
      |> restore_or_new_conversation()
      |> load_and_assign_history()
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
        |> assign(:stream_usage, nil)
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
      |> assign(:viewing_history_id, nil)
      |> assign(:loading, false)
      |> assign(:error, nil)

    {:noreply, socket}
  end

  def handle_event("switch_conversation", %{"id" => id}, socket) do
    if id == socket.assigns.active_conversation_id and is_nil(socket.assigns.viewing_history_id) do
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
            |> assign(:viewing_history_id, nil)
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

  def handle_event("delete_history", %{"id" => session_id}, socket)
      when is_binary(session_id) and byte_size(session_id) > 0 do
    workspace_id = socket.assigns.workspace && socket.assigns.workspace.id

    # Refuse to delete a session the AgentBridge is actively writing to
    # (would leave a dangling history_session_id reference).
    with false <- active_history_session?(workspace_id, session_id),
         {:ok, %{workspace_id: ^workspace_id} = session} <- Sessions.get_session(session_id) do
      _ = Sessions.delete_session(session)

      # If we were viewing this session, return to the active conversation.
      socket =
        if socket.assigns.viewing_history_id == session_id do
          id = socket.assigns.active_conversation_id
          convo = socket.assigns.conversations[id]

          socket
          |> assign(:messages, convo.messages)
          |> assign(:viewing_history_id, nil)
          |> assign(:session_stats, convo.session_stats)
        else
          socket
        end
        |> load_and_assign_history()

      {:noreply, socket}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("delete_history", _params, socket), do: {:noreply, socket}

  def handle_event("load_history", %{"id" => session_id}, socket) do
    workspace_id = socket.assigns.workspace && socket.assigns.workspace.id

    case Sessions.get_session(session_id) do
      {:ok, %{workspace_id: ^workspace_id}} ->
        messages =
          session_id
          |> Sessions.get_messages()
          |> Enum.map(&history_message_to_display/1)

        socket =
          socket
          |> persist_active_conversation()
          |> assign(:messages, messages)
          |> assign(:viewing_history_id, session_id)
          |> assign(:loading, false)
          |> assign(:streaming, false)
          |> assign(:stream_content, "")
          |> assign(:stream_byte_size, 0)
          |> assign(:error, nil)

        {:noreply, socket}

      {:ok, _wrong_workspace} ->
        {:noreply, assign(socket, :error, "Session not found.")}

      {:error, :not_found} ->
        {:noreply, assign(socket, :error, "Session not found.")}
    end
  end

  def handle_event("back_to_live", _params, socket) do
    id = socket.assigns.active_conversation_id
    convo = socket.assigns.conversations[id]

    socket =
      socket
      |> assign(:messages, convo.messages)
      |> assign(:viewing_history_id, nil)
      |> assign(:session_stats, convo.session_stats)
      |> assign(:loading, false)
      |> assign(:error, nil)

    {:noreply, socket}
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
      |> persist_active_conversation()
      |> load_and_assign_history()

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

  # Maximum number of messages kept in the display list. Older messages
  # are dropped from the front to bound LiveView assign memory.
  @max_display_messages 1000

  def handle_info({:stream_chunk, _session_id, chunk}, socket) do
    # Capture usage metadata from assistant/result messages.
    socket = maybe_capture_usage(socket, chunk)

    case classify_stream_chunk(chunk) do
      {:replace, content} ->
        # :assistant messages carry cumulative content_blocks — the latest
        # message has the full response so far. Replace the buffer to avoid
        # doubling from repeated cumulative text.
        #
        # Safety guard: if the new content is shorter than the current buffer,
        # the backend is sending incremental deltas, not cumulative snapshots.
        # Fall back to append to avoid losing prior content.
        current_size = socket.assigns.stream_byte_size
        new_content_size = byte_size(content)

        {effective_content, effective_size} =
          if new_content_size < current_size do
            # Incremental delta — append
            {socket.assigns.stream_content <> content, current_size + new_content_size}
          else
            # Cumulative snapshot — replace
            {content, new_content_size}
          end

        if effective_size > @max_stream_content_bytes do
          cancel_active_stream(socket)

          {:noreply,
           socket
           |> assign(:loading, false)
           |> assign(:streaming, false)
           |> assign(:stream_content, "")
           |> assign(:stream_byte_size, 0)
           |> assign(:error, "Response exceeded maximum size limit.")}
        else
          {:noreply,
           socket
           |> assign(:streaming, true)
           |> assign(:stream_content, effective_content)
           |> assign(:stream_byte_size, effective_size)}
        end

      {:append, content} ->
        # :text and other incremental chunks — append to existing buffer.
        new_size = socket.assigns.stream_byte_size + byte_size(content)

        if new_size > @max_stream_content_bytes do
          cancel_active_stream(socket)

          {:noreply,
           socket
           |> assign(:loading, false)
           |> assign(:streaming, false)
           |> assign(:stream_content, "")
           |> assign(:stream_byte_size, 0)
           |> assign(:error, "Response exceeded maximum size limit.")}
        else
          {:noreply,
           socket
           |> assign(:streaming, true)
           |> assign(:stream_content, socket.assigns.stream_content <> content)
           |> assign(:stream_byte_size, new_size)}
        end

      :skip ->
        {:noreply, socket}
    end
  end

  def handle_info({:stream_done, _session_id}, socket) do
    content = socket.assigns.stream_content
    latency_ms = calculate_latency(socket.assigns[:sent_at])
    usage = socket.assigns.stream_usage

    socket =
      if byte_size(content) > 0 do
        metadata = %{
          latency_ms: latency_ms,
          thinking: nil,
          input_tokens: extract_usage_field(usage, "input_tokens"),
          output_tokens: extract_usage_field(usage, "output_tokens"),
          cached_tokens: extract_cached_tokens(usage),
          thinking_tokens: nil,
          model: extract_usage_model(usage) || socket.assigns.selected_model
        }

        append_message(socket, :assistant, content, metadata)
      else
        socket
      end
      |> assign(:loading, false)
      |> assign(:streaming, false)
      |> assign(:stream_content, "")
      |> assign(:stream_byte_size, 0)
      |> assign(:stream_usage, nil)
      |> assign(:sent_at, nil)
      |> persist_active_conversation()
      |> load_and_assign_history()

    {:noreply, socket}
  end

  def handle_info({:stream_error, _session_id, reason}, socket) do
    content = socket.assigns.stream_content
    usage = socket.assigns.stream_usage

    # Preserve any partial content that arrived before the error
    socket =
      if is_binary(content) and byte_size(content) > 0 do
        latency_ms = calculate_latency(socket.assigns[:sent_at])

        metadata = %{
          latency_ms: latency_ms,
          thinking: nil,
          input_tokens: extract_usage_field(usage, "input_tokens"),
          output_tokens: extract_usage_field(usage, "output_tokens"),
          cached_tokens: extract_cached_tokens(usage),
          thinking_tokens: nil,
          model: extract_usage_model(usage) || socket.assigns.selected_model
        }

        append_message(socket, :assistant, content, metadata)
      else
        socket
      end
      |> assign(:loading, false)
      |> assign(:streaming, false)
      |> assign(:stream_content, "")
      |> assign(:stream_byte_size, 0)
      |> assign(:stream_usage, nil)
      |> assign(:sent_at, nil)
      |> assign(:error, ErrorFormatter.format(reason))
      |> persist_active_conversation()
      |> load_and_assign_history()

    {:noreply, socket}
  end

  # Normal task exit — no action needed.
  def handle_info({:DOWN, _ref, :process, _pid, :normal}, socket), do: {:noreply, socket}

  # Task crashed — if we're still loading, surface the error to the user.
  def handle_info({:DOWN, _ref, :process, _pid, reason}, socket) do
    if socket.assigns.loading do
      {:noreply,
       socket
       |> assign(:loading, false)
       |> assign(:streaming, false)
       |> assign(:stream_content, "")
       |> assign(:stream_byte_size, 0)
       |> assign(:error, "Backend task crashed: #{inspect(reason)}")}
    else
      {:noreply, socket}
    end
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

  defp load_and_assign_history(socket) do
    case socket.assigns[:workspace] do
      %{id: workspace_id} ->
        # Active DB sessions have a live AgentBridge GenServer — they
        # are current conversations, not past history.
        history =
          workspace_id
          |> Sessions.list_sessions(%{limit: 20})
          |> Enum.reject(&(&1.status == :active))

        assign(socket, :session_history, history)

      _ ->
        assign(socket, :session_history, [])
    end
  end

  defp history_message_to_display(%Sessions.Message{} = msg) do
    content =
      if msg.role == :assistant and is_binary(msg.content) do
        MonkeyClawWeb.Markdown.render(msg.content)
      else
        msg.content
      end

    meta = msg.metadata || %{}

    %{
      id: msg.id,
      role: msg.role,
      content: content,
      thinking: meta["thinking"],
      timestamp: msg.inserted_at,
      latency_ms: meta["duration_ms"],
      input_tokens: meta["input_tokens"],
      output_tokens: meta["output_tokens"],
      cached_tokens: meta["cached_tokens"],
      thinking_tokens: meta["thinking_tokens"],
      model: meta["model"]
    }
  end

  defp find_or_create_default_workspace do
    case Workspaces.list_workspaces() do
      [workspace | _] -> {:ok, workspace}
      [] -> Workspaces.create_workspace(%{name: "Default"})
    end
  end

  defp maybe_set_backend_model(nil, _model), do: :ok

  defp maybe_set_backend_model(workspace, model) do
    Task.Supervisor.start_child(MonkeyClaw.TaskSupervisor, fn ->
      case AgentBridge.set_model(workspace.id, model) do
        {:ok, _} -> :ok
        {:error, reason} -> Logger.warning("set_model failed: #{inspect(reason)}")
      end
    end)
  end

  defp dispatch_stream(workspace_id, channel_name, message, opts) do
    lv = self()

    {:ok, pid} =
      Task.Supervisor.start_child(MonkeyClaw.TaskSupervisor, fn ->
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

    Process.monitor(pid)
    :ok
  end

  # --- Conversation management ---

  # Check for an active AgentBridge session for this workspace and
  # restore its persisted messages as the initial conversation. Falls
  # back to a blank new conversation when no active session exists.
  defp restore_or_new_conversation(socket) do
    case maybe_restore_session(socket) do
      {:ok, convo, messages} ->
        socket
        |> assign(:conversations, %{convo.id => convo})
        |> assign(:conversation_order, [convo.id])
        |> assign(:active_conversation_id, convo.id)
        |> assign(:messages, messages)
        |> assign(:session_stats, convo.session_stats)

      :none ->
        convo = new_conversation()

        socket
        |> assign(:conversations, %{convo.id => convo})
        |> assign(:conversation_order, [convo.id])
        |> assign(:active_conversation_id, convo.id)
        |> assign(:messages, [])
        |> assign(:session_stats, initial_stats())
    end
  end

  # Look up the workspace's AgentBridge session. If one is active and
  # has a persisted history_session_id, load the DB messages so the
  # user resumes where they left off instead of seeing a blank chat.
  defp maybe_restore_session(%{assigns: %{workspace: %{id: workspace_id}}}) do
    with {:ok, %{status: :active, history_session_id: session_id}}
         when is_binary(session_id) <- AgentBridge.session_info(workspace_id),
         {:ok, %{workspace_id: ^workspace_id} = session} <- Sessions.get_session(session_id) do
      messages =
        session_id
        |> Sessions.get_messages()
        |> Enum.map(&history_message_to_display/1)

      stats = aggregate_session_stats(messages, session.model)

      convo = %{
        id: Ecto.UUID.generate(),
        title: session.title || "Restored conversation",
        messages: messages,
        session_stats: stats,
        created_at: session.inserted_at || DateTime.utc_now()
      }

      {:ok, convo, messages}
    else
      _ -> :none
    end
  end

  defp maybe_restore_session(_socket), do: :none

  # Returns true when the given SQLite session_id is the one the
  # AgentBridge is actively writing to.  Deleting it would leave a
  # dangling history_session_id reference in the GenServer state.
  defp active_history_session?(workspace_id, session_id) when is_binary(workspace_id) do
    case AgentBridge.session_info(workspace_id) do
      {:ok, %{history_session_id: ^session_id}} -> true
      _ -> false
    end
  end

  defp active_history_session?(_, _), do: false

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

  # Rebuild aggregate session stats from restored messages so the
  # stats footer shows correct totals after session restore.
  defp aggregate_session_stats(messages, model) do
    messages
    |> Enum.filter(&(&1.role == :assistant))
    |> Enum.reduce(initial_stats(), fn msg, acc ->
      %{
        acc
        | total_input_tokens: acc.total_input_tokens + (msg.input_tokens || 0),
          total_output_tokens: acc.total_output_tokens + (msg.output_tokens || 0),
          total_cached_tokens: acc.total_cached_tokens + (msg.cached_tokens || 0),
          total_thinking_tokens: acc.total_thinking_tokens + (msg.thinking_tokens || 0),
          message_count: acc.message_count + 1,
          current_model: msg.model || acc.current_model
      }
    end)
    |> Map.put(:current_model, model || nil)
  end

  # No-op when viewing history — socket.assigns.messages contains
  # the historical transcript, not the live conversation's messages.
  defp persist_active_conversation(%{assigns: %{viewing_history_id: id}} = socket)
       when not is_nil(id) do
    socket
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
    |> update(:messages, fn messages ->
      updated = [message | messages]
      if length(updated) > @max_display_messages, do: List.delete_at(updated, -1), else: updated
    end)
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

    update(socket, :messages, fn messages ->
      updated = [message | messages]
      if length(updated) > @max_display_messages, do: List.delete_at(updated, -1), else: updated
    end)
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

  # Classify a streaming chunk for the stream_chunk handler.
  #
  # :assistant messages carry cumulative content_blocks — each new message
  # has the FULL response so far, not just the delta. We return {:replace, text}
  # so the handler overwrites the buffer instead of appending (which would
  # double the content on every update).
  #
  # :text and other incremental messages return {:append, text}.
  # :result messages return :skip (metadata only, captured by maybe_capture_usage).
  defp classify_stream_chunk(%{type: :assistant, content_blocks: blocks})
       when is_list(blocks) do
    content =
      blocks
      |> Enum.filter(fn block -> Map.get(block, :type) == :text end)
      |> Enum.map_join("\n", fn block -> Map.get(block, :text, "") end)

    if byte_size(content) > 0, do: {:replace, content}, else: :skip
  end

  defp classify_stream_chunk(%{type: :result}), do: :skip

  defp classify_stream_chunk(%{type: :text, content: content})
       when is_binary(content) and byte_size(content) > 0,
       do: {:append, content}

  defp classify_stream_chunk(%{content: content})
       when is_binary(content) and byte_size(content) > 0,
       do: {:append, content}

  defp classify_stream_chunk(_), do: :skip

  defp displayable_message?(%{type: :assistant}), do: true
  defp displayable_message?(_), do: false

  # --- Stream usage capture ---

  # Capture usage data from :result and :assistant messages during streaming.
  # BeamAgent sends a :result message at stream end carrying the API usage map.
  # The usage map has binary string keys (from JSON parsing), e.g., "input_tokens".
  defp maybe_capture_usage(socket, %{type: type, usage: usage} = chunk)
       when type in [:result, :assistant] and is_map(usage) do
    assign(socket, :stream_usage, %{
      usage: usage,
      model: Map.get(chunk, :model),
      duration_ms: Map.get(chunk, :duration_ms)
    })
  end

  defp maybe_capture_usage(socket, _chunk), do: socket

  # Usage map keys are binary strings from JSON: "input_tokens", "output_tokens", etc.
  defp extract_usage_field(%{usage: usage}, key) when is_map(usage) and is_binary(key),
    do: Map.get(usage, key)

  defp extract_usage_field(_, _), do: nil

  defp extract_cached_tokens(%{usage: usage}) when is_map(usage) do
    cache_read = Map.get(usage, "cache_read_input_tokens", 0) || 0
    cache_create = Map.get(usage, "cache_creation_input_tokens", 0) || 0
    total = cache_read + cache_create
    if total > 0, do: total, else: nil
  end

  defp extract_cached_tokens(_), do: nil

  defp extract_usage_model(%{model: model}) when is_binary(model), do: model
  defp extract_usage_model(_), do: nil

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
