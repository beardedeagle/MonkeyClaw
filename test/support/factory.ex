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
  alias MonkeyClaw.Channels
  alias MonkeyClaw.Experiments
  alias MonkeyClaw.Notifications
  alias MonkeyClaw.Scheduling
  alias MonkeyClaw.Sessions
  alias MonkeyClaw.Skills
  alias MonkeyClaw.UserModeling
  alias MonkeyClaw.Vault
  alias MonkeyClaw.Webhooks
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

  # ──────────────────────────────────────────────
  # Experiment Builders
  # ──────────────────────────────────────────────

  @doc """
  Build a map of valid experiment attributes.

  Defaults to `:code` type with 5 max iterations and a basic
  scoped_files configuration.
  """
  @spec experiment_attrs(Enumerable.t()) :: map()
  def experiment_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        title: "experiment-#{System.unique_integer([:positive])}",
        type: :code,
        max_iterations: 5,
        config: %{
          "scoped_files" => ["lib/example.ex"],
          "optimization_goal" => "Improve performance"
        }
      },
      Map.new(overrides)
    )
  end

  @doc """
  Insert an experiment into the database within a workspace.

  Delegates to `MonkeyClaw.Experiments.create_experiment/2`.
  Raises on validation failure.
  """
  @spec insert_experiment!(MonkeyClaw.Workspaces.Workspace.t(), Enumerable.t()) ::
          MonkeyClaw.Experiments.Experiment.t()
  def insert_experiment!(workspace, overrides \\ %{}) do
    {:ok, experiment} = Experiments.create_experiment(workspace, experiment_attrs(overrides))
    experiment
  end

  # ──────────────────────────────────────────────
  # Skill Builders
  # ──────────────────────────────────────────────

  @doc """
  Build a map of valid skill attributes.

  Generates a unique title with default description and procedure.
  """
  @spec skill_attrs(Enumerable.t()) :: map()
  def skill_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        title: "skill-#{System.unique_integer([:positive])}",
        description: "A reusable procedure for testing",
        procedure: "1. First step\n2. Second step\n3. Third step",
        tags: ["test", "example"]
      },
      Map.new(overrides)
    )
  end

  @doc """
  Insert a skill into the database within a workspace.

  Delegates to `MonkeyClaw.Skills.create_skill/2`.
  Raises on validation failure.
  """
  @spec insert_skill!(MonkeyClaw.Workspaces.Workspace.t(), Enumerable.t()) ::
          MonkeyClaw.Skills.Skill.t()
  def insert_skill!(workspace, overrides \\ %{}) do
    {:ok, skill} = Skills.create_skill(workspace, skill_attrs(overrides))
    skill
  end

  # ──────────────────────────────────────────────
  # Schedule Entry Builders
  # ──────────────────────────────────────────────

  @doc """
  Build a map of valid schedule entry attributes.

  Defaults to `:once` schedule type with `next_run_at` in the future
  and a basic experiment configuration.
  """
  @spec schedule_entry_attrs(Enumerable.t()) :: map()
  def schedule_entry_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        name: "schedule-#{System.unique_integer([:positive])}",
        schedule_type: :once,
        next_run_at: DateTime.add(DateTime.utc_now(), 3600, :second),
        experiment_config: %{
          "title" => "Scheduled experiment",
          "type" => "code",
          "max_iterations" => 3
        }
      },
      Map.new(overrides)
    )
  end

  @doc """
  Insert a schedule entry into the database within a workspace.

  Delegates to `MonkeyClaw.Scheduling.create_schedule_entry/2`.
  Raises on validation failure.
  """
  @spec insert_schedule_entry!(MonkeyClaw.Workspaces.Workspace.t(), Enumerable.t()) ::
          MonkeyClaw.Scheduling.ScheduleEntry.t()
  def insert_schedule_entry!(workspace, overrides \\ %{}) do
    {:ok, entry} = Scheduling.create_schedule_entry(workspace, schedule_entry_attrs(overrides))
    entry
  end

  # ──────────────────────────────────────────────
  # User Profile Builders
  # ──────────────────────────────────────────────

  @doc """
  Build a map of valid user profile attributes.

  Defaults to `:full` privacy level with injection enabled.
  """
  @spec user_profile_attrs(Enumerable.t()) :: map()
  def user_profile_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        privacy_level: :full,
        injection_enabled: true
      },
      Map.new(overrides)
    )
  end

  # ──────────────────────────────────────────────
  # Webhook Builders
  # ──────────────────────────────────────────────

  @doc """
  Build a map of valid webhook endpoint attributes.

  Generates a unique name and defaults to `:generic` source.
  """
  @spec webhook_endpoint_attrs(Enumerable.t()) :: map()
  def webhook_endpoint_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        name: "webhook-#{System.unique_integer([:positive])}",
        source: :generic
      },
      Map.new(overrides)
    )
  end

  @doc """
  Build a map of valid webhook delivery attributes.

  Defaults to `:accepted` status with a test payload hash.
  """
  @spec webhook_delivery_attrs(Enumerable.t()) :: map()
  def webhook_delivery_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        status: :accepted,
        payload_hash: :crypto.hash(:sha256, "test-payload") |> Base.encode16(case: :lower),
        event_type: "test.event",
        remote_ip: "127.0.0.1"
      },
      Map.new(overrides)
    )
  end

  @doc """
  Insert a webhook endpoint into the database within a workspace.

  Delegates to `MonkeyClaw.Webhooks.create_endpoint/2`.
  Raises on validation failure.
  """
  @spec insert_webhook_endpoint!(MonkeyClaw.Workspaces.Workspace.t(), Enumerable.t()) ::
          MonkeyClaw.Webhooks.WebhookEndpoint.t()
  def insert_webhook_endpoint!(workspace, overrides \\ %{}) do
    {:ok, endpoint} = Webhooks.create_endpoint(workspace, webhook_endpoint_attrs(overrides))
    endpoint
  end

  @doc """
  Insert a webhook delivery into the database for an endpoint.

  Delegates to `MonkeyClaw.Webhooks.record_delivery/2`.
  Raises on validation failure.
  """
  @spec insert_webhook_delivery!(MonkeyClaw.Webhooks.WebhookEndpoint.t(), Enumerable.t()) ::
          MonkeyClaw.Webhooks.WebhookDelivery.t()
  def insert_webhook_delivery!(endpoint, overrides \\ %{}) do
    {:ok, delivery} = Webhooks.record_delivery(endpoint, webhook_delivery_attrs(overrides))
    delivery
  end

  # ──────────────────────────────────────────────
  # Channel Config Builders
  # ──────────────────────────────────────────────

  @doc """
  Build a map of valid channel config attributes.

  Generates a unique name and defaults to `:web` adapter type
  (no external config required for testing).
  """
  @spec channel_config_attrs(Enumerable.t()) :: map()
  def channel_config_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        name: "channel-config-#{System.unique_integer([:positive])}",
        adapter_type: :web,
        enabled: true,
        config: %{}
      },
      Map.new(overrides)
    )
  end

  @doc """
  Insert a channel config into the database within a workspace.

  Delegates to `MonkeyClaw.Channels.create_config/2`.
  Raises on validation failure.
  """
  @spec insert_channel_config!(MonkeyClaw.Workspaces.Workspace.t(), Enumerable.t()) ::
          MonkeyClaw.Channels.ChannelConfig.t()
  def insert_channel_config!(workspace, overrides \\ %{}) do
    {:ok, config} = Channels.create_config(workspace, channel_config_attrs(overrides))
    config
  end

  # ──────────────────────────────────────────────
  # Notification Builders
  # ──────────────────────────────────────────────

  @doc """
  Build a map of valid notification attributes.

  Generates a unique title and defaults to `:webhook` category
  with `:info` severity.
  """
  @spec notification_attrs(Enumerable.t()) :: map()
  def notification_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        title: "notification-#{System.unique_integer([:positive])}",
        category: :webhook,
        severity: :info
      },
      Map.new(overrides)
    )
  end

  @doc """
  Build a map of valid notification rule attributes.

  Generates a unique name and defaults to the
  `"monkey_claw.webhook.received"` event pattern.
  """
  @spec notification_rule_attrs(Enumerable.t()) :: map()
  def notification_rule_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        name: "rule-#{System.unique_integer([:positive])}",
        event_pattern: "monkey_claw.webhook.received",
        channel: :in_app,
        min_severity: :info
      },
      Map.new(overrides)
    )
  end

  @doc """
  Insert a notification into the database within a workspace.

  Delegates to `MonkeyClaw.Notifications.create_notification/2`.
  Raises on validation failure.
  """
  @spec insert_notification!(MonkeyClaw.Workspaces.Workspace.t(), Enumerable.t()) ::
          MonkeyClaw.Notifications.Notification.t()
  def insert_notification!(workspace, overrides \\ %{}) do
    {:ok, notification} =
      Notifications.create_notification(workspace, notification_attrs(overrides))

    notification
  end

  @doc """
  Insert a notification rule into the database within a workspace.

  Delegates to `MonkeyClaw.Notifications.create_rule/2`.
  Raises on validation failure.
  """
  @spec insert_notification_rule!(MonkeyClaw.Workspaces.Workspace.t(), Enumerable.t()) ::
          MonkeyClaw.Notifications.NotificationRule.t()
  def insert_notification_rule!(workspace, overrides \\ %{}) do
    {:ok, rule} = Notifications.create_rule(workspace, notification_rule_attrs(overrides))
    rule
  end

  # ──────────────────────────────────────────────
  # Vault Builders
  # ──────────────────────────────────────────────

  @doc """
  Build a map of valid vault secret attributes.

  Generates a unique name with a test value. The `:value` field
  is the plaintext that `Vault.create_secret/2` encrypts.
  """
  @spec vault_secret_attrs(Enumerable.t()) :: map()
  def vault_secret_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        name: "secret-#{System.unique_integer([:positive])}",
        value: "test-secret-value-#{System.unique_integer([:positive])}",
        description: "A test secret"
      },
      Map.new(overrides)
    )
  end

  @doc """
  Build a map of valid vault token attributes.

  Generates test OAuth token values.
  """
  @spec vault_token_attrs(Enumerable.t()) :: map()
  def vault_token_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        provider: "anthropic",
        access_token: "test-access-token-#{System.unique_integer([:positive])}",
        token_type: "Bearer"
      },
      Map.new(overrides)
    )
  end

  @doc """
  Insert a vault secret into the database within a workspace.

  Delegates to `MonkeyClaw.Vault.create_secret/2`.
  Raises on validation failure.
  """
  @spec insert_vault_secret!(MonkeyClaw.Workspaces.Workspace.t(), Enumerable.t()) ::
          MonkeyClaw.Vault.Secret.t()
  def insert_vault_secret!(workspace, overrides \\ %{}) do
    {:ok, secret} = Vault.create_secret(workspace, vault_secret_attrs(overrides))
    secret
  end

  @doc """
  Insert a vault token into the database within a workspace.

  Delegates to `MonkeyClaw.Vault.store_token/2`.
  Raises on validation failure.
  """
  @spec insert_vault_token!(MonkeyClaw.Workspaces.Workspace.t(), Enumerable.t()) ::
          MonkeyClaw.Vault.Token.t()
  def insert_vault_token!(workspace, overrides \\ %{}) do
    {:ok, token} = Vault.store_token(workspace, vault_token_attrs(overrides))
    token
  end

  # ──────────────────────────────────────────────
  # User Profile Builders
  # ──────────────────────────────────────────────

  @doc """
  Insert a user profile into the database within a workspace.

  Delegates to `MonkeyClaw.UserModeling.ensure_profile/1` for creation,
  then updates with overrides if provided. Each workspace can have at
  most one profile (unique constraint).
  """
  @spec insert_user_profile!(MonkeyClaw.Workspaces.Workspace.t(), Enumerable.t()) ::
          MonkeyClaw.UserModeling.UserProfile.t()
  def insert_user_profile!(workspace, overrides \\ %{}) do
    {:ok, profile} = UserModeling.ensure_profile(workspace)
    attrs = Map.new(overrides)

    if map_size(attrs) > 0 do
      {:ok, updated} = UserModeling.update_profile(profile, attrs)
      updated
    else
      profile
    end
  end
end
