defmodule MonkeyClaw.ModelRegistry do
  @moduledoc """
  Unified model registry keyed on `(backend, provider)`.

  Owns the ETS read-through cache and serializes all writes through
  a single `upsert/1` funnel. Four independent writers populate the
  cache: the `Baseline` boot loader, a periodic per-backend probe
  dispatched as `Task.Supervisor` tasks from the registry's own tick
  handler, an authenticated post-start hook from `AgentBridge.Session`,
  and on-demand synchronous probes via `refresh/1` and `refresh_all/0`.
  All four validate through the same changeset before touching SQLite
  or ETS.

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
  @startup_delay_ms_default 5_000
  @claim_timeout_ms 1_000
  @backoff_initial_ms 5_000
  @backoff_max_ms 300_000
  @per_backend_refresh_timeout_ms 30_000

  # ── State ───────────────────────────────────────────────────

  defmodule State do
    @moduledoc false

    @enforce_keys [:ets_table, :default_interval, :backends, :startup_delay_ms]
    defstruct [
      :ets_table,
      :default_interval,
      :startup_delay_ms,
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
            last_probe_at: %{String.t() => integer() | nil},
            in_flight: %{reference() => String.t()},
            backoff: %{String.t() => pos_integer()},
            tick_timer_ref: reference() | nil,
            degraded: boolean(),
            startup_delay_ms: non_neg_integer()
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
  Force an immediate synchronous probe for a single backend.

  Blocks the caller until the probe task completes or times out.
  Bypasses the tick schedule. Returns `:ok` on success,
  `{:error, reason}` on backend failure or timeout.
  """
  @spec refresh(atom() | String.t()) :: :ok | {:error, term()}
  def refresh(backend) do
    backend_str = to_string(backend)
    GenServer.call(__MODULE__, {:refresh, backend_str}, @per_backend_refresh_timeout_ms + 1_000)
  end

  @doc """
  Force-probe every configured backend sequentially.

  Runs on the GenServer loop, so other calls queue until every
  configured backend has been probed or timed out. The call
  deadline is `:infinity` — each inner probe is bounded by
  `@per_backend_refresh_timeout_ms` (30s), and the reduce is
  sequential, so the total upper bound is
  `length(state.backends) * @per_backend_refresh_timeout_ms`.
  """
  @spec refresh_all() :: :ok
  def refresh_all do
    GenServer.call(__MODULE__, :refresh_all, :infinity)
  end

  @doc """
  Update runtime configuration without restarting the GenServer.

  ## Options

    * `:backends` — List of backend identifier strings
    * `:default_interval_ms` — Positive integer
    * `:backend_intervals` — Map of backend => interval (all values ≥ effective default)
    * `:backend_configs` — Map of backend => opts map
    * `:workspace_id` — UUID or nil

  Every option is validated before any change is applied. Invalid
  input returns `{:error, {:invalid_option, key, reason}}` and leaves
  state fully unchanged (no partial application). When both
  `:default_interval_ms` and `:backend_intervals` are supplied in the
  same call, interval values are validated against the pending new
  default, not the current state value.
  """
  @spec configure(keyword()) :: :ok | {:error, {:invalid_option, atom(), term()}}
  def configure(opts) when is_list(opts) do
    GenServer.call(__MODULE__, {:configure, opts})
  end

  @doc """
  Return a map of `backend => [enriched_model]` for every cached row.
  """
  @spec list_all_by_backend() :: %{String.t() => [map()]}
  def list_all_by_backend do
    safe_ets_tab2list(@ets_table)
    |> Enum.reduce(%{}, fn
      {{:row, backend, provider}, row}, acc ->
        enriched = Enum.map(row.models, &enrich(&1, backend, provider, row.refreshed_at))
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
        enriched = Enum.map(row.models, &enrich(&1, backend, provider, row.refreshed_at))
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
    backend_intervals = Keyword.get(opts, :backend_intervals, %{})
    backends = Keyword.get(opts, :backends, [])

    unless is_integer(default_interval) and default_interval > 0 do
      raise ArgumentError,
            "ModelRegistry: default_interval_ms must be a positive integer, got: #{inspect(default_interval)}"
    end

    Enum.each(backend_intervals, fn {backend, interval} ->
      unless is_integer(interval) and interval > 0 do
        raise ArgumentError,
              "ModelRegistry: backend_intervals[#{inspect(backend)}] must be a positive integer, got: #{inspect(interval)}"
      end
    end)

    ets_table = ensure_ets_table()

    state = %State{
      ets_table: ets_table,
      default_interval: default_interval,
      backend_intervals: backend_intervals,
      backends: backends,
      workspace_id: Keyword.get(opts, :workspace_id),
      backend_configs: Keyword.get(opts, :backend_configs, %{}),
      last_probe_at: Map.new(backends, &{&1, nil}),
      in_flight: %{},
      backoff: %{},
      tick_timer_ref: nil,
      degraded: false,
      startup_delay_ms: Keyword.get(opts, :startup_delay_ms, @startup_delay_ms_default)
    }

    {:ok, state, {:continue, :load}}
  end

  @impl true
  def handle_continue(:load, %State{} = state) do
    state = load_existing_and_seed_baseline(state)
    state = schedule_tick(state, state.startup_delay_ms)
    {:noreply, state}
  end

  @impl true
  def handle_call({:upsert, writes}, _from, %State{} = state) do
    result = do_upsert(writes, state)
    {:reply, result, state}
  end

  def handle_call({:refresh, backend}, _from, %State{} = state) do
    case do_synchronous_probe(backend, state) do
      {:ok, new_state} -> {:reply, :ok, new_state}
      {{:error, reason}, new_state} -> {:reply, {:error, reason}, new_state}
    end
  end

  def handle_call(:refresh_all, _from, %State{} = state) do
    state =
      Enum.reduce(state.backends, state, fn backend, acc ->
        {_result, new_state} = do_synchronous_probe(backend, acc)
        new_state
      end)

    {:reply, :ok, state}
  end

  def handle_call({:configure, opts}, _from, %State{} = state) do
    case validate_configure_opts(opts, state) do
      :ok ->
        new_state = apply_configure_opts(opts, state)
        {:reply, :ok, new_state}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_cast({:session_hook, session_pid, writes}, %State{} = state)
      when is_pid(session_pid) and is_list(writes) do
    if session_registered?(session_pid) do
      {:ok, _applied} = do_upsert(writes, state)
      {:noreply, state}
    else
      Logger.debug(
        "ModelRegistry: rejecting session hook from unregistered pid #{inspect(session_pid)}"
      )

      {:noreply, state}
    end
  end

  def handle_cast(_other, state), do: {:noreply, state}

  @impl true
  def handle_info(:tick, %State{} = state) do
    state = Enum.reduce(state.backends, state, &maybe_dispatch_probe/2)
    state = schedule_tick(state, state.default_interval)
    {:noreply, state}
  end

  def handle_info({ref, result}, %State{in_flight: in_flight} = state) when is_reference(ref) do
    case Map.pop(in_flight, ref) do
      {nil, _} ->
        # Not one of ours — probably a late reply after shutdown.
        {:noreply, state}

      {backend, remaining} ->
        # Flush the DOWN message that will follow a successful task.
        Process.demonitor(ref, [:flush])

        state = %{state | in_flight: remaining}
        state = handle_probe_result(backend, result, state)
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %State{in_flight: in_flight} = state)
      when is_reference(ref) do
    case Map.pop(in_flight, ref) do
      {nil, _} ->
        {:noreply, state}

      {backend, remaining} ->
        Logger.warning("ModelRegistry: probe task for #{backend} crashed: #{inspect(reason)}")

        state = %{state | in_flight: remaining}
        state = apply_backoff(backend, state)
        {:noreply, state}
    end
  end

  def handle_info({:"ETS-TRANSFER", _tid, _from, :model_registry}, %State{} = state) do
    Logger.info("ModelRegistry received ETS-TRANSFER of :monkey_claw_model_registry")
    {:noreply, state}
  end

  def handle_info(msg, %State{} = state) do
    Logger.debug("ModelRegistry received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # ── Private — Tick scheduler ─────────────────────────────────

  defp schedule_tick(state, delay_ms) do
    ref = Process.send_after(self(), :tick, delay_ms)
    %{state | tick_timer_ref: ref}
  end

  defp maybe_dispatch_probe(backend, state) do
    cond do
      in_flight?(backend, state) -> state
      not due?(backend, state) -> state
      true -> dispatch_probe(backend, state)
    end
  end

  defp in_flight?(backend, %State{in_flight: map}) do
    Enum.any?(map, fn {_ref, b} -> b == backend end)
  end

  defp due?(backend, state) do
    case Map.get(state.last_probe_at, backend) do
      nil ->
        true

      last ->
        now = System.monotonic_time(:millisecond)
        personal = Map.get(state.backend_intervals, backend, state.default_interval)
        now - last >= personal
    end
  end

  defp dispatch_probe(backend, state) do
    config = Map.get(state.backend_configs, backend, %{})
    adapter = Map.get(config, :adapter, MonkeyClaw.AgentBridge.Backend.BeamAgent)
    opts = Map.delete(config, :adapter)

    task =
      Task.Supervisor.async_nolink(MonkeyClaw.TaskSupervisor, fn ->
        adapter.list_models(opts)
      end)

    %{state | in_flight: Map.put(state.in_flight, task.ref, backend)}
  end

  # ── Private — Synchronous probe ─────────────────────────────

  defp do_synchronous_probe(backend, state) do
    config = Map.get(state.backend_configs, backend, %{})
    adapter = Map.get(config, :adapter, MonkeyClaw.AgentBridge.Backend.BeamAgent)
    opts = Map.delete(config, :adapter)

    task =
      Task.Supervisor.async_nolink(MonkeyClaw.TaskSupervisor, fn ->
        adapter.list_models(opts)
      end)

    timeout =
      opts
      |> Map.get(:probe_deadline_ms, @per_backend_refresh_timeout_ms)
      |> min(@per_backend_refresh_timeout_ms)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, models}} when is_list(models) ->
        new_state = handle_probe_result(backend, {:ok, models}, state)
        {:ok, new_state}

      {:ok, {:error, reason}} ->
        new_state = handle_probe_result(backend, {:error, reason}, state)
        {{:error, reason}, new_state}

      {:ok, malformed} ->
        new_state = handle_probe_result(backend, malformed, state)
        {{:error, {:malformed_probe_result, malformed}}, new_state}

      {:exit, reason} ->
        new_state = apply_backoff(backend, state)
        {{:error, {:probe_crashed, reason}}, new_state}

      nil ->
        new_state = apply_backoff(backend, state)
        {{:error, :probe_timeout}, new_state}
    end
  end

  # ── Private — Probe result handling ─────────────────────────

  defp handle_probe_result(backend, {:ok, []}, state) do
    Logger.debug("ModelRegistry: probe for #{backend} returned empty list, marking healthy")
    state |> reset_backoff(backend) |> mark_probed(backend)
  end

  defp handle_probe_result(backend, {:ok, model_attrs_list}, state)
       when is_list(model_attrs_list) do
    now = DateTime.utc_now()
    mono = System.monotonic_time()

    writes =
      model_attrs_list
      |> Enum.group_by(& &1.provider)
      |> Enum.map(fn {provider, attrs_list} ->
        %{
          backend: backend,
          provider: provider,
          source: "probe",
          refreshed_at: now,
          refreshed_mono: mono,
          models: Enum.map(attrs_list, &Map.delete(&1, :provider))
        }
      end)

    {:ok, _applied} = do_upsert(writes, state)

    state
    |> reset_backoff(backend)
    |> mark_probed(backend)
  end

  defp handle_probe_result(backend, {:error, reason}, state) do
    Logger.warning(
      "ModelRegistry: probe failed for #{backend}: #{inspect(reason)}, keeping stale cache"
    )

    apply_backoff(backend, state)
  end

  defp handle_probe_result(backend, other, state) do
    Logger.warning(
      "ModelRegistry: probe for #{backend} returned malformed result: #{inspect(other)}, " <>
        "treating as error"
    )

    apply_backoff(backend, state)
  end

  defp mark_probed(state, backend) do
    %{
      state
      | last_probe_at: Map.put(state.last_probe_at, backend, System.monotonic_time(:millisecond))
    }
  end

  defp reset_backoff(state, backend) do
    %{state | backoff: Map.delete(state.backoff, backend)}
  end

  defp apply_backoff(backend, state) do
    next =
      case Map.get(state.backoff, backend) do
        nil -> @backoff_initial_ms
        current -> min(current * 2, @backoff_max_ms)
      end

    # Bump last_probe_at so due?/2 skips this backend until `next` ms have passed.
    # due?/2 returns true when `now - last >= interval`. We want it to return
    # false for `next` ms, so we set last such that `now - last = interval - next`.
    interval = Map.get(state.backend_intervals, backend, state.default_interval)
    now_ms = System.monotonic_time(:millisecond)
    bumped_last = now_ms - interval + next

    %{
      state
      | backoff: Map.put(state.backoff, backend, next),
        last_probe_at: Map.put(state.last_probe_at, backend, bumped_last)
    }
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
        Enum.map(row.models, &enrich(&1, backend, provider, row.refreshed_at))

      _ ->
        []
    end)
  end

  defp ets_scan_by_provider(provider) do
    safe_ets_tab2list(@ets_table)
    |> Enum.flat_map(fn
      {{:row, backend, ^provider}, row} ->
        Enum.map(row.models, &enrich(&1, backend, provider, row.refreshed_at))

      _ ->
        []
    end)
  end

  defp enrich(model, backend, provider, refreshed_at) do
    %{
      backend: backend,
      provider: provider,
      model_id: model.model_id,
      display_name: model.display_name,
      capabilities: model.capabilities,
      refreshed_at: refreshed_at
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

  # ── Private — configure/1 validation ────────────────────────

  defp validate_configure_opts(opts, state) do
    effective_default = effective_default_interval(opts, state)

    with :ok <- validate_opt_keys(opts),
         :ok <- validate_default_interval_if_present(opts) do
      validate_rest(opts, state, effective_default)
    end
  end

  defp validate_opt_keys(opts) do
    allowed = [
      :backends,
      :default_interval_ms,
      :backend_intervals,
      :backend_configs,
      :workspace_id
    ]

    Enum.reduce_while(opts, :ok, fn {key, value}, :ok ->
      if key in allowed do
        {:cont, :ok}
      else
        {:halt, {:error, {:invalid_option, key, value}}}
      end
    end)
  end

  defp validate_default_interval_if_present(opts) do
    case Keyword.fetch(opts, :default_interval_ms) do
      {:ok, value} -> validate_option(:default_interval_ms, value, nil)
      :error -> :ok
    end
  end

  defp effective_default_interval(opts, state) do
    Keyword.get(opts, :default_interval_ms, state.default_interval)
  end

  defp validate_rest(opts, state, effective_default) do
    Enum.reduce_while(opts, :ok, fn {key, value}, :ok ->
      case validate_option(key, value, %{state | default_interval: effective_default}) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp validate_option(:default_interval_ms, value, _state)
       when is_integer(value) and value > 0,
       do: :ok

  defp validate_option(:default_interval_ms, value, _state),
    do: {:error, {:invalid_option, :default_interval_ms, value}}

  defp validate_option(:backends, value, _state) when is_list(value) do
    if Enum.all?(value, &is_binary/1) do
      :ok
    else
      {:error, {:invalid_option, :backends, value}}
    end
  end

  defp validate_option(:backends, value, _state),
    do: {:error, {:invalid_option, :backends, value}}

  defp validate_option(:backend_intervals, value, state) when is_map(value) do
    min = state.default_interval

    if Enum.all?(value, fn {k, v} -> is_binary(k) and is_integer(v) and v >= min end) do
      :ok
    else
      {:error, {:invalid_option, :backend_intervals, value}}
    end
  end

  defp validate_option(:backend_intervals, value, _state),
    do: {:error, {:invalid_option, :backend_intervals, value}}

  defp validate_option(:backend_configs, value, _state) when is_map(value), do: :ok

  defp validate_option(:backend_configs, value, _state),
    do: {:error, {:invalid_option, :backend_configs, value}}

  defp validate_option(:workspace_id, nil, _state), do: :ok

  defp validate_option(:workspace_id, value, _state) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, _} -> :ok
      :error -> {:error, {:invalid_option, :workspace_id, value}}
    end
  end

  defp validate_option(key, value, _state),
    do: {:error, {:invalid_option, key, value}}

  defp apply_configure_opts(opts, state) do
    Enum.reduce(opts, state, fn
      {:backends, v}, acc -> %{acc | backends: v}
      {:default_interval_ms, v}, acc -> %{acc | default_interval: v}
      {:backend_intervals, v}, acc -> %{acc | backend_intervals: v}
      {:backend_configs, v}, acc -> %{acc | backend_configs: v}
      {:workspace_id, v}, acc -> %{acc | workspace_id: v}
    end)
  end

  # ── Private — Session hook auth ──────────────────────────────

  # Returns true when the given pid is registered in SessionRegistry,
  # meaning the cast originates from a live AgentBridge session process.
  # Unregistered pids are rejected to prevent unauthenticated writes.
  @spec session_registered?(pid()) :: boolean()
  defp session_registered?(pid) do
    case Registry.keys(MonkeyClaw.AgentBridge.SessionRegistry, pid) do
      [] -> false
      _ -> true
    end
  rescue
    _ -> false
  end
end
