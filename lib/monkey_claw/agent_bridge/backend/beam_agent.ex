defmodule MonkeyClaw.AgentBridge.Backend.BeamAgent do
  @moduledoc """
  Production backend adapter wrapping the BeamAgent runtime.

  Each callback delegates to the corresponding `BeamAgent` or
  `BeamAgent.Threads` function. This module exists solely to
  satisfy the `MonkeyClaw.AgentBridge.Backend` behaviour contract,
  keeping the Session GenServer decoupled from the concrete
  BeamAgent API.

  This is the default backend used when no `:backend` key is
  present in the session config.
  """

  @behaviour MonkeyClaw.AgentBridge.Backend

  @impl true
  def start_session(opts), do: BeamAgent.start_session(opts)

  @impl true
  def stop_session(pid), do: BeamAgent.stop(pid)

  @impl true
  def query(pid, prompt, params) when map_size(params) == 0 do
    BeamAgent.query(pid, prompt)
  end

  def query(pid, prompt, params) do
    BeamAgent.query(pid, prompt, params)
  end

  @impl true
  def stream(pid, prompt, params) do
    {:ok, BeamAgent.stream(pid, prompt, params)}
  end

  # BeamAgent.set_model/2 and BeamAgent.set_permission_mode/2 are not yet
  # exported by beam_agent_ex. Suppress Dialyzer call_to_missing with
  # @dialyzer annotations; the function_exported?/3 guard ensures runtime
  # safety until the API is available.

  @dialyzer {:nowarn_function, set_model: 2}
  @impl true
  def set_model(pid, model) do
    if function_exported?(BeamAgent, :set_model, 2) do
      BeamAgent.set_model(pid, model)
    else
      {:error, :not_supported}
    end
  end

  @dialyzer {:nowarn_function, set_permission_mode: 2}
  @impl true
  def set_permission_mode(pid, mode) do
    if function_exported?(BeamAgent, :set_permission_mode, 2) do
      BeamAgent.set_permission_mode(pid, mode)
    else
      {:error, :not_supported}
    end
  end

  @impl true
  def session_info(pid), do: BeamAgent.session_info(pid)

  @impl true
  def event_subscribe(pid), do: BeamAgent.event_subscribe(pid)

  @impl true
  def receive_event(pid, ref, timeout), do: BeamAgent.receive_event(pid, ref, timeout)

  @impl true
  def event_unsubscribe(pid, ref), do: BeamAgent.event_unsubscribe(pid, ref)

  @impl true
  def thread_start(pid, opts), do: BeamAgent.Threads.thread_start(pid, opts)

  @impl true
  def thread_resume(pid, thread_id), do: BeamAgent.Threads.thread_resume(pid, thread_id)

  @impl true
  def thread_list(pid), do: BeamAgent.Threads.thread_list(pid)

  # ── Checkpoint Operations ────────────────────────────────────

  # BeamAgent.Checkpoint may not yet export these functions.
  # Suppress Dialyzer warnings; function_exported?/3 guard
  # ensures runtime safety until the API is available.

  @impl true
  def checkpoint_save(pid, label) do
    if function_exported?(BeamAgent.Checkpoint, :save, 2) do
      apply(BeamAgent.Checkpoint, :save, [pid, label])
    else
      {:error, :not_supported}
    end
  end

  @impl true
  def checkpoint_rewind(pid, checkpoint_id) do
    if function_exported?(BeamAgent.Checkpoint, :rewind, 2) do
      apply(BeamAgent.Checkpoint, :rewind, [pid, checkpoint_id])
    else
      {:error, :not_supported}
    end
  end
end
