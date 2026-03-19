defmodule MonkeyClaw.AgentBridge.Telemetry do
  @moduledoc """
  Telemetry event definitions and emission helpers for the AgentBridge.

  All events use the `[:monkey_claw, :agent_bridge, ...]` prefix.

  ## Session Events

    * `[:monkey_claw, :agent_bridge, :session, :start]` — Emitted when a session starts.
      * Measurements: `%{system_time: integer()}`
      * Metadata: `%{session_id: String.t(), config: map()}`

    * `[:monkey_claw, :agent_bridge, :session, :stop]` — Emitted when a session stops.
      * Measurements: `%{duration: integer()}`
      * Metadata: `%{session_id: String.t(), reason: term()}`

    * `[:monkey_claw, :agent_bridge, :session, :exception]` — Emitted on session crash.
      * Measurements: `%{duration: integer()}`
      * Metadata: `%{session_id: String.t(), kind: atom(), reason: term()}`

  ## Query Events

    * `[:monkey_claw, :agent_bridge, :query, :start]` — Emitted when a query begins.
      * Measurements: `%{system_time: integer()}`
      * Metadata: `%{session_id: String.t()}`

    * `[:monkey_claw, :agent_bridge, :query, :stop]` — Emitted when a query completes.
      * Measurements: `%{duration: integer()}`
      * Metadata: `%{session_id: String.t()}`

    * `[:monkey_claw, :agent_bridge, :query, :exception]` — Emitted on query failure.
      * Measurements: `%{duration: integer()}`
      * Metadata: `%{session_id: String.t(), kind: atom(), reason: term()}`

  ## Event Bridge Events

    * `[:monkey_claw, :agent_bridge, :event, :received]` — Emitted for each BeamAgent event.
      * Measurements: `%{count: 1}`
      * Metadata: `%{session_id: String.t(), event_type: atom()}`
  """

  @prefix [:monkey_claw, :agent_bridge]

  # --- Session Events ---

  @doc """
  Emit a session start event.

  Returns the monotonic start time for subsequent duration tracking
  via `session_stop/2` or `session_exception/2`.
  """
  @spec session_start(map()) :: integer()
  def session_start(metadata) when is_map(metadata) do
    start_time = System.monotonic_time()

    :telemetry.execute(
      @prefix ++ [:session, :start],
      %{system_time: System.system_time()},
      metadata
    )

    start_time
  end

  @doc "Emit a session stop event with duration since `start_time`."
  @spec session_stop(integer(), map()) :: :ok
  def session_stop(start_time, metadata)
      when is_integer(start_time) and is_map(metadata) do
    :telemetry.execute(
      @prefix ++ [:session, :stop],
      %{duration: System.monotonic_time() - start_time},
      metadata
    )
  end

  @doc "Emit a session exception event with duration since `start_time`."
  @spec session_exception(integer(), map()) :: :ok
  def session_exception(start_time, metadata)
      when is_integer(start_time) and is_map(metadata) do
    :telemetry.execute(
      @prefix ++ [:session, :exception],
      %{duration: System.monotonic_time() - start_time},
      metadata
    )
  end

  # --- Query Events ---

  @doc """
  Emit a query start event.

  Returns the monotonic start time for subsequent duration tracking
  via `query_stop/2` or `query_exception/2`.
  """
  @spec query_start(map()) :: integer()
  def query_start(metadata) when is_map(metadata) do
    start_time = System.monotonic_time()

    :telemetry.execute(
      @prefix ++ [:query, :start],
      %{system_time: System.system_time()},
      metadata
    )

    start_time
  end

  @doc "Emit a query stop event with duration since `start_time`."
  @spec query_stop(integer(), map()) :: :ok
  def query_stop(start_time, metadata)
      when is_integer(start_time) and is_map(metadata) do
    :telemetry.execute(
      @prefix ++ [:query, :stop],
      %{duration: System.monotonic_time() - start_time},
      metadata
    )
  end

  @doc "Emit a query exception event with duration since `start_time`."
  @spec query_exception(integer(), map()) :: :ok
  def query_exception(start_time, metadata)
      when is_integer(start_time) and is_map(metadata) do
    :telemetry.execute(
      @prefix ++ [:query, :exception],
      %{duration: System.monotonic_time() - start_time},
      metadata
    )
  end

  # --- Event Bridge Events ---

  @doc "Emit an event received notification."
  @spec event_received(map()) :: :ok
  def event_received(metadata) when is_map(metadata) do
    :telemetry.execute(
      @prefix ++ [:event, :received],
      %{count: 1},
      metadata
    )
  end
end
