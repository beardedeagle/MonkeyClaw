defmodule MonkeyClaw.Webhooks.RateLimiter do
  @moduledoc """
  ETS-backed sliding window rate limiter for webhook endpoints.

  Uses a fixed-window approximation with per-minute buckets. Each
  webhook endpoint has an independent counter that tracks request
  volume within the current minute window.

  ## Algorithm

  For each incoming request:

    1. Compute the current minute bucket: `div(unix_seconds, 60)`
    2. Atomically increment the counter for `{endpoint_id, bucket}`
    3. Compare the counter against the endpoint's `rate_limit_per_minute`
    4. If over limit, reject with `:rate_limited`

  Stale entries (older than 2 minutes) are pruned inline during
  each rate check to prevent unbounded table growth.

  ## ETS Table

  The table is created as a `:public` named table during application
  startup. It uses `:set` semantics with `write_concurrency: true`
  for atomic counter updates via `:ets.update_counter/4`.

  ## Process Justification

  This module is NOT a process. Rate limiting uses ETS atomic
  operations for lock-free concurrent access. Stale entry cleanup
  is performed inline during each check — no periodic timer is
  needed because the table size is bounded by the number of active
  endpoints (small for a single-user application).

  ## Design

  Stateless function module with ETS as the backing store. All
  functions are safe for concurrent use from multiple processes.
  """

  @table_name :monkey_claw_webhook_rate_limits

  @doc """
  Initialize the rate limiter ETS table.

  Must be called once during application startup, before the
  endpoint starts serving requests. Idempotent — returns `:ok`
  if the table already exists.

  ## Examples

      :ok = RateLimiter.init()
  """
  @spec init() :: :ok
  def init do
    case :ets.info(@table_name) do
      :undefined ->
        _table =
          :ets.new(@table_name, [
            :set,
            :public,
            :named_table,
            write_concurrency: true,
            read_concurrency: true
          ])

        :ok

      _ ->
        :ok
    end
  end

  @doc """
  Check whether a webhook endpoint is within its rate limit.

  Atomically increments the counter for the current minute bucket
  and compares against the endpoint's configured limit. Prunes
  stale entries as a side effect.

  Returns `:ok` if the request is allowed, or
  `{:error, :rate_limited}` if the limit has been reached.

  ## Parameters

    * `endpoint_id` — The webhook endpoint's UUID
    * `limit` — Maximum requests per minute for this endpoint

  ## Examples

      :ok = RateLimiter.check("endpoint-uuid", 60)
      {:error, :rate_limited} = RateLimiter.check("endpoint-uuid", 1)
  """
  @spec check(String.t(), pos_integer()) :: :ok | {:error, :rate_limited}
  def check(endpoint_id, limit)
      when is_binary(endpoint_id) and is_integer(limit) and limit > 0 do
    bucket = current_bucket()
    key = {endpoint_id, bucket}

    # Atomic increment: if key doesn't exist, insert with count 1;
    # if it exists, increment the count.
    count =
      :ets.update_counter(@table_name, key, {2, 1}, {key, 0})

    # Prune stale entries for this endpoint (older than 2 buckets ago).
    prune_stale(endpoint_id, bucket)

    if count <= limit do
      :ok
    else
      {:error, :rate_limited}
    end
  end

  @doc """
  Get the current request count for an endpoint in the current window.

  Returns the count for the current minute bucket, or 0 if no
  requests have been recorded.
  """
  @spec current_count(String.t()) :: non_neg_integer()
  def current_count(endpoint_id) when is_binary(endpoint_id) do
    bucket = current_bucket()
    key = {endpoint_id, bucket}

    case :ets.lookup(@table_name, key) do
      [{^key, count}] -> count
      [] -> 0
    end
  end

  @doc """
  Reset all rate limit counters for an endpoint.

  Used when an endpoint's rate limit configuration changes or
  for testing.
  """
  @spec reset(String.t()) :: :ok
  def reset(endpoint_id) when is_binary(endpoint_id) do
    :ets.match_delete(@table_name, {{endpoint_id, :_}, :_})
    :ok
  end

  @doc """
  Reset all rate limit counters for all endpoints.

  Used during testing cleanup.
  """
  @spec reset_all() :: :ok
  def reset_all do
    :ets.delete_all_objects(@table_name)
    :ok
  end

  # ── Private ─────────────────────────────────────────────────

  @spec current_bucket() :: non_neg_integer()
  defp current_bucket do
    div(System.os_time(:second), 60)
  end

  # Remove entries for this endpoint that are older than 2 buckets.
  # This bounds table growth without needing a separate cleanup process.
  @spec prune_stale(String.t(), non_neg_integer()) :: :ok
  defp prune_stale(endpoint_id, current_bucket) do
    cutoff = current_bucket - 2

    # Match entries for this endpoint with bucket < cutoff.
    # ETS match_delete is atomic per entry.
    :ets.select_delete(@table_name, [
      {{{endpoint_id, :"$1"}, :_}, [{:<, :"$1", cutoff}], [true]}
    ])

    :ok
  end
end
