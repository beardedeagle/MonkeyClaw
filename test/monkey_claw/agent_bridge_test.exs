defmodule MonkeyClaw.AgentBridgeTest do
  use ExUnit.Case, async: true

  alias MonkeyClaw.AgentBridge
  alias MonkeyClaw.AgentBridge.Backend
  alias MonkeyClaw.AgentBridge.Session

  describe "list_sessions/0" do
    test "returns a list of session IDs" do
      assert is_list(AgentBridge.list_sessions())
    end
  end

  describe "session_count/0" do
    test "returns a non-negative integer" do
      count = AgentBridge.session_count()
      assert is_integer(count) and count >= 0
    end
  end

  describe "stop_session/1" do
    test "returns error for non-existent session" do
      assert {:error, {:session_not_found, "nonexistent"}} =
               AgentBridge.stop_session("nonexistent")
    end
  end

  describe "query/3" do
    test "returns error for non-existent session" do
      assert {:error, {:session_not_found, "nonexistent"}} =
               AgentBridge.query("nonexistent", "hello")
    end

    test "rejects non-binary session_id" do
      assert_raise FunctionClauseError, fn ->
        AgentBridge.query(123, "hello")
      end
    end

    test "rejects non-binary prompt" do
      assert_raise FunctionClauseError, fn ->
        AgentBridge.query("session", 123)
      end
    end
  end

  describe "start_thread/2" do
    test "returns error for non-existent session" do
      assert {:error, {:session_not_found, "nonexistent"}} =
               AgentBridge.start_thread("nonexistent")
    end

    test "rejects non-binary session_id" do
      assert_raise FunctionClauseError, fn ->
        AgentBridge.start_thread(123)
      end
    end
  end

  describe "resume_thread/2" do
    test "returns error for non-existent session" do
      assert {:error, {:session_not_found, "nonexistent"}} =
               AgentBridge.resume_thread("nonexistent", "thread-1")
    end

    test "rejects non-binary session_id" do
      assert_raise FunctionClauseError, fn ->
        AgentBridge.resume_thread(123, "thread-1")
      end
    end

    test "rejects non-binary thread_id" do
      assert_raise FunctionClauseError, fn ->
        AgentBridge.resume_thread("session-1", 123)
      end
    end

    test "rejects empty thread_id" do
      assert_raise FunctionClauseError, fn ->
        AgentBridge.resume_thread("session-1", "")
      end
    end
  end

  describe "list_threads/1" do
    test "returns error for non-existent session" do
      assert {:error, {:session_not_found, "nonexistent"}} =
               AgentBridge.list_threads("nonexistent")
    end

    test "rejects non-binary session_id" do
      assert_raise FunctionClauseError, fn ->
        AgentBridge.list_threads(123)
      end
    end
  end

  describe "session_info/1" do
    test "returns error for non-existent session" do
      assert {:error, {:session_not_found, "nonexistent"}} =
               AgentBridge.session_info("nonexistent")
    end
  end

  describe "start_session/1" do
    test "returns session result with subscribe token" do
      session_id = "start-test-#{System.unique_integer([:positive])}"
      config = %{id: session_id, backend: Backend.Test, session_opts: %{}}

      assert {:ok, result} = AgentBridge.start_session(config)

      assert result.id == session_id
      assert is_pid(result.pid)
      assert is_binary(result.subscribe_token)
      assert byte_size(result.subscribe_token) == 32

      AgentBridge.stop_session(session_id)
    end

    test "generates unique tokens per session" do
      config1 = %{
        id: "tok-1-#{System.unique_integer([:positive])}",
        backend: Backend.Test,
        session_opts: %{}
      }

      config2 = %{
        id: "tok-2-#{System.unique_integer([:positive])}",
        backend: Backend.Test,
        session_opts: %{}
      }

      {:ok, result1} = AgentBridge.start_session(config1)
      {:ok, result2} = AgentBridge.start_session(config2)

      refute result1.subscribe_token == result2.subscribe_token

      AgentBridge.stop_session(result1.id)
      AgentBridge.stop_session(result2.id)
    end
  end

  describe "subscribe/2 and unsubscribe/1" do
    test "returns error when subscribing to non-existent session" do
      token = :crypto.strong_rand_bytes(32)

      assert {:error, {:session_not_found, "no-such-session"}} =
               AgentBridge.subscribe("no-such-session", token)
    end

    test "subscribes and receives PubSub broadcasts with valid token" do
      session_id = "pubsub-test-#{System.unique_integer([:positive])}"
      token = :crypto.strong_rand_bytes(32)
      token_hash = :crypto.hash(:sha256, token)

      config = %{
        id: session_id,
        backend: Backend.Test,
        session_opts: %{},
        subscribe_token: token_hash
      }

      _pid = start_supervised!({Session, config})

      assert :ok = AgentBridge.subscribe(session_id, token)

      Phoenix.PubSub.broadcast(
        MonkeyClaw.PubSub,
        "agent_session:#{session_id}",
        {:session_started, session_id}
      )

      assert_receive {:session_started, ^session_id}
    end

    test "rejects subscription with invalid token" do
      session_id = "pubsub-reject-#{System.unique_integer([:positive])}"
      valid_token = :crypto.strong_rand_bytes(32)
      invalid_token = :crypto.strong_rand_bytes(32)

      config = %{
        id: session_id,
        backend: Backend.Test,
        session_opts: %{},
        subscribe_token: :crypto.hash(:sha256, valid_token)
      }

      _pid = start_supervised!({Session, config})

      assert {:error, :unauthorized} = AgentBridge.subscribe(session_id, invalid_token)
    end

    test "rejects subscription when session has no token" do
      session_id = "pubsub-notoken-#{System.unique_integer([:positive])}"
      config = %{id: session_id, backend: Backend.Test, session_opts: %{}}

      _pid = start_supervised!({Session, config})

      assert {:error, :unauthorized} =
               AgentBridge.subscribe(session_id, :crypto.strong_rand_bytes(32))
    end

    test "rejects subscription with wrong-size token via guard" do
      assert_raise FunctionClauseError, fn ->
        AgentBridge.subscribe("some-session", "too-short")
      end
    end

    test "does not receive events after rejected subscription" do
      session_id = "pubsub-noleak-#{System.unique_integer([:positive])}"
      valid_token = :crypto.strong_rand_bytes(32)

      config = %{
        id: session_id,
        backend: Backend.Test,
        session_opts: %{},
        subscribe_token: :crypto.hash(:sha256, valid_token)
      }

      _pid = start_supervised!({Session, config})

      {:error, :unauthorized} = AgentBridge.subscribe(session_id, :crypto.strong_rand_bytes(32))

      Phoenix.PubSub.broadcast(
        MonkeyClaw.PubSub,
        "agent_session:#{session_id}",
        {:session_started, session_id}
      )

      refute_receive {:session_started, ^session_id}
    end

    test "token from session A cannot subscribe to session B" do
      token_a = :crypto.strong_rand_bytes(32)
      token_b = :crypto.strong_rand_bytes(32)

      id_a = "cross-a-#{System.unique_integer([:positive])}"
      id_b = "cross-b-#{System.unique_integer([:positive])}"

      config_a = %{
        id: id_a,
        backend: Backend.Test,
        session_opts: %{},
        subscribe_token: :crypto.hash(:sha256, token_a)
      }

      config_b = %{
        id: id_b,
        backend: Backend.Test,
        session_opts: %{},
        subscribe_token: :crypto.hash(:sha256, token_b)
      }

      start_supervised!({Session, config_a}, id: :cross_a)
      start_supervised!({Session, config_b}, id: :cross_b)

      assert {:error, :unauthorized} = AgentBridge.subscribe(id_b, token_a)
    end

    test "unsubscribes and stops receiving broadcasts" do
      session_id = "unsub-test-#{System.unique_integer([:positive])}"
      token = :crypto.strong_rand_bytes(32)

      config = %{
        id: session_id,
        backend: Backend.Test,
        session_opts: %{},
        subscribe_token: :crypto.hash(:sha256, token)
      }

      _pid = start_supervised!({Session, config})

      AgentBridge.subscribe(session_id, token)
      assert :ok = AgentBridge.unsubscribe(session_id)

      Phoenix.PubSub.broadcast(
        MonkeyClaw.PubSub,
        "agent_session:#{session_id}",
        {:session_started, session_id}
      )

      refute_receive {:session_started, ^session_id}
    end
  end

  describe "capabilities/0" do
    test "returns a non-empty list" do
      caps = AgentBridge.capabilities()

      assert is_list(caps)
      assert caps != []
    end
  end

  describe "backends/0" do
    test "returns known backends" do
      backends = AgentBridge.backends()

      assert :claude in backends
    end
  end
end
