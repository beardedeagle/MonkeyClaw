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
  def set_model(pid, model), do: :beam_agent_core.set_model(pid, model)

  @impl true
  def session_info(pid), do: BeamAgent.session_info(pid)

  @impl true
  def event_subscribe(pid), do: BeamAgent.event_subscribe(pid)

  @impl true
  def receive_event(pid, ref, timeout), do: BeamAgent.receive_event(pid, ref, timeout)

  @impl true
  def thread_start(pid, opts), do: BeamAgent.Threads.thread_start(pid, opts)

  @impl true
  def thread_resume(pid, thread_id), do: BeamAgent.Threads.thread_resume(pid, thread_id)

  @impl true
  def thread_list(pid), do: BeamAgent.Threads.thread_list(pid)
end
