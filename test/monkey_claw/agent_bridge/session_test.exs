defmodule MonkeyClaw.AgentBridge.SessionTest do
  use ExUnit.Case, async: true

  alias MonkeyClaw.AgentBridge.Session

  describe "via/1" do
    test "returns a registry via tuple" do
      assert {:via, Registry, {MonkeyClaw.AgentBridge.SessionRegistry, "test-id"}} =
               Session.via("test-id")
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
    end
  end
end
