defmodule MonkeyClawWeb.NotificationRuleControllerTest do
  use MonkeyClawWeb.ConnCase

  import MonkeyClaw.Factory

  alias MonkeyClaw.Notifications

  # ──────────────────────────────────────────────
  # GET /api/workspaces/:workspace_id/notification_rules
  # ──────────────────────────────────────────────

  describe "GET /notification_rules — index" do
    test "lists rules for workspace", %{conn: conn} do
      workspace = insert_workspace!()

      insert_notification_rule!(workspace, %{
        event_pattern: "monkey_claw.webhook.received"
      })

      insert_notification_rule!(workspace, %{
        event_pattern: "monkey_claw.experiment.completed"
      })

      conn = get(conn, ~p"/api/workspaces/#{workspace.id}/notification_rules")

      assert %{"rules" => rules} = json_response(conn, 200)
      assert length(rules) == 2
    end

    test "scopes rules to workspace", %{conn: conn} do
      w1 = insert_workspace!()
      w2 = insert_workspace!()
      insert_notification_rule!(w1)
      insert_notification_rule!(w2)

      conn = get(conn, ~p"/api/workspaces/#{w1.id}/notification_rules")

      assert %{"rules" => rules} = json_response(conn, 200)
      assert length(rules) == 1
    end

    test "serializes rule fields correctly", %{conn: conn} do
      workspace = insert_workspace!()

      insert_notification_rule!(workspace, %{
        name: "My Rule",
        event_pattern: "monkey_claw.webhook.received",
        channel: :email,
        min_severity: :warning,
        enabled: true
      })

      conn = get(conn, ~p"/api/workspaces/#{workspace.id}/notification_rules")
      [rule] = json_response(conn, 200)["rules"]

      assert rule["name"] == "My Rule"
      assert rule["event_pattern"] == "monkey_claw.webhook.received"
      assert rule["channel"] == "email"
      assert rule["min_severity"] == "warning"
      assert rule["enabled"] == true
      assert rule["id"]
      assert rule["inserted_at"]
    end
  end

  # ──────────────────────────────────────────────
  # POST /api/workspaces/:workspace_id/notification_rules
  # ──────────────────────────────────────────────

  describe "POST /notification_rules — create" do
    test "creates rule with valid params", %{conn: conn} do
      workspace = insert_workspace!()

      conn =
        post(conn, ~p"/api/workspaces/#{workspace.id}/notification_rules", %{
          "name" => "Webhook alerts",
          "event_pattern" => "monkey_claw.webhook.received",
          "channel" => "in_app",
          "min_severity" => "info"
        })

      assert %{"rule" => rule} = json_response(conn, 201)
      assert rule["name"] == "Webhook alerts"
      assert rule["event_pattern"] == "monkey_claw.webhook.received"
    end

    test "returns 404 for non-existent workspace", %{conn: conn} do
      conn =
        post(conn, ~p"/api/workspaces/#{Ecto.UUID.generate()}/notification_rules", %{
          "name" => "Rule",
          "event_pattern" => "monkey_claw.webhook.received"
        })

      assert %{"error" => "workspace not found"} = json_response(conn, 404)
    end

    test "returns 422 for invalid params (missing required)", %{conn: conn} do
      workspace = insert_workspace!()

      conn =
        post(conn, ~p"/api/workspaces/#{workspace.id}/notification_rules", %{})

      assert %{"error" => errors} = json_response(conn, 422)
      assert is_map(errors)
    end

    test "returns 422 for invalid event_pattern", %{conn: conn} do
      workspace = insert_workspace!()

      conn =
        post(conn, ~p"/api/workspaces/#{workspace.id}/notification_rules", %{
          "name" => "Bad rule",
          "event_pattern" => "not.a.valid.pattern"
        })

      assert %{"error" => _} = json_response(conn, 422)
    end
  end

  # ──────────────────────────────────────────────
  # PATCH /api/workspaces/:workspace_id/notification_rules/:id
  # ──────────────────────────────────────────────

  describe "PATCH /notification_rules/:id — update" do
    test "updates rule fields", %{conn: conn} do
      workspace = insert_workspace!()
      rule = insert_notification_rule!(workspace)

      conn =
        patch(conn, ~p"/api/workspaces/#{workspace.id}/notification_rules/#{rule.id}", %{
          "name" => "Updated Name",
          "channel" => "email",
          "min_severity" => "warning",
          "enabled" => false
        })

      assert %{"rule" => updated} = json_response(conn, 200)
      assert updated["name"] == "Updated Name"
      assert updated["channel"] == "email"
      assert updated["min_severity"] == "warning"
      assert updated["enabled"] == false
    end

    test "returns 404 for non-existent rule", %{conn: conn} do
      workspace = insert_workspace!()

      conn =
        patch(
          conn,
          ~p"/api/workspaces/#{workspace.id}/notification_rules/#{Ecto.UUID.generate()}",
          %{"name" => "New"}
        )

      assert json_response(conn, 404)
    end

    test "returns 404 for rule in different workspace (anti-enumeration)", %{conn: conn} do
      w1 = insert_workspace!()
      w2 = insert_workspace!()
      rule = insert_notification_rule!(w2)

      conn =
        patch(conn, ~p"/api/workspaces/#{w1.id}/notification_rules/#{rule.id}", %{
          "name" => "Hacked"
        })

      assert %{"error" => "not found"} = json_response(conn, 404)
    end
  end

  # ──────────────────────────────────────────────
  # DELETE /api/workspaces/:workspace_id/notification_rules/:id
  # ──────────────────────────────────────────────

  describe "DELETE /notification_rules/:id — delete" do
    test "deletes rule and returns 204", %{conn: conn} do
      workspace = insert_workspace!()
      rule = insert_notification_rule!(workspace)

      conn =
        delete(conn, ~p"/api/workspaces/#{workspace.id}/notification_rules/#{rule.id}")

      assert response(conn, 204)
      assert {:error, :not_found} = Notifications.get_rule(rule.id)
    end

    test "returns 404 for non-existent rule", %{conn: conn} do
      workspace = insert_workspace!()

      conn =
        delete(
          conn,
          ~p"/api/workspaces/#{workspace.id}/notification_rules/#{Ecto.UUID.generate()}"
        )

      assert json_response(conn, 404)
    end

    test "returns 404 for rule in different workspace", %{conn: conn} do
      w1 = insert_workspace!()
      w2 = insert_workspace!()
      rule = insert_notification_rule!(w2)

      conn =
        delete(conn, ~p"/api/workspaces/#{w1.id}/notification_rules/#{rule.id}")

      assert json_response(conn, 404)
    end
  end
end
