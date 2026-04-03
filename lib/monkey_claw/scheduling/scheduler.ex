defmodule MonkeyClaw.Scheduling.Scheduler do
  @moduledoc """
  GenServer that periodically polls for due schedule entries and fires them.

  The Scheduler wakes on a configurable interval, queries for entries
  whose `next_run_at` has passed, and creates experiment runs for each
  one. Individual entry failures are logged but do not affect other
  entries in the same poll cycle.

  ## Process Justification

  A GenServer is the correct abstraction because the Scheduler is:

    * **Stateful** — holds the poll timer reference
    * **Lifecycle-bound** — timer cancellation on terminate
    * **Periodic** — must wake and check for due entries on interval
    * **Single instance** — one scheduler per node; MonkeyClaw is a
      single-user, single-instance application (no multi-node deployment)

  ## Configuration

  The poll interval is configurable via application environment:

      config :monkey_claw, :scheduler_poll_interval_ms, 15_000

  Default: 15,000 ms (15 seconds).

  ## Error Handling

    * Experiment creation failure: log warning, continue to next entry
    * DB errors in due_entries: log error, reschedule poll (don't crash)
    * Individual entry failures don't affect other entries

  ## Related Modules

    * `MonkeyClaw.Scheduling` — Context module for schedule entry persistence
    * `MonkeyClaw.Scheduling.ScheduleEntry` — Schedule entry Ecto schema
    * `MonkeyClaw.Experiments` — Experiment creation
    * `MonkeyClaw.Workspaces` — Workspace lookup
  """

  use GenServer

  require Logger

  alias MonkeyClaw.Experiments
  alias MonkeyClaw.Scheduling
  alias MonkeyClaw.Workspaces

  @default_poll_interval_ms 15_000

  @type t :: %__MODULE__{
          timer_ref: reference() | nil,
          poll_interval: pos_integer()
        }

  defstruct [:timer_ref, :poll_interval]

  # ── Client API ───────────────────────────────────────────────

  @doc """
  Start the Scheduler as a linked process.

  Registers as a named process under `__MODULE__` (single instance).

  ## Options

    * `:poll_interval` — Override the poll interval in milliseconds
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Force an immediate synchronous poll for due schedule entries.

  Blocks until the poll cycle completes. Useful for testing
  and for immediate execution when a new entry is created
  with a `next_run_at` in the past.
  """
  @spec trigger_poll() :: :ok | {:error, :not_running}
  def trigger_poll do
    case Process.whereis(__MODULE__) do
      nil -> {:error, :not_running}
      pid -> GenServer.call(pid, :trigger_poll, 30_000)
    end
  end

  # ── GenServer Callbacks ──────────────────────────────────────

  @impl true
  @spec init(keyword()) :: {:ok, t()}
  def init(opts) when is_list(opts) do
    poll_interval =
      Keyword.get_lazy(opts, :poll_interval, fn ->
        Application.get_env(:monkey_claw, :scheduler_poll_interval_ms, @default_poll_interval_ms)
      end)

    if not is_integer(poll_interval) or poll_interval <= 0 do
      raise ArgumentError,
            "poll_interval must be a positive integer, got: #{inspect(poll_interval)}"
    end

    initial_delay = Keyword.get(opts, :initial_delay, 0)

    if not is_integer(initial_delay) or initial_delay < 0 do
      raise ArgumentError,
            "initial_delay must be a non-negative integer, got: #{inspect(initial_delay)}"
    end

    state = %__MODULE__{
      timer_ref: nil,
      poll_interval: poll_interval
    }

    {:ok, schedule_poll(state, initial_delay)}
  end

  @impl true
  def handle_info(:poll, %__MODULE__{} = state) do
    state = %{state | timer_ref: nil}
    execute_poll()
    {:noreply, schedule_poll(state)}
  end

  def handle_info(msg, %__MODULE__{} = state) do
    Logger.debug("Scheduler received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def handle_call(:trigger_poll, _from, %__MODULE__{} = state) do
    state = cancel_timer(state)
    execute_poll()
    {:reply, :ok, schedule_poll(state)}
  end

  @impl true
  def terminate(_reason, %__MODULE__{} = state) do
    _state = cancel_timer(state)
    :ok
  end

  # ── Private — Poll Execution ─────────────────────────────────

  defp execute_poll do
    entries = fetch_due_entries()
    Enum.each(entries, &safe_fire_entry/1)
  end

  defp safe_fire_entry(entry) do
    fire_entry(entry)
  rescue
    error ->
      Logger.error(
        "Scheduler entry #{entry.id} crashed: #{Exception.format(:error, error, __STACKTRACE__)}"
      )
  end

  defp fetch_due_entries do
    Scheduling.due_entries()
  rescue
    error ->
      Logger.error(
        "Scheduler failed to query due entries: #{Exception.format(:error, error, __STACKTRACE__)}"
      )

      []
  end

  defp fire_entry(entry) do
    Logger.info("Scheduler firing schedule entry #{entry.id} (#{entry.name})")

    with {:ok, workspace} <- Workspaces.get_workspace(entry.workspace_id),
         {:ok, experiment} <- Experiments.create_experiment(workspace, entry.experiment_config) do
      Logger.info("Scheduler created experiment #{experiment.id} from schedule entry #{entry.id}")

      case Scheduling.record_run(entry) do
        {:ok, _updated} ->
          :ok

        {:error, :stale} ->
          # Optimistic lock conflict — defense-in-depth only. The Scheduler is
          # a single GenServer that serializes all polling and firing, so
          # concurrent fire_entry calls cannot happen under normal operation.
          # This branch guards against external callers (e.g., admin tools)
          # that might call record_run on the same entry. The experiment was
          # already created above; do not update using the stale struct.
          Logger.warning(
            "Scheduler hit optimistic lock conflict for entry #{entry.id} — leaving entry unchanged"
          )

          :ok

        {:error, changeset} ->
          # record_run failure means the entry stays active+due, which would
          # cause duplicate experiments on the next poll. Mark failed to prevent
          # infinite re-firing. The experiment was already created above.
          Logger.warning(
            "Scheduler failed to record run for entry #{entry.id}: #{inspect(changeset.errors)} — marking failed"
          )

          mark_entry_failed(entry)
      end
    else
      {:error, :not_found} ->
        Logger.warning(
          "Scheduler skipping entry #{entry.id}: workspace #{entry.workspace_id} not found"
        )

      {:error, %Ecto.Changeset{} = changeset} ->
        Logger.warning(
          "Scheduler failed to create experiment for entry #{entry.id}: #{inspect(changeset.errors)} — marking failed"
        )

        mark_entry_failed(entry)
    end
  end

  # Mark a schedule entry as :failed to prevent infinite retry loops.
  defp mark_entry_failed(entry) do
    case Scheduling.update_schedule_entry(entry, %{status: :failed}) do
      {:ok, _updated} ->
        Logger.info("Scheduler marked entry #{entry.id} as failed")

      {:error, changeset} ->
        Logger.error(
          "Scheduler failed to mark entry #{entry.id} as failed: #{inspect(changeset.errors)}"
        )
    end
  end

  # ── Private — Timer Management ───────────────────────────────

  defp schedule_poll(%__MODULE__{poll_interval: interval} = state) do
    schedule_poll(state, interval)
  end

  defp schedule_poll(%__MODULE__{} = state, delay_ms)
       when is_integer(delay_ms) and delay_ms >= 0 do
    ref = Process.send_after(self(), :poll, delay_ms)
    %{state | timer_ref: ref}
  end

  defp cancel_timer(%__MODULE__{timer_ref: nil} = state), do: state

  defp cancel_timer(%__MODULE__{timer_ref: ref} = state) when is_reference(ref) do
    _remaining = Process.cancel_timer(ref, info: false)

    # Flush any :poll message that arrived between timer fire and cancel.
    # Without this, a stale :poll in the mailbox causes a double poll cycle.
    receive do
      :poll -> :ok
    after
      0 -> :ok
    end

    %{state | timer_ref: nil}
  end
end
