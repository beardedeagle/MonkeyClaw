defmodule MonkeyClaw.UserModeling.Observer do
  @moduledoc """
  GenServer that receives observations asynchronously and batches DB writes.

  The Observer decouples observation collection from persistence,
  accumulating observations in memory and flushing them to the
  database on a periodic timer. This prevents observation recording
  from blocking the query pipeline.

  ## Process Justification

    * **Stateful** — Holds an accumulated observations buffer
    * **Lifecycle-bound** — Must flush buffer on terminate to avoid data loss
    * **Periodic** — Flush timer for batched writes at configurable intervals
    * **Async** — Observation processing does not block the query pipeline

  ## Buffer Design

  Observations are accumulated in a map keyed by workspace ID:

      %{workspace_id => [observation, ...]}

  On flush, observations for each workspace are merged into a single
  observation and passed to `UserModeling.record_observation/2`. The
  buffer is cleared after each flush regardless of individual workspace
  success or failure.

  ## Configuration

  The flush interval is configurable via Application env:

      config :monkey_claw, :observer_flush_interval_ms, 30_000

  ## Registration

  Named process `#{__MODULE__}` — single instance per node.
  """

  use GenServer

  require Logger

  alias MonkeyClaw.UserModeling

  @default_flush_interval_ms 30_000

  @type observation :: %{required(:prompt) => String.t(), optional(:response) => String.t()}

  @type t :: %__MODULE__{
          timer_ref: reference() | nil,
          flush_interval: pos_integer(),
          buffer: %{Ecto.UUID.t() => [observation()]}
        }

  defstruct [:timer_ref, :flush_interval, buffer: %{}]

  # ──────────────────────────────────────────────
  # Public API
  # ──────────────────────────────────────────────

  @doc """
  Start the Observer GenServer.

  ## Options

    * `:flush_interval_ms` — Override the flush interval in milliseconds
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Record an observation for a workspace asynchronously.

  The observation is buffered and will be flushed to the database
  on the next flush cycle. This call is non-blocking (cast).

  ## Examples

      Observer.observe(workspace_id, %{prompt: "How do I deploy?", response: "Use mix release..."})
  """
  @spec observe(Ecto.UUID.t(), observation()) :: :ok
  def observe(workspace_id, %{prompt: _} = observation)
      when is_binary(workspace_id) and byte_size(workspace_id) > 0 do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> GenServer.cast(pid, {:observe, workspace_id, observation})
    end
  end

  @doc """
  Force an immediate synchronous flush of the observation buffer.

  Blocks until the flush is complete. Primarily used for testing
  to ensure observations are persisted before assertions.
  """
  @spec flush() :: :ok
  def flush do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> GenServer.call(pid, :flush)
    end
  end

  @doc """
  Return the count of pending observations across all workspaces.

  Returns 0 when the Observer is not running. Useful for telemetry
  and testing.
  """
  @spec buffer_size() :: non_neg_integer()
  def buffer_size do
    case Process.whereis(__MODULE__) do
      nil -> 0
      pid -> GenServer.call(pid, :buffer_size)
    end
  end

  # ──────────────────────────────────────────────
  # GenServer Callbacks
  # ──────────────────────────────────────────────

  @impl true
  @spec init(keyword()) :: {:ok, t()}
  def init(opts) when is_list(opts) do
    flush_interval =
      Keyword.get_lazy(opts, :flush_interval_ms, fn ->
        Application.get_env(:monkey_claw, :observer_flush_interval_ms, @default_flush_interval_ms)
      end)

    timer_ref = schedule_flush(flush_interval)

    {:ok, %__MODULE__{timer_ref: timer_ref, flush_interval: flush_interval}}
  end

  @impl true
  def handle_cast({:observe, workspace_id, observation}, %__MODULE__{} = state) do
    updated_buffer =
      Map.update(state.buffer, workspace_id, [observation], fn existing ->
        [observation | existing]
      end)

    {:noreply, %{state | buffer: updated_buffer}}
  end

  @impl true
  def handle_info(:flush, %__MODULE__{} = state) do
    state = do_flush(state)
    timer_ref = schedule_flush(state.flush_interval)
    {:noreply, %{state | timer_ref: timer_ref}}
  end

  @impl true
  def handle_call(:flush, _from, %__MODULE__{} = state) do
    state = do_flush(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:buffer_size, _from, %__MODULE__{} = state) do
    count =
      state.buffer
      |> Map.values()
      |> Enum.reduce(0, fn observations, acc -> acc + length(observations) end)

    {:reply, count, state}
  end

  @impl true
  def terminate(_reason, %__MODULE__{} = state) do
    _state = do_flush(state)
    cancel_timer(state.timer_ref)
    :ok
  end

  # ──────────────────────────────────────────────
  # Private — Flush Logic
  # ──────────────────────────────────────────────

  defp do_flush(%__MODULE__{buffer: buffer} = state) when map_size(buffer) == 0 do
    state
  end

  defp do_flush(%__MODULE__{buffer: buffer} = state) do
    failed =
      Enum.reduce(buffer, %{}, fn {workspace_id, observations}, acc ->
        merged = merge_observations(observations)

        case flush_workspace(workspace_id, merged) do
          :ok -> acc
          :error -> Map.put(acc, workspace_id, observations)
        end
      end)

    %{state | buffer: failed}
  end

  defp flush_workspace(workspace_id, observation) do
    UserModeling.record_observation(workspace_id, observation)
    :ok
  rescue
    error ->
      Logger.warning("Observer flush failed for workspace_id=#{workspace_id}: #{inspect(error)}")
      :error
  end

  # Merge multiple observations into a single observation.
  # Concatenates prompts (newline-separated) and uses the last response.
  defp merge_observations([single]), do: single

  defp merge_observations(observations) do
    reversed = Enum.reverse(observations)

    merged_prompt =
      Enum.map_join(reversed, "\n", & &1.prompt)

    last_response =
      reversed
      |> Enum.reduce(nil, fn obs, acc -> Map.get(obs, :response, acc) end)

    base = %{prompt: merged_prompt}

    case last_response do
      nil -> base
      response -> Map.put(base, :response, response)
    end
  end

  # ──────────────────────────────────────────────
  # Private — Timer Management
  # ──────────────────────────────────────────────

  defp schedule_flush(interval) do
    Process.send_after(self(), :flush, interval)
  end

  defp cancel_timer(nil), do: :ok

  defp cancel_timer(ref) do
    _remaining = Process.cancel_timer(ref)
    :ok
  end
end
