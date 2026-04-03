defmodule MonkeyClaw.Webhooks.RateLimiterTest do
  # async: false — ETS table is shared mutable state across tests.
  use ExUnit.Case, async: false

  alias MonkeyClaw.Webhooks.RateLimiter

  setup do
    RateLimiter.reset_all()
    :ok
  end

  # ── init/0 ─────────────────────────────────────

  describe "init/0" do
    test "is idempotent" do
      assert :ok = RateLimiter.init()
      assert :ok = RateLimiter.init()
    end
  end

  # ── check/2 ────────────────────────────────────

  describe "check/2" do
    test "allows requests within limit" do
      assert :ok = RateLimiter.check("ep-1", 5)
      assert :ok = RateLimiter.check("ep-1", 5)
      assert :ok = RateLimiter.check("ep-1", 5)
    end

    test "rejects requests exceeding limit" do
      assert :ok = RateLimiter.check("ep-over", 2)
      assert :ok = RateLimiter.check("ep-over", 2)
      assert {:error, :rate_limited} = RateLimiter.check("ep-over", 2)
    end

    test "allows exactly limit requests" do
      Enum.each(1..10, fn _ ->
        RateLimiter.check("ep-exact", 10)
      end)

      assert {:error, :rate_limited} = RateLimiter.check("ep-exact", 10)
    end

    test "tracks endpoints independently" do
      assert :ok = RateLimiter.check("ep-a", 1)
      assert {:error, :rate_limited} = RateLimiter.check("ep-a", 1)

      # Different endpoint is unaffected
      assert :ok = RateLimiter.check("ep-b", 1)
    end

    test "limit of 1 allows exactly one request" do
      assert :ok = RateLimiter.check("ep-single", 1)
      assert {:error, :rate_limited} = RateLimiter.check("ep-single", 1)
    end
  end

  # ── current_count/1 ────────────────────────────

  describe "current_count/1" do
    test "returns 0 for unknown endpoint" do
      assert 0 = RateLimiter.current_count("never-seen")
    end

    test "tracks request count accurately" do
      RateLimiter.check("ep-count", 100)
      RateLimiter.check("ep-count", 100)
      RateLimiter.check("ep-count", 100)

      assert 3 = RateLimiter.current_count("ep-count")
    end

    test "count increases even when rate limited" do
      RateLimiter.check("ep-overcount", 1)
      RateLimiter.check("ep-overcount", 1)
      RateLimiter.check("ep-overcount", 1)

      # Count continues incrementing past limit
      assert RateLimiter.current_count("ep-overcount") == 3
    end
  end

  # ── reset/1 ────────────────────────────────────

  describe "reset/1" do
    test "clears counters for specific endpoint" do
      RateLimiter.check("ep-reset", 100)
      RateLimiter.check("ep-reset", 100)
      assert 2 = RateLimiter.current_count("ep-reset")

      RateLimiter.reset("ep-reset")
      assert 0 = RateLimiter.current_count("ep-reset")
    end

    test "does not affect other endpoints" do
      RateLimiter.check("ep-keep", 100)
      RateLimiter.check("ep-clear", 100)

      RateLimiter.reset("ep-clear")

      assert 1 = RateLimiter.current_count("ep-keep")
      assert 0 = RateLimiter.current_count("ep-clear")
    end

    test "allows new requests after reset" do
      assert :ok = RateLimiter.check("ep-reuse", 1)
      assert {:error, :rate_limited} = RateLimiter.check("ep-reuse", 1)

      RateLimiter.reset("ep-reuse")

      assert :ok = RateLimiter.check("ep-reuse", 1)
    end
  end

  # ── reset_all/0 ────────────────────────────────

  describe "reset_all/0" do
    test "clears all endpoint counters" do
      RateLimiter.check("ep-x", 100)
      RateLimiter.check("ep-y", 100)
      RateLimiter.check("ep-z", 100)

      RateLimiter.reset_all()

      assert 0 = RateLimiter.current_count("ep-x")
      assert 0 = RateLimiter.current_count("ep-y")
      assert 0 = RateLimiter.current_count("ep-z")
    end
  end
end
