defmodule MonkeyClaw.Skills.CacheTest do
  use ExUnit.Case, async: false

  alias MonkeyClaw.Skills.Cache
  alias MonkeyClaw.Skills.Skill

  # Cache uses a shared ETS table, so no async
  setup do
    Cache.init()
    :ets.delete_all_objects(Cache.table_name())
    :ok
  end

  # ──────────────────────────────────────────────
  # init/0
  # ──────────────────────────────────────────────

  describe "init/0" do
    test "creates ETS table" do
      # Already created in setup
      assert :ets.whereis(Cache.table_name()) != :undefined
    end

    test "is idempotent" do
      assert :ok = Cache.init()
      assert :ok = Cache.init()
    end
  end

  # ──────────────────────────────────────────────
  # get/1 and put/2
  # ──────────────────────────────────────────────

  describe "get/1 and put/2" do
    test "returns :miss for unknown workspace" do
      assert :miss = Cache.get("unknown-workspace-id")
    end

    test "stores and retrieves skills" do
      skills = [%Skill{id: "test-id", title: "Test"}]
      :ok = Cache.put("workspace-1", skills)

      assert {:ok, ^skills} = Cache.get("workspace-1")
    end

    test "overwrites existing entry" do
      skills1 = [%Skill{id: "id1", title: "First"}]
      skills2 = [%Skill{id: "id2", title: "Second"}]

      :ok = Cache.put("workspace-1", skills1)
      :ok = Cache.put("workspace-1", skills2)

      {:ok, cached} = Cache.get("workspace-1")
      assert cached == skills2
    end
  end

  # ──────────────────────────────────────────────
  # invalidate/1
  # ──────────────────────────────────────────────

  describe "invalidate/1" do
    test "removes cached entry" do
      :ok = Cache.put("workspace-1", [%Skill{id: "id", title: "T"}])
      :ok = Cache.invalidate("workspace-1")

      assert :miss = Cache.get("workspace-1")
    end

    test "no-op for missing entry" do
      assert :ok = Cache.invalidate("nonexistent")
    end
  end

  # ──────────────────────────────────────────────
  # TTL expiry
  # ──────────────────────────────────────────────

  describe "TTL expiry" do
    test "returns :miss for expired entries" do
      original = Application.get_env(:monkey_claw, :skills_cache_ttl_ms)
      Application.put_env(:monkey_claw, :skills_cache_ttl_ms, 1)

      :ok = Cache.put("workspace-1", [%Skill{id: "id", title: "T"}])

      Process.sleep(10)

      assert :miss = Cache.get("workspace-1")

      if original,
        do: Application.put_env(:monkey_claw, :skills_cache_ttl_ms, original),
        else: Application.delete_env(:monkey_claw, :skills_cache_ttl_ms)
    end
  end
end
