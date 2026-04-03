defmodule MonkeyClawWeb.NotificationControllerTest do
  use MonkeyClawWeb.ConnCase

  import MonkeyClaw.Factory

  alias MonkeyClaw.Notifications

  # ──────────────────────────────────────────────
  # GET /api/workspaces/:workspace_id/notifications
  # ──────────────────────────────────────────────

  describe "GET /notifications — index" do
    test "returns notifications with unread count", %{conn: conn} do
      workspace = insert_workspace!()
      insert_notification!(workspace, %{title: "First"})
      insert_notification!(workspace, %{title: "Second"})

      conn = get(conn, ~p"/api/workspaces/#{workspace.id}/notifications")

      assert %{
               "notifications" => notifications,
               "unread_count" => 2
             } = json_response(conn, 200)

      assert length(notifications) == 2
    end

    test "filters by status", %{conn: conn} do
      workspace = insert_workspace!()
      n1 = insert_notification!(workspace)
      _n2 = insert_notification!(workspace)

      {:ok, _} = Notifications.mark_read(n1.id)

      conn = get(conn, ~p"/api/workspaces/#{workspace.id}/notifications?status=unread")

      assert %{"notifications" => notifications} = json_response(conn, 200)
      assert length(notifications) == 1
    end

    test "filters by category", %{conn: conn} do
      workspace = insert_workspace!()
      insert_notification!(workspace, %{category: :webhook})
      insert_notification!(workspace, %{category: :experiment})

      conn = get(conn, ~p"/api/workspaces/#{workspace.id}/notifications?category=webhook")

      assert %{"notifications" => notifications} = json_response(conn, 200)
      assert length(notifications) == 1
      assert hd(notifications)["category"] == "webhook"
    end

    test "respects limit parameter", %{conn: conn} do
      workspace = insert_workspace!()
      for _ <- 1..5, do: insert_notification!(workspace)

      conn = get(conn, ~p"/api/workspaces/#{workspace.id}/notifications?limit=2")

      assert %{"notifications" => notifications} = json_response(conn, 200)
      assert length(notifications) == 2
    end

    test "ignores invalid filter values", %{conn: conn} do
      workspace = insert_workspace!()
      insert_notification!(workspace)

      # Invalid status should be ignored (returns all)
      conn = get(conn, ~p"/api/workspaces/#{workspace.id}/notifications?status=invalid")

      assert %{"notifications" => notifications} = json_response(conn, 200)
      assert length(notifications) == 1
    end

    test "serializes notification fields correctly", %{conn: conn} do
      workspace = insert_workspace!()

      insert_notification!(workspace, %{
        title: "Test",
        body: "Details",
        category: :webhook,
        severity: :warning,
        metadata: %{"key" => "value"},
        source_id: Ecto.UUID.generate(),
        source_type: "webhook_endpoint"
      })

      conn = get(conn, ~p"/api/workspaces/#{workspace.id}/notifications")
      [notification] = json_response(conn, 200)["notifications"]

      assert notification["title"] == "Test"
      assert notification["body"] == "Details"
      assert notification["category"] == "webhook"
      assert notification["severity"] == "warning"
      assert notification["status"] == "unread"
      assert notification["metadata"] == %{"key" => "value"}
      assert notification["source_type"] == "webhook_endpoint"
      assert notification["id"]
      assert notification["inserted_at"]
    end
  end

  # ──────────────────────────────────────────────
  # PATCH /api/workspaces/:workspace_id/notifications/:id/read
  # ──────────────────────────────────────────────

  describe "PATCH /notifications/:id/read — mark read" do
    test "marks notification as read", %{conn: conn} do
      workspace = insert_workspace!()
      notification = insert_notification!(workspace)

      conn =
        patch(conn, ~p"/api/workspaces/#{workspace.id}/notifications/#{notification.id}/read")

      assert %{"notification" => resp} = json_response(conn, 200)
      assert resp["status"] == "read"
      assert resp["read_at"] != nil
    end

    test "returns 404 for non-existent notification", %{conn: conn} do
      workspace = insert_workspace!()

      conn =
        patch(
          conn,
          ~p"/api/workspaces/#{workspace.id}/notifications/#{Ecto.UUID.generate()}/read"
        )

      assert json_response(conn, 404)
    end

    test "returns 404 for notification in different workspace (anti-enumeration)", %{conn: conn} do
      w1 = insert_workspace!()
      w2 = insert_workspace!()
      notification = insert_notification!(w2)

      conn = patch(conn, ~p"/api/workspaces/#{w1.id}/notifications/#{notification.id}/read")

      assert %{"error" => "not found"} = json_response(conn, 404)
    end
  end

  # ──────────────────────────────────────────────
  # PATCH /api/workspaces/:workspace_id/notifications/:id/dismiss
  # ──────────────────────────────────────────────

  describe "PATCH /notifications/:id/dismiss — dismiss" do
    test "dismisses notification", %{conn: conn} do
      workspace = insert_workspace!()
      notification = insert_notification!(workspace)

      conn =
        patch(conn, ~p"/api/workspaces/#{workspace.id}/notifications/#{notification.id}/dismiss")

      assert %{"notification" => resp} = json_response(conn, 200)
      assert resp["status"] == "dismissed"
    end

    test "returns 404 for notification in different workspace", %{conn: conn} do
      w1 = insert_workspace!()
      w2 = insert_workspace!()
      notification = insert_notification!(w2)

      conn = patch(conn, ~p"/api/workspaces/#{w1.id}/notifications/#{notification.id}/dismiss")

      assert json_response(conn, 404)
    end
  end

  # ──────────────────────────────────────────────
  # POST /api/workspaces/:workspace_id/notifications/read_all
  # ──────────────────────────────────────────────

  describe "POST /notifications/read_all — mark all read" do
    test "marks all unread notifications as read", %{conn: conn} do
      workspace = insert_workspace!()
      insert_notification!(workspace)
      insert_notification!(workspace)
      insert_notification!(workspace)

      conn = post(conn, ~p"/api/workspaces/#{workspace.id}/notifications/read_all")

      assert %{"marked_read" => 3} = json_response(conn, 200)
      assert Notifications.count_unread(workspace.id) == 0
    end

    test "returns 0 when no unread notifications", %{conn: conn} do
      workspace = insert_workspace!()

      conn = post(conn, ~p"/api/workspaces/#{workspace.id}/notifications/read_all")

      assert %{"marked_read" => 0} = json_response(conn, 200)
    end
  end
end
