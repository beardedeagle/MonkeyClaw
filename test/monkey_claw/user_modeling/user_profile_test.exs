defmodule MonkeyClaw.UserModeling.UserProfileTest do
  use MonkeyClaw.DataCase

  import MonkeyClaw.Factory

  alias MonkeyClaw.UserModeling.UserProfile

  describe "create_changeset/2" do
    test "valid defaults produce valid changeset" do
      workspace = insert_workspace!()
      profile = Ecto.build_assoc(workspace, :user_profile)

      cs = UserProfile.create_changeset(profile, %{})

      assert cs.valid?
      assert get_field(cs, :privacy_level) == :full
      assert get_field(cs, :injection_enabled) == true
    end

    test "validates privacy_level inclusion" do
      workspace = insert_workspace!()
      profile = Ecto.build_assoc(workspace, :user_profile)

      cs = UserProfile.create_changeset(profile, %{privacy_level: :invalid})
      refute cs.valid?
      assert errors_on(cs)[:privacy_level]

      for level <- [:full, :limited, :none] do
        cs = UserProfile.create_changeset(profile, %{privacy_level: level})
        assert cs.valid?, "expected :#{level} to be valid"
      end
    end

    test "validates preferences is a flat map" do
      workspace = insert_workspace!()
      profile = Ecto.build_assoc(workspace, :user_profile)

      cs =
        UserProfile.create_changeset(profile, %{
          preferences: %{"nested" => %{"key" => "value"}}
        })

      refute cs.valid?
      assert errors_on(cs)[:preferences]
    end

    test "accepts flat preferences with string, number, and boolean values" do
      workspace = insert_workspace!()
      profile = Ecto.build_assoc(workspace, :user_profile)

      cs =
        UserProfile.create_changeset(profile, %{
          preferences: %{"theme" => "dark", "font_size" => 14, "verbose" => false}
        })

      assert cs.valid?
    end

    test "unique_constraint on workspace_id" do
      workspace = insert_workspace!()
      _first = insert_user_profile!(workspace)

      profile = Ecto.build_assoc(workspace, :user_profile)
      cs = UserProfile.create_changeset(profile, %{})

      assert {:error, failed_cs} = MonkeyClaw.Repo.insert(cs)
      assert errors_on(failed_cs)[:workspace_id]
    end
  end

  describe "update_changeset/2" do
    test "allows updating display_name, privacy_level, injection_enabled, preferences" do
      workspace = insert_workspace!()
      profile = insert_user_profile!(workspace)

      cs =
        UserProfile.update_changeset(profile, %{
          display_name: "Developer",
          privacy_level: :limited,
          injection_enabled: false,
          preferences: %{"theme" => "light"}
        })

      assert cs.valid?
      assert get_change(cs, :display_name) == "Developer"
      assert get_change(cs, :privacy_level) == :limited
      assert get_change(cs, :injection_enabled) == false
      assert get_change(cs, :preferences) == %{"theme" => "light"}
    end

    test "validates observed_topics is a map" do
      workspace = insert_workspace!()
      profile = insert_user_profile!(workspace)

      cs = UserProfile.update_changeset(profile, %{observed_topics: "not a map"})
      refute cs.valid?
    end

    test "validates observed_patterns is a map" do
      workspace = insert_workspace!()
      profile = insert_user_profile!(workspace)

      cs = UserProfile.update_changeset(profile, %{observed_patterns: "not a map"})
      refute cs.valid?
    end

    test "accepts valid observed_topics map" do
      workspace = insert_workspace!()
      profile = insert_user_profile!(workspace)

      cs =
        UserProfile.update_changeset(profile, %{
          observed_topics: %{"elixir" => 5, "otp" => 3}
        })

      assert cs.valid?
    end

    test "accepts valid observed_patterns map" do
      workspace = insert_workspace!()
      profile = insert_user_profile!(workspace)

      cs =
        UserProfile.update_changeset(profile, %{
          observed_patterns: %{"morning_usage" => true}
        })

      assert cs.valid?
    end
  end

  describe "tracks_patterns?/1" do
    test "returns true only for :full" do
      assert UserProfile.tracks_patterns?(:full) == true
    end

    test "returns false for :limited" do
      assert UserProfile.tracks_patterns?(:limited) == false
    end

    test "returns false for :none" do
      assert UserProfile.tracks_patterns?(:none) == false
    end
  end
end
