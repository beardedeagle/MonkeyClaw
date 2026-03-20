defmodule MonkeyClaw.AgentBridge.Backend.Test do
  @moduledoc false
  # Test-only backend adapter that provides a real GenServer process
  # simulating BeamAgent session behaviour.
  #
  # This is NOT a mock. It is a real OTP process that the Session
  # GenServer can monitor, query, and stop — exercising the same
  # code paths as production without requiring the BeamAgent runtime.
  #
  # ## Configuration via session_opts
  #
  #   * `:session_id`      — ID returned by session_info (auto-generated)
  #   * `:query_responses`  — `:default` | list of `{:ok, msgs} | {:error, reason}`
  #                           | `(prompt, count -> response)` function
  #   * `:events`           — list of event maps to drain via receive_event
  #   * `:start_error`      — if set, start_session returns `{:error, value}`
  #                           without starting a process

  use GenServer

  @behaviour MonkeyClaw.AgentBridge.Backend

  # ── Backend Callbacks ─────────────────────────────────────────────

  @impl MonkeyClaw.AgentBridge.Backend
  def start_session(%{start_error: reason}), do: {:error, reason}
  def start_session(opts), do: GenServer.start(__MODULE__, opts)

  @impl MonkeyClaw.AgentBridge.Backend
  def stop_session(pid) do
    GenServer.stop(pid, :normal)
    :ok
  catch
    :exit, _ -> :ok
  end

  @impl MonkeyClaw.AgentBridge.Backend
  def query(pid, prompt, params) do
    GenServer.call(pid, {:query, prompt, params})
  end

  @impl MonkeyClaw.AgentBridge.Backend
  def session_info(pid) do
    GenServer.call(pid, :session_info)
  end

  @impl MonkeyClaw.AgentBridge.Backend
  def event_subscribe(pid) do
    GenServer.call(pid, :event_subscribe)
  end

  @impl MonkeyClaw.AgentBridge.Backend
  def receive_event(pid, ref, timeout) do
    GenServer.call(pid, {:receive_event, ref, timeout})
  end

  @impl MonkeyClaw.AgentBridge.Backend
  def thread_start(pid, opts) do
    GenServer.call(pid, {:thread_start, opts})
  end

  @impl MonkeyClaw.AgentBridge.Backend
  def thread_resume(pid, thread_id) do
    GenServer.call(pid, {:thread_resume, thread_id})
  end

  @impl MonkeyClaw.AgentBridge.Backend
  def thread_list(pid) do
    GenServer.call(pid, :thread_list)
  end

  # ── GenServer State ───────────────────────────────────────────────

  defstruct [
    :session_id,
    :event_ref,
    query_responses: :default,
    query_count: 0,
    threads: %{},
    events: []
  ]

  # ── GenServer Callbacks ───────────────────────────────────────────

  @impl GenServer
  def init(opts) when is_map(opts) do
    state = %__MODULE__{
      session_id: Map.get(opts, :session_id, "test-beam-#{:erlang.unique_integer([:positive])}"),
      query_responses: Map.get(opts, :query_responses, :default),
      events: Map.get(opts, :events, [])
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:query, prompt, _params}, _from, state) do
    {response, new_state} = produce_response(state, prompt)
    {:reply, response, new_state}
  end

  def handle_call(:session_info, _from, state) do
    info = %{session_id: state.session_id, backend: :test, state: :ready}
    {:reply, {:ok, info}, state}
  end

  def handle_call(:event_subscribe, _from, state) do
    ref = make_ref()
    {:reply, {:ok, ref}, %{state | event_ref: ref}}
  end

  def handle_call({:receive_event, ref, _timeout}, _from, %{event_ref: ref} = state)
      when not is_nil(ref) do
    case state.events do
      [event | rest] ->
        {:reply, {:ok, event}, %{state | events: rest}}

      [] ->
        {:reply, {:error, :timeout}, state}
    end
  end

  def handle_call({:receive_event, _ref, _timeout}, _from, state) do
    {:reply, {:error, :invalid_ref}, state}
  end

  def handle_call({:thread_start, opts}, _from, state) do
    thread_id = Map.get(opts, :thread_id, "thread-#{:erlang.unique_integer([:positive])}")

    thread = %{
      thread_id: thread_id,
      session_id: state.session_id,
      name: Map.get(opts, :name),
      metadata: Map.get(opts, :metadata, %{}),
      created_at: System.system_time(:millisecond),
      status: :active
    }

    new_threads = Map.put(state.threads, thread_id, thread)
    {:reply, {:ok, thread}, %{state | threads: new_threads}}
  end

  def handle_call({:thread_resume, thread_id}, _from, state) do
    case Map.fetch(state.threads, thread_id) do
      {:ok, thread} ->
        {:reply, {:ok, %{thread | status: :active}}, state}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:thread_list, _from, state) do
    {:reply, {:ok, Map.values(state.threads)}, state}
  end

  # ── Private ───────────────────────────────────────────────────────

  defp produce_response(state, prompt) do
    response =
      case state.query_responses do
        :default ->
          {:ok, [%{type: :text, content: "response to: #{prompt}"}]}

        responses when is_list(responses) ->
          Enum.at(
            responses,
            state.query_count,
            {:ok, [%{type: :text, content: "default response"}]}
          )

        fun when is_function(fun, 2) ->
          fun.(prompt, state.query_count)
      end

    {response, %{state | query_count: state.query_count + 1}}
  end
end
