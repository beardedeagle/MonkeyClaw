defmodule MonkeyClaw.WorkspacesTest do
  use MonkeyClaw.DataCase

  alias MonkeyClaw.Assistants
  alias MonkeyClaw.Workspaces
  alias MonkeyClaw.Workspaces.{Channel, Workspace}

  import MonkeyClaw.Factory

  # ──────────────────────────────────────────────
  # Workspace CRUD
  # ──────────────────────────────────────────────

  # --- create_workspace/1 ---

  describe "create_workspace/1" do
    test "creates with required attrs" do
      assert {:ok, %Workspace{} = workspace} = Workspaces.create_workspace(%{name: "Dev Project"})
      assert workspace.name == "Dev Project"
      assert workspace.status == :active
      assert workspace.assistant_id == nil
      assert workspace.id != nil
    end

    test "creates with all fields" do
      assistant = insert_assistant!()

      attrs = %{
        name: "Full Workspace",
        description: "A complete workspace",
        status: :active,
        assistant_id: assistant.id
      }

      assert {:ok, %Workspace{} = workspace} = Workspaces.create_workspace(attrs)
      assert workspace.name == "Full Workspace"
      assert workspace.description == "A complete workspace"
      assert workspace.status == :active
      assert workspace.assistant_id == assistant.id
    end

    test "fails without name" do
      assert {:error, changeset} = Workspaces.create_workspace(%{})
      assert "can't be blank" in errors_on(changeset).name
    end

    test "fails with duplicate name" do
      workspace = insert_workspace!()
      assert {:error, changeset} = Workspaces.create_workspace(%{name: workspace.name})
      assert "has already been taken" in errors_on(changeset).name
    end

    test "fails with nonexistent assistant_id" do
      attrs = %{name: "Dev Project", assistant_id: Ecto.UUID.generate()}
      assert {:error, changeset} = Workspaces.create_workspace(attrs)
      assert "does not exist" in errors_on(changeset).assistant_id
    end

    test "generates binary_id" do
      workspace = insert_workspace!()
      assert is_binary(workspace.id)
      assert byte_size(workspace.id) == 36
    end

    test "sets timestamps" do
      workspace = insert_workspace!()
      assert %DateTime{} = workspace.inserted_at
      assert %DateTime{} = workspace.updated_at
    end

    test "creates with archived status" do
      attrs = %{name: "Dev Project", status: :archived}
      assert {:ok, workspace} = Workspaces.create_workspace(attrs)
      assert workspace.status == :archived
    end
  end

  # --- get_workspace/1 ---

  describe "get_workspace/1" do
    test "returns workspace by ID" do
      created = insert_workspace!()
      assert {:ok, found} = Workspaces.get_workspace(created.id)
      assert found.id == created.id
      assert found.name == created.name
    end

    test "returns error for nonexistent ID" do
      assert {:error, :not_found} = Workspaces.get_workspace(Ecto.UUID.generate())
    end

    test "rejects empty string" do
      assert_raise FunctionClauseError, fn ->
        Workspaces.get_workspace("")
      end
    end
  end

  # --- get_workspace!/1 ---

  describe "get_workspace!/1" do
    test "returns workspace by ID" do
      created = insert_workspace!()
      found = Workspaces.get_workspace!(created.id)
      assert found.id == created.id
    end

    test "raises for nonexistent ID" do
      assert_raise Ecto.NoResultsError, fn ->
        Workspaces.get_workspace!(Ecto.UUID.generate())
      end
    end
  end

  # --- list_workspaces/0 ---

  describe "list_workspaces/0" do
    test "returns empty list when no workspaces" do
      assert [] = Workspaces.list_workspaces()
    end

    test "returns all workspaces ordered by name" do
      insert_workspace!(%{name: "Charlie"})
      insert_workspace!(%{name: "Alpha"})
      insert_workspace!(%{name: "Bravo"})

      workspaces = Workspaces.list_workspaces()
      assert length(workspaces) == 3
      assert [%{name: "Alpha"}, %{name: "Bravo"}, %{name: "Charlie"}] = workspaces
    end
  end

  # --- update_workspace/2 ---

  describe "update_workspace/2" do
    test "updates name" do
      workspace = insert_workspace!()
      assert {:ok, updated} = Workspaces.update_workspace(workspace, %{name: "New Name"})
      assert updated.name == "New Name"
    end

    test "updates description" do
      workspace = insert_workspace!()
      assert {:ok, updated} = Workspaces.update_workspace(workspace, %{description: "Desc"})
      assert updated.description == "Desc"
    end

    test "updates status" do
      workspace = insert_workspace!()
      assert {:ok, updated} = Workspaces.update_workspace(workspace, %{status: :archived})
      assert updated.status == :archived
    end

    test "updates assistant_id" do
      workspace = insert_workspace!()
      assistant = insert_assistant!()

      assert {:ok, updated} =
               Workspaces.update_workspace(workspace, %{assistant_id: assistant.id})

      assert updated.assistant_id == assistant.id
    end

    test "clears assistant_id" do
      assistant = insert_assistant!()
      workspace = insert_workspace!(%{name: "With Assistant", assistant_id: assistant.id})
      assert {:ok, updated} = Workspaces.update_workspace(workspace, %{assistant_id: nil})
      assert updated.assistant_id == nil
    end

    test "fails with invalid attrs" do
      workspace = insert_workspace!()
      assert {:error, _} = Workspaces.update_workspace(workspace, %{name: ""})
    end

    test "fails with duplicate name" do
      insert_workspace!(%{name: "First"})
      second = insert_workspace!(%{name: "Second"})
      assert {:error, changeset} = Workspaces.update_workspace(second, %{name: "First"})
      assert "has already been taken" in errors_on(changeset).name
    end

    test "fails with nonexistent assistant_id" do
      workspace = insert_workspace!()

      assert {:error, changeset} =
               Workspaces.update_workspace(workspace, %{assistant_id: Ecto.UUID.generate()})

      assert "does not exist" in errors_on(changeset).assistant_id
    end
  end

  # --- delete_workspace/1 ---

  describe "delete_workspace/1" do
    test "deletes the workspace" do
      workspace = insert_workspace!()
      assert {:ok, _} = Workspaces.delete_workspace(workspace)
      assert {:error, :not_found} = Workspaces.get_workspace(workspace.id)
    end

    test "cascades deletion to channels" do
      workspace = insert_workspace!()
      {:ok, channel} = Workspaces.create_channel(workspace, %{name: "general"})

      assert {:ok, _} = Workspaces.delete_workspace(workspace)
      assert {:error, :not_found} = Workspaces.get_channel(channel.id)
    end
  end

  # ──────────────────────────────────────────────
  # Channel CRUD
  # ──────────────────────────────────────────────

  # --- create_channel/2 ---

  describe "create_channel/2" do
    test "creates with required attrs" do
      workspace = insert_workspace!()

      assert {:ok, %Channel{} = channel} =
               Workspaces.create_channel(workspace, %{name: "general"})

      assert channel.name == "general"
      assert channel.workspace_id == workspace.id
      assert channel.status == :open
      assert channel.pinned == false
      assert channel.id != nil
    end

    test "creates with all fields" do
      workspace = insert_workspace!()

      attrs = %{
        name: "development",
        description: "Dev discussions",
        status: :open,
        pinned: true
      }

      assert {:ok, channel} = Workspaces.create_channel(workspace, attrs)
      assert channel.name == "development"
      assert channel.description == "Dev discussions"
      assert channel.pinned == true
    end

    test "fails without name" do
      workspace = insert_workspace!()
      assert {:error, changeset} = Workspaces.create_channel(workspace, %{})
      assert "can't be blank" in errors_on(changeset).name
    end

    test "fails with duplicate name in same workspace" do
      workspace = insert_workspace!()
      {:ok, _} = Workspaces.create_channel(workspace, %{name: "general"})
      assert {:error, changeset} = Workspaces.create_channel(workspace, %{name: "general"})
      assert "has already been taken" in errors_on(changeset).workspace_id
    end

    test "allows same channel name in different workspaces" do
      ws1 = insert_workspace!(%{name: "Workspace 1"})
      ws2 = insert_workspace!(%{name: "Workspace 2"})

      assert {:ok, _} = Workspaces.create_channel(ws1, %{name: "general"})
      assert {:ok, _} = Workspaces.create_channel(ws2, %{name: "general"})
    end

    test "generates binary_id" do
      workspace = insert_workspace!()
      {:ok, channel} = Workspaces.create_channel(workspace, %{name: "general"})
      assert is_binary(channel.id)
      assert byte_size(channel.id) == 36
    end

    test "sets timestamps" do
      workspace = insert_workspace!()
      {:ok, channel} = Workspaces.create_channel(workspace, %{name: "general"})
      assert %DateTime{} = channel.inserted_at
      assert %DateTime{} = channel.updated_at
    end

    test "creates with archived status" do
      workspace = insert_workspace!()

      assert {:ok, channel} =
               Workspaces.create_channel(workspace, %{name: "old", status: :archived})

      assert channel.status == :archived
    end
  end

  # --- get_channel/1 ---

  describe "get_channel/1" do
    test "returns channel by ID" do
      workspace = insert_workspace!()
      {:ok, created} = Workspaces.create_channel(workspace, %{name: "general"})
      assert {:ok, found} = Workspaces.get_channel(created.id)
      assert found.id == created.id
      assert found.name == created.name
    end

    test "returns error for nonexistent ID" do
      assert {:error, :not_found} = Workspaces.get_channel(Ecto.UUID.generate())
    end

    test "rejects empty string" do
      assert_raise FunctionClauseError, fn ->
        Workspaces.get_channel("")
      end
    end
  end

  # --- get_channel!/1 ---

  describe "get_channel!/1" do
    test "returns channel by ID" do
      workspace = insert_workspace!()
      {:ok, created} = Workspaces.create_channel(workspace, %{name: "general"})
      found = Workspaces.get_channel!(created.id)
      assert found.id == created.id
    end

    test "raises for nonexistent ID" do
      assert_raise Ecto.NoResultsError, fn ->
        Workspaces.get_channel!(Ecto.UUID.generate())
      end
    end
  end

  # --- list_channels/1 ---

  describe "list_channels/1" do
    test "returns empty list for empty workspace" do
      workspace = insert_workspace!()
      assert [] = Workspaces.list_channels(workspace)
    end

    test "returns channels ordered by pinned desc then name asc" do
      workspace = insert_workspace!()
      {:ok, _} = Workspaces.create_channel(workspace, %{name: "charlie"})
      {:ok, _} = Workspaces.create_channel(workspace, %{name: "alpha", pinned: true})
      {:ok, _} = Workspaces.create_channel(workspace, %{name: "bravo"})

      channels = Workspaces.list_channels(workspace)
      assert length(channels) == 3
      # Pinned first, then alphabetical
      assert [%{name: "alpha", pinned: true}, %{name: "bravo"}, %{name: "charlie"}] = channels
    end

    test "accepts workspace_id string" do
      workspace = insert_workspace!()
      {:ok, _} = Workspaces.create_channel(workspace, %{name: "general"})

      channels = Workspaces.list_channels(workspace.id)
      assert length(channels) == 1
    end

    test "does not return channels from other workspaces" do
      ws1 = insert_workspace!(%{name: "Workspace 1"})
      ws2 = insert_workspace!(%{name: "Workspace 2"})

      {:ok, _} = Workspaces.create_channel(ws1, %{name: "ws1-channel"})
      {:ok, _} = Workspaces.create_channel(ws2, %{name: "ws2-channel"})

      channels = Workspaces.list_channels(ws1)
      assert length(channels) == 1
      assert [%{name: "ws1-channel"}] = channels
    end
  end

  # --- update_channel/2 ---

  describe "update_channel/2" do
    test "updates name" do
      workspace = insert_workspace!()
      {:ok, channel} = Workspaces.create_channel(workspace, %{name: "old"})
      assert {:ok, updated} = Workspaces.update_channel(channel, %{name: "new"})
      assert updated.name == "new"
    end

    test "updates description" do
      workspace = insert_workspace!()
      {:ok, channel} = Workspaces.create_channel(workspace, %{name: "general"})
      assert {:ok, updated} = Workspaces.update_channel(channel, %{description: "Updated"})
      assert updated.description == "Updated"
    end

    test "updates status" do
      workspace = insert_workspace!()
      {:ok, channel} = Workspaces.create_channel(workspace, %{name: "general"})
      assert {:ok, updated} = Workspaces.update_channel(channel, %{status: :archived})
      assert updated.status == :archived
    end

    test "updates pinned" do
      workspace = insert_workspace!()
      {:ok, channel} = Workspaces.create_channel(workspace, %{name: "general"})
      assert {:ok, updated} = Workspaces.update_channel(channel, %{pinned: true})
      assert updated.pinned == true
    end

    test "fails with invalid attrs" do
      workspace = insert_workspace!()
      {:ok, channel} = Workspaces.create_channel(workspace, %{name: "general"})
      assert {:error, _} = Workspaces.update_channel(channel, %{name: ""})
    end

    test "fails with duplicate name in same workspace" do
      workspace = insert_workspace!()
      {:ok, _} = Workspaces.create_channel(workspace, %{name: "first"})
      {:ok, second} = Workspaces.create_channel(workspace, %{name: "second"})
      assert {:error, changeset} = Workspaces.update_channel(second, %{name: "first"})
      assert "has already been taken" in errors_on(changeset).workspace_id
    end
  end

  # --- delete_channel/1 ---

  describe "delete_channel/1" do
    test "deletes the channel" do
      workspace = insert_workspace!()
      {:ok, channel} = Workspaces.create_channel(workspace, %{name: "general"})
      assert {:ok, _} = Workspaces.delete_channel(channel)
      assert {:error, :not_found} = Workspaces.get_channel(channel.id)
    end

    test "does not delete the workspace" do
      workspace = insert_workspace!()
      {:ok, channel} = Workspaces.create_channel(workspace, %{name: "general"})
      {:ok, _} = Workspaces.delete_channel(channel)
      assert {:ok, _} = Workspaces.get_workspace(workspace.id)
    end
  end

  # ──────────────────────────────────────────────
  # BeamAgent Integration
  # ──────────────────────────────────────────────

  # --- to_session_config/1 ---

  describe "to_session_config/1" do
    test "renders workspace without assistant" do
      workspace = insert_workspace!()
      config = Workspaces.to_session_config(workspace)

      assert config.id == workspace.id
      assert config.session_opts == %{}
    end

    test "renders workspace with assistant" do
      assistant = insert_assistant!()

      workspace =
        insert_workspace!(%{
          name: "With Assistant",
          assistant_id: assistant.id
        })

      config = Workspaces.to_session_config(workspace)

      assert config.id == workspace.id
      assert config.session_opts.backend == :claude
    end

    test "renders workspace with full assistant" do
      {:ok, assistant} =
        Assistants.create_assistant(%{
          name: "Full Assistant",
          backend: :claude,
          model: "opus",
          system_prompt: "You are helpful.",
          permission_mode: :default
        })

      workspace = insert_workspace!(%{name: "Full WS", assistant_id: assistant.id})
      config = Workspaces.to_session_config(workspace)

      assert config.session_opts.backend == :claude
      assert config.session_opts.model == "opus"
      assert config.session_opts.system_prompt == "You are helpful."
      assert config.session_opts.permission_mode == :default
    end

    test "handles already-preloaded assistant" do
      assistant = insert_assistant!()
      workspace = insert_workspace!(%{name: "Preloaded", assistant_id: assistant.id})
      workspace = Repo.preload(workspace, :assistant)

      # Should not fail on double preload
      config = Workspaces.to_session_config(workspace)
      assert config.session_opts.backend == :claude
    end

    test "rejects non-Workspace struct" do
      assert_raise FunctionClauseError, fn ->
        # credo:disable-for-next-line Credo.Check.Refactor.Apply
        apply(Workspaces, :to_session_config, [%{id: "test"}])
      end
    end
  end

  # --- to_thread_config/1 ---

  describe "to_thread_config/1" do
    test "renders channel as thread config" do
      workspace = insert_workspace!()
      {:ok, channel} = Workspaces.create_channel(workspace, %{name: "general"})

      thread_config = Workspaces.to_thread_config(channel)
      assert thread_config == %{name: "general"}
    end

    test "rejects non-Channel struct" do
      assert_raise FunctionClauseError, fn ->
        # credo:disable-for-next-line Credo.Check.Refactor.Apply
        apply(Workspaces, :to_thread_config, [%{name: "test"}])
      end
    end
  end

  # ──────────────────────────────────────────────
  # Assistant Deletion Behavior
  # ──────────────────────────────────────────────

  describe "assistant deletion nilifies workspace reference" do
    test "workspace assistant_id becomes nil when assistant is deleted" do
      assistant = insert_assistant!()
      workspace = insert_workspace!(%{name: "Linked WS", assistant_id: assistant.id})
      assert workspace.assistant_id == assistant.id

      {:ok, _} = Assistants.delete_assistant(assistant)

      {:ok, reloaded} = Workspaces.get_workspace(workspace.id)
      assert reloaded.assistant_id == nil
    end
  end
end
