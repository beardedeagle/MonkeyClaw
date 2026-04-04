defmodule MonkeyClaw.Vault.Secret do
  @moduledoc """
  Ecto schema for vault secret records.

  A secret stores a named, encrypted value (typically an API key)
  scoped to a workspace. The `encrypted_value` field is stored as
  raw ciphertext — it is NOT auto-decrypted on load. Decryption
  happens only in `MonkeyClaw.Vault.resolve_secret/2` at the HTTP
  call boundary.

  ## Security Invariant

  The AI model never sees plaintext secret values. Config references
  secrets via `@secret:name` opaque strings. Resolution to plaintext
  occurs only in the process making the external API call.

  ## Fields

    * `:name` — Unique identifier within the workspace (e.g., "anthropic_key")
    * `:encrypted_value` — AES-256-GCM ciphertext (raw binary, no auto-decrypt)
    * `:description` — Human-readable purpose (e.g., "Anthropic API key for production")
    * `:provider` — Optional provider association (anthropic, openai, google, etc.)
    * `:last_used_at` — Updated each time the secret is resolved (audit trail)

  ## Design

  This is NOT a process. Secrets are data entities persisted in
  SQLite3 via Ecto. They are created through the Vault context
  and resolved at HTTP call boundaries.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias MonkeyClaw.Workspaces.Workspace

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          workspace_id: Ecto.UUID.t() | nil,
          name: String.t() | nil,
          encrypted_value: binary() | nil,
          description: String.t() | nil,
          provider: String.t() | nil,
          last_used_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @providers ~w(anthropic openai google github_copilot local)
  @max_name_length 100
  @max_description_length 500

  @create_fields [:name, :encrypted_value, :description, :provider]
  @update_fields [:description, :provider]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "vault_secrets" do
    field :name, :string
    field :encrypted_value, :binary
    field :description, :string
    field :provider, :string
    field :last_used_at, :utc_datetime_usec

    belongs_to :workspace, Workspace

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Changeset for creating a new vault secret.

  Required fields: `:name`, `:encrypted_value`.
  The `:workspace_id` is set via `Ecto.build_assoc/3`.

  The `encrypted_value` must already be encrypted via
  `MonkeyClaw.Vault.Crypto.encrypt/1` before being passed
  to this changeset.

  ## Validation

    * Name: 1-#{@max_name_length} characters, `[a-zA-Z0-9_-]` only
    * Description: max #{@max_description_length} characters
    * Provider: one of #{inspect(@providers)} (if provided)
  """
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(%__MODULE__{} = secret, attrs) when is_map(attrs) do
    secret
    |> cast(attrs, @create_fields)
    |> validate_required([:name, :encrypted_value])
    |> validate_length(:name, min: 1, max: @max_name_length)
    |> validate_format(:name, ~r/\A[a-zA-Z0-9_-]+\z/,
      message: "must contain only letters, digits, underscores, and hyphens"
    )
    |> validate_length(:description, max: @max_description_length)
    |> validate_provider()
    |> assoc_constraint(:workspace)
    |> unique_constraint([:workspace_id, :name])
  end

  @doc """
  Changeset for updating vault secret metadata.

  Only `:description` and `:provider` can be changed after creation.
  To change the encrypted value, delete and recreate the secret.
  """
  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(%__MODULE__{} = secret, attrs) when is_map(attrs) do
    secret
    |> cast(attrs, @update_fields)
    |> validate_length(:description, max: @max_description_length)
    |> validate_provider()
  end

  @doc """
  Changeset for updating `last_used_at` on resolution.

  Used internally by the vault context when a secret is resolved.
  """
  @spec touch_changeset(t()) :: Ecto.Changeset.t()
  def touch_changeset(%__MODULE__{} = secret) do
    change(secret, last_used_at: DateTime.utc_now())
  end

  @doc """
  Returns the list of valid provider identifiers.
  """
  @spec valid_providers() :: [String.t()]
  def valid_providers, do: @providers

  # ── Private ─────────────────────────────────────────────────

  defp validate_provider(changeset) do
    case fetch_change(changeset, :provider) do
      :error ->
        changeset

      {:ok, nil} ->
        changeset

      {:ok, value} when value in @providers ->
        changeset

      {:ok, _} ->
        add_error(changeset, :provider, "must be one of: #{Enum.join(@providers, ", ")}")
    end
  end
end
