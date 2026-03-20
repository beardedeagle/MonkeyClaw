defmodule MonkeyClaw.Extensions.Hook do
  @moduledoc """
  Defines the extension hook points in MonkeyClaw's lifecycle.

  Hook points are named events where the extension pipeline
  executes. Each corresponds to a specific moment in MonkeyClaw's
  processing flow where plugs may observe or transform data.

  ## Hook Categories

    * **Query hooks** — Before and after sending a query to BeamAgent
    * **Session hooks** — Session lifecycle transitions
    * **Workspace hooks** — Workspace CRUD events
    * **Channel hooks** — Channel CRUD events

  ## Design

  This is NOT a process. Hook definitions are compile-time
  constants with runtime validation functions. Adding a new hook
  point means adding an atom to the `@hooks` list — downstream
  code (pipelines, config) picks it up automatically.
  """

  @type t ::
          :query_pre
          | :query_post
          | :session_starting
          | :session_started
          | :session_stopping
          | :session_stopped
          | :workspace_created
          | :workspace_updated
          | :workspace_deleted
          | :channel_created
          | :channel_updated
          | :channel_deleted

  @hooks [
    :query_pre,
    :query_post,
    :session_starting,
    :session_started,
    :session_stopping,
    :session_stopped,
    :workspace_created,
    :workspace_updated,
    :workspace_deleted,
    :channel_created,
    :channel_updated,
    :channel_deleted
  ]

  @doc """
  List all defined hook points.

  ## Examples

      iex> hooks = MonkeyClaw.Extensions.Hook.all()
      iex> :query_pre in hooks
      true
  """
  @spec all() :: [t(), ...]
  def all, do: @hooks

  @doc """
  Check if a value is a valid hook point.

  ## Examples

      iex> MonkeyClaw.Extensions.Hook.valid?(:query_pre)
      true

      iex> MonkeyClaw.Extensions.Hook.valid?(:not_a_hook)
      false
  """
  @spec valid?(term()) :: boolean()
  def valid?(hook) when hook in @hooks, do: true
  def valid?(_other), do: false
end
