defmodule MonkeyClaw.AgentBridge.SessionTest do
  use ExUnit.Case, async: true

  alias MonkeyClaw.AgentBridge.Backend
  alias MonkeyClaw.AgentBridge.Session

  # ──────────────────────────────────────────────
  # Client API (pure, no live GenServer)
  # ──────────────────────────────────────────────

  describe "via/1 and via/2" do
    test "returns a registry via tuple without token" do
      assert {:via, Registry, {MonkeyClaw.AgentBridge.SessionRegistry, "test-id"}} =
               Session.via("test-id")
    end

    test "returns a registry via tuple with token" do
      token = :crypto.strong_rand_bytes(32)

      assert {:via, Registry, {MonkeyClaw.AgentBridge.SessionRegistry, "test-id", ^token}} =
               Session.via("test-id", token)
    end

    test "nil token produces same result as via/1" do
      assert Session.via("test-id") == Session.via("test-id", nil)
    end

    test "rejects non-binary input" do
      assert_raise FunctionClauseError, fn ->
        Session.via(123)
      end
    end
  end

  describe "child_spec/1" do
    test "uses temporary restart strategy" do
      config = %{id: "test", session_opts: %{}}
      spec = Session.child_spec(config)

      assert spec.restart == :temporary
    end

    test "includes session ID in child spec ID" do
      config = %{id: "my-session", session_opts: %{}}
      spec = Session.child_spec(config)

      assert spec.id == {Session, "my-session"}
    end

    test "start function references start_link with config" do
      config = %{id: "test", session_opts: %{backend: :claude}}
      spec = Session.child_spec(config)

      assert spec.start == {Session, :start_link, [config]}
    end
  end

  describe "lookup/1" do
    test "returns {:error, :not_found} for unregistered session" do
      assert {:error, :not_found} = Session.lookup("nonexistent-#{System.unique_integer()}")
    end
  end

  describe "Registry token storage" do
    test "stores subscribe_token as Registry value when provided" do
      token = :crypto.strong_rand_bytes(32)
      session_id = unique_session_id()
      config = %{id: session_id, backend: Backend.Test, session_opts: %{}, subscribe_token: token}

      _pid = start_supervised!({Session, config})

      [{_pid, stored_token}] =
        Registry.lookup(MonkeyClaw.AgentBridge.SessionRegistry, session_id)

      assert stored_token == token
    end

    test "stores nil as Registry value when no token provided" do
      session_id = unique_session_id()
      config = %{id: session_id, backend: Backend.Test, session_opts: %{}}

      _pid = start_supervised!({Session, config})

      [{_pid, stored_value}] =
        Registry.lookup(MonkeyClaw.AgentBridge.SessionRegistry, session_id)

      assert is_nil(stored_value)
    end

    test "token is cleaned up when session terminates" do
      session_id = unique_session_id()
      token = :crypto.strong_rand_bytes(32)
      config = %{id: session_id, backend: Backend.Test, session_opts: %{}, subscribe_token: token}

      pid = start_supervised!({Session, config})

      # Verify token is stored
      assert [{^pid, ^token}] =
               Registry.lookup(MonkeyClaw.AgentBridge.SessionRegistry, session_id)

      # Stop session — Registry entry should be cleaned up automatically
      Session.stop(pid)
      Process.sleep(50)

      assert [] = Registry.lookup(MonkeyClaw.AgentBridge.SessionRegistry, session_id)
    end
  end

  describe "struct" do
    test "enforces required keys" do
      assert_raise ArgumentError, fn ->
        struct!(Session, [])
      end
    end

    test "defaults status to :starting" do
      session = struct!(Session, id: "test", config: %{})
      assert session.status == :starting
    end

    test "defaults optional fields to nil" do
      session = struct!(Session, id: "test", config: %{})

      assert is_nil(session.session_pid)
      assert is_nil(session.beam_session_id)
      assert is_nil(session.event_ref)
      assert is_nil(session.monitor_ref)
      assert is_nil(session.started_at)
      assert is_nil(session.telemetry_start)
      assert is_nil(session.backend)
    end
  end

  # ──────────────────────────────────────────────
  # Init — Successful Start
  # ──────────────────────────────────────────────

  describe "init/1 — successful start" do
    setup :start_test_session

    test "transitions to :active status", %{session_pid: pid} do
      assert :sys.get_state(pid).status == :active
    end

    test "stores backend process pid", %{session_pid: pid} do
      state = :sys.get_state(pid)
      assert is_pid(state.session_pid)
      assert Process.alive?(state.session_pid)
    end

    test "extracts beam session ID from backend", %{session_pid: pid} do
      state = :sys.get_state(pid)
      assert is_binary(state.beam_session_id)
      assert state.beam_session_id =~ "test-beam-"
    end

    test "monitors backend process", %{session_pid: pid} do
      assert is_reference(:sys.get_state(pid).monitor_ref)
    end

    test "subscribes to events", %{session_pid: pid} do
      assert is_reference(:sys.get_state(pid).event_ref)
    end

    test "broadcasts :session_started via PubSub" do
      id = unique_session_id()
      config = test_session_config(id)

      Phoenix.PubSub.subscribe(MonkeyClaw.PubSub, "agent_session:#{id}")
      _pid = start_supervised!({Session, config})

      assert_receive {:session_started, ^id}
    end

    test "registers in SessionRegistry", %{session_id: id} do
      assert {:ok, _pid} = Session.lookup(id)
    end

    test "stores backend module in state", %{session_pid: pid} do
      assert :sys.get_state(pid).backend == Backend.Test
    end

    test "sets started_at timestamp", %{session_pid: pid} do
      assert %DateTime{} = :sys.get_state(pid).started_at
    end

    test "stores telemetry start time", %{session_pid: pid} do
      assert is_integer(:sys.get_state(pid).telemetry_start)
    end

    test "defaults to BeamAgent backend when not specified" do
      # Verify the default path — we can't start a real BeamAgent,
      # but we can check that init attempts to use the BeamAgent backend
      # by observing the error when it's not available.
      config = %{id: unique_session_id(), session_opts: %{}}

      assert {:error, _reason} = start_supervised({Session, config})
    end
  end

  # ──────────────────────────────────────────────
  # Init — Failed Start
  # ──────────────────────────────────────────────

  describe "init/1 — failed start" do
    test "stops with {:failed_to_start_session, reason}" do
      Process.flag(:trap_exit, true)

      config = %{
        id: unique_session_id(),
        backend: Backend.Test,
        session_opts: %{start_error: :backend_unavailable}
      }

      assert {:error, {:failed_to_start_session, :backend_unavailable}} =
               Session.start_link(config)
    end

    test "does not register in SessionRegistry on failure" do
      session_id = unique_session_id()

      config = %{
        id: session_id,
        backend: Backend.Test,
        session_opts: %{start_error: :nope}
      }

      start_supervised({Session, config})

      assert {:error, :not_found} = Session.lookup(session_id)
    end
  end

  # ──────────────────────────────────────────────
  # Query
  # ──────────────────────────────────────────────

  describe "query/3 — active session" do
    setup :start_test_session

    test "returns {:ok, messages} with default handler", %{session_pid: pid} do
      assert {:ok, [%{type: :text, content: content}]} = Session.query(pid, "hello")
      assert content == "response to: hello"
    end

    test "returns configured responses in order" do
      config = %{
        id: unique_session_id(),
        backend: Backend.Test,
        session_opts: %{
          query_responses: [
            {:ok, [%{type: :text, content: "first"}]},
            {:ok, [%{type: :text, content: "second"}]},
            {:error, :rate_limited}
          ]
        }
      }

      pid = start_supervised!({Session, config})

      assert {:ok, [%{content: "first"}]} = Session.query(pid, "q1")
      assert {:ok, [%{content: "second"}]} = Session.query(pid, "q2")
      assert {:error, :rate_limited} = Session.query(pid, "q3")
    end

    test "supports function-based response handler" do
      handler = fn prompt, count ->
        {:ok, [%{type: :text, content: "#{prompt}:#{count}"}]}
      end

      config = %{
        id: unique_session_id(),
        backend: Backend.Test,
        session_opts: %{query_responses: handler}
      }

      pid = start_supervised!({Session, config})

      assert {:ok, [%{content: "hi:0"}]} = Session.query(pid, "hi")
      assert {:ok, [%{content: "bye:1"}]} = Session.query(pid, "bye")
    end

    test "falls back to default response when list exhausted" do
      config = %{
        id: unique_session_id(),
        backend: Backend.Test,
        session_opts: %{query_responses: [{:ok, [%{type: :text, content: "only"}]}]}
      }

      pid = start_supervised!({Session, config})

      assert {:ok, [%{content: "only"}]} = Session.query(pid, "q1")
      assert {:ok, [%{content: "default response"}]} = Session.query(pid, "q2")
    end
  end

  describe "query/3 — non-active session" do
    setup :start_test_session

    test "returns {:error, :session_unavailable}", %{session_pid: pid} do
      :sys.replace_state(pid, fn state -> %{state | status: :stopped} end)

      assert {:error, :session_unavailable} = Session.query(pid, "hello")
    end
  end

  # ──────────────────────────────────────────────
  # Thread Operations
  # ──────────────────────────────────────────────

  describe "start_thread/2 — active session" do
    setup :start_test_session

    test "returns thread info with name", %{session_pid: pid} do
      assert {:ok, thread} = Session.start_thread(pid, %{name: "general"})

      assert is_binary(thread.thread_id)
      assert thread.name == "general"
      assert thread.status == :active
      assert is_integer(thread.created_at)
    end

    test "creates threads with unique IDs", %{session_pid: pid} do
      {:ok, t1} = Session.start_thread(pid, %{name: "ch-1"})
      {:ok, t2} = Session.start_thread(pid, %{name: "ch-2"})

      assert t1.thread_id != t2.thread_id
    end
  end

  describe "start_thread/2 — non-active session" do
    setup :start_test_session

    test "returns {:error, :session_unavailable}", %{session_pid: pid} do
      :sys.replace_state(pid, fn state -> %{state | status: :stopped} end)

      assert {:error, :session_unavailable} = Session.start_thread(pid, %{})
    end
  end

  describe "resume_thread/2 — active session" do
    setup :start_test_session

    test "resumes existing thread", %{session_pid: pid} do
      {:ok, thread} = Session.start_thread(pid, %{name: "test"})

      assert {:ok, resumed} = Session.resume_thread(pid, thread.thread_id)
      assert resumed.status == :active
      assert resumed.thread_id == thread.thread_id
    end

    test "returns {:error, :not_found} for unknown thread", %{session_pid: pid} do
      assert {:error, :not_found} = Session.resume_thread(pid, "no-such-thread")
    end
  end

  describe "resume_thread/2 — non-active session" do
    setup :start_test_session

    test "returns {:error, :session_unavailable}", %{session_pid: pid} do
      :sys.replace_state(pid, fn state -> %{state | status: :stopped} end)

      assert {:error, :session_unavailable} = Session.resume_thread(pid, "thread-1")
    end
  end

  describe "list_threads/1 — active session" do
    setup :start_test_session

    test "returns empty list when no threads", %{session_pid: pid} do
      assert {:ok, []} = Session.list_threads(pid)
    end

    test "returns all created threads", %{session_pid: pid} do
      {:ok, _} = Session.start_thread(pid, %{name: "ch-1"})
      {:ok, _} = Session.start_thread(pid, %{name: "ch-2"})

      assert {:ok, threads} = Session.list_threads(pid)
      assert length(threads) == 2

      names = Enum.map(threads, & &1.name)
      assert "ch-1" in names
      assert "ch-2" in names
    end
  end

  describe "list_threads/1 — non-active session" do
    setup :start_test_session

    test "returns {:error, :session_unavailable}", %{session_pid: pid} do
      :sys.replace_state(pid, fn state -> %{state | status: :stopped} end)

      assert {:error, :session_unavailable} = Session.list_threads(pid)
    end
  end

  # ──────────────────────────────────────────────
  # Session Info
  # ──────────────────────────────────────────────

  describe "info/1" do
    setup :start_test_session

    test "returns session metadata", %{session_pid: pid, session_id: id} do
      assert {:ok, info} = Session.info(pid)

      assert info.id == id
      assert info.status == :active
      assert is_binary(info.beam_session_id)
      assert %DateTime{} = info.started_at
    end

    test "sanitizes config — excludes session_opts", %{session_pid: pid} do
      assert {:ok, info} = Session.info(pid)

      refute Map.has_key?(info.config, :session_opts)
    end

    test "includes backend in sanitized config", %{session_pid: pid} do
      assert {:ok, info} = Session.info(pid)

      assert info.config.backend == Backend.Test
    end
  end

  # ──────────────────────────────────────────────
  # Stop
  # ──────────────────────────────────────────────

  describe "stop/1 — active session" do
    test "returns :ok and broadcasts :session_stopped" do
      session_id = unique_session_id()
      config = test_session_config(session_id)

      Phoenix.PubSub.subscribe(MonkeyClaw.PubSub, "agent_session:#{session_id}")
      pid = start_supervised!({Session, config})

      assert_receive {:session_started, ^session_id}
      assert :ok = Session.stop(pid)
      assert_receive {:session_stopped, ^session_id, :normal}
    end

    test "session process terminates after stop" do
      config = test_session_config()

      {:ok, pid} = Session.start_link(config)
      ref = Process.monitor(pid)

      Session.stop(pid)

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    end

    test "stops the backend process" do
      config = test_session_config()

      {:ok, pid} = Session.start_link(config)
      %{session_pid: backend_pid} = :sys.get_state(pid)
      backend_ref = Process.monitor(backend_pid)

      Session.stop(pid)

      assert_receive {:DOWN, ^backend_ref, :process, ^backend_pid, _reason}
    end
  end

  describe "stop/1 — non-active session" do
    test "returns :ok and terminates" do
      config = test_session_config()

      {:ok, pid} = Session.start_link(config)
      ref = Process.monitor(pid)

      :sys.replace_state(pid, fn state -> %{state | status: :stopped} end)

      assert :ok = Session.stop(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    end
  end

  # ──────────────────────────────────────────────
  # Backend Crash (:DOWN handling)
  # ──────────────────────────────────────────────

  describe "handle_info :DOWN — backend crash" do
    test "broadcasts :session_terminated and stops session" do
      Process.flag(:trap_exit, true)

      session_id = unique_session_id()
      config = test_session_config(session_id)

      Phoenix.PubSub.subscribe(MonkeyClaw.PubSub, "agent_session:#{session_id}")

      {:ok, pid} = Session.start_link(config)
      session_ref = Process.monitor(pid)

      assert_receive {:session_started, ^session_id}

      # Kill the backend process to simulate a crash
      %{session_pid: backend_pid} = :sys.get_state(pid)
      Process.exit(backend_pid, :kill)

      assert_receive {:session_terminated, ^session_id, :killed}
      assert_receive {:DOWN, ^session_ref, :process, ^pid, {:beam_agent_terminated, :killed}}
    end
  end

  # ──────────────────────────────────────────────
  # Event Polling
  # ──────────────────────────────────────────────

  describe "event polling" do
    test "drains events and broadcasts via PubSub" do
      session_id = unique_session_id()
      event = %{type: :tool_use, tool_name: "read", content: "reading file"}

      config = %{
        id: session_id,
        backend: Backend.Test,
        session_opts: %{events: [event]}
      }

      Phoenix.PubSub.subscribe(MonkeyClaw.PubSub, "agent_session:#{session_id}")
      _pid = start_supervised!({Session, config})

      assert_receive {:session_started, ^session_id}
      # Event polling runs on a 100ms interval
      assert_receive {:beam_agent_event, ^session_id, ^event}, 1_000
    end

    test "handles empty event queue without error" do
      session_id = unique_session_id()
      config = test_session_config(session_id)

      Phoenix.PubSub.subscribe(MonkeyClaw.PubSub, "agent_session:#{session_id}")
      _pid = start_supervised!({Session, config})

      assert_receive {:session_started, ^session_id}

      # Wait for at least one poll cycle — no crash expected
      Process.sleep(150)
      refute_received {:beam_agent_event, ^session_id, _}
    end

    test "ignores poll_events when not active" do
      config = test_session_config()
      pid = start_supervised!({Session, config})

      :sys.replace_state(pid, fn state -> %{state | status: :stopped} end)

      # Manually send poll message
      send(pid, :poll_events)
      Process.sleep(50)

      assert Process.alive?(pid)
      assert :sys.get_state(pid).status == :stopped
    end
  end

  # ──────────────────────────────────────────────
  # Unexpected Messages
  # ──────────────────────────────────────────────

  describe "unexpected messages" do
    setup :start_test_session

    test "are handled without crashing", %{session_pid: pid} do
      send(pid, {:unexpected, :message})
      send(pid, "string message")
      send(pid, 42)

      Process.sleep(50)
      assert Process.alive?(pid)
      assert :sys.get_state(pid).status == :active
    end
  end

  # ──────────────────────────────────────────────
  # Terminate
  # ──────────────────────────────────────────────

  describe "terminate/2" do
    test "stops backend when session is active" do
      Process.flag(:trap_exit, true)

      config = test_session_config()

      {:ok, pid} = Session.start_link(config)
      %{session_pid: backend_pid} = :sys.get_state(pid)
      backend_ref = Process.monitor(backend_pid)

      GenServer.stop(pid, :shutdown)

      assert_receive {:DOWN, ^backend_ref, :process, ^backend_pid, _reason}
    end

    test "no-op when session is not active" do
      Process.flag(:trap_exit, true)

      config = test_session_config()

      {:ok, pid} = Session.start_link(config)

      :sys.replace_state(pid, fn state -> %{state | status: :stopped} end)

      GenServer.stop(pid, :shutdown)

      # The key assertion is: GenServer.stop didn't crash
      Process.sleep(50)
    end
  end

  # ──────────────────────────────────────────────
  # Telemetry
  # ──────────────────────────────────────────────

  describe "telemetry — session lifecycle" do
    test "emits start event on successful init" do
      session_id = unique_session_id()
      config = test_session_config(session_id)
      handler_id = attach_session_telemetry()

      _pid = start_supervised!({Session, config})

      assert_receive {:telemetry, [:monkey_claw, :agent_bridge, :session, :start], measurements,
                      metadata}

      assert is_integer(measurements.system_time)
      assert metadata.session_id == session_id

      :telemetry.detach(handler_id)
    end

    test "emits stop event on graceful stop" do
      config = test_session_config()
      handler_id = attach_session_telemetry()

      {:ok, pid} = Session.start_link(config)
      assert_receive {:telemetry, [:monkey_claw, :agent_bridge, :session, :start], _, _}

      Session.stop(pid)

      assert_receive {:telemetry, [:monkey_claw, :agent_bridge, :session, :stop],
                      %{duration: duration}, metadata}

      assert is_integer(duration)
      assert duration >= 0
      assert metadata.session_id == config.id

      :telemetry.detach(handler_id)
    end

    test "emits exception event on failed init" do
      session_id = unique_session_id()
      handler_id = attach_session_telemetry()

      config = %{
        id: session_id,
        backend: Backend.Test,
        session_opts: %{start_error: :boom}
      }

      start_supervised({Session, config})

      assert_receive {:telemetry, [:monkey_claw, :agent_bridge, :session, :start], _, _}

      assert_receive {:telemetry, [:monkey_claw, :agent_bridge, :session, :exception], _,
                      %{session_id: ^session_id, kind: :start_failure, reason: :boom}}

      :telemetry.detach(handler_id)
    end

    test "emits exception event on backend crash" do
      Process.flag(:trap_exit, true)

      config = test_session_config()
      handler_id = attach_session_telemetry()

      {:ok, pid} = Session.start_link(config)
      session_ref = Process.monitor(pid)

      assert_receive {:telemetry, [:monkey_claw, :agent_bridge, :session, :start], _, _}

      %{session_pid: backend_pid} = :sys.get_state(pid)
      Process.exit(backend_pid, :kill)

      # Wait for Session to terminate from the backend :DOWN.
      # Generous timeout — CI runners can be slow to propagate the
      # kill → Session handle_info → telemetry → Session terminate chain.
      assert_receive {:DOWN, ^session_ref, :process, ^pid, _}, 5_000

      assert_receive {:telemetry, [:monkey_claw, :agent_bridge, :session, :exception], _,
                      %{kind: :beam_agent_down, reason: :killed}},
                     5_000

      :telemetry.detach(handler_id)
    end
  end

  describe "telemetry — query lifecycle" do
    test "emits start and stop on successful query" do
      session_id = unique_session_id()
      config = test_session_config(session_id)
      handler_id = attach_query_telemetry()

      pid = start_supervised!({Session, config})
      Session.query(pid, "hello")

      assert_receive {:telemetry, [:monkey_claw, :agent_bridge, :query, :start], _,
                      %{session_id: ^session_id}}

      assert_receive {:telemetry, [:monkey_claw, :agent_bridge, :query, :stop], %{duration: d},
                      %{session_id: ^session_id, message_count: 1}}

      assert is_integer(d) and d >= 0

      :telemetry.detach(handler_id)
    end

    test "emits exception on query error" do
      session_id = unique_session_id()
      handler_id = attach_query_telemetry()

      config = %{
        id: session_id,
        backend: Backend.Test,
        session_opts: %{query_responses: [{:error, :overloaded}]}
      }

      pid = start_supervised!({Session, config})
      Session.query(pid, "hello")

      assert_receive {:telemetry, [:monkey_claw, :agent_bridge, :query, :start], _, _}

      assert_receive {:telemetry, [:monkey_claw, :agent_bridge, :query, :exception], _,
                      %{session_id: ^session_id, kind: :query_error, reason: :overloaded}}

      :telemetry.detach(handler_id)
    end
  end

  describe "telemetry — event bridge" do
    test "emits event_received on drained events" do
      session_id = unique_session_id()
      test_pid = self()
      event = %{type: :tool_use, tool_name: "read"}

      handler_id = "event-telemetry-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:monkey_claw, :agent_bridge, :event, :received],
        fn event_name, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event_name, measurements, metadata})
        end,
        nil
      )

      config = %{
        id: session_id,
        backend: Backend.Test,
        session_opts: %{events: [event]}
      }

      _pid = start_supervised!({Session, config})

      assert_receive {:telemetry, [:monkey_claw, :agent_bridge, :event, :received], _,
                      %{session_id: ^session_id, event_type: :tool_use}},
                     1_000

      :telemetry.detach(handler_id)
    end
  end

  # ──────────────────────────────────────────────
  # Helpers
  # ──────────────────────────────────────────────

  defp unique_session_id do
    "test-session-#{System.unique_integer([:positive])}"
  end

  defp test_session_config(session_id \\ nil) do
    %{
      id: session_id || unique_session_id(),
      backend: Backend.Test,
      session_opts: %{},
      subscribe_token: :crypto.strong_rand_bytes(32)
    }
  end

  defp start_test_session(_context) do
    session_id = unique_session_id()
    config = test_session_config(session_id)

    Phoenix.PubSub.subscribe(MonkeyClaw.PubSub, "agent_session:#{session_id}")
    pid = start_supervised!({Session, config})

    # Drain the :session_started message so tests start from a clean slate
    assert_receive {:session_started, ^session_id}

    %{
      session_id: session_id,
      session_pid: pid,
      config: config,
      subscribe_token: config.subscribe_token
    }
  end

  defp attach_session_telemetry do
    test_pid = self()
    handler_id = "session-telemetry-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler_id,
      [
        [:monkey_claw, :agent_bridge, :session, :start],
        [:monkey_claw, :agent_bridge, :session, :stop],
        [:monkey_claw, :agent_bridge, :session, :exception]
      ],
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    handler_id
  end

  defp attach_query_telemetry do
    test_pid = self()
    handler_id = "query-telemetry-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler_id,
      [
        [:monkey_claw, :agent_bridge, :query, :start],
        [:monkey_claw, :agent_bridge, :query, :stop],
        [:monkey_claw, :agent_bridge, :query, :exception]
      ],
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    handler_id
  end
end
