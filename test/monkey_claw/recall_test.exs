defmodule MonkeyClaw.RecallTest do
  use MonkeyClaw.DataCase

  alias MonkeyClaw.Recall
  alias MonkeyClaw.Sessions.Message

  import MonkeyClaw.Factory

  # ──────────────────────────────────────────────
  # recall/3
  # ──────────────────────────────────────────────

  describe "recall/3" do
    test "returns matching messages from past sessions" do
      workspace = insert_workspace!()
      session = insert_session!(workspace)
      insert_message!(session, %{role: :user, content: "deploy the application to staging"})
      insert_message!(session, %{role: :assistant, content: "deployment steps are ready"})

      result = Recall.recall(workspace.id, "deploy the application")

      assert result.match_count > 0
      assert result.formatted != ""
      assert result.truncated == false
      assert is_list(result.matches)
      assert Enum.all?(result.matches, &match?(%Message{}, &1))
    end

    test "returns empty result for no matches" do
      workspace = insert_workspace!()
      session = insert_session!(workspace)
      insert_message!(session, %{role: :user, content: "hello world"})

      result = Recall.recall(workspace.id, "completely unrelated xyzzy query term")

      assert result == %{matches: [], formatted: "", match_count: 0, truncated: false}
    end

    test "returns empty result when query has no usable keywords" do
      workspace = insert_workspace!()
      session = insert_session!(workspace)
      insert_message!(session, %{role: :user, content: "something meaningful"})

      # All words under 3 chars
      result = Recall.recall(workspace.id, "a b c")

      assert result == %{matches: [], formatted: "", match_count: 0, truncated: false}
    end

    test "returns empty result for empty query" do
      workspace = insert_workspace!()

      result = Recall.recall(workspace.id, "")

      assert result == %{matches: [], formatted: "", match_count: 0, truncated: false}
    end

    test "respects :limit option" do
      workspace = insert_workspace!()
      session = insert_session!(workspace)

      Enum.each(1..5, fn i ->
        insert_message!(session, %{role: :user, content: "searchable keyword item #{i}"})
      end)

      result = Recall.recall(workspace.id, "searchable keyword", %{limit: 2})

      assert result.match_count <= 2
    end

    test "respects :roles filter" do
      workspace = insert_workspace!()
      session = insert_session!(workspace)
      insert_message!(session, %{role: :user, content: "deploy the feature"})
      insert_message!(session, %{role: :system, content: "deploy system event"})

      result = Recall.recall(workspace.id, "deploy feature", %{roles: [:user]})

      assert result.match_count > 0
      assert Enum.all?(result.matches, &(&1.role == :user))
    end

    test "respects :exclude_session_id" do
      workspace = insert_workspace!()
      s1 = insert_session!(workspace)
      s2 = insert_session!(workspace)
      insert_message!(s1, %{role: :user, content: "unique_recall_term"})
      insert_message!(s2, %{role: :user, content: "unique_recall_term"})

      result = Recall.recall(workspace.id, "unique_recall_term", %{exclude_session_id: s1.id})

      assert result.match_count == 1
      assert hd(result.matches).session_id == s2.id
    end

    test "respects :after temporal filter" do
      workspace = insert_workspace!()
      session = insert_session!(workspace)
      insert_message!(session, %{role: :user, content: "temporal_filter_test_keyword"})

      # Search with a future :after should find nothing
      future = DateTime.add(DateTime.utc_now(), 3600, :second)
      result = Recall.recall(workspace.id, "temporal_filter_test_keyword", %{after: future})

      assert result.match_count == 0
    end

    test "respects :before temporal filter" do
      workspace = insert_workspace!()
      session = insert_session!(workspace)
      insert_message!(session, %{role: :user, content: "before_filter_test_keyword"})

      # Search with a past :before should find nothing
      past = DateTime.add(DateTime.utc_now(), -3600, :second)
      result = Recall.recall(workspace.id, "before_filter_test_keyword", %{before: past})

      assert result.match_count == 0
    end

    test "scopes recall to workspace" do
      w1 = insert_workspace!()
      w2 = insert_workspace!()
      s1 = insert_session!(w1)
      s2 = insert_session!(w2)
      insert_message!(s1, %{role: :user, content: "workspace_scope_keyword"})
      insert_message!(s2, %{role: :user, content: "workspace_scope_keyword"})

      result = Recall.recall(w1.id, "workspace_scope_keyword")

      assert result.match_count == 1
      assert hd(result.matches).session_id == s1.id
    end

    test "truncates formatted output to max_chars budget" do
      workspace = insert_workspace!()

      # Insert messages across separate sessions so the formatter can
      # include some session blocks and drop others when the budget
      # is exceeded. Each block is ~130 chars; budget of 350 fits
      # roughly 2 blocks, leaving 3 truncated.
      Enum.each(1..5, fn i ->
        session = insert_session!(workspace)
        content = "budget_test_keyword " <> String.duplicate("x", 50) <> " item #{i}"
        insert_message!(session, %{role: :user, content: content})
      end)

      result = Recall.recall(workspace.id, "budget_test_keyword", %{max_chars: 350})

      # Verify results were found and at least one block was formatted,
      # but the budget was too small to include all session blocks.
      assert result.match_count > 0
      assert result.formatted != ""
      assert result.truncated == true
    end
  end

  # ──────────────────────────────────────────────
  # sanitize_query/1
  # ──────────────────────────────────────────────

  describe "sanitize_query/1" do
    test "extracts keywords and joins with OR" do
      result = Recall.sanitize_query("How do I deploy to production?")

      assert is_binary(result)
      assert String.contains?(result, "deploy")
      assert String.contains?(result, "production")
      assert String.contains?(result, " OR ")
    end

    test "strips FTS5 special characters" do
      result = Recall.sanitize_query("search \"quoted\" and (grouped) with *prefix")

      assert result != nil
      refute String.contains?(result, "\"")
      refute String.contains?(result, "(")
      refute String.contains?(result, ")")
      refute String.contains?(result, "*")
    end

    test "removes short words (under 3 chars)" do
      result = Recall.sanitize_query("a to do it deploy")

      assert result != nil
      refute String.contains?(result, " a ")
      refute String.contains?(result, " to ")
      assert String.contains?(result, "deploy")
    end

    test "returns nil for no usable keywords" do
      assert Recall.sanitize_query("a b") == nil
      assert Recall.sanitize_query("") == nil
      assert Recall.sanitize_query("  ") == nil
    end

    test "deduplicates keywords" do
      result = Recall.sanitize_query("deploy deploy deploy production")

      assert result != nil
      # Should have "deploy OR production", not "deploy OR deploy OR deploy OR production"
      assert length(String.split(result, " OR ")) == 2
    end

    test "limits to 8 keywords" do
      words = Enum.map_join(1..12, " ", fn i -> "keyword#{i}" end)
      result = Recall.sanitize_query(words)

      assert result != nil
      assert length(String.split(result, " OR ")) <= 8
    end

    test "strips FTS5 reserved operators" do
      result = Recall.sanitize_query("deploy and not near production")

      assert result != nil
      # "and", "not", "near" are FTS5 operators — must be stripped
      refute String.contains?(result, " and ")
      refute String.contains?(result, " not ")
      refute String.contains?(result, " near ")
      assert String.contains?(result, "deploy")
      assert String.contains?(result, "production")
    end

    test "returns nil when only FTS5 reserved words remain" do
      assert Recall.sanitize_query("and not or near") == nil
    end

    test "downcases keywords" do
      result = Recall.sanitize_query("DEPLOY Production")

      assert result != nil
      assert String.contains?(result, "deploy")
      assert String.contains?(result, "production")
      refute String.contains?(result, "DEPLOY")
    end
  end
end
