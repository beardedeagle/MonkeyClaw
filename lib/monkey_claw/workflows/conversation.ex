defmodule MonkeyClaw.Workflows.Conversation do
  @moduledoc """
  Workflow recipe for the "talk to an agent" flow.

  Orchestrates the complete path from user message to AI response:
  load domain entities, ensure session and thread, execute extension
  hooks, and dispatch the query through AgentBridge.

  ## Flow

  1. Load workspace (with assistant) from the database
  2. Build session configuration from the workspace and its assistant
  3. Ensure a BeamAgent session is running for the workspace
  4. Find or create the conversation channel
  5. Start a BeamAgent thread for the channel
  6. Execute `:query_pre` extension hooks
  7. Send the query through the session
  8. Execute `:query_post` extension hooks
  9. Return the result

  ## Streaming

  `stream_message/4` follows the same orchestration but dispatches
  via `AgentBridge.stream_query/3`, returning `{:ok, %{streaming: true, ...}}`
  immediately. Chunks arrive as messages to the calling process.
  Post-hooks are the caller's responsibility after stream completion.

  ## Extension Hook Integration

  The workflow fires two hook points:

    * `:query_pre` — Before sending the query to BeamAgent. If a
      plug halts the context, the query is not sent and
      `{:error, {:halted, context}}` is returned. If a plug sets
      `:effective_prompt` in assigns, that prompt is used instead
      of the original.
    * `:query_post` — After receiving the response. Plugs can
      observe or annotate the result via assigns. For streaming,
      post-hooks are not called by the workflow — the caller runs
      `run_query_post/3` after accumulating the full response.

  ## What This Module Owns

  This module owns the product-level orchestration — composing
  existing APIs from `Workspaces`, `AgentBridge`, and `Extensions`
  into a user-facing operation. It does NOT own session lifecycle,
  thread mechanics, or extension execution — those belong to their
  respective modules.

  ## Design

  This is NOT a process. It is a stateless recipe that composes
  existing APIs. The caller's process (e.g., a LiveView or
  controller) provides sufficient execution context.
  """

  import Ecto.Query

  alias MonkeyClaw.AgentBridge
  alias MonkeyClaw.Extensions
  alias MonkeyClaw.Repo
  alias MonkeyClaw.Workspaces
  alias MonkeyClaw.Workspaces.{Channel, Workspace}

  # Maximum allowed byte size for channel names (stored in DB).
  @max_channel_name_bytes 255

  # Maximum allowed byte size for prompts. Generous enough for any
  # reasonable query, small enough to prevent cost-inflation abuse.
  @max_prompt_bytes 500_000

  @type message_result ::
          {:ok, %{messages: list(), context: Extensions.Context.t()}}
          | {:error, term()}

  @type stream_result ::
          {:ok, %{streaming: true, context: Extensions.Context.t()}}
          | {:error, term()}

  @doc """
  Send a message to an AI agent through a workspace channel.

  Orchestrates the full conversation flow: entity resolution,
  session management, extension hooks, and query dispatch.

  ## Parameters

    * `workspace_id` — The workspace to send the message in
    * `channel_name` — The channel (conversation thread) name
    * `prompt` — The user's message
    * `opts` — Optional keyword list:
      * `:timeout` — Query timeout in milliseconds
      * `:create_channel` — Whether to create the channel if
        it doesn't exist (default: `true`)

  ## Returns

    * `{:ok, %{messages: [...], context: context}}` — Success
    * `{:error, reason}` — Failure at any step

  ## Examples

      MonkeyClaw.Workflows.Conversation.send_message(
        workspace_id,
        "general",
        "Hello, can you help me?"
      )
  """
  @spec send_message(String.t(), String.t(), String.t(), keyword()) :: message_result()
  def send_message(workspace_id, channel_name, prompt, opts \\ [])
      when is_binary(workspace_id) and byte_size(workspace_id) > 0 and
             is_binary(channel_name) and byte_size(channel_name) > 0 and
             byte_size(channel_name) <= @max_channel_name_bytes and
             is_binary(prompt) and byte_size(prompt) > 0 and
             byte_size(prompt) <= @max_prompt_bytes do
    with {:ok, workspace} <- resolve_workspace(workspace_id),
         {:ok, session_config} <- build_session_config(workspace),
         session_config = apply_model_override(session_config, opts),
         :ok <- ensure_session(session_config),
         {:ok, channel} <- resolve_channel(workspace, channel_name, opts),
         {:ok, _thread} <- ensure_thread(workspace.id, channel),
         {:ok, pre_ctx} <- run_query_pre(workspace.id, prompt),
         query_prompt = effective_prompt(pre_ctx, prompt),
         {:ok, messages} <- AgentBridge.query(workspace.id, query_prompt, opts),
         {:ok, post_ctx} <- run_query_post(workspace.id, query_prompt, messages) do
      {:ok, %{messages: messages, context: post_ctx}}
    end
  end

  @doc """
  Start a streaming message to an AI agent through a workspace channel.

  Performs the same orchestration as `send_message/4` (entity resolution,
  session management, pre-hooks) but dispatches via `AgentBridge.stream_query/3`
  instead of blocking on `AgentBridge.query/3`.

  Chunks are delivered as messages to the calling process:

    * `{:stream_chunk, session_id, chunk}` — A response fragment
    * `{:stream_done, session_id}` — Stream completed successfully
    * `{:stream_error, session_id, reason}` — Stream failed

  Post-hooks are NOT executed by this function — the caller is responsible
  for running `run_query_post/3` after the stream completes, since the
  full response is not available until all chunks arrive.

  ## Parameters

    * `workspace_id` — The workspace to send the message in
    * `channel_name` — The channel (conversation thread) name
    * `prompt` — The user's message
    * `opts` — Optional keyword list:
      * `:stream_to` — PID to receive stream messages (default: `self()`)
      * `:timeout` — Stream initiation timeout in milliseconds
      * `:create_channel` — Auto-create missing channels (default: `true`)

  ## Returns

    * `{:ok, %{streaming: true, context: context}}` — Stream initiated
    * `{:error, reason}` — Failure at any step
  """
  @spec stream_message(String.t(), String.t(), String.t(), keyword()) :: stream_result()
  def stream_message(workspace_id, channel_name, prompt, opts \\ [])
      when is_binary(workspace_id) and byte_size(workspace_id) > 0 and
             is_binary(channel_name) and byte_size(channel_name) > 0 and
             byte_size(channel_name) <= @max_channel_name_bytes and
             is_binary(prompt) and byte_size(prompt) > 0 and
             byte_size(prompt) <= @max_prompt_bytes do
    with {:ok, workspace} <- resolve_workspace(workspace_id),
         {:ok, session_config} <- build_session_config(workspace),
         session_config = apply_model_override(session_config, opts),
         :ok <- ensure_session(session_config),
         {:ok, channel} <- resolve_channel(workspace, channel_name, opts),
         {:ok, _thread} <- ensure_thread(workspace.id, channel),
         {:ok, pre_ctx} <- run_query_pre(workspace.id, prompt),
         query_prompt = effective_prompt(pre_ctx, prompt),
         stream_opts = Keyword.take(opts, [:stream_to, :timeout]),
         {:ok, :streaming} <- AgentBridge.stream_query(workspace.id, query_prompt, stream_opts) do
      {:ok, %{streaming: true, context: pre_ctx}}
    end
  end

  # --- Entity Resolution ---

  @doc """
  Load a workspace by ID.

  Returns `{:ok, workspace}` if found, or
  `{:error, {:workspace_not_found, id}}` if the workspace does
  not exist.

  Note: the assistant association is NOT preloaded here.
  `build_session_config/1` handles preloading via
  `Workspaces.to_session_config/1`, which is the single
  preload site for assistant data.
  """
  @spec resolve_workspace(String.t()) :: {:ok, Workspace.t()} | {:error, term()}
  def resolve_workspace(workspace_id) when is_binary(workspace_id) do
    case Workspaces.get_workspace(workspace_id) do
      {:ok, workspace} -> {:ok, workspace}
      {:error, :not_found} -> {:error, {:workspace_not_found, workspace_id}}
    end
  end

  @doc """
  Find or create a channel within a workspace.

  Looks up a channel by name within the workspace. If not found
  and `create_channel: true` (the default), creates a new channel.
  If not found and `create_channel: false`, returns an error.

  ## Options

    * `:create_channel` — Auto-create missing channels (default: `true`)
  """
  @spec resolve_channel(Workspace.t(), String.t(), keyword()) ::
          {:ok, Channel.t()} | {:error, term()}
  def resolve_channel(%Workspace{} = workspace, channel_name, opts \\ [])
      when is_binary(channel_name) and byte_size(channel_name) > 0 do
    create? = Keyword.get(opts, :create_channel, true)

    case find_channel_by_name(workspace.id, channel_name) do
      {:ok, channel} ->
        {:ok, channel}

      {:error, :not_found} when create? ->
        Workspaces.create_channel(workspace, %{name: channel_name})

      {:error, :not_found} ->
        {:error, {:channel_not_found, channel_name}}
    end
  end

  # --- Session Management ---

  @doc """
  Build a BeamAgent session configuration from a workspace.

  Renders the workspace (with optional assistant persona) into
  the config format expected by `AgentBridge.start_session/1`.
  """
  @spec build_session_config(Workspace.t()) :: {:ok, %{id: String.t(), session_opts: map()}}
  def build_session_config(%Workspace{} = workspace) do
    {:ok, Workspaces.to_session_config(workspace)}
  end

  # Merge the :model from query opts into session_config so that
  # ensure_session starts the CLI process with the correct model.
  defp apply_model_override(config, opts) do
    case Keyword.fetch(opts, :model) do
      {:ok, model} ->
        update_in(config, [:session_opts], &Map.put(&1, :model, model))

      :error ->
        config
    end
  end

  @doc """
  Ensure a BeamAgent session is running for the given config.

  If a session is already active for the config's ID, returns `:ok`.
  If no session exists, starts one. If a session exists but is not
  active, returns an error.
  """
  @spec ensure_session(%{id: String.t(), session_opts: map()}) ::
          :ok | {:error, {:session_start_failed, term()} | :session_unavailable}
  def ensure_session(%{id: session_id} = config) do
    case AgentBridge.session_info(session_id) do
      {:ok, %{status: :active}} ->
        :ok

      {:error, {:session_not_found, _}} ->
        case AgentBridge.start_session(config) do
          {:ok, _result} -> :ok
          {:error, reason} -> {:error, {:session_start_failed, reason}}
        end

      {:ok, %{status: _status}} ->
        {:error, :session_unavailable}
    end
  end

  # --- Thread Management ---

  @doc """
  Start a BeamAgent thread for a channel within a session.

  Translates the channel into thread options and starts the
  thread via AgentBridge.
  """
  @spec ensure_thread(String.t(), Channel.t()) ::
          {:ok, map()} | {:error, {:thread_start_failed, term()}}
  def ensure_thread(session_id, %Channel{} = channel)
      when is_binary(session_id) and byte_size(session_id) > 0 do
    thread_opts = Workspaces.to_thread_config(channel)

    case AgentBridge.start_thread(session_id, thread_opts) do
      {:ok, thread} -> {:ok, thread}
      {:error, reason} -> {:error, {:thread_start_failed, reason}}
    end
  end

  # --- Extension Hooks ---

  @doc """
  Execute `:query_pre` extension hooks.

  Fires the `:query_pre` hook with the workspace ID and prompt.
  If a plug halts the context, returns `{:error, {:halted, ctx}}`.
  """
  @spec run_query_pre(String.t(), String.t()) ::
          {:ok, Extensions.Context.t()} | {:error, term()}
  def run_query_pre(workspace_id, prompt)
      when is_binary(workspace_id) and is_binary(prompt) do
    case Extensions.execute(:query_pre, %{workspace_id: workspace_id, prompt: prompt}) do
      {:ok, %{halted: true} = ctx} -> {:error, {:halted, ctx}}
      {:ok, ctx} -> {:ok, ctx}
      {:error, reason} -> {:error, {:extension_error, reason}}
    end
  end

  @doc """
  Execute `:query_post` extension hooks.

  Fires the `:query_post` hook with the workspace ID, prompt,
  and response messages.
  """
  @spec run_query_post(String.t(), String.t(), list()) ::
          {:ok, Extensions.Context.t()} | {:error, term()}
  def run_query_post(workspace_id, prompt, messages)
      when is_binary(workspace_id) and is_binary(prompt) and is_list(messages) do
    data = %{workspace_id: workspace_id, prompt: prompt, messages: messages}

    case Extensions.execute(:query_post, data) do
      {:ok, ctx} -> {:ok, ctx}
      {:error, reason} -> {:error, {:extension_error, reason}}
    end
  end

  # --- Prompt Selection ---

  @doc """
  Select the effective prompt from extension assigns.

  If the assigns map contains an `:effective_prompt` key with a
  non-empty binary value within `@max_prompt_bytes`, that value
  is used. Otherwise, the original prompt is returned.

  This is the public, testable core of the prompt selection logic
  used by the conversation workflow after `:query_pre` hooks.
  Oversized substitutions are silently rejected — the original
  prompt is used instead.

  ## Examples

      iex> select_prompt(%{effective_prompt: "modified"}, "original")
      "modified"

      iex> select_prompt(%{}, "original")
      "original"
  """
  @spec select_prompt(map(), String.t()) :: String.t()
  def select_prompt(%{effective_prompt: prompt}, _original)
      when is_binary(prompt) and byte_size(prompt) > 0 and
             byte_size(prompt) <= @max_prompt_bytes do
    prompt
  end

  def select_prompt(_assigns, original), do: original

  # --- Private Helpers ---

  # Unwraps the context struct and delegates to select_prompt/2.
  defp effective_prompt(%{assigns: assigns}, original) do
    select_prompt(assigns, original)
  end

  defp find_channel_by_name(workspace_id, channel_name) do
    query =
      from(c in Channel,
        where: c.workspace_id == ^workspace_id and c.name == ^channel_name
      )

    case Repo.one(query) do
      nil -> {:error, :not_found}
      channel -> {:ok, channel}
    end
  end
end
