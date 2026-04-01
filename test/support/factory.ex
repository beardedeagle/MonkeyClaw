defmodule MonkeyClaw.Factory do
  @moduledoc """
  Test data builders for MonkeyClaw domain entities.

  Provides attribute builders (`*_attrs`) for pure tests and
  insert helpers (`insert_*!`) for integration tests. All insert
  helpers delegate to the public context module APIs — no raw
  `Repo.insert!` calls — so factory-created entities pass
  through the same validation pipeline as production code.

  Names are auto-generated with unique integers to avoid
  constraint violations in concurrent test runs.

  ## Usage

      # In DataCase tests:
      import MonkeyClaw.Factory

      assistant = insert_assistant!()
      workspace = insert_workspace!(%{assistant_id: assistant.id})
      channel = insert_channel!(workspace, %{name: "general"})

      # For pure changeset tests (no DB):
      attrs = assistant_attrs(%{backend: :gemini})
  """

  alias MonkeyClaw.Assistants
  alias MonkeyClaw.Sessions
  alias MonkeyClaw.Workspaces

  # ──────────────────────────────────────────────
  # Attribute Builders (pure, no DB access)
  # ──────────────────────────────────────────────

  @doc """
  Build a map of valid assistant attributes.

  Generates a unique name and defaults to `:claude` backend.
  """
  @spec assistant_attrs(Enumerable.t()) :: map()
  def assistant_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        name: "assistant-#{System.unique_integer([:positive])}",
        backend: :claude
      },
      Map.new(overrides)
    )
  end

  @doc """
  Build a map of valid workspace attributes.

  Generates a unique name.
  """
  @spec workspace_attrs(Enumerable.t()) :: map()
  def workspace_attrs(overrides \\ %{}) do
    Map.merge(
      %{name: "workspace-#{System.unique_integer([:positive])}"},
      Map.new(overrides)
    )
  end

  @doc """
  Build a map of valid channel attributes.

  Generates a unique name.
  """
  @spec channel_attrs(Enumerable.t()) :: map()
  def channel_attrs(overrides \\ %{}) do
    Map.merge(
      %{name: "channel-#{System.unique_integer([:positive])}"},
      Map.new(overrides)
    )
  end

  # ──────────────────────────────────────────────
  # Insert Helpers (require DB / DataCase)
  # ──────────────────────────────────────────────

  @doc """
  Insert an assistant into the database.

  Delegates to `MonkeyClaw.Assistants.create_assistant/1`.
  Raises on validation failure.
  """
  @spec insert_assistant!(Enumerable.t()) :: MonkeyClaw.Assistants.Assistant.t()
  def insert_assistant!(overrides \\ %{}) do
    {:ok, assistant} =
      overrides
      |> assistant_attrs()
      |> Assistants.create_assistant()

    assistant
  end

  @doc """
  Insert a workspace into the database.

  Delegates to `MonkeyClaw.Workspaces.create_workspace/1`.
  Raises on validation failure.
  """
  @spec insert_workspace!(Enumerable.t()) :: MonkeyClaw.Workspaces.Workspace.t()
  def insert_workspace!(overrides \\ %{}) do
    {:ok, workspace} =
      overrides
      |> workspace_attrs()
      |> Workspaces.create_workspace()

    workspace
  end

  @doc """
  Insert a channel into the database within a workspace.

  Delegates to `MonkeyClaw.Workspaces.create_channel/2`.
  Raises on validation failure.
  """
  @spec insert_channel!(MonkeyClaw.Workspaces.Workspace.t(), Enumerable.t()) ::
          MonkeyClaw.Workspaces.Channel.t()
  def insert_channel!(workspace, overrides \\ %{}) do
    {:ok, channel} = Workspaces.create_channel(workspace, channel_attrs(overrides))
    channel
  end

  # ──────────────────────────────────────────────
  # Session History Builders
  # ──────────────────────────────────────────────

  @doc """
  Build a map of valid session attributes.
  """
  @spec session_attrs(Enumerable.t()) :: map()
  def session_attrs(overrides \\ %{}) do
    Map.merge(%{model: "claude-sonnet-4-6"}, Map.new(overrides))
  end

  @doc """
  Build a map of valid message attributes.

  Defaults to `:user` role with unique content.
  """
  @spec message_attrs(Enumerable.t()) :: map()
  def message_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        role: :user,
        content: "message-#{System.unique_integer([:positive])}"
      },
      Map.new(overrides)
    )
  end

  @doc """
  Insert a session into the database within a workspace.

  Delegates to `MonkeyClaw.Sessions.create_session/2`.
  Raises on validation failure.
  """
  @spec insert_session!(MonkeyClaw.Workspaces.Workspace.t(), Enumerable.t()) ::
          MonkeyClaw.Sessions.Session.t()
  def insert_session!(workspace, overrides \\ %{}) do
    {:ok, session} = Sessions.create_session(workspace, session_attrs(overrides))
    session
  end

  @doc """
  Record a message within a session.

  Delegates to `MonkeyClaw.Sessions.record_message/2`.
  Raises on validation failure. Sequence is auto-assigned.
  """
  @spec insert_message!(MonkeyClaw.Sessions.Session.t(), Enumerable.t()) ::
          MonkeyClaw.Sessions.Message.t()
  def insert_message!(session, overrides \\ %{}) do
    {:ok, message} = Sessions.record_message(session, message_attrs(overrides))
    message
  end
end
