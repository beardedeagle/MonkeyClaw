defmodule MonkeyClaw.Vault.Token do
  @moduledoc """
  Ecto schema for vault OAuth token records.

  A token stores encrypted OAuth credentials (access token, refresh
  token) for a provider within a workspace. Unlike vault secrets,
  tokens use `MonkeyClaw.Vault.EncryptedField` for automatic
  encrypt-on-write and decrypt-on-read, since token lifecycle
  management (refresh, expiry check) requires reading the plaintext
  values programmatically.

  ## Fields

    * `:provider` �� Provider identifier (anthropic, openai, google, github_copilot)
    * `:access_token` — Encrypted OAuth access token (auto-decrypt on load)
    * `:refresh_token` — Encrypted OAuth refresh token (auto-decrypt on load, optional)
    * `:token_type` — Token type, typically "Bearer"
    * `:scope` — OAuth scope string (optional)
    * `:expires_at` — Token expiration time (optional)

  ## Security

  While tokens auto-decrypt for lifecycle management, they must
  never be exposed to the AI model. Resolution for HTTP calls
  happens through `MonkeyClaw.Vault.resolve_token/2` which returns
  the plaintext only to the calling process.

  ## Design

  This is NOT a process. Tokens are data entities persisted in
  SQLite3 via Ecto. One token per provider per workspace.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias MonkeyClaw.Vault.EncryptedField
  alias MonkeyClaw.Workspaces.Workspace

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          workspace_id: Ecto.UUID.t() | nil,
          provider: String.t() | nil,
          access_token: String.t() | nil,
          refresh_token: String.t() | nil,
          token_type: String.t() | nil,
          scope: String.t() | nil,
          expires_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @providers ~w(anthropic openai google github_copilot)
  @max_scope_length 500

  @create_fields [:provider, :access_token, :refresh_token, :token_type, :scope, :expires_at]
  @update_fields [:access_token, :refresh_token, :token_type, :scope, :expires_at]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "vault_tokens" do
    field :provider, :string
    field :access_token, EncryptedField
    field :refresh_token, EncryptedField
    field :token_type, :string, default: "Bearer"
    field :scope, :string
    field :expires_at, :utc_datetime_usec

    belongs_to :workspace, Workspace

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Changeset for storing a new OAuth token.

  Required fields: `:provider`, `:access_token`.
  The `:workspace_id` is set via `Ecto.build_assoc/3`.

  ## Validation

    * Provider: one of #{inspect(@providers)}
    * Access token: required, non-empty
    * Scope: max #{@max_scope_length} characters
  """
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(%__MODULE__{} = token, attrs) when is_map(attrs) do
    token
    |> cast(attrs, @create_fields)
    |> validate_required([:provider, :access_token])
    |> validate_inclusion(:provider, @providers)
    |> validate_length(:scope, max: @max_scope_length)
    |> assoc_constraint(:workspace)
    |> unique_constraint([:workspace_id, :provider])
  end

  @doc """
  Changeset for updating an existing OAuth token.

  Used for token refresh — updates access token, optionally
  refresh token and expiry.
  """
  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(%__MODULE__{} = token, attrs) when is_map(attrs) do
    token
    |> cast(attrs, @update_fields)
    |> validate_length(:scope, max: @max_scope_length)
  end

  @doc """
  Check if a token has expired.

  Returns `true` if `expires_at` is set and is in the past.
  Returns `false` if `expires_at` is nil (token does not expire)
  or is in the future.
  """
  @spec expired?(t()) :: boolean()
  def expired?(%__MODULE__{expires_at: nil}), do: false

  def expired?(%__MODULE__{expires_at: expires_at}) do
    DateTime.compare(expires_at, DateTime.utc_now()) == :lt
  end

  @doc """
  Returns the list of valid provider identifiers for tokens.
  """
  @spec valid_providers() :: [String.t()]
  def valid_providers, do: @providers
end
