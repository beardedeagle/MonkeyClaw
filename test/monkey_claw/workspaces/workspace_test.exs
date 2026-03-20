defmodule MonkeyClaw.Workspaces.WorkspaceTest do
  use ExUnit.Case, async: true

  alias MonkeyClaw.Workspaces.Workspace

  # Local helper — avoids pulling in DataCase for pure changeset tests
  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  # --- create_changeset/2 ---

  describe "create_changeset/2" do
    test "valid with required fields only" do
      changeset = Workspace.create_changeset(%Workspace{}, %{name: "My Project"})
      assert changeset.valid?
    end

    test "valid with all fields" do
      attrs = %{
        name: "Full Workspace",
        description: "A complete workspace",
        status: :archived,
        assistant_id: Ecto.UUID.generate()
      }

      changeset = Workspace.create_changeset(%Workspace{}, attrs)
      assert changeset.valid?
    end

    test "defaults status to :active" do
      changeset = Workspace.create_changeset(%Workspace{}, %{name: "Dev"})
      assert changeset.valid?
      # Status default comes from schema, not changeset, so it won't appear in changes
      refute Map.has_key?(changeset.changes, :status)
    end

    test "requires name" do
      changeset = Workspace.create_changeset(%Workspace{}, %{})
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).name
    end

    test "validates name min length" do
      changeset = Workspace.create_changeset(%Workspace{}, %{name: ""})
      refute changeset.valid?
    end

    test "validates name max length" do
      attrs = %{name: String.duplicate("a", 101)}
      changeset = Workspace.create_changeset(%Workspace{}, attrs)
      refute changeset.valid?
    end

    test "accepts name at max length" do
      attrs = %{name: String.duplicate("a", 100)}
      changeset = Workspace.create_changeset(%Workspace{}, attrs)
      assert changeset.valid?
    end

    test "validates description max length" do
      attrs = %{name: "Dev", description: String.duplicate("a", 501)}
      changeset = Workspace.create_changeset(%Workspace{}, attrs)
      refute changeset.valid?
    end

    test "accepts description at max length" do
      attrs = %{name: "Dev", description: String.duplicate("a", 500)}
      changeset = Workspace.create_changeset(%Workspace{}, attrs)
      assert changeset.valid?
    end

    test "rejects invalid status" do
      attrs = %{name: "Dev", status: :invalid}
      changeset = Workspace.create_changeset(%Workspace{}, attrs)
      refute changeset.valid?
    end

    test "accepts all valid statuses" do
      for status <- [:active, :archived] do
        changeset = Workspace.create_changeset(%Workspace{}, %{name: "Dev", status: status})
        assert changeset.valid?, "expected #{status} to be valid"
      end
    end

    test "allows nil optional fields" do
      changeset =
        Workspace.create_changeset(%Workspace{}, %{
          name: "Dev",
          description: nil,
          assistant_id: nil,
          status: nil
        })

      assert changeset.valid?
    end

    test "rejects non-map attrs" do
      assert_raise FunctionClauseError, fn ->
        Workspace.create_changeset(%Workspace{}, "not a map")
      end
    end

    test "rejects non-struct first argument" do
      assert_raise FunctionClauseError, fn ->
        # credo:disable-for-next-line Credo.Check.Refactor.Apply
        apply(Workspace, :create_changeset, [%{}, %{name: "Dev"}])
      end
    end
  end

  # --- update_changeset/2 ---

  describe "update_changeset/2" do
    test "allows updating name" do
      workspace = %Workspace{name: "Old", status: :active}
      changeset = Workspace.update_changeset(workspace, %{name: "New Name"})
      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :name) == "New Name"
    end

    test "allows updating description" do
      workspace = %Workspace{name: "Dev", status: :active}
      changeset = Workspace.update_changeset(workspace, %{description: "Updated desc"})
      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :description) == "Updated desc"
    end

    test "allows updating status" do
      workspace = %Workspace{name: "Dev", status: :active}
      changeset = Workspace.update_changeset(workspace, %{status: :archived})
      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :status) == :archived
    end

    test "allows updating assistant_id" do
      workspace = %Workspace{name: "Dev", status: :active}
      new_id = Ecto.UUID.generate()
      changeset = Workspace.update_changeset(workspace, %{assistant_id: new_id})
      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :assistant_id) == new_id
    end

    test "allows clearing assistant_id" do
      workspace = %Workspace{name: "Dev", status: :active, assistant_id: Ecto.UUID.generate()}
      changeset = Workspace.update_changeset(workspace, %{assistant_id: nil})
      assert changeset.valid?
    end

    test "validates same constraints as create" do
      workspace = %Workspace{name: "Dev", status: :active}
      changeset = Workspace.update_changeset(workspace, %{name: String.duplicate("a", 101)})
      refute changeset.valid?
    end
  end
end
