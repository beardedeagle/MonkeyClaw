defmodule MonkeyClaw.AgentBridge.Scope do
  @moduledoc """
  Maps MonkeyClaw product concepts to BeamAgent scopes.

  This module defines the conceptual bridge between MonkeyClaw's
  domain model and BeamAgent's runtime model. All functions are
  pure and side-effect-free.

  ## Concept Mapping

  | MonkeyClaw       | BeamAgent               | Relationship |
  |------------------|-------------------------|--------------|
  | Workspace        | Session + Memory scope  | 1:1          |
  | Channel          | Thread within Session   | 1:1          |
  | Persona          | Session configuration   | configures   |
  | Workflow Run     | Run/Steps               | 1:1          |

  ## Memory Scope Hierarchy

  BeamAgent memory scopes nest naturally with MonkeyClaw concepts:

    * Workspace-level: `session_id` (broad memory scope)
    * Run-level: `{session_id, thread_id, run_id}` (fully scoped)

  ## Why This Exists

  MonkeyClaw product code should never call BeamAgent directly.
  This module translates between MonkeyClaw's domain vocabulary
  and BeamAgent's runtime vocabulary, keeping the coupling in
  one place.
  """

  @type workspace_id :: String.t()
  @type channel_id :: String.t()
  @type run_id :: String.t()
  @type beam_agent_scope :: String.t() | {String.t(), String.t(), String.t()}

  @type persona_config :: %{
          optional(:backend) => atom(),
          optional(:model) => String.t(),
          optional(:system_prompt) => String.t(),
          optional(:cwd) => String.t(),
          optional(:max_thinking_tokens) => pos_integer(),
          optional(:permission_mode) => :auto | :manual | :accept_edits
        }

  @type channel_config :: %{
          optional(:name) => String.t(),
          optional(:metadata) => map()
        }

  @doc """
  Build a workspace-level BeamAgent memory scope.

  A workspace maps to a single BeamAgent session. The workspace
  ID becomes the session-level memory scope identifier.

  ## Examples

      iex> MonkeyClaw.AgentBridge.Scope.memory_scope("workspace-abc")
      "workspace-abc"
  """
  @spec memory_scope(workspace_id()) :: String.t()
  def memory_scope(workspace_id)
      when is_binary(workspace_id) and byte_size(workspace_id) > 0 do
    workspace_id
  end

  @doc """
  Build a fully-scoped BeamAgent memory scope.

  Narrows the memory scope to a specific channel (thread) and
  run within a workspace (session).

  ## Examples

      iex> MonkeyClaw.AgentBridge.Scope.memory_scope("ws-1", "ch-2", "run-3")
      {"ws-1", "ch-2", "run-3"}
  """
  @spec memory_scope(workspace_id(), channel_id(), run_id()) ::
          {String.t(), String.t(), String.t()}
  def memory_scope(workspace_id, channel_id, run_id)
      when is_binary(workspace_id) and byte_size(workspace_id) > 0 and
             is_binary(channel_id) and byte_size(channel_id) > 0 and
             is_binary(run_id) and byte_size(run_id) > 0 do
    {workspace_id, channel_id, run_id}
  end

  @doc """
  Build BeamAgent session options from MonkeyClaw persona configuration.

  Translates MonkeyClaw persona settings into the keyword options
  expected by `BeamAgent.start_session/1`. Invalid or missing
  options are silently omitted — the caller is responsible for
  ensuring required options (like `:backend`) are present.

  ## Supported Options

    * `:backend` — LLM backend atom (e.g., `:claude`, `:gemini`)
    * `:model` — Model identifier string
    * `:system_prompt` — System prompt string
    * `:cwd` — Working directory path
    * `:max_thinking_tokens` — Thinking budget (positive integer)
    * `:permission_mode` — Permission mode atom

  ## Examples

      iex> MonkeyClaw.AgentBridge.Scope.session_opts(%{backend: :claude, model: "opus"})
      %{backend: :claude, model: "opus"}

      iex> MonkeyClaw.AgentBridge.Scope.session_opts(%{backend: nil})
      %{}
  """
  @spec session_opts(persona_config()) :: map()
  def session_opts(persona_config) when is_map(persona_config) do
    persona_config
    |> Map.take([:backend, :model, :system_prompt, :cwd, :max_thinking_tokens, :permission_mode])
    |> Enum.reduce(%{}, fn
      {:backend, v}, acc when is_atom(v) and not is_nil(v) ->
        Map.put(acc, :backend, v)

      {:model, v}, acc when is_binary(v) and byte_size(v) > 0 ->
        Map.put(acc, :model, v)

      {:system_prompt, v}, acc when is_binary(v) ->
        Map.put(acc, :system_prompt, v)

      {:cwd, v}, acc when is_binary(v) and byte_size(v) > 0 ->
        Map.put(acc, :cwd, v)

      {:max_thinking_tokens, v}, acc when is_integer(v) and v > 0 ->
        Map.put(acc, :max_thinking_tokens, v)

      {:permission_mode, v}, acc when v in [:auto, :manual, :accept_edits] ->
        Map.put(acc, :permission_mode, v)

      _other, acc ->
        acc
    end)
  end

  @doc """
  Build BeamAgent thread options from MonkeyClaw channel configuration.

  Translates channel settings into the map expected by
  `BeamAgent.Threads.thread_start/2`.

  ## Examples

      iex> MonkeyClaw.AgentBridge.Scope.thread_opts(%{name: "general"})
      %{name: "general"}

      iex> MonkeyClaw.AgentBridge.Scope.thread_opts(%{})
      %{}
  """
  @spec thread_opts(channel_config()) :: map()
  def thread_opts(channel_config) when is_map(channel_config) do
    channel_config
    |> Map.take([:name, :metadata])
    |> Enum.reduce(%{}, fn
      {:name, v}, acc when is_binary(v) and byte_size(v) > 0 ->
        Map.put(acc, :name, v)

      {:metadata, v}, acc when is_map(v) ->
        Map.put(acc, :metadata, v)

      _other, acc ->
        acc
    end)
  end
end
