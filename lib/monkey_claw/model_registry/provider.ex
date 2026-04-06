defmodule MonkeyClaw.ModelRegistry.Provider do
  @moduledoc """
  HTTP fetching of model lists from provider APIs.

  Each provider has a dedicated fetch function that calls the
  provider's model-list endpoint and normalizes the response into
  a common `%{model_id, display_name, capabilities}` shape.

  ## Configurable Base URLs

  Each provider's base URL is configurable via opts or application
  config. This enables test isolation (local Bandit server) without
  mocks.

      config :monkey_claw, MonkeyClaw.ModelRegistry.Provider,
        provider_urls: %{
          "anthropic" => "http://localhost:4100",
          "openai" => "http://localhost:4101"
        }

  ## API Key Resolution

  API keys are resolved via the vault. Each fetch call requires a
  `:workspace_id` and `:secret_name` to resolve the key, or an
  `:api_key` opt for direct injection (testing).

  ## Design

  This is NOT a process. All functions are stateless HTTP calls
  dispatched by the `MonkeyClaw.ModelRegistry` GenServer.
  """

  require Logger

  alias MonkeyClaw.Vault
  alias MonkeyClaw.Vault.SecretScanner

  @default_urls %{
    "anthropic" => "https://api.anthropic.com",
    "openai" => "https://api.openai.com",
    "google" => "https://generativelanguage.googleapis.com"
  }

  @type model_attrs :: %{
          model_id: String.t(),
          display_name: String.t(),
          capabilities: map()
        }

  @doc """
  Fetch the model list from a provider API.

  Dispatches to the provider-specific fetch function and returns
  a normalized list of model attribute maps.

  ## Options

    * `:workspace_id` — Required for vault secret resolution
    * `:secret_name` — Vault secret name for the provider's API key
    * `:api_key` — Direct API key injection (bypasses vault; for testing)
    * `:base_url` — Override the provider's base URL

  ## Returns

    * `{:ok, [model_attrs]}` — List of normalized model attributes
    * `{:error, reason}` — Fetch or parse failure

  ## Examples

      iex> Provider.fetch_models("anthropic", workspace_id: ws_id, secret_name: "anthropic_key")
      {:ok, [%{model_id: "claude-3-opus-20240229", display_name: "claude-3-opus-20240229", capabilities: %{}}]}

      iex> Provider.fetch_models("local")
      {:ok, []}
  """
  @spec fetch_models(String.t(), keyword()) :: {:ok, [model_attrs()]} | {:error, term()}
  def fetch_models(provider, opts \\ [])

  def fetch_models("anthropic", opts), do: fetch_anthropic(opts)
  def fetch_models("openai", opts), do: fetch_openai(opts)
  def fetch_models("google", opts), do: fetch_google(opts)
  def fetch_models("github_copilot", _opts), do: {:error, :not_implemented}
  def fetch_models("local", _opts), do: {:ok, []}

  def fetch_models(provider, _opts) do
    {:error, {:unknown_provider, provider}}
  end

  # ── Private — Provider Implementations ──────────────────────

  defp fetch_anthropic(opts) do
    with {:ok, api_key} <- resolve_api_key(opts),
         {:ok, data} <- anthropic_request(api_key, opts) do
      {:ok, parse_anthropic(data)}
    end
  end

  defp fetch_openai(opts) do
    with {:ok, api_key} <- resolve_api_key(opts),
         {:ok, data} <- openai_request(api_key, opts) do
      {:ok, parse_openai(data)}
    end
  end

  defp fetch_google(opts) do
    with {:ok, api_key} <- resolve_api_key(opts),
         {:ok, models} <- google_request(api_key, opts) do
      {:ok, parse_google(models)}
    end
  end

  # ── Private — HTTP Requests ────────────────────────────────

  defp anthropic_request(api_key, opts) do
    base_url = base_url("anthropic", opts)

    case Req.get("#{base_url}/v1/models",
           headers: [
             {"x-api-key", api_key},
             {"anthropic-version", "2023-06-01"}
           ],
           retry: false
         ) do
      {:ok, %Req.Response{status: 200, body: %{"data" => data}}} when is_list(data) ->
        {:ok, data}

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.warning("Anthropic models API returned #{status}: #{sanitize_for_log(body)}")
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        Logger.warning("Anthropic models API request failed: #{sanitize_for_log(reason)}")
        {:error, {:request_failed, reason}}
    end
  end

  defp openai_request(api_key, opts) do
    base_url = base_url("openai", opts)

    case Req.get("#{base_url}/v1/models",
           headers: [
             {"authorization", "Bearer #{api_key}"}
           ],
           retry: false
         ) do
      {:ok, %Req.Response{status: 200, body: %{"data" => data}}} when is_list(data) ->
        {:ok, data}

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.warning("OpenAI models API returned #{status}: #{sanitize_for_log(body)}")
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        Logger.warning("OpenAI models API request failed: #{sanitize_for_log(reason)}")
        {:error, {:request_failed, reason}}
    end
  end

  # Google's API requires the key as a URL query parameter (`?key=...`),
  # which means the secret appears in the URL and may be captured by HTTP
  # proxies, server access logs, or Req debug output. This is a Google API
  # design constraint — Anthropic and OpenAI use HTTP headers instead.
  # Ensure Req debug logging is disabled in production and any intermediate
  # proxies do not log query strings.
  defp google_request(api_key, opts) do
    base_url = base_url("google", opts)

    case Req.get("#{base_url}/v1beta/models", params: [key: api_key], retry: false) do
      {:ok, %Req.Response{status: 200, body: %{"models" => models}}} when is_list(models) ->
        {:ok, models}

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.warning("Google models API returned #{status}: #{sanitize_for_log(body)}")
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        Logger.warning("Google models API request failed: #{sanitize_for_log(reason)}")
        {:error, {:request_failed, reason}}
    end
  end

  # ── Private — Response Parsing ─────────────────────────────

  defp parse_anthropic(data) do
    Enum.map(data, fn m ->
      %{
        model_id: m["id"],
        display_name: m["display_name"] || m["id"],
        capabilities: %{}
      }
    end)
  end

  defp parse_openai(data) do
    Enum.map(data, fn m ->
      %{
        model_id: m["id"],
        display_name: m["id"],
        capabilities: %{owned_by: m["owned_by"]}
      }
    end)
  end

  defp parse_google(models) do
    Enum.map(models, fn m ->
      %{
        model_id: m["name"],
        display_name: m["displayName"] || m["name"],
        capabilities: %{
          input_token_limit: m["inputTokenLimit"],
          output_token_limit: m["outputTokenLimit"]
        }
      }
    end)
  end

  # ── Private — API Key Resolution ────────────────────────────

  defp resolve_api_key(opts) do
    case Keyword.get(opts, :api_key) do
      nil -> resolve_via_vault(opts)
      key when is_binary(key) and byte_size(key) > 0 -> {:ok, key}
      _ -> {:error, :invalid_api_key}
    end
  end

  defp resolve_via_vault(opts) do
    workspace_id = Keyword.get(opts, :workspace_id)
    secret_name = Keyword.get(opts, :secret_name)

    cond do
      is_nil(workspace_id) ->
        {:error, :missing_workspace_id}

      is_nil(secret_name) ->
        {:error, :missing_secret_name}

      true ->
        Vault.resolve_secret(workspace_id, secret_name)
    end
  end

  # ── Private — Base URL Resolution ───────────────────────────

  defp base_url(provider, opts) do
    case Keyword.get(opts, :base_url) do
      nil -> configured_url(provider)
      url when is_binary(url) -> url
      other -> raise ArgumentError, "expected :base_url to be a string, got: #{inspect(other)}"
    end
  end

  defp configured_url(provider) do
    config = Application.get_env(:monkey_claw, __MODULE__, [])
    urls = Keyword.get(config, :provider_urls, %{})
    Map.get(urls, provider, Map.get(@default_urls, provider))
  end

  # ── Log Sanitization ────────────────────────────────────────

  @doc false
  # Public only so the test module can call it directly; not part
  # of the public API. Sanitize a term for logging by inspecting it
  # and routing the resulting string through Vault.SecretScanner.
  # Any matched secret is replaced with [REDACTED:LABEL]. On scan
  # failure we return a safe placeholder rather than logging raw
  # content.
  @spec sanitize_for_log(term()) :: String.t()
  def sanitize_for_log(term) do
    inspected = inspect(term, limit: :infinity, printable_limit: 4096)

    case SecretScanner.scan_and_redact(inspected) do
      {:ok, redacted, _count} -> redacted
      {:error, _} -> "[LOG_SANITIZE_FAILED]"
    end
  end
end
