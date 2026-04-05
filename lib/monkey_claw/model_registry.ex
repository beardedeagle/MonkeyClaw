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

  alias MonkeyClaw.ModelRegistry.Baseline
  alias MonkeyClaw.ModelRegistry.CachedModel
  alias MonkeyClaw.ModelRegistry.EtsHeir
  alias MonkeyClaw.Repo

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
  Apply a batch of writes to the cache.

  Each write is a map with keys `:backend`, `:provider`, `:source`,
  `:refreshed_at`, `:refreshed_mono`, `:models`. Every write is
  validated through `CachedModel.changeset/2` — invalid writes are
  dropped with a log. Valid writes go through a single SQLite
  transaction with conditional upsert precedence on
  `(refreshed_at, refreshed_mono)`. Returns the list of rows that
  actually won their conditional upsert (stale writes are silently
  dropped).

  ETS is updated only after the transaction commits, so ETS rows
  always correspond to persisted SQLite rows.

  This is the single write funnel — every writer (baseline, probe,
  session) ends here.
  """
  @spec upsert([map()]) :: {:ok, [CachedModel.t()]}
  def upsert(writes) when is_list(writes) do
    GenServer.call(__MODULE__, {:upsert, writes}, 30_000)
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
  @spec init(keyword()) :: {:ok, State.t(), {:continue, :load}}
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
      tick_timer_ref: nil,
      degraded: false
    }

    {:ok, state, {:continue, :load}}
  end

  @impl true
  def handle_continue(:load, %State{} = state) do
    state = load_existing_and_seed_baseline(state)
    {:noreply, state}
  end

  @impl true
  def handle_call({:upsert, writes}, _from, %State{} = state) do
    result = do_upsert(writes, state)
    {:reply, result, state}
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

  # ── Private — Upsert funnel ──────────────────────────────────

  defp do_upsert(writes, state) do
    {valid_changesets, dropped} = validate_writes(writes)

    if dropped > 0 do
      Logger.warning("ModelRegistry: dropped #{dropped} invalid upsert writes")
    end

    {:ok, applied} = Repo.transaction(fn -> apply_upserts(valid_changesets) end)

    Enum.each(applied, fn row ->
      :ets.insert(state.ets_table, {{:row, row.backend, row.provider}, row})
    end)

    {:ok, applied}
  end

  defp validate_writes(writes) do
    {valid, dropped} =
      Enum.reduce(writes, {[], 0}, fn write, {acc, dropped} ->
        changeset = CachedModel.changeset(%CachedModel{}, write)

        if changeset.valid? do
          {[{write, changeset} | acc], dropped}
        else
          Logger.warning(
            "ModelRegistry: rejecting write for " <>
              "#{inspect({Map.get(write, :backend), Map.get(write, :provider)})}: " <>
              "#{inspect(changeset.errors)}"
          )

          {acc, dropped + 1}
        end
      end)

    {Enum.reverse(valid), dropped}
  end

  defp apply_upserts(valid_changesets) do
    Enum.reduce(valid_changesets, [], fn {write, changeset}, applied ->
      case upsert_single_row(write, changeset) do
        {:ok, row} ->
          [row | applied]

        :skipped ->
          applied

        {:error, reason} ->
          Logger.warning(
            "ModelRegistry: upsert failed for #{inspect({write.backend, write.provider})}: " <>
              inspect(reason)
          )

          applied
      end
    end)
    |> Enum.reverse()
  end

  # Serialized writes run entirely inside the GenServer, so the
  # conditional precedence check does not need to live in raw SQL.
  # An in-process read-then-compare-then-write is race-free here
  # because no other process writes to cached_models. The spec's
  # ON CONFLICT ... WHERE SQL is an equivalent expression of the
  # same precedence rule.
  defp upsert_single_row(write, changeset) do
    existing =
      Repo.get_by(CachedModel, backend: write.backend, provider: write.provider)

    cond do
      is_nil(existing) ->
        Repo.insert(changeset)

      newer?(write, existing) ->
        existing
        |> CachedModel.changeset(write)
        |> Repo.update()

      true ->
        :skipped
    end
  end

  defp newer?(write, %CachedModel{refreshed_at: existing_at, refreshed_mono: existing_mono}) do
    case DateTime.compare(write.refreshed_at, existing_at) do
      :gt -> true
      :lt -> false
      :eq -> write.refreshed_mono > existing_mono
    end
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

  # ── Private — Boot sequence ──────────────────────────────────

  defp load_existing_and_seed_baseline(state) do
    case load_sqlite_rows() do
      {:ok, rows} ->
        populate_ets(state.ets_table, rows)
        :ok = seed_baseline_delta(state, rows)
        state

      {:error, reason} ->
        Logger.warning(
          "ModelRegistry: SQLite load failed (#{inspect(reason)}), falling back to baseline-only ETS"
        )

        :ok = seed_baseline_ets_only(state)
        %{state | degraded: true}
    end
  end

  defp load_sqlite_rows do
    {:ok, Repo.all(CachedModel)}
  rescue
    # Degraded mode triggers only on environmental DB failures
    # (connection down, file locked, corrupt page) — not on
    # programming bugs like schema mismatches.
    e in [DBConnection.ConnectionError, Exqlite.Error] ->
      {:error, e}
  end

  defp populate_ets(table, rows) do
    Enum.each(rows, fn %CachedModel{} = row ->
      :ets.insert(table, {{:row, row.backend, row.provider}, row})
    end)
  end

  defp seed_baseline_delta(state, existing_rows) do
    existing_keys =
      MapSet.new(existing_rows, fn %CachedModel{backend: b, provider: p} -> {b, p} end)

    {:ok, entries} = Baseline.load!()
    now = DateTime.utc_now()
    mono = System.monotonic_time()

    entries
    |> Enum.reject(fn entry -> MapSet.member?(existing_keys, {entry.backend, entry.provider}) end)
    |> Enum.each(fn entry ->
      attrs = %{
        backend: entry.backend,
        provider: entry.provider,
        source: "baseline",
        refreshed_at: now,
        refreshed_mono: mono,
        models: entry.models
      }

      case %CachedModel{} |> CachedModel.changeset(attrs) |> Repo.insert() do
        {:ok, row} ->
          :ets.insert(state.ets_table, {{:row, row.backend, row.provider}, row})

        {:error, changeset} ->
          Logger.warning(
            "ModelRegistry: baseline entry rejected by changeset: #{inspect(changeset.errors)}"
          )
      end
    end)

    :ok
  end

  defp seed_baseline_ets_only(state) do
    {:ok, entries} = Baseline.load!()
    now = DateTime.utc_now()

    Enum.each(entries, fn entry ->
      models =
        Enum.map(entry.models, fn m ->
          struct(CachedModel.Model, m)
        end)

      row = %CachedModel{
        backend: entry.backend,
        provider: entry.provider,
        source: "baseline",
        refreshed_at: now,
        refreshed_mono: System.monotonic_time(),
        models: models
      }

      :ets.insert(state.ets_table, {{:row, entry.backend, entry.provider}, row})
    end)

    :ok
  end
end
