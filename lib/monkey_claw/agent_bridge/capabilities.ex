defmodule MonkeyClaw.AgentBridge.Capabilities do
  @moduledoc """
  Pure functions for querying BeamAgent capabilities.

  Provides a MonkeyClaw-specific view of what the underlying
  BeamAgent runtime supports across backends. All functions
  are side-effect-free and safe to call from any process.

  ## Backends

  BeamAgent supports five agentic coder backends:

    * `:claude` — Anthropic Claude
    * `:codex` — OpenAI Codex
    * `:gemini` — Google Gemini
    * `:opencode` — OpenCode
    * `:copilot` — GitHub Copilot

  ## Capabilities

  Each backend exposes up to 22 capabilities (session lifecycle,
  thread management, MCP tools, hooks, etc.). Use `supports?/2`
  to check availability before calling a backend-specific feature.
  """

  @type capability_id :: atom()
  @type backend :: :claude | :codex | :gemini | :opencode | :copilot

  @type capability_info :: %{
          required(:id) => capability_id(),
          required(:title) => String.t(),
          required(:support) => %{
            required(:claude) => map(),
            required(:codex) => map(),
            required(:copilot) => map(),
            required(:gemini) => map(),
            required(:opencode) => map()
          }
        }

  @type for_session_error ::
          :backend_not_present
          | {:invalid_session_info, term()}
          | {:session_backend_lookup_failed, term()}
          | {:unknown_backend, term()}

  @doc """
  List all capability atom identifiers.

  Returns a flat list of capability IDs supported by BeamAgent.

  ## Examples

      iex> ids = MonkeyClaw.AgentBridge.Capabilities.all_ids()
      iex> :session_lifecycle in ids
      true
  """
  @spec all_ids() :: [capability_id()]
  def all_ids do
    BeamAgent.Capabilities.capability_ids()
  end

  @doc """
  List all capability details.

  Returns the full capability info maps including per-backend
  support levels.
  """
  @spec all() :: [capability_info(), ...]
  def all do
    BeamAgent.Capabilities.all()
  end

  @doc """
  List all supported backend identifiers.

  ## Examples

      iex> backends = MonkeyClaw.AgentBridge.Capabilities.backends()
      iex> :claude in backends
      true
  """
  @spec backends() :: [backend(), ...]
  def backends do
    BeamAgent.Capabilities.backends()
  end

  @doc """
  Check whether a capability is supported on a given backend.

  Returns `true` if the capability has `:full` or `:baseline`
  support, `false` otherwise.

  ## Examples

      iex> MonkeyClaw.AgentBridge.Capabilities.supports?(:session_lifecycle, :claude)
      true
  """
  @spec supports?(capability_id(), backend()) :: boolean()
  def supports?(capability, backend)
      when is_atom(capability) and is_atom(backend) do
    case BeamAgent.Capabilities.status(capability, backend) do
      {:ok, info} when is_map(info) ->
        Map.get(info, :support_level) in [:full, :baseline]

      _ ->
        false
    end
  end

  @doc """
  Get detailed support info for a capability on a backend.

  Returns `{:ok, support_info}` on success or `{:error, reason}` on failure.
  The support info map includes `:support_level`, `:implementation`,
  and `:fidelity` fields.
  """
  @spec status(capability_id(), backend()) :: {:ok, map()} | {:error, term()}
  def status(capability, backend)
      when is_atom(capability) and is_atom(backend) do
    BeamAgent.Capabilities.status(capability, backend)
  end

  @doc """
  List all capabilities for a specific backend.

  Returns `{:ok, capabilities}` with capability maps for the given backend.
  """
  @spec for_backend(backend()) :: {:ok, [map()]} | {:error, term()}
  def for_backend(backend) when is_atom(backend) do
    BeamAgent.Capabilities.for_backend(backend)
  end

  @doc """
  List capabilities for a live session.

  Discovers what the session's current backend supports by querying
  the running session process.
  """
  @spec for_session(pid()) :: {:ok, [map()]} | {:error, for_session_error()}
  def for_session(session_pid) when is_pid(session_pid) do
    BeamAgent.Capabilities.for_session(session_pid)
  end
end
