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
  def stream(pid, prompt, params) do
    GenServer.call(pid, {:stream, prompt, params})
  end

  @impl MonkeyClaw.AgentBridge.Backend
  def set_model(_pid, _model), do: {:ok, :noop}

  @impl MonkeyClaw.AgentBridge.Backend
  def set_permission_mode(_pid, _mode), do: {:ok, :noop}

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
  def event_unsubscribe(pid, ref) do
    GenServer.call(pid, {:event_unsubscribe, ref})
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

  @impl MonkeyClaw.AgentBridge.Backend
  def checkpoint_save(pid, label) do
    GenServer.call(pid, {:checkpoint_save, label})
  end

  @impl MonkeyClaw.AgentBridge.Backend
  def checkpoint_rewind(pid, checkpoint_id) do
    GenServer.call(pid, {:checkpoint_rewind, checkpoint_id})
  end

  @impl MonkeyClaw.AgentBridge.Backend
  def list_models(opts) when is_map(opts) do
    delay_ms = Map.get(opts, :list_models_delay_ms, 0)
    deadline_ms = Map.get(opts, :probe_deadline_ms, :infinity)

    cond do
      deadline_ms != :infinity and delay_ms > deadline_ms ->
        {:error, :deadline_exceeded}

      delay_ms > 0 ->
        Process.sleep(delay_ms)
        respond(opts)

      true ->
        respond(opts)
    end
  end

  defp respond(opts) do
    case Map.get(opts, :list_models_response, :default) do
      :default ->
        {:ok,
         [
           %{
             provider: "anthropic",
             model_id: "claude-sonnet-4-6",
             display_name: "Claude Sonnet 4.6",
             capabilities: %{}
           },
           %{
             provider: "anthropic",
             model_id: "claude-opus-4-6",
             display_name: "Claude Opus 4.6",
             capabilities: %{}
           }
         ]}

      {:ok, models} when is_list(models) ->
        {:ok, models}

      {:ok, non_list} ->
        {:ok, non_list}

      {:error, reason} ->
        {:error, reason}

      {:crash, message} ->
        raise message
    end
  end

  # ── GenServer State ───────────────────────────────────────────────

  defstruct [
    :session_id,
    :event_ref,
    query_responses: :default,
    stream_responses: :default,
    query_count: 0,
    stream_count: 0,
    threads: %{},
    events: [],
    checkpoints: %{}
  ]

  # ── GenServer Callbacks ───────────────────────────────────────────

  @impl GenServer
  def init(opts) when is_map(opts) do
    state = %__MODULE__{
      session_id: Map.get(opts, :session_id, "test-beam-#{:erlang.unique_integer([:positive])}"),
      query_responses: Map.get(opts, :query_responses, :default),
      stream_responses: Map.get(opts, :stream_responses, :default),
      events: Map.get(opts, :events, [])
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:query, prompt, _params}, _from, state) do
    {response, new_state} = produce_response(state, prompt)
    {:reply, response, new_state}
  end

  def handle_call({:stream, prompt, _params}, _from, state) do
    {items, new_state} = produce_stream_chunks(state, prompt)
    {:reply, {:ok, items}, new_state}
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

  def handle_call({:event_unsubscribe, ref}, _from, %{event_ref: ref} = state)
      when not is_nil(ref) do
    {:reply, :ok, %{state | event_ref: nil, events: []}}
  end

  def handle_call({:event_unsubscribe, _ref}, _from, state) do
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

  # ── Checkpoint Operations ────────────────────────────────────────

  def handle_call({:checkpoint_save, label}, _from, state) do
    id = "chk-#{label}-#{:erlang.unique_integer([:positive])}"
    checkpoints = Map.put(state.checkpoints, id, label)
    {:reply, {:ok, id}, %{state | checkpoints: checkpoints}}
  end

  def handle_call({:checkpoint_rewind, checkpoint_id}, _from, state) do
    case Map.fetch(state.checkpoints, checkpoint_id) do
      {:ok, _label} -> {:reply, :ok, state}
      :error -> {:reply, {:error, :checkpoint_not_found}, state}
    end
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

  # Returns a list of `{:ok, msg}` / `{:error, reason}` tagged tuples,
  # matching the real BeamAgent.stream/3 contract. The Session's stream
  # task enumerates these items directly.
  defp produce_stream_chunks(state, prompt) do
    items =
      case state.stream_responses do
        :default ->
          [
            {:ok, %{type: :text, content: "streaming: #{prompt}"}},
            {:ok, %{type: :result, content: "done"}}
          ]

        responses when is_list(responses) ->
          Enum.at(
            responses,
            state.stream_count,
            [{:ok, %{type: :text, content: "default stream"}}]
          )

        fun when is_function(fun, 2) ->
          fun.(prompt, state.stream_count)
      end

    {items, %{state | stream_count: state.stream_count + 1}}
  end
end
