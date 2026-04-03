defmodule MonkeyClaw.UserModelingTest do
  use MonkeyClaw.DataCase

  alias MonkeyClaw.UserModeling
  alias MonkeyClaw.UserModeling.UserProfile

  import MonkeyClaw.Factory

  # ──────────────────────────────────────────────
  # ensure_profile/1
  # ──────────────────────────────────────────────

  describe "ensure_profile/1" do
    test "creates a new profile when none exists" do
      workspace = insert_workspace!()

      assert {:ok, %UserProfile{} = profile} = UserModeling.ensure_profile(workspace)
      assert profile.workspace_id == workspace.id
      assert profile.privacy_level == :full
      assert profile.injection_enabled == true
      assert profile.observed_topics == %{}
      assert profile.observed_patterns == %{}
    end

    test "returns existing profile if one already exists" do
      workspace = insert_workspace!()

      {:ok, first} = UserModeling.ensure_profile(workspace)
      {:ok, second} = UserModeling.ensure_profile(workspace)

      assert first.id == second.id
    end

    test "profile belongs to workspace" do
      workspace = insert_workspace!()

      {:ok, profile} = UserModeling.ensure_profile(workspace)

      assert profile.workspace_id == workspace.id
    end
  end

  # ──────────────────────────────────────────────
  # get_profile/1
  # ──────────────────────────────────────────────

  describe "get_profile/1" do
    test "returns {:ok, profile} for existing workspace_id" do
      workspace = insert_workspace!()
      profile = insert_user_profile!(workspace)

      assert {:ok, found} = UserModeling.get_profile(workspace.id)
      assert found.id == profile.id
    end

    test "returns {:error, :not_found} for unknown workspace_id" do
      assert {:error, :not_found} = UserModeling.get_profile(Ecto.UUID.generate())
    end
  end

  # ──────────────────────────────────────────────
  # update_profile/2
  # ──────────────────────────────────────────────

  describe "update_profile/2" do
    test "updates display_name" do
      workspace = insert_workspace!()
      profile = insert_user_profile!(workspace)

      assert {:ok, updated} = UserModeling.update_profile(profile, %{display_name: "Dev User"})
      assert updated.display_name == "Dev User"
    end

    test "updates privacy_level" do
      workspace = insert_workspace!()
      profile = insert_user_profile!(workspace)

      assert {:ok, updated} = UserModeling.update_profile(profile, %{privacy_level: :limited})
      assert updated.privacy_level == :limited
    end

    test "updates preferences" do
      workspace = insert_workspace!()
      profile = insert_user_profile!(workspace)

      assert {:ok, updated} =
               UserModeling.update_profile(profile, %{
                 preferences: %{"verbose_output" => true, "theme" => "dark"}
               })

      assert updated.preferences == %{"verbose_output" => true, "theme" => "dark"}
    end

    test "returns {:error, changeset} for invalid attrs" do
      workspace = insert_workspace!()
      profile = insert_user_profile!(workspace)

      assert {:error, changeset} =
               UserModeling.update_profile(profile, %{preferences: %{"nested" => %{}}})

      assert errors_on(changeset)[:preferences]
    end
  end

  # ──────────────────────────────────────────────
  # delete_profile/1
  # ──────────────────────────────────────────────

  describe "delete_profile/1" do
    test "deletes profile and get_profile returns :not_found after" do
      workspace = insert_workspace!()
      profile = insert_user_profile!(workspace)

      assert {:ok, _deleted} = UserModeling.delete_profile(profile)
      assert {:error, :not_found} = UserModeling.get_profile(workspace.id)
    end
  end

  # ──────────────────────────────────────────────
  # extract_topics/1
  # ──────────────────────────────────────────────

  describe "extract_topics/1" do
    test "extracts topic frequencies from text" do
      result = UserModeling.extract_topics("How do I deploy an Elixir release?")

      assert Map.has_key?(result, "deploy")
      assert Map.has_key?(result, "elixir")
      assert Map.has_key?(result, "release")
    end

    test "downcases and filters stopwords" do
      result = UserModeling.extract_topics("The quick brown fox")

      refute Map.has_key?(result, "the")
      assert Map.has_key?(result, "quick")
      assert Map.has_key?(result, "brown")
    end

    test "filters words shorter than 4 characters" do
      result = UserModeling.extract_topics("run the big test suite")

      refute Map.has_key?(result, "run")
      refute Map.has_key?(result, "the")
      refute Map.has_key?(result, "big")
      assert Map.has_key?(result, "test")
      assert Map.has_key?(result, "suite")
    end

    test "counts frequencies — word appearing twice gets count 2" do
      result = UserModeling.extract_topics("elixir elixir deploy")

      assert result["elixir"] == 2
      assert result["deploy"] == 1
    end
  end

  # ──────────────────────────────────────────────
  # merge_topics/2
  # ──────────────────────────────────────────────

  describe "merge_topics/2" do
    test "adds counts for overlapping keys" do
      existing = %{"elixir" => 5, "deploy" => 3}
      new = %{"elixir" => 2}

      result = UserModeling.merge_topics(existing, new)

      assert result["elixir"] == 7
      assert result["deploy"] == 3
    end

    test "keeps non-overlapping keys from both maps" do
      existing = %{"elixir" => 3}
      new = %{"deploy" => 1}

      result = UserModeling.merge_topics(existing, new)

      assert result["elixir"] == 3
      assert result["deploy"] == 1
    end

    test "trims result to top 100 topics by frequency" do
      # Build two maps that together exceed 100 topics.
      # existing: topics 1..60 with count 10
      # new:      topics 41..120 with count 5
      # Merged: topics 41..60 have count 15 (overlap), others have 5 or 10.
      # Top 100 should include all topics with count >= 10, then fill from count 5.
      existing =
        for i <- 1..60, into: %{}, do: {"topic_#{String.pad_leading("#{i}", 3, "0")}", 10}

      new = for i <- 41..120, into: %{}, do: {"topic_#{String.pad_leading("#{i}", 3, "0")}", 5}

      result = UserModeling.merge_topics(existing, new)

      assert map_size(result) == 100

      # All topics from the overlap range (41..60) should be present with merged count 15
      for i <- 41..60 do
        key = "topic_#{String.pad_leading("#{i}", 3, "0")}"
        assert Map.has_key?(result, key), "expected #{key} in result"
        assert result[key] == 15
      end

      # All topics from the existing-only range (1..40) should be present with count 10
      for i <- 1..40 do
        key = "topic_#{String.pad_leading("#{i}", 3, "0")}"
        assert Map.has_key?(result, key), "expected #{key} in result"
        assert result[key] == 10
      end

      # The remaining 40 slots (100 - 60) come from the new-only range (61..120)
      # which all have count 5. Exactly 40 of these 60 should survive.
      new_only_surviving =
        for i <- 61..120,
            Map.has_key?(result, "topic_#{String.pad_leading("#{i}", 3, "0")}"),
            do: i

      assert length(new_only_surviving) == 40
    end

    test "caps individual topic counts at 1000" do
      existing = %{"elixir" => 999}
      new = %{"elixir" => 5}

      result = UserModeling.merge_topics(existing, new)

      assert result["elixir"] == 1000
    end
  end

  # ──────────────────────────────────────────────
  # merge_patterns/2
  # ──────────────────────────────────────────────

  describe "merge_patterns/2" do
    test "adds query_count values" do
      existing = %{"query_count" => 10, "avg_prompt_length" => 50.0, "active_hours" => %{}}
      new = %{"query_count" => 5, "avg_prompt_length" => 50.0, "active_hours" => %{}}

      result = UserModeling.merge_patterns(existing, new)

      assert result["query_count"] == 15
    end

    test "calculates weighted average of avg_prompt_length" do
      existing = %{"query_count" => 10, "avg_prompt_length" => 50.0, "active_hours" => %{}}
      new = %{"query_count" => 10, "avg_prompt_length" => 100.0, "active_hours" => %{}}

      result = UserModeling.merge_patterns(existing, new)

      assert_in_delta result["avg_prompt_length"], 75.0, 0.01
    end

    test "merges active_hours maps by adding counts" do
      existing = %{
        "query_count" => 5,
        "avg_prompt_length" => 40.0,
        "active_hours" => %{"14" => 3, "9" => 2}
      }

      new = %{
        "query_count" => 2,
        "avg_prompt_length" => 60.0,
        "active_hours" => %{"14" => 1, "20" => 4}
      }

      result = UserModeling.merge_patterns(existing, new)

      assert result["active_hours"]["14"] == 4
      assert result["active_hours"]["9"] == 2
      assert result["active_hours"]["20"] == 4
    end

    test "caps query_count at 1_000_000" do
      existing = %{
        "query_count" => 999_999,
        "avg_prompt_length" => 50.0,
        "active_hours" => %{}
      }

      new = %{"query_count" => 5, "avg_prompt_length" => 50.0, "active_hours" => %{}}

      result = UserModeling.merge_patterns(existing, new)

      assert result["query_count"] == 1_000_000
    end
  end

  # ──────────────────────────────────────────────
  # record_observation/2
  # ──────────────────────────────────────────────

  describe "record_observation/2" do
    test "updates observed_topics on the profile" do
      workspace = insert_workspace!()
      insert_user_profile!(workspace)

      assert :ok =
               UserModeling.record_observation(workspace.id, %{
                 prompt: "How do I deploy an Elixir release?"
               })

      {:ok, updated} = UserModeling.get_profile(workspace.id)
      assert Map.has_key?(updated.observed_topics, "deploy")
      assert Map.has_key?(updated.observed_topics, "elixir")
      assert Map.has_key?(updated.observed_topics, "release")
    end

    test "updates observed_patterns when privacy_level is :full" do
      workspace = insert_workspace!()
      insert_user_profile!(workspace, %{privacy_level: :full})

      assert :ok =
               UserModeling.record_observation(workspace.id, %{
                 prompt: "How do I deploy an Elixir release?"
               })

      {:ok, updated} = UserModeling.get_profile(workspace.id)
      assert Map.has_key?(updated.observed_patterns, "query_count")
      assert updated.observed_patterns["query_count"] == 1
    end

    test "only updates topics (not patterns) when privacy_level is :limited" do
      workspace = insert_workspace!()
      insert_user_profile!(workspace, %{privacy_level: :limited})

      assert :ok =
               UserModeling.record_observation(workspace.id, %{
                 prompt: "How do I deploy an Elixir release?"
               })

      {:ok, updated} = UserModeling.get_profile(workspace.id)
      assert Map.has_key?(updated.observed_topics, "deploy")
      assert updated.observed_patterns == %{}
    end

    test "no-ops when privacy_level is :none" do
      workspace = insert_workspace!()
      insert_user_profile!(workspace, %{privacy_level: :none})

      assert :ok =
               UserModeling.record_observation(workspace.id, %{
                 prompt: "How do I deploy an Elixir release?"
               })

      {:ok, updated} = UserModeling.get_profile(workspace.id)
      assert updated.observed_topics == %{}
      assert updated.observed_patterns == %{}
    end

    test "creates profile if one does not exist for the workspace" do
      workspace = insert_workspace!()

      assert :ok =
               UserModeling.record_observation(workspace.id, %{
                 prompt: "Elixir pattern matching"
               })

      assert {:ok, profile} = UserModeling.get_profile(workspace.id)
      assert Map.has_key?(profile.observed_topics, "elixir")
      assert Map.has_key?(profile.observed_topics, "pattern")
      assert Map.has_key?(profile.observed_topics, "matching")
    end

    test "returns :ok" do
      workspace = insert_workspace!()

      assert :ok = UserModeling.record_observation(workspace.id, %{prompt: "test prompt here"})
    end
  end

  # ──────────────────────────────────────────────
  # toggle_injection/2
  # ──────────────────────────────────────────────

  describe "toggle_injection/2" do
    test "disables injection on a profile" do
      workspace = insert_workspace!()
      profile = insert_user_profile!(workspace, %{injection_enabled: true})

      assert {:ok, updated} = UserModeling.toggle_injection(profile, false)
      assert updated.injection_enabled == false
    end

    test "enables injection on a profile" do
      workspace = insert_workspace!()
      profile = insert_user_profile!(workspace, %{injection_enabled: false})

      assert {:ok, updated} = UserModeling.toggle_injection(profile, true)
      assert updated.injection_enabled == true
    end

    test "disabling injection causes get_injectable_context to return empty string" do
      workspace = insert_workspace!()

      profile =
        insert_user_profile!(workspace, %{
          injection_enabled: true,
          observed_topics: %{"elixir" => 10}
        })

      # Verify context is non-empty before toggle
      context_before = UserModeling.get_injectable_context(workspace.id)
      assert String.contains?(context_before, "elixir")

      # Toggle off
      {:ok, _} = UserModeling.toggle_injection(profile, false)

      # Now context should be empty
      assert UserModeling.get_injectable_context(workspace.id) == ""
    end
  end

  # ──────────────────────────────────────────────
  # build_injection_context/1
  # ──────────────────────────────────────────────

  describe "build_injection_context/1" do
    test "formats context regardless of injection_enabled flag" do
      workspace = insert_workspace!()

      profile =
        insert_user_profile!(workspace, %{
          injection_enabled: false,
          observed_topics: %{"elixir" => 10}
        })

      # build_injection_context is a pure formatting function — it does
      # NOT check injection_enabled. That gating is in get_injectable_context.
      result = UserModeling.build_injection_context(profile)
      assert String.starts_with?(result, "[User context]")
      assert String.contains?(result, "elixir")
    end

    test "returns empty string when no useful data" do
      workspace = insert_workspace!()
      profile = insert_user_profile!(workspace)

      assert UserModeling.build_injection_context(profile) == ""
    end

    test "returns formatted context with top interests when topics exist" do
      workspace = insert_workspace!()

      profile =
        insert_user_profile!(workspace, %{
          observed_topics: %{"elixir" => 10, "testing" => 7, "deployment" => 5}
        })

      context = UserModeling.build_injection_context(profile)

      assert String.contains?(context, "elixir")
      assert String.contains?(context, "testing")
      assert String.contains?(context, "deployment")
      assert String.contains?(context, "Top interests:")
    end

    test "returns formatted context with preferences when set" do
      workspace = insert_workspace!()

      profile =
        insert_user_profile!(workspace, %{
          preferences: %{"verbose_output" => true}
        })

      context = UserModeling.build_injection_context(profile)

      assert String.contains?(context, "Preferences:")
      assert String.contains?(context, "verbose_output=true")
    end

    test "starts with \"[User context]\"" do
      workspace = insert_workspace!()

      profile =
        insert_user_profile!(workspace, %{
          observed_topics: %{"elixir" => 5}
        })

      context = UserModeling.build_injection_context(profile)

      assert String.starts_with?(context, "[User context]")
    end
  end

  # ──────────────────────────────────────────────
  # get_injectable_context/1
  # ──────────────────────────────────────────────

  describe "get_injectable_context/1" do
    test "returns context string for workspace with profile" do
      workspace = insert_workspace!()

      insert_user_profile!(workspace, %{
        observed_topics: %{"elixir" => 8, "testing" => 4}
      })

      context = UserModeling.get_injectable_context(workspace.id)

      assert String.starts_with?(context, "[User context]")
      assert String.contains?(context, "elixir")
    end

    test "returns empty string when injection is disabled" do
      workspace = insert_workspace!()

      insert_user_profile!(workspace, %{
        injection_enabled: false,
        observed_topics: %{"elixir" => 8}
      })

      assert UserModeling.get_injectable_context(workspace.id) == ""
    end

    test "returns empty string for workspace without profile" do
      workspace = insert_workspace!()

      assert UserModeling.get_injectable_context(workspace.id) == ""
    end
  end
end
