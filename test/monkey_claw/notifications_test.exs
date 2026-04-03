defmodule MonkeyClaw.NotificationsTest do
  use MonkeyClaw.DataCase

  alias MonkeyClaw.Notifications
  alias MonkeyClaw.Notifications.Notification
  alias MonkeyClaw.Notifications.NotificationRule

  import MonkeyClaw.Factory

  # ──────────────────────────────────────────────
  # create_notification/2
  # ──────────────────────────────────────────────

  describe "create_notification/2" do
    test "creates notification within workspace" do
      workspace = insert_workspace!()

      {:ok, notification} =
        Notifications.create_notification(workspace, %{
          title: "Webhook received",
          category: :webhook,
          severity: :info,
          body: "A push event"
        })

      assert %Notification{} = notification
      assert notification.workspace_id == workspace.id
      assert notification.title == "Webhook received"
      assert notification.status == :unread
    end

    test "rejects missing required fields" do
      workspace = insert_workspace!()

      {:error, cs} = Notifications.create_notification(workspace, %{})
      assert errors_on(cs)[:title]
      assert errors_on(cs)[:category]
    end
  end

  # ──────────────────────────────────────────────
  # create_notification_by_workspace_id/2
  # ──────────────────────────────────────────────

  describe "create_notification_by_workspace_id/2" do
    test "creates notification with raw workspace_id" do
      workspace = insert_workspace!()

      {:ok, notification} =
        Notifications.create_notification_by_workspace_id(workspace.id, %{
          title: "Session error",
          category: :session,
          severity: :error
        })

      assert notification.workspace_id == workspace.id
    end
  end

  # ──────────────────────────────────────────────
  # get_notification/1
  # ──────────────────────────────────────────────

  describe "get_notification/1" do
    test "returns {:ok, notification} for existing ID" do
      workspace = insert_workspace!()
      notification = insert_notification!(workspace)

      assert {:ok, found} = Notifications.get_notification(notification.id)
      assert found.id == notification.id
    end

    test "returns {:error, :not_found} for missing ID" do
      assert {:error, :not_found} = Notifications.get_notification(Ecto.UUID.generate())
    end
  end

  # ──────────────────────────────────────────────
  # list_notifications/2
  # ──────────────────────────────────────────────

  describe "list_notifications/2" do
    test "lists notifications for workspace ordered by inserted_at desc" do
      workspace = insert_workspace!()
      _n1 = insert_notification!(workspace, %{title: "First"})
      _n2 = insert_notification!(workspace, %{title: "Second"})

      notifications = Notifications.list_notifications(workspace.id)
      assert length(notifications) == 2
      # Most recent first
      assert hd(notifications).title == "Second"
    end

    test "scopes to workspace" do
      w1 = insert_workspace!()
      w2 = insert_workspace!()
      insert_notification!(w1)
      insert_notification!(w2)

      notifications = Notifications.list_notifications(w1.id)
      assert length(notifications) == 1
      assert hd(notifications).workspace_id == w1.id
    end

    test "filters by status" do
      workspace = insert_workspace!()
      n1 = insert_notification!(workspace)
      _n2 = insert_notification!(workspace)

      {:ok, _} = Notifications.mark_read(n1.id)

      unread = Notifications.list_notifications(workspace.id, %{status: :unread})
      assert length(unread) == 1

      read = Notifications.list_notifications(workspace.id, %{status: :read})
      assert length(read) == 1
    end

    test "filters by category" do
      workspace = insert_workspace!()
      insert_notification!(workspace, %{category: :webhook})
      insert_notification!(workspace, %{category: :experiment})

      webhooks = Notifications.list_notifications(workspace.id, %{category: :webhook})
      assert length(webhooks) == 1
      assert hd(webhooks).category == :webhook
    end

    test "respects limit" do
      workspace = insert_workspace!()
      for _ <- 1..5, do: insert_notification!(workspace)

      notifications = Notifications.list_notifications(workspace.id, %{limit: 3})
      assert length(notifications) == 3
    end

    test "clamps limit to max 200" do
      workspace = insert_workspace!()
      insert_notification!(workspace)

      # Should not crash with high limit
      notifications = Notifications.list_notifications(workspace.id, %{limit: 999})
      assert length(notifications) == 1
    end
  end

  # ──────────────────────────────────────────────
  # list_unread/1 and count_unread/1
  # ──────────────────────────────────────────────

  describe "list_unread/1 and count_unread/1" do
    test "lists only unread notifications" do
      workspace = insert_workspace!()
      n1 = insert_notification!(workspace)
      _n2 = insert_notification!(workspace)

      {:ok, _} = Notifications.mark_read(n1.id)

      unread = Notifications.list_unread(workspace.id)
      assert length(unread) == 1
    end

    test "counts unread notifications" do
      workspace = insert_workspace!()
      n1 = insert_notification!(workspace)
      _n2 = insert_notification!(workspace)
      _n3 = insert_notification!(workspace)

      assert Notifications.count_unread(workspace.id) == 3

      {:ok, _} = Notifications.mark_read(n1.id)
      assert Notifications.count_unread(workspace.id) == 2
    end
  end

  # ──────────────────────────────────────────────
  # mark_read/1 and mark_all_read/1
  # ──────────────────────────────────────────────

  describe "mark_read/1" do
    test "transitions notification to :read and sets read_at" do
      workspace = insert_workspace!()
      notification = insert_notification!(workspace)
      assert notification.status == :unread

      {:ok, read} = Notifications.mark_read(notification.id)
      assert read.status == :read
      assert read.read_at != nil
    end

    test "returns {:error, :not_found} for missing ID" do
      assert {:error, :not_found} = Notifications.mark_read(Ecto.UUID.generate())
    end
  end

  describe "mark_all_read/1" do
    test "marks all unread notifications in workspace as read" do
      workspace = insert_workspace!()
      insert_notification!(workspace)
      insert_notification!(workspace)
      insert_notification!(workspace)

      assert Notifications.count_unread(workspace.id) == 3

      {count, _} = Notifications.mark_all_read(workspace.id)
      assert count == 3
      assert Notifications.count_unread(workspace.id) == 0
    end

    test "does not affect other workspaces" do
      w1 = insert_workspace!()
      w2 = insert_workspace!()
      insert_notification!(w1)
      insert_notification!(w2)

      Notifications.mark_all_read(w1.id)

      assert Notifications.count_unread(w1.id) == 0
      assert Notifications.count_unread(w2.id) == 1
    end
  end

  # ──────────────────────────────────────────────
  # dismiss/1
  # ──────────────────────────────────────────────

  describe "dismiss/1" do
    test "transitions notification to :dismissed" do
      workspace = insert_workspace!()
      notification = insert_notification!(workspace)

      {:ok, dismissed} = Notifications.dismiss(notification.id)
      assert dismissed.status == :dismissed
    end

    test "returns {:error, :not_found} for missing ID" do
      assert {:error, :not_found} = Notifications.dismiss(Ecto.UUID.generate())
    end
  end

  # ──────────────────────────────────────────────
  # prune/2
  # ──────────────────────────────────────────────

  describe "prune/2" do
    test "deletes old read/dismissed notifications beyond retention" do
      workspace = insert_workspace!()
      n1 = insert_notification!(workspace)
      {:ok, _} = Notifications.mark_read(n1.id)

      # Backdate the notification to 40 days ago via raw SQL
      Repo.update_all(
        from(n in Notification, where: n.id == ^n1.id),
        set: [inserted_at: DateTime.add(DateTime.utc_now(), -40, :day)]
      )

      # Insert a recent unread one (should not be pruned)
      insert_notification!(workspace)

      {deleted, _} = Notifications.prune(workspace.id, 30)
      assert deleted == 1

      # The recent unread one remains
      assert length(Notifications.list_notifications(workspace.id)) == 1
    end

    test "does not prune unread notifications" do
      workspace = insert_workspace!()
      n1 = insert_notification!(workspace)

      # Backdate but keep unread
      Repo.update_all(
        from(n in Notification, where: n.id == ^n1.id),
        set: [inserted_at: DateTime.add(DateTime.utc_now(), -40, :day)]
      )

      {deleted, _} = Notifications.prune(workspace.id, 30)
      assert deleted == 0
    end
  end

  # ──────────────────────────────────────────────
  # Notification Rule CRUD
  # ──────────────────────────────────────────────

  describe "create_rule/2" do
    test "creates rule within workspace" do
      workspace = insert_workspace!()

      {:ok, rule} =
        Notifications.create_rule(workspace, %{
          name: "Webhook alerts",
          event_pattern: "monkey_claw.webhook.received",
          channel: :in_app,
          min_severity: :info
        })

      assert %NotificationRule{} = rule
      assert rule.workspace_id == workspace.id
      assert rule.enabled == true
    end

    test "enforces unique (workspace_id, event_pattern)" do
      workspace = insert_workspace!()

      {:ok, _} =
        Notifications.create_rule(workspace, %{
          name: "Rule 1",
          event_pattern: "monkey_claw.webhook.received"
        })

      {:error, cs} =
        Notifications.create_rule(workspace, %{
          name: "Rule 2",
          event_pattern: "monkey_claw.webhook.received"
        })

      assert errors_on(cs)[:workspace_id] || errors_on(cs)[:event_pattern]
    end

    test "different workspaces can have same event_pattern" do
      w1 = insert_workspace!()
      w2 = insert_workspace!()

      {:ok, _} =
        Notifications.create_rule(w1, %{
          name: "Rule 1",
          event_pattern: "monkey_claw.webhook.received"
        })

      {:ok, _} =
        Notifications.create_rule(w2, %{
          name: "Rule 2",
          event_pattern: "monkey_claw.webhook.received"
        })
    end
  end

  describe "get_rule/1" do
    test "returns {:ok, rule} for existing ID" do
      workspace = insert_workspace!()
      rule = insert_notification_rule!(workspace)

      assert {:ok, found} = Notifications.get_rule(rule.id)
      assert found.id == rule.id
    end

    test "returns {:error, :not_found} for missing ID" do
      assert {:error, :not_found} = Notifications.get_rule(Ecto.UUID.generate())
    end
  end

  describe "list_rules/1" do
    test "lists rules for workspace" do
      workspace = insert_workspace!()

      insert_notification_rule!(workspace, %{
        event_pattern: "monkey_claw.webhook.received"
      })

      insert_notification_rule!(workspace, %{
        event_pattern: "monkey_claw.experiment.completed"
      })

      rules = Notifications.list_rules(workspace.id)
      assert length(rules) == 2
    end

    test "scopes to workspace" do
      w1 = insert_workspace!()
      w2 = insert_workspace!()
      insert_notification_rule!(w1)
      insert_notification_rule!(w2)

      rules = Notifications.list_rules(w1.id)
      assert length(rules) == 1
    end
  end

  describe "update_rule/2" do
    test "updates rule fields" do
      workspace = insert_workspace!()
      rule = insert_notification_rule!(workspace)

      {:ok, updated} =
        Notifications.update_rule(rule, %{
          name: "Renamed",
          channel: :email,
          min_severity: :warning
        })

      assert updated.name == "Renamed"
      assert updated.channel == :email
      assert updated.min_severity == :warning
    end
  end

  describe "delete_rule/1" do
    test "deletes rule, get returns :not_found" do
      workspace = insert_workspace!()
      rule = insert_notification_rule!(workspace)

      {:ok, _} = Notifications.delete_rule(rule)
      assert {:error, :not_found} = Notifications.get_rule(rule.id)
    end
  end

  describe "enable_rule/1 and disable_rule/1" do
    test "toggles enabled state" do
      workspace = insert_workspace!()
      rule = insert_notification_rule!(workspace)
      assert rule.enabled == true

      {:ok, disabled} = Notifications.disable_rule(rule)
      assert disabled.enabled == false

      {:ok, enabled} = Notifications.enable_rule(disabled)
      assert enabled.enabled == true
    end
  end

  describe "list_enabled_rules_by_pattern/0" do
    test "groups enabled rules by event_pattern" do
      w1 = insert_workspace!()
      w2 = insert_workspace!()

      insert_notification_rule!(w1, %{event_pattern: "monkey_claw.webhook.received"})
      insert_notification_rule!(w2, %{event_pattern: "monkey_claw.webhook.received"})
      insert_notification_rule!(w1, %{event_pattern: "monkey_claw.experiment.completed"})

      grouped = Notifications.list_enabled_rules_by_pattern()

      assert length(Map.get(grouped, "monkey_claw.webhook.received", [])) == 2
      assert length(Map.get(grouped, "monkey_claw.experiment.completed", [])) == 1
    end

    test "excludes disabled rules" do
      workspace = insert_workspace!()
      rule = insert_notification_rule!(workspace)
      {:ok, _} = Notifications.disable_rule(rule)

      grouped = Notifications.list_enabled_rules_by_pattern()
      assert grouped == %{}
    end
  end

  # ──────────────────────────────────────────────
  # PubSub
  # ──────────────────────────────────────────────

  describe "subscribe/1 and broadcast_created/1" do
    test "subscriber receives {:notification_created, notification}" do
      workspace = insert_workspace!()
      :ok = Notifications.subscribe(workspace.id)

      notification = insert_notification!(workspace)
      :ok = Notifications.broadcast_created(notification)

      assert_receive {:notification_created, received}, 1_000
      assert received.id == notification.id
    end

    test "subscriber on different workspace does not receive message" do
      w1 = insert_workspace!()
      w2 = insert_workspace!()
      :ok = Notifications.subscribe(w1.id)

      notification = insert_notification!(w2)
      :ok = Notifications.broadcast_created(notification)

      refute_receive {:notification_created, _}, 200
    end
  end

  describe "topic/1" do
    test "returns workspace-scoped topic string" do
      id = Ecto.UUID.generate()
      assert Notifications.topic(id) == "notifications:#{id}"
    end
  end
end
