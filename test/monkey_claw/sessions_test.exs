defmodule MonkeyClaw.SessionsTest do
  use MonkeyClaw.DataCase

  alias MonkeyClaw.Sessions
  alias MonkeyClaw.Sessions.{Message, Session}

  import MonkeyClaw.Factory

  # ──────────────────────────────────────────────
  # Session CRUD
  # ──────────────────────────────────────────────

  describe "create_session/2" do
    test "creates with defaults" do
      workspace = insert_workspace!()

      assert {:ok, %Session{} = session} = Sessions.create_session(workspace)
      assert session.workspace_id == workspace.id
      assert session.status == :active
      assert session.message_count == 0
      assert session.title == nil
      assert session.id != nil
    end

    test "creates with model" do
      workspace = insert_workspace!()

      assert {:ok, %Session{} = session} =
               Sessions.create_session(workspace, %{model: "claude-opus-4-6"})

      assert session.model == "claude-opus-4-6"
    end

    test "creates with all optional fields" do
      workspace = insert_workspace!()

      attrs = %{
        title: "My Chat",
        model: "claude-opus-4-6",
        summary: "A conversation about code"
      }

      assert {:ok, %Session{} = session} = Sessions.create_session(workspace, attrs)
      assert session.title == "My Chat"
      assert session.model == "claude-opus-4-6"
      assert session.summary == "A conversation about code"
    end

    test "generates binary_id" do
      workspace = insert_workspace!()
      session = insert_session!(workspace)

      assert is_binary(session.id)
      assert {:ok, _} = Ecto.UUID.cast(session.id)
    end

    test "defaults status to :active" do
      workspace = insert_workspace!()
      session = insert_session!(workspace)

      assert session.status == :active
    end

    test "validates title length" do
      workspace = insert_workspace!()
      long_title = String.duplicate("a", 201)

      assert {:error, changeset} =
               Sessions.create_session(workspace, %{title: long_title})

      assert "should be at most 200 character(s)" in errors_on(changeset).title
    end

    test "validates model length" do
      workspace = insert_workspace!()
      long_model = String.duplicate("x", 101)

      assert {:error, changeset} =
               Sessions.create_session(workspace, %{model: long_model})

      assert "should be at most 100 character(s)" in errors_on(changeset).model
    end
  end

  describe "get_session/1" do
    test "returns session by ID" do
      workspace = insert_workspace!()
      session = insert_session!(workspace)

      assert {:ok, found} = Sessions.get_session(session.id)
      assert found.id == session.id
    end

    test "returns {:error, :not_found} for missing ID" do
      assert {:error, :not_found} = Sessions.get_session(Ecto.UUID.generate())
    end
  end

  describe "get_session!/1" do
    test "returns session by ID" do
      workspace = insert_workspace!()
      session = insert_session!(workspace)

      assert %Session{} = Sessions.get_session!(session.id)
    end

    test "raises for missing ID" do
      assert_raise Ecto.NoResultsError, fn ->
        Sessions.get_session!(Ecto.UUID.generate())
      end
    end
  end

  describe "list_sessions/1" do
    test "returns sessions for a workspace, most recent first" do
      workspace = insert_workspace!()
      s1 = insert_session!(workspace, %{model: "first"})
      s2 = insert_session!(workspace, %{model: "second"})

      sessions = Sessions.list_sessions(workspace.id)
      ids = Enum.map(sessions, & &1.id)

      assert s2.id in ids
      assert s1.id in ids
      # Most recent first (s2 was created after s1)
      assert hd(ids) == s2.id
    end

    test "does not return sessions from other workspaces" do
      w1 = insert_workspace!()
      w2 = insert_workspace!()
      insert_session!(w1)
      insert_session!(w2)

      sessions = Sessions.list_sessions(w1.id)
      assert length(sessions) == 1
    end

    test "accepts workspace struct" do
      workspace = insert_workspace!()
      insert_session!(workspace)

      sessions = Sessions.list_sessions(workspace)
      assert length(sessions) == 1
    end
  end

  describe "list_sessions/2 with options" do
    test "limits results" do
      workspace = insert_workspace!()
      Enum.each(1..5, fn _ -> insert_session!(workspace) end)

      sessions = Sessions.list_sessions(workspace.id, %{limit: 3})
      assert length(sessions) == 3
    end

    test "filters by status" do
      workspace = insert_workspace!()
      active = insert_session!(workspace)
      stopped = insert_session!(workspace)
      Sessions.update_session(stopped, %{status: :stopped})

      active_sessions = Sessions.list_sessions(workspace.id, %{status: :active})
      assert length(active_sessions) == 1
      assert hd(active_sessions).id == active.id
    end
  end

  describe "update_session/2" do
    test "updates title" do
      workspace = insert_workspace!()
      session = insert_session!(workspace)

      assert {:ok, updated} = Sessions.update_session(session, %{title: "New Title"})
      assert updated.title == "New Title"
    end

    test "updates status" do
      workspace = insert_workspace!()
      session = insert_session!(workspace)

      assert {:ok, updated} = Sessions.update_session(session, %{status: :stopped})
      assert updated.status == :stopped
    end

    test "updates message_count" do
      workspace = insert_workspace!()
      session = insert_session!(workspace)

      assert {:ok, updated} = Sessions.update_session(session, %{message_count: 42})
      assert updated.message_count == 42
    end

    test "rejects negative message_count" do
      workspace = insert_workspace!()
      session = insert_session!(workspace)

      assert {:error, changeset} = Sessions.update_session(session, %{message_count: -1})
      assert "must be greater than or equal to 0" in errors_on(changeset).message_count
    end
  end

  describe "delete_session/1" do
    test "deletes the session" do
      workspace = insert_workspace!()
      session = insert_session!(workspace)

      assert {:ok, _} = Sessions.delete_session(session)
      assert {:error, :not_found} = Sessions.get_session(session.id)
    end

    test "cascade-deletes messages" do
      workspace = insert_workspace!()
      session = insert_session!(workspace)
      insert_message!(session, %{role: :user, content: "hello"})
      insert_message!(session, %{role: :assistant, content: "world"})

      assert {:ok, _} = Sessions.delete_session(session)
      assert Sessions.get_messages(session.id) == []
    end
  end

  # ──────────────────────────────────────────────
  # Message Operations
  # ──────────────────────────────────────────────

  describe "record_message/2" do
    test "inserts a message and increments session count" do
      workspace = insert_workspace!()
      session = insert_session!(workspace)

      assert {:ok, %Message{} = msg} =
               Sessions.record_message(session, %{role: :user, content: "Hello!"})

      assert msg.role == :user
      assert msg.content == "Hello!"
      assert msg.session_id == session.id
      assert msg.sequence == 0

      # Verify denormalized count was incremented
      {:ok, reloaded} = Sessions.get_session(session.id)
      assert reloaded.message_count == 1
    end

    test "auto-assigns incrementing sequence numbers" do
      workspace = insert_workspace!()
      session = insert_session!(workspace)

      {:ok, m1} = Sessions.record_message(session, %{role: :user, content: "First"})
      {:ok, m2} = Sessions.record_message(session, %{role: :assistant, content: "Second"})
      {:ok, m3} = Sessions.record_message(session, %{role: :user, content: "Third"})

      assert m1.sequence == 0
      assert m2.sequence == 1
      assert m3.sequence == 2
    end

    test "increments count atomically" do
      workspace = insert_workspace!()
      session = insert_session!(workspace)

      Enum.each(1..5, fn _ ->
        Sessions.record_message(session, %{role: :user, content: "msg"})
      end)

      {:ok, reloaded} = Sessions.get_session(session.id)
      assert reloaded.message_count == 5
    end

    test "supports all valid roles" do
      workspace = insert_workspace!()
      session = insert_session!(workspace)

      for role <- [:user, :assistant, :system, :tool_use, :tool_result] do
        assert {:ok, %Message{role: ^role}} =
                 Sessions.record_message(session, %{role: role, content: "test"})
      end
    end

    test "allows nil content" do
      workspace = insert_workspace!()
      session = insert_session!(workspace)

      assert {:ok, %Message{content: nil}} =
               Sessions.record_message(session, %{role: :tool_use})
    end

    test "stores metadata" do
      workspace = insert_workspace!()
      session = insert_session!(workspace)

      metadata = %{tool_name: "read_file", tool_id: "abc123"}

      assert {:ok, msg} =
               Sessions.record_message(session, %{
                 role: :tool_use,
                 content: nil,
                 metadata: metadata
               })

      assert msg.metadata == %{tool_name: "read_file", tool_id: "abc123"}
    end

    test "fails without role" do
      workspace = insert_workspace!()
      session = insert_session!(workspace)

      assert {:error, changeset} = Sessions.record_message(session, %{content: "orphan"})
      assert "can't be blank" in errors_on(changeset).role
    end
  end

  describe "get_messages/1" do
    test "returns messages ordered by sequence" do
      workspace = insert_workspace!()
      session = insert_session!(workspace)

      insert_message!(session, %{role: :user, content: "first"})
      insert_message!(session, %{role: :assistant, content: "second"})
      insert_message!(session, %{role: :user, content: "third"})

      messages = Sessions.get_messages(session.id)
      assert length(messages) == 3
      assert Enum.map(messages, & &1.content) == ["first", "second", "third"]
      assert Enum.map(messages, & &1.sequence) == [0, 1, 2]
    end

    test "returns empty list for session with no messages" do
      workspace = insert_workspace!()
      session = insert_session!(workspace)

      assert Sessions.get_messages(session.id) == []
    end
  end

  describe "get_messages/2 with options" do
    setup do
      workspace = insert_workspace!()
      session = insert_session!(workspace)

      Enum.each(1..10, fn i ->
        role = if rem(i, 2) == 1, do: :user, else: :assistant
        insert_message!(session, %{role: role, content: "msg-#{i}"})
      end)

      %{session: session}
    end

    test "limits results", %{session: session} do
      messages = Sessions.get_messages(session.id, %{limit: 3})
      assert length(messages) == 3
    end

    test "offsets results", %{session: session} do
      # SQLite requires LIMIT with OFFSET — use a large limit
      messages = Sessions.get_messages(session.id, %{limit: 100, offset: 8})
      assert length(messages) == 2
    end

    test "combines limit and offset", %{session: session} do
      messages = Sessions.get_messages(session.id, %{limit: 3, offset: 2})
      assert length(messages) == 3
      assert hd(messages).content == "msg-3"
    end

    test "filters by roles", %{session: session} do
      user_messages = Sessions.get_messages(session.id, %{roles: [:user]})
      assert length(user_messages) == 5
      assert Enum.all?(user_messages, &(&1.role == :user))
    end

    test "filters by multiple roles", %{session: session} do
      messages = Sessions.get_messages(session.id, %{roles: [:user, :assistant]})
      assert length(messages) == 10
    end
  end

  # ──────────────────────────────────────────────
  # FTS5 Search
  # ──────────────────────────────────────────────

  describe "search_messages/2" do
    test "finds messages by content" do
      workspace = insert_workspace!()
      session = insert_session!(workspace)

      insert_message!(session, %{role: :user, content: "deploy the application"})
      insert_message!(session, %{role: :assistant, content: "deployment complete"})
      insert_message!(session, %{role: :user, content: "check the logs"})

      results = Sessions.search_messages(workspace.id, "deploy*")
      assert length(results) == 2
    end

    test "returns empty for no matches" do
      workspace = insert_workspace!()
      session = insert_session!(workspace)

      insert_message!(session, %{role: :user, content: "hello world"})

      assert Sessions.search_messages(workspace.id, "nonexistent") == []
    end

    test "scopes search to workspace" do
      w1 = insert_workspace!()
      w2 = insert_workspace!()
      s1 = insert_session!(w1)
      s2 = insert_session!(w2)

      insert_message!(s1, %{role: :user, content: "unique_term_alpha"})
      insert_message!(s2, %{role: :user, content: "unique_term_alpha"})

      results = Sessions.search_messages(w1.id, "unique_term_alpha")
      assert length(results) == 1
    end

    test "returns Message structs with correct fields" do
      workspace = insert_workspace!()
      session = insert_session!(workspace)

      insert_message!(session, %{role: :user, content: "findable content"})

      [result] = Sessions.search_messages(workspace.id, "findable")
      assert %Message{} = result
      assert result.role == :user
      assert result.content == "findable content"
      assert result.session_id == session.id
    end

    test "respects limit option" do
      workspace = insert_workspace!()
      session = insert_session!(workspace)

      Enum.each(1..10, fn i ->
        insert_message!(session, %{role: :user, content: "searchable item #{i}"})
      end)

      results = Sessions.search_messages(workspace.id, "searchable", %{limit: 3})
      assert length(results) == 3
    end

    test "searches across multiple sessions in same workspace" do
      workspace = insert_workspace!()
      s1 = insert_session!(workspace)
      s2 = insert_session!(workspace)

      insert_message!(s1, %{role: :user, content: "cross_session_term"})
      insert_message!(s2, %{role: :user, content: "cross_session_term"})

      results = Sessions.search_messages(workspace.id, "cross_session_term")
      assert length(results) == 2
    end
  end

  # ──────────────────────────────────────────────
  # FTS5 Search Filters
  # ──────────────────────────────────────────────

  describe "search_messages/3 with filters" do
    test "filters by :after temporal boundary" do
      workspace = insert_workspace!()
      session = insert_session!(workspace)
      insert_message!(session, %{role: :user, content: "temporal_after_keyword"})

      # Search with a future :after should find nothing
      future = DateTime.add(DateTime.utc_now(), 3600, :second)
      results = Sessions.search_messages(workspace.id, "temporal_after_keyword", %{after: future})

      assert results == []
    end

    test "filters by :before temporal boundary" do
      workspace = insert_workspace!()
      session = insert_session!(workspace)
      insert_message!(session, %{role: :user, content: "temporal_before_keyword"})

      # Search with a past :before should find nothing
      past = DateTime.add(DateTime.utc_now(), -3600, :second)

      results =
        Sessions.search_messages(workspace.id, "temporal_before_keyword", %{before: past})

      assert results == []
    end

    test "filters by :roles" do
      workspace = insert_workspace!()
      session = insert_session!(workspace)
      insert_message!(session, %{role: :user, content: "role_filter_keyword"})
      insert_message!(session, %{role: :assistant, content: "role_filter_keyword"})
      insert_message!(session, %{role: :system, content: "role_filter_keyword"})

      results =
        Sessions.search_messages(workspace.id, "role_filter_keyword", %{roles: [:user]})

      assert length(results) == 1
      assert hd(results).role == :user
    end

    test "filters by multiple :roles" do
      workspace = insert_workspace!()
      session = insert_session!(workspace)
      insert_message!(session, %{role: :user, content: "multi_role_keyword"})
      insert_message!(session, %{role: :assistant, content: "multi_role_keyword"})
      insert_message!(session, %{role: :system, content: "multi_role_keyword"})

      results =
        Sessions.search_messages(workspace.id, "multi_role_keyword", %{
          roles: [:user, :assistant]
        })

      assert length(results) == 2
      roles = Enum.map(results, & &1.role) |> Enum.sort()
      assert roles == [:assistant, :user]
    end

    test "excludes session by :exclude_session_id" do
      workspace = insert_workspace!()
      s1 = insert_session!(workspace)
      s2 = insert_session!(workspace)
      insert_message!(s1, %{role: :user, content: "exclude_session_keyword"})
      insert_message!(s2, %{role: :user, content: "exclude_session_keyword"})

      results =
        Sessions.search_messages(workspace.id, "exclude_session_keyword", %{
          exclude_session_id: s1.id
        })

      assert length(results) == 1
      assert hd(results).session_id == s2.id
    end

    test "combines multiple filters" do
      workspace = insert_workspace!()
      session = insert_session!(workspace)
      insert_message!(session, %{role: :user, content: "combined_filter_keyword"})
      insert_message!(session, %{role: :assistant, content: "combined_filter_keyword"})

      results =
        Sessions.search_messages(workspace.id, "combined_filter_keyword", %{
          roles: [:user],
          after: DateTime.add(DateTime.utc_now(), -3600, :second),
          limit: 5
        })

      assert length(results) == 1
      assert hd(results).role == :user
    end
  end

  # ──────────────────────────────────────────────
  # Title Derivation
  # ──────────────────────────────────────────────

  describe "derive_title/1" do
    test "derives title from first user message" do
      workspace = insert_workspace!()
      session = insert_session!(workspace)

      insert_message!(session, %{role: :user, content: "How do I deploy to production?"})
      insert_message!(session, %{role: :assistant, content: "Here are the steps..."})

      assert {:ok, updated} = Sessions.derive_title(session)
      assert updated.title == "How do I deploy to production?"
    end

    test "truncates long messages to 100 characters" do
      workspace = insert_workspace!()
      session = insert_session!(workspace)

      long_msg = String.duplicate("x", 150)
      insert_message!(session, %{role: :user, content: long_msg})

      assert {:ok, updated} = Sessions.derive_title(session)
      assert String.length(updated.title) == 100
    end

    test "no-op when session already has title" do
      workspace = insert_workspace!()
      session = insert_session!(workspace, %{title: "Existing Title"})

      assert {:ok, unchanged} = Sessions.derive_title(session)
      assert unchanged.title == "Existing Title"
    end

    test "no-op when session has no user messages" do
      workspace = insert_workspace!()
      session = insert_session!(workspace)

      insert_message!(session, %{role: :assistant, content: "I'm ready to help"})

      assert {:ok, unchanged} = Sessions.derive_title(session)
      assert unchanged.title == nil
    end

    test "no-op when session has no messages at all" do
      workspace = insert_workspace!()
      session = insert_session!(workspace)

      assert {:ok, unchanged} = Sessions.derive_title(session)
      assert unchanged.title == nil
    end
  end

  # ──────────────────────────────────────────────
  # Sequence Numbering
  # ──────────────────────────────────────────────

  describe "next_sequence/1" do
    test "returns 0 for empty session" do
      workspace = insert_workspace!()
      session = insert_session!(workspace)

      assert Sessions.next_sequence(session.id) == 0
    end

    test "returns max + 1 for session with messages" do
      workspace = insert_workspace!()
      session = insert_session!(workspace)

      insert_message!(session, %{role: :user, content: "first"})
      insert_message!(session, %{role: :assistant, content: "second"})

      assert Sessions.next_sequence(session.id) == 2
    end
  end

  describe "increment_message_count/1" do
    test "increments the denormalized counter" do
      workspace = insert_workspace!()
      session = insert_session!(workspace)

      :ok = Sessions.increment_message_count(session.id)
      :ok = Sessions.increment_message_count(session.id)

      {:ok, reloaded} = Sessions.get_session(session.id)
      assert reloaded.message_count == 2
    end
  end
end
