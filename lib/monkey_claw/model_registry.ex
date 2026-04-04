defmodule MonkeyClaw.ModelRegistry do
  @moduledoc """
  GenServer that manages the ETS write-through cache and periodic
  refresh of available AI models from provider APIs.

  The registry maintains a local cache of model lists fetched from
  providers (Anthropic, OpenAI, Google, etc.) with SQLite as the
  durable store and ETS for low-latency reads.

  ## Process Justification

  A GenServer is the correct abstraction because the ModelRegistry is:

    * **Stateful** — owns the ETS table lifecycle and timer reference
    * **Periodic** — must refresh model lists on a configurable interval
    * **Serialized** — write access is serialized to prevent concurrent
      refresh races that could produce inconsistent cache state
    * **Single instance** — one registry per node; MonkeyClaw is a
      single-user, single-instance application

  ## ETS Table Design

  The ETS table stores `{provider, [%CachedModel{}], refreshed_at}`
  tuples. Read-concurrency is enabled since reads dominate. The table
  is `:public` for direct read access from any process; writes go
  through the GenServer.

  ## Graceful Degradation

    * Provider API failure: log warning, keep stale cache, reschedule
    * Vault resolution failure: log warning, skip that provider
    * Never crash the GenServer on refresh failure

  ## Related Modules

    * `MonkeyClaw.ModelRegistry.CachedModel` — Ecto schema
    * `MonkeyClaw.ModelRegistry.Provider` — HTTP fetching
    * `MonkeyClaw.Vault` — API key resolution
  """

  use GenServer

  require Logger

  import Ecto.Query

  alias MonkeyClaw.ModelRegistry.CachedModel
  alias MonkeyClaw.ModelRegistry.Provider
  alias MonkeyClaw.Repo

  @ets_table :monkey_claw_model_registry
  @default_refresh_interval_ms 3_600_000
  @startup_refresh_delay_ms 5_000

  # ── State ───────────────────────────────────────────────────

  defmodule State do
    @moduledoc false

    @enforce_keys [:ets_table, :refresh_interval_ms]
    defstruct [
      :ets_table,
      :refresh_interval_ms,
      :workspace_id,
      :timer_ref,
      provider_secrets: %{},
      refreshing: false
    ]

    @type t :: %__MODULE__{
            ets_table: :ets.table(),
            refresh_interval_ms: pos_integer(),
            workspace_id: Ecto.UUID.t() | nil,
            timer_ref: reference() | nil,
            provider_secrets: %{String.t() => String.t()},
            refreshing: boolean()
          }
  end

  # ── Client API ──────────────────────────────────────────────

  @doc """
  Start the ModelRegistry as a linked process.

  Registers as a named process under `__MODULE__` (single instance).

  ## Options

    * `:refresh_interval_ms` — Override the refresh interval (default: 1 hour)
    * `:workspace_id` — Workspace ID for vault key resolution
    * `:provider_secrets` — Map of provider => secret_name
      (e.g., `%{"anthropic" => "anthropic_key"}`)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  List cached models for a provider.

  Reads from ETS first for low-latency access. Falls back to
  SQLite on cache miss and populates ETS for subsequent reads.

  ## Examples

      iex> ModelRegistry.list_models("anthropic")
      [%CachedModel{provider: "anthropic", model_id: "claude-3-opus-20240229", ...}]
  """
  @spec list_models(String.t()) :: [CachedModel.t()]
  def list_models(provider) when is_binary(provider) do
    case ets_lookup(provider) do
      {:ok, models} ->
        models

      :miss ->
        models = load_from_sqlite(provider)
        ets_put(provider, models)
        models
    end
  end

  @doc """
  List all cached models grouped by provider.

  Returns a map of provider => model list. Reads from ETS with
  SQLite fallback for each configured provider.

  ## Examples

      iex> ModelRegistry.list_all_models()
      %{"anthropic" => [%CachedModel{}, ...], "openai" => [%CachedModel{}, ...]}
  """
  @spec list_all_models() :: %{String.t() => [CachedModel.t()]}
  def list_all_models do
    CachedModel.valid_providers()
    |> Enum.map(fn provider -> {provider, list_models(provider)} end)
    |> Enum.reject(fn {_provider, models} -> models == [] end)
    |> Map.new()
  end

  @doc """
  Force refresh a single provider's model list.

  Fetches from the provider API, upserts into SQLite, updates ETS,
  and removes stale models. Blocks until the refresh completes.

  ## Returns

    * `:ok` — Refresh succeeded
    * `{:error, reason}` — Refresh failed (stale cache preserved)
  """
  @spec refresh(String.t()) :: :ok | {:error, term()}
  def refresh(provider) when is_binary(provider) do
    GenServer.call(__MODULE__, {:refresh, provider}, 30_000)
  end

  @doc """
  Force refresh all configured providers.

  Iterates each provider with a configured secret and refreshes
  sequentially. Returns `:ok` regardless of individual failures
  (failures are logged).
  """
  @spec refresh_all() :: :ok
  def refresh_all do
    GenServer.call(__MODULE__, :refresh_all, 120_000)
  end

  @doc """
  Update runtime configuration.

  Allows changing the workspace ID and provider secret mappings
  without restarting the GenServer.

  ## Options

    * `:workspace_id` — New workspace ID for vault resolution
    * `:provider_secrets` — New provider => secret_name map
  """
  @spec configure(keyword()) :: :ok
  def configure(opts) when is_list(opts) do
    GenServer.call(__MODULE__, {:configure, opts})
  end

  # ── GenServer Callbacks ─────────────────────────────────────

  @impl true
  @spec init(keyword()) :: {:ok, State.t()}
  def init(opts) when is_list(opts) do
    refresh_interval =
      Keyword.get(opts, :refresh_interval_ms, @default_refresh_interval_ms)

    if not is_integer(refresh_interval) or refresh_interval <= 0 do
      raise ArgumentError,
            "refresh_interval_ms must be a positive integer, got: #{inspect(refresh_interval)}"
    end

    ets_table = create_ets_table()
    load_all_from_sqlite(ets_table)

    state = %State{
      ets_table: ets_table,
      refresh_interval_ms: refresh_interval,
      workspace_id: Keyword.get(opts, :workspace_id),
      provider_secrets: Keyword.get(opts, :provider_secrets, %{}),
      timer_ref: nil,
      refreshing: false
    }

    {:ok, schedule_refresh(state, @startup_refresh_delay_ms)}
  end

  @impl true
  def handle_call({:refresh, provider}, _from, %State{} = state) do
    case do_refresh_provider(provider, state) do
      :ok -> {:reply, :ok, state}
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call(:refresh_all, _from, %State{} = state) do
    do_refresh_all(state)
    {:reply, :ok, state}
  end

  def handle_call({:configure, opts}, _from, %State{} = state) do
    state =
      state
      |> maybe_update_workspace_id(opts)
      |> maybe_update_provider_secrets(opts)

    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:scheduled_refresh, %State{refreshing: true} = state) do
    Logger.debug("ModelRegistry: refresh already in progress, rescheduling")
    {:noreply, schedule_refresh(%{state | timer_ref: nil})}
  end

  def handle_info(:scheduled_refresh, %State{} = state) do
    state = %{state | timer_ref: nil, refreshing: true}
    do_refresh_all(state)
    state = %{state | refreshing: false}
    {:noreply, schedule_refresh(state)}
  end

  def handle_info(msg, %State{} = state) do
    Logger.debug("ModelRegistry received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %State{} = state) do
    _state = cancel_timer(state)
    :ok
  end

  # ── Private — Refresh Logic ─────────────────────────────────

  defp do_refresh_all(%State{provider_secrets: secrets} = state) do
    Enum.each(secrets, fn {provider, _secret_name} ->
      case do_refresh_provider(provider, state) do
        :ok ->
          Logger.info("ModelRegistry: refreshed #{provider}")

        {:error, reason} ->
          Logger.warning("ModelRegistry: failed to refresh #{provider}: #{inspect(reason)}")
      end
    end)
  end

  defp do_refresh_provider(provider, %State{} = state) do
    opts = build_provider_opts(provider, state)

    case Provider.fetch_models(provider, opts) do
      {:ok, model_attrs_list} ->
        now = DateTime.utc_now()
        upsert_models(provider, model_attrs_list, now)
        delete_stale_models(provider, model_attrs_list)
        models = load_from_sqlite(provider)
        ets_put(provider, models)
        :ok

      {:error, reason} ->
        Logger.warning(
          "ModelRegistry: provider #{provider} fetch failed: #{inspect(reason)}, keeping stale cache"
        )

        {:error, reason}
    end
  rescue
    error ->
      Logger.warning(
        "ModelRegistry: provider #{provider} refresh crashed: #{Exception.format(:error, error, __STACKTRACE__)}"
      )

      {:error, :refresh_crashed}
  end

  defp build_provider_opts(provider, %State{workspace_id: workspace_id, provider_secrets: secrets}) do
    opts = []
    opts = if workspace_id, do: Keyword.put(opts, :workspace_id, workspace_id), else: opts

    case Map.get(secrets, provider) do
      nil -> opts
      secret_name -> Keyword.put(opts, :secret_name, secret_name)
    end
  end

  # ── Private — SQLite Persistence ────────────────────────────

  defp upsert_models(provider, model_attrs_list, now) do
    Enum.each(model_attrs_list, fn attrs ->
      upsert_single_model(provider, attrs, now)
    end)
  end

  defp upsert_single_model(provider, attrs, now) do
    case Repo.one(
           from(m in CachedModel,
             where: m.provider == ^provider and m.model_id == ^attrs.model_id
           )
         ) do
      nil ->
        %CachedModel{}
        |> CachedModel.create_changeset(%{
          provider: provider,
          model_id: attrs.model_id,
          display_name: attrs.display_name,
          capabilities: attrs.capabilities,
          refreshed_at: now
        })
        |> Repo.insert!()

      existing ->
        existing
        |> CachedModel.update_changeset(%{
          display_name: attrs.display_name,
          capabilities: attrs.capabilities,
          refreshed_at: now
        })
        |> Repo.update!()
    end
  end

  defp delete_stale_models(provider, model_attrs_list) do
    current_model_ids = Enum.map(model_attrs_list, & &1.model_id)

    from(m in CachedModel,
      where: m.provider == ^provider and m.model_id not in ^current_model_ids
    )
    |> Repo.delete_all()
  end

  defp load_from_sqlite(provider) do
    from(m in CachedModel,
      where: m.provider == ^provider,
      order_by: [asc: m.display_name]
    )
    |> Repo.all()
  end

  defp load_all_from_sqlite(ets_table) do
    models_by_provider =
      from(m in CachedModel, order_by: [asc: m.display_name])
      |> Repo.all()
      |> Enum.group_by(& &1.provider)

    Enum.each(models_by_provider, fn {provider, models} ->
      refreshed_at =
        models
        |> Enum.map(& &1.refreshed_at)
        |> Enum.max(fn a, b -> DateTime.compare(a, b) != :lt end, fn -> DateTime.utc_now() end)

      :ets.insert(ets_table, {provider, models, refreshed_at})
    end)
  end

  # ── Private — ETS Operations ────────────────────────────────

  defp create_ets_table do
    case :ets.whereis(@ets_table) do
      :undefined ->
        :ets.new(@ets_table, [:set, :public, :named_table, read_concurrency: true])

      ref ->
        ref
    end
  end

  defp ets_lookup(provider) do
    case :ets.whereis(@ets_table) do
      :undefined ->
        :miss

      _ref ->
        case :ets.lookup(@ets_table, provider) do
          [{^provider, models, _refreshed_at}] -> {:ok, models}
          [] -> :miss
        end
    end
  end

  defp ets_put(provider, models) do
    case :ets.whereis(@ets_table) do
      :undefined ->
        :ok

      _ref ->
        now = DateTime.utc_now()
        :ets.insert(@ets_table, {provider, models, now})
        :ok
    end
  end

  # ── Private — Timer Management ──────────────────────────────

  defp schedule_refresh(%State{refresh_interval_ms: interval} = state) do
    schedule_refresh(state, interval)
  end

  defp schedule_refresh(%State{} = state, delay_ms)
       when is_integer(delay_ms) and delay_ms >= 0 do
    ref = Process.send_after(self(), :scheduled_refresh, delay_ms)
    %{state | timer_ref: ref}
  end

  defp cancel_timer(%State{timer_ref: nil} = state), do: state

  defp cancel_timer(%State{timer_ref: ref} = state) when is_reference(ref) do
    _remaining = Process.cancel_timer(ref, info: false)

    receive do
      :scheduled_refresh -> :ok
    after
      0 -> :ok
    end

    %{state | timer_ref: nil}
  end

  # ── Private — Configure Helpers ─────────────────────────────

  defp maybe_update_workspace_id(state, opts) do
    case Keyword.fetch(opts, :workspace_id) do
      {:ok, workspace_id} -> %{state | workspace_id: workspace_id}
      :error -> state
    end
  end

  defp maybe_update_provider_secrets(state, opts) do
    case Keyword.fetch(opts, :provider_secrets) do
      {:ok, secrets} when is_map(secrets) -> %{state | provider_secrets: secrets}
      _ -> state
    end
  end
end
