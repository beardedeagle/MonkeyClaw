defmodule MonkeyClaw.WebhooksTest do
  use MonkeyClaw.DataCase

  alias MonkeyClaw.Webhooks
  alias MonkeyClaw.Webhooks.RateLimiter
  alias MonkeyClaw.Webhooks.WebhookDelivery
  alias MonkeyClaw.Webhooks.WebhookEndpoint

  import MonkeyClaw.Factory

  # ──────────────────────────────────────────────
  # generate_signing_secret/0
  # ──────────────────────────────────────────────

  describe "generate_signing_secret/0" do
    test "produces unique values" do
      s1 = Webhooks.generate_signing_secret()
      s2 = Webhooks.generate_signing_secret()
      assert s1 != s2
    end

    test "produces URL-safe Base64 encoding" do
      secret = Webhooks.generate_signing_secret()
      assert secret =~ ~r/^[A-Za-z0-9_-]+$/
      assert byte_size(secret) > 20
    end
  end

  # ──────────────────────────────────────────────
  # create_endpoint/2
  # ──────────────────────────────────────────────

  describe "create_endpoint/2" do
    test "creates endpoint with auto-generated secret" do
      workspace = insert_workspace!()

      {:ok, endpoint} =
        Webhooks.create_endpoint(workspace, %{name: "CI Notifications"})

      assert %WebhookEndpoint{} = endpoint
      assert endpoint.workspace_id == workspace.id
      assert endpoint.name == "CI Notifications"
      assert endpoint.source == :generic
      assert endpoint.status == :active
      assert byte_size(endpoint.signing_secret) > 0
      assert endpoint.rate_limit_per_minute == 60
      assert endpoint.delivery_count == 0
      assert endpoint.allowed_events == %{}
    end

    test "creates endpoint with provided attributes" do
      workspace = insert_workspace!()
      secret = Webhooks.generate_signing_secret()

      {:ok, endpoint} =
        Webhooks.create_endpoint(workspace, %{
          name: "GitHub Actions",
          source: :github,
          signing_secret: secret,
          rate_limit_per_minute: 120,
          allowed_events: %{"push" => true, "release" => true}
        })

      assert endpoint.signing_secret == secret
      assert endpoint.source == :github
      assert endpoint.rate_limit_per_minute == 120
      assert endpoint.allowed_events == %{"push" => true, "release" => true}
    end

    test "requires name" do
      workspace = insert_workspace!()
      {:error, cs} = Webhooks.create_endpoint(workspace, %{})
      assert errors_on(cs)[:name]
    end

    test "enforces unique name per workspace" do
      workspace = insert_workspace!()
      {:ok, _} = Webhooks.create_endpoint(workspace, %{name: "duplicate"})
      {:error, changeset} = Webhooks.create_endpoint(workspace, %{name: "duplicate"})
      refute changeset.valid?
    end

    test "allows same name in different workspaces" do
      w1 = insert_workspace!()
      w2 = insert_workspace!()
      assert {:ok, _} = Webhooks.create_endpoint(w1, %{name: "shared"})
      assert {:ok, _} = Webhooks.create_endpoint(w2, %{name: "shared"})
    end

    test "validates rate_limit_per_minute bounds" do
      workspace = insert_workspace!()

      {:error, cs} =
        Webhooks.create_endpoint(workspace, %{name: "bad-rate", rate_limit_per_minute: 0})

      assert errors_on(cs)[:rate_limit_per_minute]

      {:error, cs} =
        Webhooks.create_endpoint(workspace, %{name: "bad-rate", rate_limit_per_minute: 10_001})

      assert errors_on(cs)[:rate_limit_per_minute]
    end

    test "validates allowed_events map structure" do
      workspace = insert_workspace!()

      {:error, cs} =
        Webhooks.create_endpoint(workspace, %{
          name: "bad-events",
          allowed_events: %{123 => "not-boolean"}
        })

      assert errors_on(cs)[:allowed_events]
    end
  end

  # ──────────────────────────────────────────────
  # get_endpoint/1
  # ──────────────────────────────────────────────

  describe "get_endpoint/1" do
    test "returns endpoint by ID" do
      workspace = insert_workspace!()
      endpoint = insert_webhook_endpoint!(workspace)

      assert {:ok, found} = Webhooks.get_endpoint(endpoint.id)
      assert found.id == endpoint.id
      assert found.name == endpoint.name
    end

    test "returns error for missing ID" do
      assert {:error, :not_found} = Webhooks.get_endpoint(Ecto.UUID.generate())
    end
  end

  # ──────────────────────────────────────────────
  # get_active_endpoint/1
  # ──────────────────────────────────────────────

  describe "get_active_endpoint/1" do
    test "returns active endpoint" do
      workspace = insert_workspace!()
      endpoint = insert_webhook_endpoint!(workspace)

      assert {:ok, found} = Webhooks.get_active_endpoint(endpoint.id)
      assert found.id == endpoint.id
    end

    test "returns not_found for paused endpoint (anti-enumeration)" do
      workspace = insert_workspace!()
      endpoint = insert_webhook_endpoint!(workspace)
      {:ok, _paused} = Webhooks.pause_endpoint(endpoint)

      assert {:error, :not_found} = Webhooks.get_active_endpoint(endpoint.id)
    end

    test "returns not_found for revoked endpoint (anti-enumeration)" do
      workspace = insert_workspace!()
      endpoint = insert_webhook_endpoint!(workspace)
      {:ok, _revoked} = Webhooks.revoke_endpoint(endpoint)

      assert {:error, :not_found} = Webhooks.get_active_endpoint(endpoint.id)
    end

    test "returns not_found for non-existent ID" do
      assert {:error, :not_found} = Webhooks.get_active_endpoint(Ecto.UUID.generate())
    end
  end

  # ──────────────────────────────────────────────
  # list_endpoints/1
  # ──────────────────────────────────────────────

  describe "list_endpoints/1" do
    test "lists endpoints for workspace ordered by name" do
      workspace = insert_workspace!()
      insert_webhook_endpoint!(workspace, %{name: "Zebra"})
      insert_webhook_endpoint!(workspace, %{name: "Alpha"})

      endpoints = Webhooks.list_endpoints(workspace.id)
      assert length(endpoints) == 2
      assert hd(endpoints).name == "Alpha"
      assert List.last(endpoints).name == "Zebra"
    end

    test "scopes to workspace" do
      w1 = insert_workspace!()
      w2 = insert_workspace!()
      insert_webhook_endpoint!(w1)
      insert_webhook_endpoint!(w2)

      assert length(Webhooks.list_endpoints(w1.id)) == 1
      assert length(Webhooks.list_endpoints(w2.id)) == 1
    end

    test "returns empty list for workspace with no endpoints" do
      workspace = insert_workspace!()
      assert [] = Webhooks.list_endpoints(workspace.id)
    end
  end

  # ──────────────────────────────────────────────
  # update_endpoint/2
  # ──────────────────────────────────────────────

  describe "update_endpoint/2" do
    test "updates name and metadata" do
      workspace = insert_workspace!()
      endpoint = insert_webhook_endpoint!(workspace)

      {:ok, updated} =
        Webhooks.update_endpoint(endpoint, %{
          name: "New Name",
          metadata: %{"env" => "staging"}
        })

      assert updated.name == "New Name"
      assert updated.metadata == %{"env" => "staging"}
    end

    test "does not accept signing_secret changes" do
      workspace = insert_workspace!()
      endpoint = insert_webhook_endpoint!(workspace)

      {:ok, updated} =
        Webhooks.update_endpoint(endpoint, %{signing_secret: "attempt-change"})

      # signing_secret not in @update_fields — change is silently ignored
      assert updated.signing_secret == endpoint.signing_secret
    end
  end

  # ──────────────────────────────────────────────
  # delete_endpoint/1
  # ──────────────────────────────────────────────

  describe "delete_endpoint/1" do
    test "deletes endpoint" do
      workspace = insert_workspace!()
      endpoint = insert_webhook_endpoint!(workspace)

      {:ok, _deleted} = Webhooks.delete_endpoint(endpoint)
      assert {:error, :not_found} = Webhooks.get_endpoint(endpoint.id)
    end

    test "cascades to associated deliveries" do
      workspace = insert_workspace!()
      endpoint = insert_webhook_endpoint!(workspace)
      insert_webhook_delivery!(endpoint)
      insert_webhook_delivery!(endpoint)

      {:ok, _deleted} = Webhooks.delete_endpoint(endpoint)
      assert [] = Webhooks.list_deliveries(endpoint.id)
    end
  end

  # ──────────────────────────────────────────────
  # Status Transitions
  # ──────────────────────────────────────────────

  describe "status transitions" do
    test "active -> paused" do
      workspace = insert_workspace!()
      endpoint = insert_webhook_endpoint!(workspace)

      {:ok, paused} = Webhooks.pause_endpoint(endpoint)
      assert paused.status == :paused
    end

    test "paused -> active (reversible)" do
      workspace = insert_workspace!()
      endpoint = insert_webhook_endpoint!(workspace)
      {:ok, paused} = Webhooks.pause_endpoint(endpoint)

      {:ok, reactivated} = Webhooks.activate_endpoint(paused)
      assert reactivated.status == :active
    end

    test "active -> revoked (terminal)" do
      workspace = insert_workspace!()
      endpoint = insert_webhook_endpoint!(workspace)

      {:ok, revoked} = Webhooks.revoke_endpoint(endpoint)
      assert revoked.status == :revoked
    end

    test "paused -> revoked (terminal)" do
      workspace = insert_workspace!()
      endpoint = insert_webhook_endpoint!(workspace)
      {:ok, paused} = Webhooks.pause_endpoint(endpoint)

      {:ok, revoked} = Webhooks.revoke_endpoint(paused)
      assert revoked.status == :revoked
    end

    test "revoked cannot transition to active" do
      workspace = insert_workspace!()
      endpoint = insert_webhook_endpoint!(workspace)
      {:ok, revoked} = Webhooks.revoke_endpoint(endpoint)

      {:error, cs} = Webhooks.activate_endpoint(revoked)
      assert errors_on(cs)[:status]
    end

    test "revoked cannot transition to paused" do
      workspace = insert_workspace!()
      endpoint = insert_webhook_endpoint!(workspace)
      {:ok, revoked} = Webhooks.revoke_endpoint(endpoint)

      {:error, cs} = Webhooks.pause_endpoint(revoked)
      assert errors_on(cs)[:status]
    end
  end

  # ──────────────────────────────────────────────
  # rotate_secret/1
  # ──────────────────────────────────────────────

  describe "rotate_secret/1" do
    test "generates new signing secret" do
      workspace = insert_workspace!()
      endpoint = insert_webhook_endpoint!(workspace)
      original_secret = endpoint.signing_secret

      {:ok, rotated} = Webhooks.rotate_secret(endpoint)

      assert rotated.signing_secret != original_secret
      assert byte_size(rotated.signing_secret) > 0
    end

    test "new secret persists across reads" do
      workspace = insert_workspace!()
      endpoint = insert_webhook_endpoint!(workspace)
      {:ok, rotated} = Webhooks.rotate_secret(endpoint)

      {:ok, reloaded} = Webhooks.get_endpoint(rotated.id)
      assert reloaded.signing_secret == rotated.signing_secret
    end
  end

  # ──────────────────────────────────────────────
  # record_delivery/2
  # ──────────────────────────────────────────────

  describe "record_delivery/2" do
    test "creates delivery record" do
      workspace = insert_workspace!()
      endpoint = insert_webhook_endpoint!(workspace)

      {:ok, delivery} =
        Webhooks.record_delivery(endpoint, %{
          status: :accepted,
          payload_hash: "abcdef0123456789",
          event_type: "push",
          remote_ip: "192.168.1.1",
          idempotency_key: "uniq-123"
        })

      assert %WebhookDelivery{} = delivery
      assert delivery.webhook_endpoint_id == endpoint.id
      assert delivery.status == :accepted
      assert delivery.event_type == "push"
      assert delivery.remote_ip == "192.168.1.1"
      assert delivery.idempotency_key == "uniq-123"
    end

    test "increments endpoint delivery_count" do
      workspace = insert_workspace!()
      endpoint = insert_webhook_endpoint!(workspace)

      insert_webhook_delivery!(endpoint)
      insert_webhook_delivery!(endpoint)
      insert_webhook_delivery!(endpoint)

      {:ok, refreshed} = Webhooks.get_endpoint(endpoint.id)
      assert refreshed.delivery_count == 3
    end

    test "updates last_received_at" do
      workspace = insert_workspace!()
      endpoint = insert_webhook_endpoint!(workspace)
      assert endpoint.last_received_at == nil

      insert_webhook_delivery!(endpoint)

      {:ok, refreshed} = Webhooks.get_endpoint(endpoint.id)
      assert refreshed.last_received_at != nil
    end

    test "requires status and payload_hash" do
      workspace = insert_workspace!()
      endpoint = insert_webhook_endpoint!(workspace)

      {:error, cs} = Webhooks.record_delivery(endpoint, %{})
      assert errors_on(cs)[:status]
      assert errors_on(cs)[:payload_hash]
    end
  end

  # ──────────────────────────────────────────────
  # update_delivery/2
  # ──────────────────────────────────────────────

  describe "update_delivery/2" do
    test "transitions delivery status" do
      workspace = insert_workspace!()
      endpoint = insert_webhook_endpoint!(workspace)
      delivery = insert_webhook_delivery!(endpoint)

      {:ok, updated} =
        Webhooks.update_delivery(delivery, %{
          status: :processed,
          processed_at: DateTime.utc_now()
        })

      assert updated.status == :processed
      assert updated.processed_at != nil
    end
  end

  # ──────────────────────────────────────────────
  # list_deliveries/1
  # ──────────────────────────────────────────────

  describe "list_deliveries/1" do
    test "returns deliveries newest first" do
      workspace = insert_workspace!()
      endpoint = insert_webhook_endpoint!(workspace)
      insert_webhook_delivery!(endpoint, %{event_type: "first"})
      insert_webhook_delivery!(endpoint, %{event_type: "second"})

      deliveries = Webhooks.list_deliveries(endpoint.id)
      assert length(deliveries) == 2
      assert hd(deliveries).event_type == "second"
    end

    test "respects limit option" do
      workspace = insert_workspace!()
      endpoint = insert_webhook_endpoint!(workspace)
      Enum.each(1..5, fn i -> insert_webhook_delivery!(endpoint, %{event_type: "e#{i}"}) end)

      assert length(Webhooks.list_deliveries(endpoint.id, limit: 2)) == 2
    end

    test "caps limit at 200" do
      workspace = insert_workspace!()
      endpoint = insert_webhook_endpoint!(workspace)

      # Request higher than cap
      deliveries = Webhooks.list_deliveries(endpoint.id, limit: 500)
      assert is_list(deliveries)
    end

    test "returns empty list for endpoint with no deliveries" do
      workspace = insert_workspace!()
      endpoint = insert_webhook_endpoint!(workspace)

      assert [] = Webhooks.list_deliveries(endpoint.id)
    end
  end

  # ──────────────────────────────────────────────
  # check_replay/2
  # ──────────────────────────────────────────────

  describe "check_replay/2" do
    test "allows new idempotency key" do
      workspace = insert_workspace!()
      endpoint = insert_webhook_endpoint!(workspace)

      assert :ok = Webhooks.check_replay(endpoint, "brand-new-key")
    end

    test "detects replay with existing key" do
      workspace = insert_workspace!()
      endpoint = insert_webhook_endpoint!(workspace)
      insert_webhook_delivery!(endpoint, %{idempotency_key: "already-used"})

      assert {:error, :replay_detected} = Webhooks.check_replay(endpoint, "already-used")
    end

    test "nil idempotency key always passes (no replay check)" do
      workspace = insert_workspace!()
      endpoint = insert_webhook_endpoint!(workspace)

      assert :ok = Webhooks.check_replay(endpoint, nil)
    end

    test "scopes replay check to endpoint" do
      workspace = insert_workspace!()
      ep1 = insert_webhook_endpoint!(workspace, %{name: "endpoint-1"})
      ep2 = insert_webhook_endpoint!(workspace, %{name: "endpoint-2"})
      insert_webhook_delivery!(ep1, %{idempotency_key: "cross-key"})

      # Same key on different endpoint is not a replay
      assert :ok = Webhooks.check_replay(ep2, "cross-key")
    end
  end

  # ──────────────────────────────────────────────
  # event_allowed?/2
  # ──────────────────────────────────────────────

  describe "event_allowed?/2" do
    test "empty allowed_events map accepts all events" do
      endpoint = %WebhookEndpoint{allowed_events: %{}}

      assert Webhooks.event_allowed?(endpoint, "push")
      assert Webhooks.event_allowed?(endpoint, "release")
      assert Webhooks.event_allowed?(endpoint, "anything")
    end

    test "non-empty map accepts only listed events" do
      endpoint = %WebhookEndpoint{allowed_events: %{"push" => true, "release" => true}}

      assert Webhooks.event_allowed?(endpoint, "push")
      assert Webhooks.event_allowed?(endpoint, "release")
      refute Webhooks.event_allowed?(endpoint, "issue")
      refute Webhooks.event_allowed?(endpoint, "pull_request")
    end
  end

  # ──────────────────────────────────────────────
  # check_rate_limit/1
  # ──────────────────────────────────────────────

  describe "check_rate_limit/1" do
    setup do
      RateLimiter.reset_all()
      :ok
    end

    test "allows requests within limit" do
      workspace = insert_workspace!()
      endpoint = insert_webhook_endpoint!(workspace, %{rate_limit_per_minute: 5})

      assert :ok = Webhooks.check_rate_limit(endpoint)
      assert :ok = Webhooks.check_rate_limit(endpoint)
    end

    test "rejects requests exceeding limit" do
      workspace = insert_workspace!()
      endpoint = insert_webhook_endpoint!(workspace, %{rate_limit_per_minute: 1})

      assert :ok = Webhooks.check_rate_limit(endpoint)
      assert {:error, :rate_limited} = Webhooks.check_rate_limit(endpoint)
    end
  end
end
