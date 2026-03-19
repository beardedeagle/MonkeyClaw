defmodule MonkeyClaw.Assistants do
  @moduledoc """
  Context module for assistant definitions.

  Provides CRUD operations for managing assistants and rendering
  them into BeamAgent session configurations. This is the public
  API for all assistant-related operations in MonkeyClaw.

  ## What Is an Assistant

  An assistant is a named configuration that defines how a BeamAgent
  session should behave — backend, model, prompt layers, runtime
  options, and permission mode. The single-user model means there
  is no user scoping; all assistants belong to the operator.

  ## Default Assistant

  Exactly one assistant may be marked as default. The default is
  used when starting a session without specifying an assistant.
  Use `set_default_assistant/1` to change the default — it
  atomically unsets the previous default in a transaction.

  ## Integration with AgentBridge

  The `to_session_opts/1` function renders an assistant into
  the format expected by `MonkeyClaw.AgentBridge.start_session/1`:

      assistant = Assistants.get_default_assistant!()
      session_opts = Assistants.to_session_opts(assistant)
      AgentBridge.start_session(%{id: "workspace-1", session_opts: session_opts})

  ## Design

  This module is NOT a process. It delegates persistence to
  `MonkeyClaw.Repo` (Ecto/SQLite3) and prompt composition to
  `MonkeyClaw.Assistants.PromptBuilder`.

  ## Related Modules

    * `MonkeyClaw.Assistants.Assistant` — Ecto schema and changesets
    * `MonkeyClaw.Assistants.PromptBuilder` — Prompt layer composition
    * `MonkeyClaw.AgentBridge.Scope` — Session option translation
  """

  import Ecto.Query

  alias MonkeyClaw.AgentBridge.Scope
  alias MonkeyClaw.Assistants.{Assistant, PromptBuilder}
  alias MonkeyClaw.Repo

  # --- CRUD ---

  @doc """
  Create a new assistant.

  Required attributes: `:name`, `:backend`.

  ## Examples

      Assistants.create_assistant(%{name: "Dev", backend: :claude})
  """
  @spec create_assistant(map()) :: {:ok, Assistant.t()} | {:error, Ecto.Changeset.t()}
  def create_assistant(attrs) when is_map(attrs) do
    %Assistant{}
    |> Assistant.create_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Get an assistant by ID.

  Returns `{:ok, assistant}` if found, `{:error, :not_found}` otherwise.
  """
  @spec get_assistant(Ecto.UUID.t()) :: {:ok, Assistant.t()} | {:error, :not_found}
  def get_assistant(id) when is_binary(id) and byte_size(id) > 0 do
    case Repo.get(Assistant, id) do
      nil -> {:error, :not_found}
      assistant -> {:ok, assistant}
    end
  end

  @doc """
  Get an assistant by ID, raising on not found.
  """
  @spec get_assistant!(Ecto.UUID.t()) :: Assistant.t()
  def get_assistant!(id) when is_binary(id) and byte_size(id) > 0 do
    Repo.get!(Assistant, id)
  end

  @doc """
  List all assistants, ordered by name.
  """
  @spec list_assistants() :: [Assistant.t()]
  def list_assistants do
    Assistant
    |> order_by(:name)
    |> Repo.all()
  end

  @doc """
  Update an existing assistant.

  The `:is_default` flag cannot be changed through this function.
  Use `set_default_assistant/1` instead.
  """
  @spec update_assistant(Assistant.t(), map()) ::
          {:ok, Assistant.t()} | {:error, Ecto.Changeset.t()}
  def update_assistant(%Assistant{} = assistant, attrs) when is_map(attrs) do
    assistant
    |> Assistant.update_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Delete an assistant.
  """
  @spec delete_assistant(Assistant.t()) ::
          {:ok, Assistant.t()} | {:error, Ecto.Changeset.t()}
  def delete_assistant(%Assistant{} = assistant) do
    Repo.delete(assistant)
  end

  # --- Default Management ---

  @doc """
  Get the default assistant.

  Returns `{:ok, assistant}` if a default is set,
  `{:error, :no_default}` otherwise.
  """
  @spec get_default_assistant() :: {:ok, Assistant.t()} | {:error, :no_default}
  def get_default_assistant do
    query = from(a in Assistant, where: a.is_default == true, limit: 1)

    case Repo.one(query) do
      nil -> {:error, :no_default}
      assistant -> {:ok, assistant}
    end
  end

  @doc """
  Set an assistant as the default.

  Atomically unsets any existing default and sets the given
  assistant as the new default within a transaction.
  """
  @spec set_default_assistant(Assistant.t()) ::
          {:ok, Assistant.t()} | {:error, term()}
  def set_default_assistant(%Assistant{} = assistant) do
    Repo.transaction(fn ->
      # Unset all current defaults
      _ =
        from(a in Assistant, where: a.is_default == true)
        |> Repo.update_all(set: [is_default: false])

      # Set the new default
      case assistant
           |> Assistant.default_changeset(true)
           |> Repo.update() do
        {:ok, updated} -> updated
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  # --- BeamAgent Integration ---

  @doc """
  Render an assistant into BeamAgent session options.

  Returns a map suitable for passing as `session_opts` to
  `MonkeyClaw.AgentBridge.start_session/1`. Prompt layers are
  composed by `MonkeyClaw.Assistants.PromptBuilder` and translated
  through `MonkeyClaw.AgentBridge.Scope.session_opts/1`.

  ## Examples

      opts = Assistants.to_session_opts(assistant)
      AgentBridge.start_session(%{id: "ws-1", session_opts: opts})
  """
  @spec to_session_opts(Assistant.t()) :: map()
  def to_session_opts(%Assistant{} = assistant) do
    Scope.session_opts(%{
      backend: assistant.backend,
      model: assistant.model,
      system_prompt: PromptBuilder.build_system_prompt(assistant),
      cwd: assistant.cwd,
      max_thinking_tokens: assistant.max_thinking_tokens,
      permission_mode: assistant.permission_mode
    })
  end
end
