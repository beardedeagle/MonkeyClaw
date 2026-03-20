defmodule MonkeyClaw.Workflows.ConversationTest do
  # Not async: tests mutate Application config and :persistent_term
  # for extension pipeline testing.
  use MonkeyClaw.DataCase

  alias MonkeyClaw.Extensions
  alias MonkeyClaw.TestPlugs
  alias MonkeyClaw.Workflows.Conversation

  import MonkeyClaw.Factory

  setup do
    Extensions.clear_pipelines()

    on_exit(fn ->
      Application.delete_env(:monkey_claw, MonkeyClaw.Extensions)
      Extensions.clear_pipelines()
    end)
  end

  # ──────────────────────────────────────────────
  # Entity Resolution
  # ──────────────────────────────────────────────

  describe "resolve_workspace/1" do
    test "returns workspace with preloaded assistant" do
      assistant = insert_assistant!()
      workspace = insert_workspace!(%{assistant_id: assistant.id})

      assert {:ok, resolved} = Conversation.resolve_workspace(workspace.id)
      assert resolved.id == workspace.id
      assert %MonkeyClaw.Assistants.Assistant{} = resolved.assistant
      assert resolved.assistant.id == assistant.id
    end

    test "returns workspace without assistant when none assigned" do
      workspace = insert_workspace!()

      assert {:ok, resolved} = Conversation.resolve_workspace(workspace.id)
      assert resolved.id == workspace.id
      assert is_nil(resolved.assistant)
    end

    test "returns error for unknown workspace" do
      fake_id = Ecto.UUID.generate()

      assert {:error, {:workspace_not_found, ^fake_id}} =
               Conversation.resolve_workspace(fake_id)
    end
  end

  describe "resolve_channel/3" do
    test "finds existing channel by name" do
      workspace = insert_workspace!()
      channel = insert_channel!(workspace, %{name: "general"})

      assert {:ok, found} = Conversation.resolve_channel(workspace, "general")
      assert found.id == channel.id
      assert found.name == "general"
    end

    test "creates channel when not found and create_channel: true (default)" do
      workspace = insert_workspace!()

      assert {:ok, created} = Conversation.resolve_channel(workspace, "new-channel")
      assert created.name == "new-channel"
      assert created.workspace_id == workspace.id
    end

    test "returns error when not found and create_channel: false" do
      workspace = insert_workspace!()

      assert {:error, {:channel_not_found, "missing"}} =
               Conversation.resolve_channel(workspace, "missing", create_channel: false)
    end

    test "returns existing channel even when create_channel: true" do
      workspace = insert_workspace!()
      channel = insert_channel!(workspace, %{name: "existing"})

      assert {:ok, found} = Conversation.resolve_channel(workspace, "existing")
      assert found.id == channel.id
    end
  end

  # ──────────────────────────────────────────────
  # Session Configuration
  # ──────────────────────────────────────────────

  describe "build_session_config/1" do
    test "builds config with assistant session opts" do
      assistant = insert_assistant!(%{backend: :claude, model: "opus"})
      workspace = insert_workspace!(%{assistant_id: assistant.id})
      workspace = Repo.preload(workspace, :assistant)

      assert {:ok, config} = Conversation.build_session_config(workspace)
      assert config.id == workspace.id
      assert is_map(config.session_opts)
      assert config.session_opts.backend == :claude
      assert config.session_opts.model == "opus"
    end

    test "builds config without assistant" do
      workspace = insert_workspace!()

      assert {:ok, config} = Conversation.build_session_config(workspace)
      assert config.id == workspace.id
      assert config.session_opts == %{}
    end
  end

  # ──────────────────────────────────────────────
  # Extension Hooks
  # ──────────────────────────────────────────────

  describe "run_query_pre/2" do
    test "returns ok with context when no plugs configured" do
      Extensions.compile_pipelines()

      assert {:ok, ctx} = Conversation.run_query_pre("session-1", "Hello")
      assert ctx.event == :query_pre
      assert ctx.data.prompt == "Hello"
      assert ctx.data.session_id == "session-1"
      refute ctx.halted
    end

    test "returns error when halted by plug" do
      Application.put_env(:monkey_claw, MonkeyClaw.Extensions,
        hooks: %{query_pre: [{TestPlugs.Halter, []}]}
      )

      Extensions.compile_pipelines()

      assert {:error, {:halted, ctx}} = Conversation.run_query_pre("session-1", "Hello")
      assert ctx.halted
    end

    test "plugs can enrich context via assigns" do
      Application.put_env(:monkey_claw, MonkeyClaw.Extensions,
        hooks: %{query_pre: [{TestPlugs.Assigner, [processed: true]}]}
      )

      Extensions.compile_pipelines()

      assert {:ok, ctx} = Conversation.run_query_pre("session-1", "Hello")
      assert ctx.assigns.processed == true
    end

    test "global plugs run on query_pre" do
      Application.put_env(:monkey_claw, MonkeyClaw.Extensions,
        global: [{TestPlugs.Counter, key: :global_count}]
      )

      Extensions.compile_pipelines()

      assert {:ok, ctx} = Conversation.run_query_pre("session-1", "Hello")
      assert ctx.assigns.global_count == 1
    end
  end

  describe "run_query_post/3" do
    test "returns ok with context" do
      Extensions.compile_pipelines()

      messages = [%{type: :text, content: "Hi there"}]

      assert {:ok, ctx} = Conversation.run_query_post("session-1", "Hello", messages)
      assert ctx.event == :query_post
      assert ctx.data.messages == messages
      assert ctx.data.prompt == "Hello"
      assert ctx.data.session_id == "session-1"
    end

    test "runs configured plugs" do
      Application.put_env(:monkey_claw, MonkeyClaw.Extensions,
        hooks: %{query_post: [{TestPlugs.Counter, key: :post_count}]}
      )

      Extensions.compile_pipelines()

      assert {:ok, ctx} = Conversation.run_query_post("session-1", "Hello", [])
      assert ctx.assigns.post_count == 1
    end

    test "exceptions in plugs propagate" do
      Application.put_env(:monkey_claw, MonkeyClaw.Extensions,
        hooks: %{query_post: [{TestPlugs.Exploder, []}]}
      )

      Extensions.compile_pipelines()

      assert_raise RuntimeError, "boom", fn ->
        Conversation.run_query_post("session-1", "Hello", [])
      end
    end
  end

  # ──────────────────────────────────────────────
  # Effective Prompt
  # ──────────────────────────────────────────────

  describe "effective_prompt/2" do
    test "uses original prompt when no override in assigns" do
      ctx = Extensions.Context.new!(:query_pre)
      assert Conversation.effective_prompt(ctx, "original") == "original"
    end

    test "uses assigns effective_prompt when present" do
      ctx =
        Extensions.Context.new!(:query_pre)
        |> Extensions.Context.assign(:effective_prompt, "modified")

      assert Conversation.effective_prompt(ctx, "original") == "modified"
    end

    test "ignores empty effective_prompt in assigns" do
      ctx =
        Extensions.Context.new!(:query_pre)
        |> Extensions.Context.assign(:effective_prompt, "")

      assert Conversation.effective_prompt(ctx, "original") == "original"
    end

    test "ignores non-binary effective_prompt in assigns" do
      ctx =
        Extensions.Context.new!(:query_pre)
        |> Extensions.Context.assign(:effective_prompt, 42)

      assert Conversation.effective_prompt(ctx, "original") == "original"
    end
  end

  # ──────────────────────────────────────────────
  # send_message/4 Error Paths
  # ──────────────────────────────────────────────

  describe "send_message/4 error paths" do
    test "returns error for unknown workspace" do
      fake_id = Ecto.UUID.generate()

      assert {:error, {:workspace_not_found, ^fake_id}} =
               Conversation.send_message(fake_id, "general", "Hello")
    end

    test "rejects empty workspace_id" do
      assert_raise FunctionClauseError, fn ->
        Conversation.send_message("", "general", "Hello")
      end
    end

    test "rejects empty channel_name" do
      assert_raise FunctionClauseError, fn ->
        Conversation.send_message("workspace-id", "", "Hello")
      end
    end

    test "rejects empty prompt" do
      assert_raise FunctionClauseError, fn ->
        Conversation.send_message("workspace-id", "general", "")
      end
    end
  end

  # ──────────────────────────────────────────────
  # Ensure Session (structural)
  # ──────────────────────────────────────────────

  describe "ensure_session/1" do
    test "returns error when session cannot be found or started" do
      config = %{id: "nonexistent-#{System.unique_integer([:positive])}", session_opts: %{}}

      # With no real backend, start_session will fail —
      # the exact error depends on the Session GenServer init.
      # We verify it returns an error tuple, not a crash.
      assert {:error, _reason} = Conversation.ensure_session(config)
    end
  end

  # ──────────────────────────────────────────────
  # Ensure Thread (structural)
  # ──────────────────────────────────────────────

  describe "ensure_thread/2" do
    test "returns error when session not found" do
      workspace = insert_workspace!()
      channel = insert_channel!(workspace)

      assert {:error, {:thread_start_failed, {:session_not_found, _}}} =
               Conversation.ensure_thread(workspace.id, channel)
    end
  end
end
