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
  """
  @spec claim(pid()) :: :ok
  def claim(claimer_pid) when is_pid(claimer_pid) do
    GenServer.call(__MODULE__, {:claim, claimer_pid})
  end

  # ── GenServer ───────────────────────────────────────────────

  @impl true
  def init(_) do
    # Create or reuse the ETS table. On re-starts (after a registry
    # crash), the table already exists and is owned by this process —
    # just keep it.
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

        :ok

      _tid ->
        # Re-adopt the table if we have access.
        :ok
    end

    {:ok, %{}}
  end

  @impl true
  def handle_call({:claim, pid}, _from, state) do
    :ets.give_away(@ets_table, pid, :model_registry)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:"ETS-TRANSFER", _tid, _from, :model_registry}, state) do
    # Registry crashed — the table is now ours until the next claim.
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
