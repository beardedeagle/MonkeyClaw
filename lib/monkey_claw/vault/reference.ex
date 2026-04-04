defmodule MonkeyClaw.Vault.Reference do
  @moduledoc """
  Validation and resolution of `@secret:name` opaque references.

  Configuration fields store secret references as opaque strings
  (e.g., `"@secret:anthropic_key"`). This module provides:

    * **Validation** — Check if a string is a valid `@secret:` reference
      without ever resolving it. Safe for use in config validation,
      UI display, and model context.

    * **Resolution** — Resolve a reference to its plaintext value by
      delegating to `MonkeyClaw.Vault.resolve_secret/2`. Must be
      called ONLY at HTTP call boundaries.

  ## Syntax

  A valid reference matches `@secret:<name>` where `<name>` is
  1-100 characters of `[a-zA-Z0-9_-]`.

  ## Security

  Validation functions are always safe — they inspect syntax only.
  Resolution functions return plaintext and must be confined to
  the process making the external API call. Plaintext never enters
  model context, logs, or responses.

  ## Design

  This is NOT a process. Reference operations are pure functions
  (validation) or delegate to the Vault context (resolution).
  """

  alias MonkeyClaw.Vault

  @prefix "@secret:"
  @name_pattern ~r/\A[a-zA-Z0-9_-]{1,100}\z/

  @doc """
  Check if a string is a valid `@secret:name` reference.

  Returns `true` if the string starts with `@secret:` and the
  name portion matches `[a-zA-Z0-9_-]{1,100}`.

  This function NEVER resolves the reference — it only validates
  syntax. Safe for use anywhere.

  ## Examples

      iex> Reference.valid_reference?("@secret:my_api_key")
      true

      iex> Reference.valid_reference?("@secret:")
      false

      iex> Reference.valid_reference?("not-a-reference")
      false
  """
  @spec valid_reference?(term()) :: boolean()
  def valid_reference?(value) when is_binary(value) do
    case extract_name(value) do
      {:ok, _} -> true
      :error -> false
    end
  end

  def valid_reference?(_), do: false

  @doc """
  Extract the secret name from a `@secret:name` reference.

  Returns `{:ok, name}` if the string is a valid reference, or
  `:error` if it is not.

  ## Examples

      iex> Reference.extract_name("@secret:anthropic_key")
      {:ok, "anthropic_key"}

      iex> Reference.extract_name("@secret:")
      :error

      iex> Reference.extract_name("plain-string")
      :error
  """
  @spec extract_name(String.t()) :: {:ok, String.t()} | :error
  def extract_name(value) when is_binary(value) do
    case String.split_at(value, byte_size(@prefix)) do
      {@prefix, name} when byte_size(name) > 0 ->
        if Regex.match?(@name_pattern, name), do: {:ok, name}, else: :error

      _ ->
        :error
    end
  end

  def extract_name(_), do: :error

  @doc """
  Resolve a single `@secret:name` reference to its plaintext value.

  Delegates to `MonkeyClaw.Vault.resolve_secret/2`. Call this ONLY
  at HTTP call boundaries.

  ## Returns

    * `{:ok, plaintext}` — Reference resolved successfully
    * `{:error, :invalid_reference}` — String is not a valid `@secret:` reference
    * `{:error, :not_found}` — Secret name does not exist in workspace
    * `{:error, :decryption_failed}` — Secret exists but decryption failed
  """
  @spec resolve(Ecto.UUID.t(), String.t()) ::
          {:ok, String.t()} | {:error, :invalid_reference | :not_found | :decryption_failed}
  def resolve(workspace_id, reference) when is_binary(workspace_id) and is_binary(reference) do
    case extract_name(reference) do
      {:ok, name} -> Vault.resolve_secret(workspace_id, name)
      :error -> {:error, :invalid_reference}
    end
  end

  @doc """
  Recursively resolve all `@secret:` references in a map or keyword list.

  Traverses the data structure and replaces any string value that
  is a valid `@secret:` reference with its resolved plaintext.
  Non-reference strings are left unchanged.

  Call this ONLY at HTTP call boundaries for resolving configuration
  maps before making external API calls.

  ## Returns

    * `{:ok, resolved_data}` — All references resolved successfully
    * `{:error, {key_path, reason}}` — A reference failed to resolve;
      `key_path` is the list of keys leading to the failed value

  ## Examples

      iex> data = %{api_key: "@secret:my_key", model: "claude-sonnet-4-20250514"}
      iex> {:ok, resolved} = Reference.resolve_all(workspace_id, data)
      iex> resolved.model
      "claude-sonnet-4-20250514"
  """
  @spec resolve_all(Ecto.UUID.t(), map() | keyword()) ::
          {:ok, map() | keyword()} | {:error, {list(), term()}}
  def resolve_all(workspace_id, data) when is_binary(workspace_id) and is_map(data) do
    resolve_map(workspace_id, data, [])
  end

  def resolve_all(workspace_id, data) when is_binary(workspace_id) and is_list(data) do
    resolve_keyword(workspace_id, data, [])
  end

  # ── Private ─────────────────────────────────────────────────

  defp resolve_map(workspace_id, map, path) do
    Enum.reduce_while(map, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case resolve_value(workspace_id, value, [key | path]) do
        {:ok, resolved} -> {:cont, {:ok, Map.put(acc, key, resolved)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp resolve_keyword(workspace_id, keyword, path) do
    Enum.reduce_while(keyword, {:ok, []}, fn {key, value}, {:ok, acc} ->
      case resolve_value(workspace_id, value, [key | path]) do
        {:ok, resolved} -> {:cont, {:ok, [{key, resolved} | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp resolve_value(workspace_id, value, path) when is_binary(value) do
    if valid_reference?(value) do
      case resolve(workspace_id, value) do
        {:ok, plaintext} -> {:ok, plaintext}
        {:error, reason} -> {:error, {Enum.reverse(path), reason}}
      end
    else
      {:ok, value}
    end
  end

  defp resolve_value(workspace_id, value, path) when is_map(value) do
    resolve_map(workspace_id, value, path)
  end

  defp resolve_value(workspace_id, value, path) when is_list(value) do
    if Keyword.keyword?(value) do
      resolve_keyword(workspace_id, value, path)
    else
      resolve_list(workspace_id, value, path, 0)
    end
  end

  defp resolve_value(_workspace_id, value, _path), do: {:ok, value}

  defp resolve_list(_workspace_id, [], _path, _index), do: {:ok, []}

  defp resolve_list(workspace_id, [head | tail], path, index) do
    with {:ok, resolved_head} <- resolve_value(workspace_id, head, [index | path]),
         {:ok, resolved_tail} <- resolve_list(workspace_id, tail, path, index + 1) do
      {:ok, [resolved_head | resolved_tail]}
    end
  end
end
