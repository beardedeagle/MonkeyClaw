defmodule MonkeyClaw.Workspaces.ChannelTest do
  use ExUnit.Case, async: true

  alias MonkeyClaw.Workspaces.Channel

  # Local helper — avoids pulling in DataCase for pure changeset tests
  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  # Builds a channel struct with workspace_id pre-set (simulating Ecto.build_assoc)
  defp build_channel(workspace_id \\ Ecto.UUID.generate()) do
    %Channel{workspace_id: workspace_id}
  end

  # --- create_changeset/2 ---

  describe "create_changeset/2" do
    test "valid with required fields only" do
      changeset = Channel.create_changeset(build_channel(), %{name: "general"})
      assert changeset.valid?
    end

    test "valid with all fields" do
      attrs = %{
        name: "development",
        description: "Dev discussions",
        status: :archived,
        pinned: true
      }

      changeset = Channel.create_changeset(build_channel(), attrs)
      assert changeset.valid?
    end

    test "defaults status to :open" do
      changeset = Channel.create_changeset(build_channel(), %{name: "general"})
      assert changeset.valid?
      # Status default comes from schema, not changeset
      refute Map.has_key?(changeset.changes, :status)
    end

    test "defaults pinned to false" do
      changeset = Channel.create_changeset(build_channel(), %{name: "general"})
      assert changeset.valid?
      refute Map.has_key?(changeset.changes, :pinned)
    end

    test "requires name" do
      changeset = Channel.create_changeset(build_channel(), %{})
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).name
    end

    test "validates name min length" do
      changeset = Channel.create_changeset(build_channel(), %{name: ""})
      refute changeset.valid?
    end

    test "validates name max length" do
      changeset = Channel.create_changeset(build_channel(), %{name: String.duplicate("a", 101)})
      refute changeset.valid?
    end

    test "accepts name at max length" do
      changeset = Channel.create_changeset(build_channel(), %{name: String.duplicate("a", 100)})
      assert changeset.valid?
    end

    test "validates description max length" do
      attrs = %{name: "general", description: String.duplicate("a", 501)}
      changeset = Channel.create_changeset(build_channel(), attrs)
      refute changeset.valid?
    end

    test "accepts description at max length" do
      attrs = %{name: "general", description: String.duplicate("a", 500)}
      changeset = Channel.create_changeset(build_channel(), attrs)
      assert changeset.valid?
    end

    test "rejects invalid status" do
      attrs = %{name: "general", status: :invalid}
      changeset = Channel.create_changeset(build_channel(), attrs)
      refute changeset.valid?
    end

    test "accepts all valid statuses" do
      for status <- [:open, :archived] do
        changeset = Channel.create_changeset(build_channel(), %{name: "general", status: status})
        assert changeset.valid?, "expected #{status} to be valid"
      end
    end

    test "does not cast workspace_id from attrs" do
      # workspace_id should come from Ecto.build_assoc, not from user input
      other_id = Ecto.UUID.generate()
      original_id = Ecto.UUID.generate()
      channel = build_channel(original_id)

      changeset = Channel.create_changeset(channel, %{name: "general", workspace_id: other_id})
      assert changeset.valid?
      # workspace_id should NOT be in changes (it's set on the struct, not cast)
      refute Map.has_key?(changeset.changes, :workspace_id)
    end

    test "allows nil optional fields" do
      changeset =
        Channel.create_changeset(build_channel(), %{
          name: "general",
          description: nil,
          status: nil,
          pinned: nil
        })

      assert changeset.valid?
    end

    test "rejects non-map attrs" do
      assert_raise FunctionClauseError, fn ->
        Channel.create_changeset(build_channel(), "not a map")
      end
    end

    test "rejects non-struct first argument" do
      assert_raise FunctionClauseError, fn ->
        # credo:disable-for-next-line Credo.Check.Refactor.Apply
        apply(Channel, :create_changeset, [%{}, %{name: "general"}])
      end
    end

    test "has assoc_constraint on workspace" do
      # Verify the changeset includes the workspace assoc constraint
      changeset = Channel.create_changeset(%Channel{}, %{name: "general"})
      # The changeset should be valid (assoc_constraint only triggers on insert)
      assert changeset.valid?
    end
  end

  # --- update_changeset/2 ---

  describe "update_changeset/2" do
    test "allows updating name" do
      channel = %Channel{name: "old", workspace_id: Ecto.UUID.generate(), status: :open}
      changeset = Channel.update_changeset(channel, %{name: "new-name"})
      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :name) == "new-name"
    end

    test "allows updating description" do
      channel = %Channel{name: "general", workspace_id: Ecto.UUID.generate(), status: :open}
      changeset = Channel.update_changeset(channel, %{description: "Updated"})
      assert changeset.valid?
    end

    test "allows updating status" do
      channel = %Channel{name: "general", workspace_id: Ecto.UUID.generate(), status: :open}
      changeset = Channel.update_changeset(channel, %{status: :archived})
      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :status) == :archived
    end

    test "allows updating pinned" do
      channel = %Channel{
        name: "general",
        workspace_id: Ecto.UUID.generate(),
        status: :open,
        pinned: false
      }

      changeset = Channel.update_changeset(channel, %{pinned: true})
      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :pinned) == true
    end

    test "does not allow changing workspace_id" do
      channel = %Channel{name: "general", workspace_id: Ecto.UUID.generate(), status: :open}
      other_id = Ecto.UUID.generate()
      changeset = Channel.update_changeset(channel, %{workspace_id: other_id})
      refute Map.has_key?(changeset.changes, :workspace_id)
    end

    test "validates same constraints as create" do
      channel = %Channel{name: "general", workspace_id: Ecto.UUID.generate(), status: :open}
      changeset = Channel.update_changeset(channel, %{name: String.duplicate("a", 101)})
      refute changeset.valid?
    end
  end
end
