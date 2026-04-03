defmodule MonkeyClaw.Notifications.EventMapperTest do
  use MonkeyClaw.DataCase

  import MonkeyClaw.Factory

  alias MonkeyClaw.Notifications.EventMapper

  # ──────────────────────────────────────────────
  # Webhook Events
  # ──────────────────────────────────────────────

  describe "map_event/3 — webhook received" do
    test "maps webhook.received with valid endpoint" do
      workspace = insert_workspace!()
      endpoint = insert_webhook_endpoint!(workspace)

      {:ok, attrs} =
        EventMapper.map_event(
          [:monkey_claw, :webhook, :received],
          %{},
          %{endpoint_id: endpoint.id, source: :github, event_type: "push"}
        )

      assert attrs.workspace_id == workspace.id
      assert attrs.category == :webhook
      assert attrs.severity == :info
      assert attrs.title =~ "push"
      assert attrs.source_id == endpoint.id
      assert attrs.source_type == "webhook_endpoint"
    end

    test "returns :skip for non-existent endpoint" do
      assert :skip =
               EventMapper.map_event(
                 [:monkey_claw, :webhook, :received],
                 %{},
                 %{endpoint_id: Ecto.UUID.generate(), source: :generic, event_type: "test"}
               )
    end
  end

  describe "map_event/3 — webhook rejected" do
    test "maps webhook.rejected with endpoint_id in metadata" do
      workspace = insert_workspace!()
      endpoint = insert_webhook_endpoint!(workspace)

      {:ok, attrs} =
        EventMapper.map_event(
          [:monkey_claw, :webhook, :rejected],
          %{},
          %{status: 401, endpoint_id: endpoint.id}
        )

      assert attrs.workspace_id == workspace.id
      assert attrs.category == :webhook
      assert attrs.severity == :warning
      assert attrs.title =~ "rejected"
    end

    test "returns :skip when rejected with no endpoint_id" do
      assert :skip =
               EventMapper.map_event(
                 [:monkey_claw, :webhook, :rejected],
                 %{},
                 %{status: 404}
               )
    end
  end

  describe "map_event/3 — webhook dispatched" do
    test "maps webhook.dispatched with valid endpoint" do
      workspace = insert_workspace!()
      endpoint = insert_webhook_endpoint!(workspace)

      {:ok, attrs} =
        EventMapper.map_event(
          [:monkey_claw, :webhook, :dispatched],
          %{},
          %{endpoint_id: endpoint.id, event_type: "push"}
        )

      assert attrs.workspace_id == workspace.id
      assert attrs.category == :webhook
      assert attrs.severity == :info
      assert attrs.title =~ "dispatched"
    end
  end

  # ──────────────────────────────────────────────
  # Experiment Events
  # ──────────────────────────────────────────────

  describe "map_event/3 — experiment completed" do
    test "maps experiment.completed with valid experiment" do
      workspace = insert_workspace!()
      experiment = insert_experiment!(workspace)

      {:ok, attrs} =
        EventMapper.map_event(
          [:monkey_claw, :experiment, :completed],
          %{},
          %{experiment_id: experiment.id, strategy: "code", decision: "accept"}
        )

      assert attrs.workspace_id == workspace.id
      assert attrs.category == :experiment
      assert attrs.severity == :info
      assert attrs.title =~ "accept"
      assert attrs.source_id == experiment.id
      assert attrs.source_type == "experiment"
    end

    test "returns :skip for non-existent experiment" do
      assert :skip =
               EventMapper.map_event(
                 [:monkey_claw, :experiment, :completed],
                 %{},
                 %{experiment_id: Ecto.UUID.generate(), strategy: "code", decision: "accept"}
               )
    end
  end

  describe "map_event/3 — experiment rollback" do
    test "maps experiment.rollback with valid experiment" do
      workspace = insert_workspace!()
      experiment = insert_experiment!(workspace)

      {:ok, attrs} =
        EventMapper.map_event(
          [:monkey_claw, :experiment, :rollback],
          %{},
          %{experiment_id: experiment.id, strategy: "code", iteration: 3}
        )

      assert attrs.workspace_id == workspace.id
      assert attrs.category == :experiment
      assert attrs.severity == :warning
      assert attrs.title =~ "rollback"
    end
  end

  # ──────────────────────────────────────────────
  # Agent Bridge Events
  # ──────────────────────────────────────────────

  describe "map_event/3 — agent bridge session exception" do
    test "maps session.exception using session_id as workspace_id" do
      session_id = Ecto.UUID.generate()

      {:ok, attrs} =
        EventMapper.map_event(
          [:monkey_claw, :agent_bridge, :session, :exception],
          %{},
          %{session_id: session_id, kind: :error, reason: :timeout}
        )

      assert attrs.workspace_id == session_id
      assert attrs.category == :session
      assert attrs.severity == :error
      assert attrs.source_type == "session"
    end
  end

  describe "map_event/3 — agent bridge query exception" do
    test "maps query.exception using session_id as workspace_id" do
      session_id = Ecto.UUID.generate()

      {:ok, attrs} =
        EventMapper.map_event(
          [:monkey_claw, :agent_bridge, :query, :exception],
          %{},
          %{session_id: session_id, kind: :error, reason: :timeout}
        )

      assert attrs.workspace_id == session_id
      assert attrs.category == :session
      assert attrs.severity == :error
    end
  end

  # ──────────────────────────────────────────────
  # Catch-all and Severity
  # ──────────────────────────────────────────────

  describe "map_event/3 — catch-all" do
    test "returns :skip for unknown events" do
      assert :skip = EventMapper.map_event([:unknown, :event], %{}, %{})
    end
  end

  describe "severity_meets_threshold?/2" do
    test "info meets info threshold" do
      assert EventMapper.severity_meets_threshold?(:info, :info)
    end

    test "warning meets info threshold" do
      assert EventMapper.severity_meets_threshold?(:warning, :info)
    end

    test "error meets info threshold" do
      assert EventMapper.severity_meets_threshold?(:error, :info)
    end

    test "info does not meet warning threshold" do
      refute EventMapper.severity_meets_threshold?(:info, :warning)
    end

    test "warning meets warning threshold" do
      assert EventMapper.severity_meets_threshold?(:warning, :warning)
    end

    test "error meets warning threshold" do
      assert EventMapper.severity_meets_threshold?(:error, :warning)
    end

    test "info does not meet error threshold" do
      refute EventMapper.severity_meets_threshold?(:info, :error)
    end

    test "warning does not meet error threshold" do
      refute EventMapper.severity_meets_threshold?(:warning, :error)
    end

    test "error meets error threshold" do
      assert EventMapper.severity_meets_threshold?(:error, :error)
    end
  end
end
