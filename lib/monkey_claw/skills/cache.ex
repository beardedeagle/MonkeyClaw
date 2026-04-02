defmodule MonkeyClaw.Skills.Cache do
  @moduledoc """
  ETS hot cache for per-workspace skill lookups.

  Provides low-latency access to cached skill lists for a
  workspace, used by `top_skills/2` to avoid repeated database
  queries. Entries have a TTL (default 5 minutes) and are
  invalidated on skill create/update/delete operations.

  ## Table Design

  The ETS table stores `{workspace_id, skills_list, timestamp}`
  tuples. Read-concurrency is enabled since reads dominate.
  The table is `:set` type (one entry per workspace).

  ## Initialization

  `init/0` must be called from `Application.start/2` before
  any cache operations. It creates the named ETS table.

  ## Design

  This is NOT a process. All operations are direct ETS calls
  using `:ets` module functions. No GenServer, no Agent, no
  message passing. The table is `:public` for direct access
  from any process.
  """

  @table :monkey_claw_skills_cache
  @default_ttl_ms :timer.minutes(5)

  @doc """
  Create the skills cache ETS table.

  Must be called once during application startup, before the
  supervision tree starts. Safe to call if the table already
  exists (returns `:ok` without error).

  ## Examples

      :ok = MonkeyClaw.Skills.Cache.init()
  """
  @spec init() :: :ok
  def init do
    case :ets.whereis(@table) do
      :undefined ->
        _ref = :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
        :ok

      _ref ->
        :ok
    end
  end

  @doc """
  Fetch cached skills for a workspace.

  Returns `{:ok, skills}` if the entry exists and has not
  expired, or `:miss` if the entry is missing or stale.

  ## Examples

      {:ok, skills} = Cache.get(workspace_id)
      :miss = Cache.get("unknown-workspace")
  """
  @spec get(Ecto.UUID.t()) :: {:ok, [MonkeyClaw.Skills.Skill.t()]} | :miss
  def get(workspace_id) when is_binary(workspace_id) do
    case :ets.lookup(@table, workspace_id) do
      [{^workspace_id, skills, timestamp}] ->
        if expired?(timestamp) do
          :ets.delete(@table, workspace_id)
          :miss
        else
          {:ok, skills}
        end

      [] ->
        :miss
    end
  end

  @doc """
  Cache a skill list for a workspace.

  Overwrites any existing entry. The timestamp is set to the
  current system monotonic time for TTL tracking.

  ## Examples

      :ok = Cache.put(workspace_id, skills)
  """
  @spec put(Ecto.UUID.t(), [MonkeyClaw.Skills.Skill.t()]) :: :ok
  def put(workspace_id, skills)
      when is_binary(workspace_id) and is_list(skills) do
    :ets.insert(@table, {workspace_id, skills, System.monotonic_time(:millisecond)})
    :ok
  end

  @doc """
  Clear the cache entry for a workspace.

  No-op if no entry exists. Called by the Skills context
  module on create, update, and delete operations.

  ## Examples

      :ok = Cache.invalidate(workspace_id)
  """
  @spec invalidate(Ecto.UUID.t()) :: :ok
  def invalidate(workspace_id) when is_binary(workspace_id) do
    :ets.delete(@table, workspace_id)
    :ok
  end

  @doc """
  Returns the ETS table name.

  Useful for test assertions and debugging.
  """
  @spec table_name() :: :monkey_claw_skills_cache
  def table_name, do: @table

  @spec expired?(integer()) :: boolean()
  defp expired?(timestamp) do
    now = System.monotonic_time(:millisecond)
    now - timestamp > ttl_ms()
  end

  @spec ttl_ms() :: non_neg_integer()
  defp ttl_ms do
    Application.get_env(:monkey_claw, :skills_cache_ttl_ms, @default_ttl_ms)
  end
end
