defmodule MonkeyClaw.Assistants.Assistant do
  @moduledoc """
  Ecto schema for assistant definitions.

  An assistant is a named configuration that defines how a BeamAgent
  session should behave. It includes backend preferences, composable
  system prompt layers, and runtime options.

  ## Prompt Layers

  Assistants support three composable prompt layers:

    * `system_prompt` — Core identity ("You are...")
    * `persona_prompt` — Personality overlay (tone, expertise, behavior)
    * `context_prompt` — Contextual instructions (workspace/project-specific)

  Layers are composed by `MonkeyClaw.Assistants.PromptBuilder`.

  ## Design

  This is NOT a process. Assistants are data entities persisted in
  SQLite3 via Ecto. They are read from the database and rendered into
  BeamAgent session configurations as needed.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          name: String.t() | nil,
          description: String.t() | nil,
          backend: backend() | nil,
          model: String.t() | nil,
          system_prompt: String.t() | nil,
          persona_prompt: String.t() | nil,
          context_prompt: String.t() | nil,
          cwd: String.t() | nil,
          max_thinking_tokens: pos_integer() | nil,
          permission_mode: permission_mode() | nil,
          is_default: boolean(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @type backend :: :claude | :codex | :gemini | :opencode | :copilot
  @type permission_mode :: :default | :accept_edits | :bypass_permissions | :plan | :dont_ask

  @backends [:claude, :codex, :gemini, :opencode, :copilot]
  @permission_modes [:default, :accept_edits, :bypass_permissions, :plan, :dont_ask]

  @create_fields [
    :name,
    :description,
    :backend,
    :model,
    :system_prompt,
    :persona_prompt,
    :context_prompt,
    :cwd,
    :max_thinking_tokens,
    :permission_mode
  ]

  @update_fields [
    :name,
    :description,
    :backend,
    :model,
    :system_prompt,
    :persona_prompt,
    :context_prompt,
    :cwd,
    :max_thinking_tokens,
    :permission_mode
  ]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "assistants" do
    field :name, :string
    field :description, :string
    field :backend, Ecto.Enum, values: @backends
    field :model, :string
    field :system_prompt, :string
    field :persona_prompt, :string
    field :context_prompt, :string
    field :cwd, :string
    field :max_thinking_tokens, :integer
    field :permission_mode, Ecto.Enum, values: @permission_modes
    field :is_default, :boolean, default: false

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Changeset for creating a new assistant.

  Required fields: `:name`, `:backend`.

  The `:is_default` flag is not settable through this changeset.
  Use `MonkeyClaw.Assistants.set_default_assistant/1` instead.

  ## Examples

      Assistant.create_changeset(%Assistant{}, %{name: "Dev", backend: :claude})
  """
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(%__MODULE__{} = assistant, attrs) when is_map(attrs) do
    assistant
    |> cast(attrs, @create_fields)
    |> validate_required([:name, :backend])
    |> validate_length(:name, min: 1, max: 100)
    |> validate_length(:description, max: 500)
    |> validate_length(:model, max: 100)
    |> validate_length(:system_prompt, max: 32_000)
    |> validate_length(:persona_prompt, max: 16_000)
    |> validate_length(:context_prompt, max: 16_000)
    |> validate_number(:max_thinking_tokens, greater_than: 0, less_than_or_equal_to: 100_000)
    |> validate_cwd()
    |> unique_constraint(:name)
  end

  @doc """
  Changeset for updating an existing assistant.

  The `:is_default` flag is not updatable through this changeset.
  Use `MonkeyClaw.Assistants.set_default_assistant/1` instead.
  """
  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(%__MODULE__{} = assistant, attrs) when is_map(attrs) do
    assistant
    |> cast(attrs, @update_fields)
    |> validate_required([:name, :backend])
    |> validate_length(:name, min: 1, max: 100)
    |> validate_length(:description, max: 500)
    |> validate_length(:model, max: 100)
    |> validate_length(:system_prompt, max: 32_000)
    |> validate_length(:persona_prompt, max: 16_000)
    |> validate_length(:context_prompt, max: 16_000)
    |> validate_number(:max_thinking_tokens, greater_than: 0, less_than_or_equal_to: 100_000)
    |> validate_cwd()
    |> unique_constraint(:name)
  end

  @doc """
  Changeset for toggling the default flag.

  Used internally by `MonkeyClaw.Assistants.set_default_assistant/1`.
  """
  @spec default_changeset(t(), boolean()) :: Ecto.Changeset.t()
  def default_changeset(%__MODULE__{} = assistant, is_default)
      when is_boolean(is_default) do
    change(assistant, is_default: is_default)
  end

  # Validates that cwd is an absolute path without traversal sequences.
  defp validate_cwd(changeset) do
    validate_change(changeset, :cwd, fn :cwd, value ->
      cond do
        byte_size(value) > 4096 ->
          [cwd: "path too long (max 4096 characters)"]

        not String.starts_with?(value, "/") ->
          [cwd: "must be an absolute path"]

        String.contains?(value, "..") ->
          [cwd: "path traversal sequences not permitted"]

        true ->
          []
      end
    end)
  end
end
