defmodule MonkeyClaw.ModelRegistry do
  @moduledoc """
  Cutover stub for the model registry.

  This file exists for exactly the duration of Tasks 2 through 10 of
  the list-models-per-backend cutover. Task 11 replaces this stub
  with the full GenServer implementation (new state struct, ETS
  lifecycle, upsert funnel, probe dispatch, etc.).

  The stub preserves the minimum public API surface required by
  `MonkeyClaw.Application` (must be startable as a supervised child)
  and `MonkeyClawWeb.Live.VaultLive` (which calls `list_all_models/0`
  and `refresh_all/0` behind a `Process.whereis/1` guard). All calls
  return empty/no-op results — no cache, no refresh, no state.

  DO NOT add logic to this file. DO NOT extend it. It is a placeholder.
  Task 11 will delete this entire file and write a new one from scratch.
  """

  use GenServer

  # ── Client API ──────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Stub reader — returns an empty map.

  Task 11 replaces this with the real `list_all_by_backend/0` and
  `list_all_by_provider/0` readers. Until then, `vault_live.ex` sees
  an empty map and renders the empty state.
  """
  @spec list_all_models() :: %{}
  def list_all_models, do: %{}

  @doc """
  Stub refresher — returns `:ok` without doing any work.

  Task 11 replaces this with the real `refresh_all/0` entry point
  that kicks off probes for every configured backend.
  """
  @spec refresh_all() :: :ok
  def refresh_all, do: :ok

  # ── Server Callbacks ────────────────────────────────────────

  @impl GenServer
  def init(_opts), do: {:ok, %{}}

  @impl GenServer
  def handle_info(_msg, state), do: {:noreply, state}
end
