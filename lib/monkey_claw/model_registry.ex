defmodule MonkeyClaw.ModelRegistry do
  @moduledoc """
  Unified model registry keyed on `(backend, provider)`.

  Owns the ETS read-through cache and serializes all writes through
  a single `upsert/1` funnel. Three independent writers populate the
  cache: the `Baseline` boot loader, a periodic per-backend probe
  dispatched as `Task.Supervisor` tasks from the registry's own tick
  handler, and an authenticated post-start hook from
  `AgentBridge.Session`. All three validate through the same
  changeset before touching SQLite or ETS.

  ## Process Justification

    * **Stateful** — owns ETS table lifecycle via heir and maintains
      per-backend probe schedules
    * **Serialized** — writes funnel through a single process to avoid
      race conditions on the conditional upsert precedence
    * **Single instance** — registered under `__MODULE__`; one
      registry per node

  See `docs/superpowers/specs/2026-04-05-list-models-per-backend-design.md`
  for the full design.
  """

  use GenServer

  require Logger

  alias MonkeyClaw.ModelRegistry.EtsHeir

  @ets_table :monkey_claw_model_registry
  @default_interval_ms :timer.hours(24)
  @claim_timeout_ms 1_000

  # ── State ───────────────────────────────────────────────────

  defmodule State do
    @moduledoc false

    @enforce_keys [:ets_table, :default_interval, :backends]
    defstruct [
      :ets_table,
      :default_interval,
      backend_intervals: %{},
      backends: [],
      workspace_id: nil,
      backend_configs: %{},
      last_probe_at: %{},
      in_flight: %{},
      backoff: %{},
      tick_timer_ref: nil,
      degraded: false
    ]

    @type t :: %__MODULE__{
            ets_table: :ets.table(),
            default_interval: pos_integer(),
            backend_intervals: %{String.t() => pos_integer()},
            backends: [String.t()],
            workspace_id: Ecto.UUID.t() | nil,
            backend_configs: %{String.t() => map()},
            last_probe_at: %{String.t() => integer()},
            in_flight: %{reference() => String.t()},
            backoff: %{String.t() => pos_integer()},
            tick_timer_ref: reference() | nil,
            degraded: boolean()
          }
  end

  # ── Client API ──────────────────────────────────────────────

  @doc """
  Start the ModelRegistry under `__MODULE__`.

  ## Options

    * `:backends` — List of backend identifier strings (default: `[]`)
    * `:default_interval_ms` — Tick interval, floor cadence (default: 24h)
    * `:backend_intervals` — Per-backend interval overrides (must be ≥ default)
    * `:backend_configs` — Per-backend opts passed to `list_models/1`
    * `:workspace_id` — Default workspace for vault resolution
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Return all cached models for a single backend.

  Accepts atom or string `backend`. Normalizes via `to_string/1`.
  Returns an empty list when the backend has no rows.
  """
  @spec list_for_backend(atom() | String.t()) :: [map()]
  def list_for_backend(backend) do
    backend_str = to_string(backend)
    ets_scan_by_backend(backend_str)
  end

  @doc """
  Return all cached models for a single provider, across every backend.
  """
  @spec list_for_provider(String.t()) :: [map()]
  def list_for_provider(provider) when is_binary(provider) do
    ets_scan_by_provider(provider)
  end

  @doc """
  Return a map of `backend => [enriched_model]` for every cached row.
  """
  @spec list_all_by_backend() :: %{String.t() => [map()]}
  def list_all_by_backend do
    safe_ets_tab2list(@ets_table)
    |> Enum.reduce(%{}, fn
      {{:row, backend, provider}, row}, acc ->
        enriched = Enum.map(row.models, &enrich(&1, backend, provider))
        Map.update(acc, backend, enriched, &(&1 ++ enriched))

      _, acc ->
        acc
    end)
  end

  @doc """
  Return a map of `provider => [enriched_model]` for every cached row.
  """
  @spec list_all_by_provider() :: %{String.t() => [map()]}
  def list_all_by_provider do
    safe_ets_tab2list(@ets_table)
    |> Enum.reduce(%{}, fn
      {{:row, backend, provider}, row}, acc ->
        enriched = Enum.map(row.models, &enrich(&1, backend, provider))
        Map.update(acc, provider, enriched, &(&1 ++ enriched))

      _, acc ->
        acc
    end)
  end

  # ── GenServer Callbacks ─────────────────────────────────────

  @impl true
  @spec init(keyword()) :: {:ok, State.t()}
  def init(opts) when is_list(opts) do
    app_config = Application.get_env(:monkey_claw, __MODULE__, [])
    opts = Keyword.merge(app_config, opts)

    default_interval = Keyword.get(opts, :default_interval_ms, @default_interval_ms)
    backends = Keyword.get(opts, :backends, [])

    ets_table = ensure_ets_table()

    state = %State{
      ets_table: ets_table,
      default_interval: default_interval,
      backend_intervals: Keyword.get(opts, :backend_intervals, %{}),
      backends: backends,
      workspace_id: Keyword.get(opts, :workspace_id),
      backend_configs: Keyword.get(opts, :backend_configs, %{}),
      last_probe_at: Map.new(backends, &{&1, 0}),
      in_flight: %{},
      backoff: %{},
      tick_timer_ref: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_info({:"ETS-TRANSFER", _tid, _from, :model_registry}, %State{} = state) do
    Logger.info("ModelRegistry received ETS-TRANSFER of :monkey_claw_model_registry")
    {:noreply, state}
  end

  def handle_info(msg, %State{} = state) do
    Logger.debug("ModelRegistry received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # ── Private — ETS ───────────────────────────────────────────

  defp ensure_ets_table do
    case Process.whereis(EtsHeir) do
      nil ->
        # Standalone start (tests without the full tree) — create directly.
        case :ets.whereis(@ets_table) do
          :undefined ->
            :ets.new(@ets_table, [:set, :public, :named_table, read_concurrency: true])

          ref ->
            ref
        end

      _pid ->
        case EtsHeir.claim(self()) do
          :ok -> :ok
          {:error, reason} -> raise "ModelRegistry: EtsHeir claim failed: #{inspect(reason)}"
        end

        # Wait for the give_away message before returning.
        receive do
          {:"ETS-TRANSFER", _tid, _from, :model_registry} -> :ok
        after
          @claim_timeout_ms ->
            raise "ModelRegistry: timeout claiming ETS table from EtsHeir after #{@claim_timeout_ms}ms"
        end

        :ets.whereis(@ets_table)
    end
  end

  defp safe_ets_tab2list(table) do
    case :ets.whereis(table) do
      :undefined -> []
      _ -> :ets.tab2list(table)
    end
  end

  defp ets_scan_by_backend(backend) do
    safe_ets_tab2list(@ets_table)
    |> Enum.flat_map(fn
      {{:row, ^backend, provider}, row} ->
        Enum.map(row.models, &enrich(&1, backend, provider))

      _ ->
        []
    end)
  end

  defp ets_scan_by_provider(provider) do
    safe_ets_tab2list(@ets_table)
    |> Enum.flat_map(fn
      {{:row, backend, ^provider}, row} ->
        Enum.map(row.models, &enrich(&1, backend, provider))

      _ ->
        []
    end)
  end

  defp enrich(model, backend, provider) do
    %{
      backend: backend,
      provider: provider,
      model_id: model.model_id,
      display_name: model.display_name,
      capabilities: model.capabilities
    }
  end
end
