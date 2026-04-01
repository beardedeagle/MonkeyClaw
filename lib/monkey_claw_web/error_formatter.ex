defmodule MonkeyClawWeb.ErrorFormatter do
  @moduledoc """
  Translates agent error reasons into user-facing messages.

  Pattern-matches on structured BeamAgent errors enriched by
  `beam_agent_core` as well as application-level error
  tuples from the conversation workflow.

  ## Structured Error Categories

  BeamAgent enriches error-type messages with a `:category` atom
  and optional `:retry_after` seconds:

    * `:rate_limit` — Provider rate-limit hit; may include `:retry_after`
    * `:subscription_exhausted` — API plan quota exceeded
    * `:context_exceeded` — Conversation exceeded the context window
    * `:auth_expired` — Provider authentication expired or revoked
    * `:server_error` — Upstream provider error (5xx)
    * `:unknown` — Unclassified error

  ## Design

  This is a pure function module — no processes, no side effects
  beyond logging. Logging of unexpected errors is intentional:
  it provides an audit trail for errors that reach the UI layer
  without a recognized category.

  The module is the single translation point between internal error
  representations and user-facing strings. ChatLive delegates to
  `format/1` rather than inlining format logic, keeping the LiveView
  focused on UI concerns.

  `categorized_error?/1` is a companion predicate for filtering
  enriched error messages from the message stream.
  """

  require Logger

  @doc """
  Format an error reason into a user-facing message string.

  Handles three error shapes:

    1. **Structured BeamAgent errors** — maps with a `:category` atom
       and optional `:retry_after` integer (seconds)
    2. **Application-level errors** — tuples from the conversation
       workflow (e.g., `{:session_start_failed, reason}`)
    3. **Catch-all** — any unrecognized error shape

  ## Examples

      iex> MonkeyClawWeb.ErrorFormatter.format(%{category: :rate_limit, retry_after: 30})
      "Rate limited — retry in 30 seconds."

      iex> MonkeyClawWeb.ErrorFormatter.format(%{category: :context_exceeded})
      "Conversation too long — context limit reached. Start a new conversation."

      iex> MonkeyClawWeb.ErrorFormatter.format({:workspace_not_found, "abc"})
      "Workspace not found."
  """
  @spec format(term()) :: String.t()

  # --- Structured BeamAgent errors (maps with :category) ---

  def format(%{category: :rate_limit, retry_after: 1}) do
    "Rate limited — retry in 1 second."
  end

  def format(%{category: :rate_limit, retry_after: seconds})
      when is_integer(seconds) and seconds > 1 do
    "Rate limited — retry in #{seconds} seconds."
  end

  def format(%{category: :rate_limit}) do
    "Rate limited — please wait a moment."
  end

  def format(%{category: :subscription_exhausted}) do
    "Subscription quota exhausted. Check your plan limits."
  end

  def format(%{category: :context_exceeded}) do
    "Conversation too long — context limit reached. Start a new conversation."
  end

  def format(%{category: :auth_expired}) do
    "Authentication expired. Restart the session."
  end

  def format(%{category: :server_error}) do
    "The AI service encountered an error. Try again shortly."
  end

  def format(%{category: :unknown}) do
    Logger.warning("Agent returned unclassified error")
    "Something went wrong. Check server logs for details."
  end

  # --- Application-level errors ---

  def format({:workspace_not_found, _id}), do: "Workspace not found."

  def format({:session_start_failed, reason}) do
    Logger.warning(
      "Session failed to start: #{inspect(reason, limit: 50, printable_limit: 4096)}"
    )

    "Session failed to start. Check server logs for details."
  end

  def format({:thread_start_failed, reason}) do
    Logger.warning("Thread failed to start: #{inspect(reason, limit: 50, printable_limit: 4096)}")
    "Thread failed to start. Check server logs for details."
  end

  def format({:halted, _ctx}), do: "Request blocked by an extension hook."

  def format(:rate_limited), do: "Rate limited — please wait a moment."

  # --- Catch-all ---

  def format(reason) do
    Logger.warning("Unexpected chat error: #{inspect(reason, limit: 50, printable_limit: 4096)}")
    "Something went wrong. Check server logs for details."
  end

  # --- Predicates ---

  @doc """
  Returns `true` if the message is a categorized error from BeamAgent.

  A categorized error is a map with `type: :error` and a `:category` field
  set by `beam_agent_core:categorize/1`.
  """
  @spec categorized_error?(term()) :: boolean()
  def categorized_error?(%{type: :error, category: _}), do: true
  def categorized_error?(_), do: false
end
