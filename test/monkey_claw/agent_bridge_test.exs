defmodule MonkeyClaw.AgentBridgeTest do
  use ExUnit.Case, async: true

  alias MonkeyClaw.AgentBridge

  describe "list_sessions/0" do
    test "returns empty list when no sessions are active" do
      assert AgentBridge.list_sessions() == []
    end
  end

  describe "session_count/0" do
    test "returns zero when no sessions are active" do
      assert AgentBridge.session_count() == 0
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

  describe "subscribe/1 and unsubscribe/1" do
    test "subscribes and receives PubSub broadcasts" do
      session_id = "pubsub-test-#{System.unique_integer([:positive])}"

      assert :ok = AgentBridge.subscribe(session_id)

      Phoenix.PubSub.broadcast(
        MonkeyClaw.PubSub,
        "agent_session:#{session_id}",
        {:session_started, session_id}
      )

      assert_receive {:session_started, ^session_id}
    end

    test "unsubscribes and stops receiving broadcasts" do
      session_id = "unsub-test-#{System.unique_integer([:positive])}"

      AgentBridge.subscribe(session_id)
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
