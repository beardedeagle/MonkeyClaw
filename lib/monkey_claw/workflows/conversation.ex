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

  ## Extension Hook Integration

  The workflow fires two hook points:

    * `:query_pre` — Before sending the query to BeamAgent. If a
      plug halts the context, the query is not sent and
      `{:error, {:halted, context}}` is returned. If a plug sets
      `:effective_prompt` in assigns, that prompt is used instead
      of the original.
    * `:query_post` — After receiving the response. Plugs can
      observe or annotate the result via assigns.

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

  @type message_result ::
          {:ok, %{messages: list(), context: Extensions.Context.t()}}
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
             is_binary(prompt) and byte_size(prompt) > 0 do
    with {:ok, workspace} <- resolve_workspace(workspace_id),
         {:ok, session_config} <- build_session_config(workspace),
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

  # --- Entity Resolution ---

  @doc """
  Load a workspace by ID with its assistant preloaded.

  Returns `{:ok, workspace}` with the assistant association loaded,
  or `{:error, {:workspace_not_found, id}}` if the workspace does
  not exist.
  """
  @spec resolve_workspace(String.t()) :: {:ok, Workspace.t()} | {:error, term()}
  def resolve_workspace(workspace_id) when is_binary(workspace_id) do
    case Workspaces.get_workspace(workspace_id) do
      {:ok, workspace} -> {:ok, Repo.preload(workspace, :assistant)}
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

  @doc """
  Ensure a BeamAgent session is running for the given config.

  If a session is already active for the config's ID, returns `:ok`.
  If no session exists, starts one. If a session exists but is not
  active, returns an error.
  """
  @spec ensure_session(%{id: String.t(), session_opts: map()}) ::
          :ok | {:error, {:session_start_failed, term()} | {:session_not_active, atom()}}
  def ensure_session(%{id: session_id} = config) do
    case AgentBridge.session_info(session_id) do
      {:ok, %{status: :active}} ->
        :ok

      {:error, {:session_not_found, _}} ->
        case AgentBridge.start_session(config) do
          {:ok, _pid} -> :ok
          {:error, reason} -> {:error, {:session_start_failed, reason}}
        end

      {:ok, %{status: status}} ->
        {:error, {:session_not_active, status}}
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

  Fires the `:query_pre` hook with the session ID and prompt.
  If a plug halts the context, returns `{:error, {:halted, ctx}}`.
  """
  @spec run_query_pre(String.t(), String.t()) ::
          {:ok, Extensions.Context.t()} | {:error, term()}
  def run_query_pre(session_id, prompt)
      when is_binary(session_id) and is_binary(prompt) do
    case Extensions.execute(:query_pre, %{session_id: session_id, prompt: prompt}) do
      {:ok, %{halted: true} = ctx} -> {:error, {:halted, ctx}}
      {:ok, ctx} -> {:ok, ctx}
      {:error, reason} -> {:error, {:extension_error, reason}}
    end
  end

  @doc """
  Execute `:query_post` extension hooks.

  Fires the `:query_post` hook with the session ID, prompt,
  and response messages.
  """
  @spec run_query_post(String.t(), String.t(), list()) ::
          {:ok, Extensions.Context.t()} | {:error, term()}
  def run_query_post(session_id, prompt, messages)
      when is_binary(session_id) and is_binary(prompt) and is_list(messages) do
    data = %{session_id: session_id, prompt: prompt, messages: messages}

    case Extensions.execute(:query_post, data) do
      {:ok, ctx} -> {:ok, ctx}
      {:error, reason} -> {:error, {:extension_error, reason}}
    end
  end

  # --- Private Helpers ---

  # If a query_pre plug sets :effective_prompt in assigns,
  # use it instead of the original prompt. This enables prompt
  # enrichment or transformation by extension plugs.
  @doc false
  @spec effective_prompt(Extensions.Context.t(), String.t()) :: String.t()
  def effective_prompt(%{assigns: %{effective_prompt: prompt}}, _original)
      when is_binary(prompt) and byte_size(prompt) > 0 do
    prompt
  end

  def effective_prompt(_ctx, original), do: original

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
