defmodule MonkeyClaw.Vault do
  @moduledoc """
  Context for managing encrypted secrets and OAuth tokens.

  The vault provides workspace-scoped storage for API keys and
  OAuth tokens with AES-256-GCM encryption at rest. Secrets are
  referenced in configuration via opaque `@secret:name` strings
  and resolved to plaintext only at HTTP call boundaries.

  ## Security Invariant

  The AI model never sees plaintext secret values. It sees
  `@secret:anthropic_key` in config. The resolved plaintext only
  exists in the process making the external API call — it never
  appears in messages, logs, config state, or responses that flow
  back to the model.

  ## Secrets vs Tokens

    * **Secrets** — Named key-value pairs (API keys). Stored with
      explicit encryption; decryption only via `resolve_secret/2`.
      The `encrypted_value` field is raw ciphertext on load.

    * **Tokens** — OAuth credentials with lifecycle metadata
      (expiry, refresh). Use `EncryptedField` for auto-decrypt
      since token management requires reading values.

  ## Design

  This is NOT a process. The vault is a stateless Ecto-backed
  context module. Encryption keys are derived from the BEAM cookie
  and cached in `:persistent_term`.
  """

  require Logger

  import Ecto.Query

  alias MonkeyClaw.Repo
  alias MonkeyClaw.Vault.{Crypto, Secret, Token}
  alias MonkeyClaw.Workspaces.Workspace

  # ── Secrets ──────────────────────────────────────────────────

  @doc """
  Create a new vault secret.

  The plaintext value is encrypted before storage. The returned
  secret contains the `encrypted_value` as ciphertext — it is
  never auto-decrypted.

  ## Parameters

    * `workspace` — The workspace struct (for `build_assoc`)
    * `attrs` — Must include `:name` and `:value` (plaintext).
      Optional: `:description`, `:provider`

  ## Examples

      iex> Vault.create_secret(workspace, %{name: "my_key", value: "sk-..."})
      {:ok, %Secret{name: "my_key", encrypted_value: <<...>>}}
  """
  @spec create_secret(Workspace.t(), map()) :: {:ok, Secret.t()} | {:error, Ecto.Changeset.t()}
  def create_secret(%Workspace{} = workspace, attrs) when is_map(attrs) do
    with {:ok, encrypted} <- encrypt_value(attrs) do
      workspace
      |> Ecto.build_assoc(:vault_secrets)
      |> Secret.create_changeset(encrypted)
      |> Repo.insert()
    end
  end

  @doc """
  Update vault secret metadata.

  Only `:description` and `:provider` can be changed. To change the
  encrypted value, delete and recreate the secret.
  """
  @spec update_secret(Secret.t(), map()) :: {:ok, Secret.t()} | {:error, Ecto.Changeset.t()}
  def update_secret(%Secret{} = secret, attrs) when is_map(attrs) do
    secret
    |> Secret.update_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Delete a vault secret.
  """
  @spec delete_secret(Secret.t()) :: {:ok, Secret.t()} | {:error, Ecto.Changeset.t()}
  def delete_secret(%Secret{} = secret) do
    Repo.delete(secret)
  end

  @doc """
  Get a vault secret by ID.
  """
  @spec get_secret(Ecto.UUID.t()) :: {:ok, Secret.t()} | {:error, :not_found}
  def get_secret(id) when is_binary(id) do
    case Repo.get(Secret, id) do
      nil -> {:error, :not_found}
      secret -> {:ok, secret}
    end
  end

  @doc """
  Get a vault secret by workspace and name.
  """
  @spec get_secret_by_name(Ecto.UUID.t(), String.t()) :: {:ok, Secret.t()} | {:error, :not_found}
  def get_secret_by_name(workspace_id, name) when is_binary(workspace_id) and is_binary(name) do
    query =
      from s in Secret,
        where: s.workspace_id == ^workspace_id and s.name == ^name

    case Repo.one(query) do
      nil -> {:error, :not_found}
      secret -> {:ok, secret}
    end
  end

  @doc """
  List all secrets for a workspace.

  Returns secrets with metadata only — `encrypted_value` is present
  as raw ciphertext but is never decrypted in this function.
  """
  @spec list_secrets(Ecto.UUID.t()) :: [Secret.t()]
  def list_secrets(workspace_id) when is_binary(workspace_id) do
    from(s in Secret,
      where: s.workspace_id == ^workspace_id,
      order_by: [asc: s.name]
    )
    |> Repo.all()
  end

  @doc """
  Resolve a secret to its plaintext value.

  This is the ONLY function that decrypts a secret. It should be
  called exclusively at HTTP call boundaries — never in model
  context, logs, or responses.

  Updates `last_used_at` for audit trail.

  ## Returns

    * `{:ok, plaintext}` — Secret found and decrypted
    * `{:error, :not_found}` — No secret with that name in workspace
    * `{:error, :decryption_failed}` — Secret exists but decryption failed
  """
  @spec resolve_secret(Ecto.UUID.t(), String.t()) ::
          {:ok, String.t()} | {:error, :not_found | :decryption_failed}
  def resolve_secret(workspace_id, name)
      when is_binary(workspace_id) and is_binary(name) do
    with {:ok, secret} <- get_secret_by_name(workspace_id, name),
         {:ok, plaintext} <- Crypto.decrypt(secret.encrypted_value) do
      # Update last_used_at synchronously. This is a single indexed UPDATE
      # on SQLite — microseconds. Async Task.start would risk write contention
      # under SQLite's single-writer model and violate process discipline.
      case secret |> Secret.touch_changeset() |> Repo.update() do
        {:ok, _} ->
          :ok

        {:error, changeset} ->
          Logger.warning(
            "Vault: failed to update last_used_at for secret #{secret.id}: #{inspect(changeset.errors)}"
          )
      end

      {:ok, plaintext}
    else
      {:error, :not_found} -> {:error, :not_found}
      {:error, _} -> {:error, :decryption_failed}
    end
  end

  # ── Tokens ─────────────────────────────────────────────────────

  @doc """
  Store an OAuth token for a provider in a workspace.

  Uses upsert semantics — if a token already exists for the
  provider in this workspace, it is replaced.
  """
  @spec store_token(Workspace.t(), map()) :: {:ok, Token.t()} | {:error, Ecto.Changeset.t()}
  def store_token(%Workspace{} = workspace, attrs) when is_map(attrs) do
    workspace
    |> Ecto.build_assoc(:vault_tokens)
    |> Token.create_changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace_all_except, [:id, :workspace_id, :provider, :inserted_at]},
      conflict_target: [:workspace_id, :provider]
    )
  end

  @doc """
  Get an OAuth token for a provider in a workspace.
  """
  @spec get_token(Ecto.UUID.t(), String.t() | nil) :: {:ok, Token.t()} | {:error, :not_found}
  def get_token(workspace_id, provider)
      when is_binary(workspace_id) and is_binary(provider) do
    query =
      from t in Token,
        where: t.workspace_id == ^workspace_id and t.provider == ^provider

    case Repo.one(query) do
      nil -> {:error, :not_found}
      token -> {:ok, token}
    end
  end

  def get_token(_, _), do: {:error, :not_found}

  @doc """
  Delete an OAuth token.
  """
  @spec delete_token(Token.t()) :: {:ok, Token.t()} | {:error, Ecto.Changeset.t()}
  def delete_token(%Token{} = token) do
    Repo.delete(token)
  end

  @doc """
  Resolve a token to its access token plaintext.

  Tokens auto-decrypt via `EncryptedField`, so this simply
  returns the access token value if the token exists and is
  not expired.

  ## Returns

    * `{:ok, access_token}` — Token found and valid
    * `{:error, :not_found}` — No token for this provider
    * `{:error, :expired}` — Token exists but has expired
  """
  @spec resolve_token(Ecto.UUID.t(), String.t()) ::
          {:ok, String.t()} | {:error, :not_found | :expired}
  def resolve_token(workspace_id, provider)
      when is_binary(workspace_id) and is_binary(provider) do
    case get_token(workspace_id, provider) do
      {:ok, token} ->
        if Token.expired?(token) do
          {:error, :expired}
        else
          {:ok, token.access_token}
        end

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc """
  List all tokens for a workspace.
  """
  @spec list_tokens(Ecto.UUID.t()) :: [Token.t()]
  def list_tokens(workspace_id) when is_binary(workspace_id) do
    from(t in Token,
      where: t.workspace_id == ^workspace_id,
      order_by: [asc: t.provider]
    )
    |> Repo.all()
  end

  @doc """
  Check if a token has expired.

  Convenience wrapper around `MonkeyClaw.Vault.Token.expired?/1`.
  """
  @spec token_expired?(Token.t()) :: boolean()
  def token_expired?(%Token{} = token), do: Token.expired?(token)

  # ── Private ─────────────────────────────────────────────────

  # Encrypt the :value field from attrs, replacing it with :encrypted_value.
  # Returns {:ok, modified_attrs} or {:error, reason}.
  @spec encrypt_value(map()) :: {:ok, map()} | {:error, Ecto.Changeset.t()}
  defp encrypt_value(attrs) do
    {value, rest} = pop_value(attrs)

    # Strip any caller-supplied :encrypted_value to prevent bypass
    # of the encryption layer via direct ciphertext injection.
    rest = Map.delete(rest, :encrypted_value) |> Map.delete("encrypted_value")

    case value do
      plaintext when is_binary(plaintext) and byte_size(plaintext) > 0 ->
        case Crypto.encrypt(plaintext) do
          {:ok, ciphertext} ->
            {:ok, Map.put(rest, :encrypted_value, ciphertext)}

          {:error, reason} ->
            changeset =
              %Secret{}
              |> Ecto.Changeset.change()
              |> Ecto.Changeset.add_error(:value, "encryption failed: #{reason}")

            {:error, changeset}
        end

      _ ->
        changeset =
          %Secret{}
          |> Ecto.Changeset.change()
          |> Ecto.Changeset.add_error(:value, "can't be blank")

        {:error, changeset}
    end
  end

  # Extract :value from attrs (string or atom key), removing it from the map.
  defp pop_value(attrs) do
    case Map.pop(attrs, :value) do
      {nil, rest} -> Map.pop(rest, "value")
      result -> result
    end
  end
end
