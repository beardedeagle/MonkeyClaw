defmodule MonkeyClaw.ModelRegistry.EtsHeir do
  @moduledoc """
  Long-lived heir for the ModelRegistry ETS table.

  Creates the `:monkey_claw_model_registry` ETS table at start time
  with `heir: {self(), :model_registry}` and gives ownership to the
  ModelRegistry GenServer on request. When the registry crashes,
  ownership returns to this process; when the supervisor restarts
  the registry, the restarted process asks for the table back via
  `claim/1`.

  ## Process Justification

    * **Stable owner** — must outlive the ModelRegistry to survive
      its crash/restart cycle
    * **Minimal** — does nothing except own the ETS table and
      transfer ownership on demand

  See spec §Supervision Tree (C4).
  """

  use GenServer

  require Logger

  @ets_table :monkey_claw_model_registry

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Claim ownership of the ETS table for the calling process.

  Called by `MonkeyClaw.ModelRegistry.init/1`. The heir sends
  `{:'ETS-TRANSFER', tid, _heir_pid, :model_registry}` to the caller,
  which the registry handles in `handle_info/2`.

  Returns `:ok` on success, or `{:error, :not_owner}` if the heir
  does not currently own the table.
  """
  @spec claim(pid()) :: :ok | {:error, :not_owner}
  def claim(claimer_pid) when is_pid(claimer_pid) do
    GenServer.call(__MODULE__, {:claim, claimer_pid})
  end

  # ── GenServer ───────────────────────────────────────────────

  @spec init(term()) :: {:ok, %{}} | {:stop, {:ets_table_not_owned, :monkey_claw_model_registry}}
  @impl true
  def init(_) do
    case :ets.whereis(@ets_table) do
      :undefined ->
        _tid =
          :ets.new(@ets_table, [
            :set,
            :public,
            :named_table,
            {:read_concurrency, true},
            {:heir, self(), :model_registry}
          ])

        {:ok, %{}}

      _tid ->
        case :ets.info(@ets_table, :owner) do
          owner when owner == self() ->
            {:ok, %{}}

          _other ->
            {:stop, {:ets_table_not_owned, @ets_table}}
        end
    end
  end

  @impl true
  def handle_call({:claim, pid}, _from, state) do
    case :ets.info(@ets_table, :owner) do
      owner when owner == self() ->
        :ets.give_away(@ets_table, pid, :model_registry)
        {:reply, :ok, state}

      _other ->
        {:reply, {:error, :not_owner}, state}
    end
  end

  @impl true
  def handle_info({:"ETS-TRANSFER", _tid, _from, :model_registry}, state) do
    Logger.warning("EtsHeir reclaimed :monkey_claw_model_registry after ModelRegistry crash")
    {:noreply, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("EtsHeir received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end
end
