defmodule MonkeyClaw.Sessions do
  @moduledoc """
  Context module for conversation session history.

  Provides CRUD operations for sessions and their messages, plus
  full-text search across message content via SQLite FTS5. This
  is the public API for all session history operations in MonkeyClaw.

  ## What Is a Session

  A session represents a single conversation interaction within a
  workspace. Each time the `MonkeyClaw.AgentBridge.Session` GenServer
  starts for a workspace, a new session record is created here to
  track that conversation's metadata and messages.

  ## FTS5 Integration

  Message content is indexed in an FTS5 external content table
  (`session_messages_fts`). Database triggers keep the index in
  sync automatically on INSERT and DELETE — no application-level
  sync needed. Search results join back to source messages via
  rowid for full metadata access.

  ## Design

  This module is NOT a process. It delegates persistence to
  `MonkeyClaw.Repo` (Ecto/SQLite3). All functions are pure
  (database I/O aside) and safe for concurrent use.

  ## Related Modules

    * `MonkeyClaw.Sessions.Session` — Session Ecto schema
    * `MonkeyClaw.Sessions.Message` — Message Ecto schema
    * `MonkeyClaw.AgentBridge.Session` — GenServer that persists here
    * `MonkeyClaw.Workspaces` — Workspace context (parent entity)
  """

  require Logger

  import Ecto.Query

  alias Ecto.Multi
  alias MonkeyClaw.Repo
  alias MonkeyClaw.Sessions.{Message, Session}
  alias MonkeyClaw.Workspaces.Workspace

  # ──────────────────────────────────────────────
  # Session CRUD
  # ──────────────────────────────────────────────

  @doc """
  Create a new session within a workspace.

  The workspace association is set automatically via `Ecto.build_assoc/3`.

  ## Examples

      {:ok, workspace} = Workspaces.get_workspace(workspace_id)
      {:ok, session} = Sessions.create_session(workspace, %{model: "claude-sonnet-4-6"})
  """
  @spec create_session(Workspace.t(), map()) ::
          {:ok, Session.t()} | {:error, Ecto.Changeset.t()}
  def create_session(%Workspace{} = workspace, attrs \\ %{}) when is_map(attrs) do
    workspace
    |> Ecto.build_assoc(:sessions)
    |> Session.create_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Get a session by ID.

  Returns `{:ok, session}` if found, `{:error, :not_found}` otherwise.
  """
  @spec get_session(Ecto.UUID.t()) :: {:ok, Session.t()} | {:error, :not_found}
  def get_session(id) when is_binary(id) and byte_size(id) > 0 do
    case Repo.get(Session, id) do
      nil -> {:error, :not_found}
      session -> {:ok, session}
    end
  end

  @doc """
  Get a session by ID, raising on not found.
  """
  @spec get_session!(Ecto.UUID.t()) :: Session.t()
  def get_session!(id) when is_binary(id) and byte_size(id) > 0 do
    Repo.get!(Session, id)
  end

  @doc """
  List sessions for a workspace, most recent first.

  ## Examples

      sessions = Sessions.list_sessions(workspace)
      sessions = Sessions.list_sessions(workspace_id)
  """
  @spec list_sessions(Workspace.t() | Ecto.UUID.t()) :: [Session.t()]
  def list_sessions(%Workspace{id: workspace_id}), do: list_sessions(workspace_id)

  def list_sessions(workspace_id) when is_binary(workspace_id) and byte_size(workspace_id) > 0 do
    list_sessions(workspace_id, %{})
  end

  @doc """
  List sessions for a workspace with filtering options.

  ## Options

    * `:limit` — Maximum number of sessions to return
    * `:status` — Filter by session status (`:active`, `:stopped`, `:crashed`)

  ## Examples

      Sessions.list_sessions(workspace_id, %{limit: 10, status: :active})
  """
  @spec list_sessions(Ecto.UUID.t(), map()) :: [Session.t()]
  def list_sessions(workspace_id, opts)
      when is_binary(workspace_id) and byte_size(workspace_id) > 0 and is_map(opts) do
    Session
    |> where([s], s.workspace_id == ^workspace_id)
    |> apply_status_filter(opts)
    |> order_by([s], desc: s.inserted_at)
    |> apply_limit(opts)
    |> Repo.all()
  end

  @doc """
  Update an existing session.
  """
  @spec update_session(Session.t(), map()) ::
          {:ok, Session.t()} | {:error, Ecto.Changeset.t()}
  def update_session(%Session{} = session, attrs) when is_map(attrs) do
    session
    |> Session.update_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Delete a session and all its messages.

  Messages are cascade-deleted by the database foreign key
  constraint, and the FTS5 DELETE trigger automatically removes
  the corresponding index entries.
  """
  @spec delete_session(Session.t()) ::
          {:ok, Session.t()} | {:error, Ecto.Changeset.t()}
  def delete_session(%Session{} = session) do
    Repo.delete(session)
  end

  # ──────────────────────────────────────────────
  # Message Operations
  # ──────────────────────────────────────────────

  @doc """
  Record a new message within a session.

  Atomically inserts the message and increments the session's
  message count. The FTS5 index is updated automatically by the
  database INSERT trigger — no application-level sync needed.

  The `:sequence` is auto-assigned as the next value for the session.

  ## Examples

      {:ok, message} = Sessions.record_message(session, %{
        role: :user,
        content: "Hello!"
      })
  """
  # Dialyzer false positive: Ecto.Multi.new() returns a struct containing an
  # opaque MapSet which triggers :call_without_opaque on Multi.insert/3.
  # This is a known Ecto.Multi / Dialyzer interaction issue.
  @dialyzer {:nowarn_function, record_message: 2}
  @spec record_message(Session.t(), map()) ::
          {:ok, Message.t()} | {:error, Ecto.Changeset.t() | term()}
  def record_message(%Session{} = session, attrs) when is_map(attrs) do
    Multi.new()
    |> Multi.update_all(
      :increment_count,
      fn _changes ->
        from(s in Session,
          where: s.id == ^session.id,
          update: [inc: [message_count: 1]],
          select: s.message_count
        )
      end,
      []
    )
    |> Multi.insert(:message, fn %{increment_count: {1, [count]}} ->
      # count is post-increment; sequence is 0-based
      sequence = count - 1
      attrs = Map.put(attrs, :sequence, sequence)

      session
      |> Ecto.build_assoc(:messages)
      |> Message.create_changeset(attrs)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{message: message}} -> {:ok, message}
      {:error, :message, changeset, _} -> {:error, changeset}
      {:error, :increment_count, error, _} -> {:error, {:increment_count, error}}
    end
  end

  @doc """
  Get all messages for a session, ordered by sequence.
  """
  @spec get_messages(Ecto.UUID.t()) :: [Message.t()]
  def get_messages(session_id) when is_binary(session_id) and byte_size(session_id) > 0 do
    get_messages(session_id, %{})
  end

  @doc """
  Get messages for a session with pagination options.

  ## Options

    * `:limit` — Maximum number of messages to return
    * `:offset` — Number of messages to skip from the start
    * `:roles` — Filter by message roles (list of atoms)

  ## Examples

      Sessions.get_messages(session_id, %{limit: 50, offset: 0})
      Sessions.get_messages(session_id, %{roles: [:user, :assistant]})
  """
  @spec get_messages(Ecto.UUID.t(), map()) :: [Message.t()]
  def get_messages(session_id, opts)
      when is_binary(session_id) and byte_size(session_id) > 0 and is_map(opts) do
    Message
    |> where([m], m.session_id == ^session_id)
    |> apply_roles_filter(opts)
    |> order_by([m], asc: m.sequence)
    |> apply_limit(opts)
    |> apply_offset(opts)
    |> Repo.all()
  end

  @doc """
  Search messages across all sessions in a workspace via FTS5.

  Returns messages whose content matches the FTS5 query string,
  ordered by relevance (FTS5 rank). Results are joined back to
  the source `Message` records for full metadata access.

  ## FTS5 Query Syntax

  Supports standard FTS5 query syntax:

    * Simple terms: `"hello world"` — matches messages containing both
    * Phrases: `"hello world"` (in quotes) — matches exact phrase
    * Prefix: `"hel*"` — matches words starting with "hel"
    * Boolean: `"hello OR world"` — matches either term
    * Negation: `"hello NOT world"` — matches hello, excludes world

  ## Examples

      messages = Sessions.search_messages(workspace_id, "deployment error")
  """
  @spec search_messages(Ecto.UUID.t(), String.t()) :: [Message.t()]
  def search_messages(workspace_id, query)
      when is_binary(workspace_id) and byte_size(workspace_id) > 0 and
             is_binary(query) and byte_size(query) > 0 do
    search_messages(workspace_id, query, %{})
  end

  @doc """
  Search messages with options.

  ## Options

    * `:limit` — Maximum number of results (default: 50)
  """
  @spec search_messages(Ecto.UUID.t(), String.t(), map()) :: [Message.t()]
  def search_messages(workspace_id, query, opts)
      when is_binary(workspace_id) and byte_size(workspace_id) > 0 and
             is_binary(query) and byte_size(query) > 0 and is_map(opts) do
    limit = opts |> Map.get(:limit, 50) |> clamp_search_limit()

    # Use raw SQL for FTS5 MATCH + join back to source messages.
    # External content FTS5 joins via rowid. We join through sessions
    # to verify workspace ownership (defense in depth).
    sql = """
    SELECT m.*
    FROM session_messages_fts AS fts
    JOIN session_messages AS m ON m.rowid = fts.rowid
    JOIN sessions AS s ON s.id = m.session_id
    WHERE fts.content MATCH ?1
      AND s.workspace_id = ?2
    ORDER BY fts.rank
    LIMIT ?3
    """

    case Repo.query(sql, [query, workspace_id, limit]) do
      {:ok, %{rows: rows, columns: columns}} ->
        Enum.map(rows, fn row ->
          columns
          |> Enum.zip(row)
          |> Map.new()
          |> load_message()
        end)

      {:error, %{message: msg}} when is_binary(msg) ->
        if String.contains?(msg, "fts5: syntax error") do
          Logger.debug("FTS5 syntax error for query: #{inspect(query)}")
        else
          Logger.warning("Search query failed: #{inspect(msg)}")
        end

        []

      {:error, reason} ->
        Logger.warning("Search query failed: #{inspect(reason)}")
        []
    end
  end

  # ──────────────────────────────────────────────
  # Title Derivation
  # ──────────────────────────────────────────────

  @doc """
  Auto-derive a session title from the first user message.

  Truncates the content to 100 characters. No-op if the session
  already has a title or has no user messages.
  """
  @spec derive_title(Session.t()) :: {:ok, Session.t()} | {:error, term()}
  def derive_title(%Session{title: title} = session) when not is_nil(title) and title != "" do
    {:ok, session}
  end

  def derive_title(%Session{} = session) do
    first_user_message =
      Message
      |> where([m], m.session_id == ^session.id and m.role == :user)
      |> order_by([m], asc: m.sequence)
      |> limit(1)
      |> Repo.one()

    case first_user_message do
      %Message{content: content} when is_binary(content) and byte_size(content) > 0 ->
        title = String.slice(content, 0, 100)
        update_session(session, %{title: title})

      _ ->
        {:ok, session}
    end
  end

  # ──────────────────────────────────────────────
  # Helpers
  # ──────────────────────────────────────────────

  @doc false
  @spec increment_message_count(Ecto.UUID.t()) :: :ok
  def increment_message_count(session_id)
      when is_binary(session_id) and byte_size(session_id) > 0 do
    Session
    |> where([s], s.id == ^session_id)
    |> Repo.update_all(inc: [message_count: 1])

    :ok
  end

  @doc false
  @spec next_sequence(Ecto.UUID.t()) :: non_neg_integer()
  def next_sequence(session_id)
      when is_binary(session_id) and byte_size(session_id) > 0 do
    result =
      Message
      |> where([m], m.session_id == ^session_id)
      |> select([m], max(m.sequence))
      |> Repo.one()

    case result do
      nil -> 0
      n when is_integer(n) -> n + 1
    end
  end

  # ──────────────────────────────────────────────
  # Private
  # ──────────────────────────────────────────────

  defp apply_status_filter(query, %{status: status}) when is_atom(status) do
    where(query, [s], s.status == ^status)
  end

  defp apply_status_filter(query, _opts), do: query

  defp apply_roles_filter(query, %{roles: roles}) when is_list(roles) and roles != [] do
    where(query, [m], m.role in ^roles)
  end

  defp apply_roles_filter(query, _opts), do: query

  defp apply_limit(query, %{limit: limit}) when is_integer(limit) and limit > 0 do
    limit(query, ^limit)
  end

  defp apply_limit(query, _opts), do: query

  defp apply_offset(query, %{offset: offset}) when is_integer(offset) and offset >= 0 do
    offset(query, ^offset)
  end

  defp apply_offset(query, _opts), do: query

  # Clamp search limit to a safe integer range.
  # Rejects non-integer, zero, and negative values.
  @max_search_limit 200
  defp clamp_search_limit(n) when is_integer(n) and n > 0 and n <= @max_search_limit, do: n
  defp clamp_search_limit(n) when is_integer(n) and n > @max_search_limit, do: @max_search_limit
  defp clamp_search_limit(_), do: 50

  # Load a raw SQL row map into a Message struct.
  # Handles type coercion for enum and datetime fields.
  defp load_message(row) do
    %Message{
      id: row["id"],
      session_id: row["session_id"],
      role: coerce_role(row["role"]),
      content: row["content"],
      sequence: row["sequence"],
      metadata: decode_metadata(row["metadata"]),
      inserted_at: parse_datetime(row["inserted_at"])
    }
  end

  @role_allowlist %{
    "user" => :user,
    "assistant" => :assistant,
    "system" => :system,
    "tool_use" => :tool_use,
    "tool_result" => :tool_result
  }

  defp coerce_role(role) when is_binary(role) do
    case Map.fetch(@role_allowlist, role) do
      {:ok, atom} ->
        atom

      :error ->
        Logger.warning(
          "Unknown message role in database: #{inspect(role)}, defaulting to :system"
        )

        :system
    end
  end

  defp coerce_role(role) when is_atom(role), do: role

  defp decode_metadata(nil), do: %{}
  defp decode_metadata(meta) when is_map(meta), do: meta

  defp decode_metadata(meta) when is_binary(meta) do
    case Jason.decode(meta) do
      {:ok, decoded} -> decoded
      {:error, _} -> %{}
    end
  end

  defp parse_datetime(nil), do: nil

  defp parse_datetime(%DateTime{} = dt), do: dt

  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> dt
      {:error, _} -> nil
    end
  end
end
