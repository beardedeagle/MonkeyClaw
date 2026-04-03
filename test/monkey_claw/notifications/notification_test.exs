defmodule MonkeyClaw.Notifications.NotificationTest do
  use MonkeyClaw.ChangesetCase, async: true

  alias MonkeyClaw.Notifications.Notification

  # ──────────────────────────────────────────────
  # create_changeset/2
  # ──────────────────────────────────────────────

  describe "create_changeset/2" do
    test "valid attrs produce a valid changeset" do
      cs =
        %Notification{}
        |> Notification.create_changeset(%{
          title: "Webhook received",
          category: :webhook,
          severity: :info,
          body: "A webhook was received"
        })

      assert cs.valid?
    end

    test "requires title and category" do
      cs = Notification.create_changeset(%Notification{}, %{})

      errors = errors_on(cs)
      assert errors[:title]
      assert errors[:category]
    end

    test "validates title length (1–255)" do
      cs_empty =
        Notification.create_changeset(%Notification{}, %{
          title: "",
          category: :webhook
        })

      assert errors_on(cs_empty)[:title]

      cs_long =
        Notification.create_changeset(%Notification{}, %{
          title: String.duplicate("a", 256),
          category: :webhook
        })

      assert errors_on(cs_long)[:title]

      cs_max =
        Notification.create_changeset(%Notification{}, %{
          title: String.duplicate("a", 255),
          category: :webhook
        })

      assert cs_max.valid?
    end

    test "validates body length (max 5000)" do
      cs_long =
        Notification.create_changeset(%Notification{}, %{
          title: "Test",
          category: :webhook,
          body: String.duplicate("a", 5001)
        })

      assert errors_on(cs_long)[:body]

      cs_max =
        Notification.create_changeset(%Notification{}, %{
          title: "Test",
          category: :webhook,
          body: String.duplicate("a", 5000)
        })

      assert cs_max.valid?
    end

    test "validates category enum" do
      for category <- [:webhook, :experiment, :session, :system] do
        cs =
          Notification.create_changeset(%Notification{}, %{
            title: "Test",
            category: category
          })

        assert cs.valid?, "expected #{category} to be valid"
      end

      cs =
        Notification.create_changeset(%Notification{}, %{
          title: "Test",
          category: :invalid
        })

      assert errors_on(cs)[:category]
    end

    test "validates severity enum" do
      for sev <- [:info, :warning, :error] do
        cs =
          Notification.create_changeset(%Notification{}, %{
            title: "Test",
            category: :webhook,
            severity: sev
          })

        assert cs.valid?, "expected #{sev} to be valid"
      end

      cs =
        Notification.create_changeset(%Notification{}, %{
          title: "Test",
          category: :webhook,
          severity: :critical
        })

      assert errors_on(cs)[:severity]
    end

    test "defaults severity to :info and status to :unread" do
      cs =
        Notification.create_changeset(%Notification{}, %{
          title: "Test",
          category: :webhook
        })

      assert Ecto.Changeset.get_field(cs, :severity) == :info
      assert Ecto.Changeset.get_field(cs, :status) == :unread
    end

    test "validates source_type against allowlist" do
      for st <- ~w(webhook_delivery webhook_endpoint experiment session) do
        cs =
          Notification.create_changeset(%Notification{}, %{
            title: "Test",
            category: :webhook,
            source_type: st
          })

        assert cs.valid?, "expected source_type #{st} to be valid"
      end

      cs =
        Notification.create_changeset(%Notification{}, %{
          title: "Test",
          category: :webhook,
          source_type: "unknown_type"
        })

      assert errors_on(cs)[:source_type]
    end

    test "validates source_id max length" do
      cs =
        Notification.create_changeset(%Notification{}, %{
          title: "Test",
          category: :webhook,
          source_id: String.duplicate("a", 256)
        })

      assert errors_on(cs)[:source_id]
    end

    test "validates metadata must be a map" do
      cs =
        Notification.create_changeset(%Notification{}, %{
          title: "Test",
          category: :webhook,
          metadata: "not a map"
        })

      assert errors_on(cs)[:metadata]
    end

    test "accepts valid metadata map" do
      cs =
        Notification.create_changeset(%Notification{}, %{
          title: "Test",
          category: :webhook,
          metadata: %{"key" => "value", "nested" => %{"a" => 1}}
        })

      assert cs.valid?
    end
  end

  # ──────────────────────────────────────────────
  # update_changeset/2
  # ──────────────────────────────────────────────

  describe "update_changeset/2" do
    test "allows status transition" do
      notification = %Notification{status: :unread}

      cs = Notification.update_changeset(notification, %{status: :read})
      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :status) == :read
    end

    test "auto-sets read_at when transitioning to :read" do
      notification = %Notification{status: :unread, read_at: nil}

      cs = Notification.update_changeset(notification, %{status: :read})
      assert Ecto.Changeset.get_change(cs, :read_at)
    end

    test "does not overwrite existing read_at when transitioning to :read" do
      existing_time = ~U[2026-01-01 00:00:00.000000Z]
      notification = %Notification{status: :unread, read_at: existing_time}

      cs = Notification.update_changeset(notification, %{status: :read})
      refute Ecto.Changeset.get_change(cs, :read_at)
    end

    test "does not set read_at for non-:read status changes" do
      notification = %Notification{status: :unread, read_at: nil}

      cs = Notification.update_changeset(notification, %{status: :dismissed})
      refute Ecto.Changeset.get_change(cs, :read_at)
    end

    test "does not allow changing immutable create fields" do
      notification = %Notification{title: "Original", category: :webhook}

      cs =
        Notification.update_changeset(notification, %{
          title: "Changed",
          category: :experiment,
          body: "New body"
        })

      refute Ecto.Changeset.get_change(cs, :title)
      refute Ecto.Changeset.get_change(cs, :category)
      refute Ecto.Changeset.get_change(cs, :body)
    end
  end
end
