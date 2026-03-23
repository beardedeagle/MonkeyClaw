defmodule MonkeyClawWeb.ErrorFormatterTest do
  @moduledoc false
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias MonkeyClawWeb.ErrorFormatter

  doctest ErrorFormatter

  # --- Structured BeamAgent errors (maps with :category) ---

  describe "format/1 with :rate_limit category" do
    test "includes retry_after seconds when positive integer" do
      assert ErrorFormatter.format(%{category: :rate_limit, retry_after: 30}) ==
               "Rate limited — retry in 30 seconds."
    end

    test "includes retry_after of 1 second" do
      assert ErrorFormatter.format(%{category: :rate_limit, retry_after: 1}) ==
               "Rate limited — retry in 1 second."
    end

    test "falls through when retry_after is zero" do
      assert ErrorFormatter.format(%{category: :rate_limit, retry_after: 0}) ==
               "Rate limited — please wait a moment."
    end

    test "falls through when retry_after is negative" do
      assert ErrorFormatter.format(%{category: :rate_limit, retry_after: -5}) ==
               "Rate limited — please wait a moment."
    end

    test "falls through when retry_after is non-integer" do
      assert ErrorFormatter.format(%{category: :rate_limit, retry_after: "30"}) ==
               "Rate limited — please wait a moment."
    end

    test "returns generic message without retry_after" do
      assert ErrorFormatter.format(%{category: :rate_limit}) ==
               "Rate limited — please wait a moment."
    end

    test "ignores extra keys in the error map" do
      error = %{category: :rate_limit, retry_after: 10, content: "too fast", type: :error}

      assert ErrorFormatter.format(error) ==
               "Rate limited — retry in 10 seconds."
    end
  end

  describe "format/1 with other structured categories" do
    test "subscription_exhausted" do
      assert ErrorFormatter.format(%{category: :subscription_exhausted}) ==
               "Subscription quota exhausted. Check your plan limits."
    end

    test "subscription_exhausted ignores extra keys" do
      assert ErrorFormatter.format(%{
               category: :subscription_exhausted,
               type: :error,
               content: "quota"
             }) ==
               "Subscription quota exhausted. Check your plan limits."
    end

    test "context_exceeded" do
      assert ErrorFormatter.format(%{category: :context_exceeded}) ==
               "Conversation too long — context limit reached. Start a new conversation."
    end

    test "auth_expired" do
      assert ErrorFormatter.format(%{category: :auth_expired}) ==
               "Authentication expired. Restart the session."
    end

    test "server_error" do
      assert ErrorFormatter.format(%{category: :server_error}) ==
               "The AI service encountered an error. Try again shortly."
    end

    test "unknown category logs warning and returns generic message" do
      log =
        capture_log(fn ->
          assert ErrorFormatter.format(%{category: :unknown}) ==
                   "Something went wrong. Check server logs for details."
        end)

      assert log =~ "Agent returned unclassified error"
    end
  end

  # --- Application-level errors ---

  describe "format/1 with application-level errors" do
    test "workspace_not_found" do
      assert ErrorFormatter.format({:workspace_not_found, "ws-123"}) ==
               "Workspace not found."
    end

    test "session_start_failed logs reason and returns message" do
      log =
        capture_log(fn ->
          assert ErrorFormatter.format({:session_start_failed, :econnrefused}) ==
                   "Session failed to start. Check server logs for details."
        end)

      assert log =~ "Session failed to start"
      assert log =~ "econnrefused"
    end

    test "thread_start_failed logs reason and returns message" do
      log =
        capture_log(fn ->
          assert ErrorFormatter.format({:thread_start_failed, {:timeout, 5000}}) ==
                   "Thread failed to start. Check server logs for details."
        end)

      assert log =~ "Thread failed to start"
    end

    test "halted" do
      assert ErrorFormatter.format({:halted, %{assigns: %{}}}) ==
               "Request blocked by an extension hook."
    end

    test "rate_limited atom" do
      assert ErrorFormatter.format(:rate_limited) ==
               "Rate limited — please wait a moment."
    end
  end

  # --- Catch-all ---

  describe "format/1 catch-all" do
    test "unrecognized atom logs warning and returns generic message" do
      log =
        capture_log(fn ->
          assert ErrorFormatter.format(:some_weird_error) ==
                   "Something went wrong. Check server logs for details."
        end)

      assert log =~ "Unexpected chat error"
      assert log =~ "some_weird_error"
    end

    test "unrecognized tuple logs warning and returns generic message" do
      log =
        capture_log(fn ->
          assert ErrorFormatter.format({:unexpected, "details"}) ==
                   "Something went wrong. Check server logs for details."
        end)

      assert log =~ "Unexpected chat error"
    end

    test "unrecognized string logs warning and returns generic message" do
      log =
        capture_log(fn ->
          assert ErrorFormatter.format("raw error string") ==
                   "Something went wrong. Check server logs for details."
        end)

      assert log =~ "Unexpected chat error"
    end

    test "map without category key falls through to catch-all" do
      log =
        capture_log(fn ->
          assert ErrorFormatter.format(%{message: "something broke"}) ==
                   "Something went wrong. Check server logs for details."
        end)

      assert log =~ "Unexpected chat error"
    end
  end
end
