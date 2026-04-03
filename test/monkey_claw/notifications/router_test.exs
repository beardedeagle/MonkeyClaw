defmodule MonkeyClaw.Notifications.RouterTest do
  use MonkeyClaw.DataCase

  import MonkeyClaw.Factory

  alias MonkeyClaw.Notifications
  alias MonkeyClaw.Notifications.Router, as: NotificationRouter

  setup do
    # Router is disabled in test.exs (:start_notification_router false).
    # Start a test-controlled instance with a long cache refresh interval
    # so it does not auto-refresh during tests. Tests trigger refresh explicitly.
    start_supervised!({NotificationRouter, [cache_refresh_ms: 999_999_999]})
    :ok
  end

  # ──────────────────────────────────────────────
  # Full pipeline: telemetry → notification
  # ──────────────────────────────────────────────

  describe "telemetry event → notification creation" do
    test "creates notification when rule matches telemetry event" do
      workspace = insert_workspace!()
      endpoint = insert_webhook_endpoint!(workspace)

      insert_notification_rule!(workspace, %{
        event_pattern: "monkey_claw.webhook.received",
        channel: :in_app,
        min_severity: :info
      })

      :ok = NotificationRouter.refresh_cache()

      # Subscribe to PubSub to verify in-app delivery
      :ok = Notifications.subscribe(workspace.id)

      # Fire telemetry event
      :telemetry.execute(
        [:monkey_claw, :webhook, :received],
        %{},
        %{endpoint_id: endpoint.id, source: :github, event_type: "push"}
      )

      # Synchronize: the telemetry handler casts to the GenServer.
      # A synchronous call ensures the cast was processed first.
      _ = :sys.get_state(NotificationRouter)

      # Verify notification was created in DB
      notifications = Notifications.list_notifications(workspace.id)
      assert length(notifications) == 1
      notification = hd(notifications)
      assert notification.title =~ "push"
      assert notification.category == :webhook

      # Verify PubSub delivery
      assert_receive {:notification_created, received}, 1_000
      assert received.id == notification.id
    end

    test "does not create notification when no rule exists" do
      workspace = insert_workspace!()
      endpoint = insert_webhook_endpoint!(workspace)

      # No rules — refresh cache with empty rules
      :ok = NotificationRouter.refresh_cache()

      :telemetry.execute(
        [:monkey_claw, :webhook, :received],
        %{},
        %{endpoint_id: endpoint.id, source: :generic, event_type: "test"}
      )

      _ = :sys.get_state(NotificationRouter)

      assert Notifications.list_notifications(workspace.id) == []
    end

    test "does not create notification when severity below threshold" do
      workspace = insert_workspace!()
      endpoint = insert_webhook_endpoint!(workspace)

      # Rule requires :error severity — webhook.received is :info
      insert_notification_rule!(workspace, %{
        event_pattern: "monkey_claw.webhook.received",
        min_severity: :error
      })

      :ok = NotificationRouter.refresh_cache()

      :telemetry.execute(
        [:monkey_claw, :webhook, :received],
        %{},
        %{endpoint_id: endpoint.id, source: :generic, event_type: "test"}
      )

      _ = :sys.get_state(NotificationRouter)

      assert Notifications.list_notifications(workspace.id) == []
    end

    test "disabled rule does not fire" do
      workspace = insert_workspace!()
      endpoint = insert_webhook_endpoint!(workspace)

      rule =
        insert_notification_rule!(workspace, %{
          event_pattern: "monkey_claw.webhook.received"
        })

      {:ok, _} = Notifications.disable_rule(rule)
      :ok = NotificationRouter.refresh_cache()

      :telemetry.execute(
        [:monkey_claw, :webhook, :received],
        %{},
        %{endpoint_id: endpoint.id, source: :generic, event_type: "test"}
      )

      _ = :sys.get_state(NotificationRouter)

      assert Notifications.list_notifications(workspace.id) == []
    end
  end

  # ──────────────────────────────────────────────
  # Agent bridge events (session_id = workspace_id)
  # ──────────────────────────────────────────────

  describe "agent bridge session exception" do
    test "creates error notification from session exception event" do
      workspace = insert_workspace!()

      insert_notification_rule!(workspace, %{
        event_pattern: "monkey_claw.agent_bridge.session.exception",
        channel: :in_app,
        min_severity: :info
      })

      :ok = NotificationRouter.refresh_cache()

      :telemetry.execute(
        [:monkey_claw, :agent_bridge, :session, :exception],
        %{},
        %{session_id: workspace.id, kind: :error, reason: :timeout}
      )

      _ = :sys.get_state(NotificationRouter)

      notifications = Notifications.list_notifications(workspace.id)
      assert length(notifications) == 1
      assert hd(notifications).severity == :error
      assert hd(notifications).category == :session
    end
  end

  # ──────────────────────────────────────────────
  # Workspace scoping
  # ──────────────────────────────────────────────

  describe "workspace scoping" do
    test "rule in workspace A does not fire for workspace B events" do
      w1 = insert_workspace!()
      w2 = insert_workspace!()
      endpoint_w2 = insert_webhook_endpoint!(w2)

      # Rule only in w1
      insert_notification_rule!(w1, %{
        event_pattern: "monkey_claw.webhook.received"
      })

      :ok = NotificationRouter.refresh_cache()

      # Event for w2's endpoint
      :telemetry.execute(
        [:monkey_claw, :webhook, :received],
        %{},
        %{endpoint_id: endpoint_w2.id, source: :generic, event_type: "test"}
      )

      _ = :sys.get_state(NotificationRouter)

      assert Notifications.list_notifications(w1.id) == []
      assert Notifications.list_notifications(w2.id) == []
    end
  end

  # ──────────────────────────────────────────────
  # Email delivery
  # ──────────────────────────────────────────────

  describe "email delivery" do
    setup do
      # Configure email for tests
      original = Application.get_env(:monkey_claw, Notifications.Email)

      Application.put_env(:monkey_claw, Notifications.Email,
        from: {"MonkeyClaw", "test@monkeyclaw.dev"},
        to: "user@example.com"
      )

      on_exit(fn ->
        if original do
          Application.put_env(:monkey_claw, Notifications.Email, original)
        else
          Application.delete_env(:monkey_claw, Notifications.Email)
        end
      end)

      :ok
    end

    test "creates notification when channel is :email" do
      workspace = insert_workspace!()
      endpoint = insert_webhook_endpoint!(workspace)

      insert_notification_rule!(workspace, %{
        event_pattern: "monkey_claw.webhook.received",
        channel: :email,
        min_severity: :info
      })

      :ok = NotificationRouter.refresh_cache()

      :telemetry.execute(
        [:monkey_claw, :webhook, :received],
        %{},
        %{endpoint_id: endpoint.id, source: :generic, event_type: "push"}
      )

      _ = :sys.get_state(NotificationRouter)

      # Verify notification was created in DB
      notifications = Notifications.list_notifications(workspace.id)
      assert length(notifications) == 1
      assert hd(notifications).title =~ "push"
    end

    test "delivers in-app and creates notification when channel is :all" do
      workspace = insert_workspace!()
      endpoint = insert_webhook_endpoint!(workspace)

      insert_notification_rule!(workspace, %{
        event_pattern: "monkey_claw.webhook.received",
        channel: :all,
        min_severity: :info
      })

      :ok = NotificationRouter.refresh_cache()
      :ok = Notifications.subscribe(workspace.id)

      :telemetry.execute(
        [:monkey_claw, :webhook, :received],
        %{},
        %{endpoint_id: endpoint.id, source: :generic, event_type: "push"}
      )

      _ = :sys.get_state(NotificationRouter)

      # PubSub delivery (in-app channel)
      assert_receive {:notification_created, _}, 1_000

      # Notification persisted in DB
      assert length(Notifications.list_notifications(workspace.id)) == 1
    end
  end

  # ──────────────────────────────────────────────
  # refresh_cache/0
  # ──────────────────────────────────────────────

  describe "refresh_cache/0" do
    test "picks up newly created rules" do
      workspace = insert_workspace!()
      endpoint = insert_webhook_endpoint!(workspace)

      # No rules initially
      :ok = NotificationRouter.refresh_cache()

      :telemetry.execute(
        [:monkey_claw, :webhook, :received],
        %{},
        %{endpoint_id: endpoint.id, source: :generic, event_type: "test"}
      )

      _ = :sys.get_state(NotificationRouter)
      assert Notifications.list_notifications(workspace.id) == []

      # Add a rule and refresh
      insert_notification_rule!(workspace, %{
        event_pattern: "monkey_claw.webhook.received"
      })

      :ok = NotificationRouter.refresh_cache()

      :telemetry.execute(
        [:monkey_claw, :webhook, :received],
        %{},
        %{endpoint_id: endpoint.id, source: :generic, event_type: "test"}
      )

      _ = :sys.get_state(NotificationRouter)
      assert length(Notifications.list_notifications(workspace.id)) == 1
    end

    test "returns {:error, :not_running} when router is not started" do
      stop_supervised!(NotificationRouter)
      assert {:error, :not_running} = NotificationRouter.refresh_cache()
    end
  end

  # ──────────────────────────────────────────────
  # Resilience
  # ──────────────────────────────────────────────

  describe "resilience" do
    test "router survives event with non-existent endpoint" do
      workspace = insert_workspace!()

      insert_notification_rule!(workspace, %{
        event_pattern: "monkey_claw.webhook.received"
      })

      :ok = NotificationRouter.refresh_cache()

      # Fire event for non-existent endpoint — EventMapper returns :skip
      :telemetry.execute(
        [:monkey_claw, :webhook, :received],
        %{},
        %{endpoint_id: Ecto.UUID.generate(), source: :generic, event_type: "test"}
      )

      _ = :sys.get_state(NotificationRouter)

      # Router should still be alive and functional
      assert Process.alive?(Process.whereis(NotificationRouter))
    end
  end
end
