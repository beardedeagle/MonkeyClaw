defmodule MonkeyClaw.Notifications.NotificationRuleTest do
  use MonkeyClaw.ChangesetCase, async: true

  alias MonkeyClaw.Notifications.NotificationRule

  # ──────────────────────────────────────────────
  # create_changeset/2
  # ──────────────────────────────────────────────

  describe "create_changeset/2" do
    test "valid attrs produce a valid changeset" do
      cs =
        %NotificationRule{}
        |> NotificationRule.create_changeset(%{
          name: "Webhook alerts",
          event_pattern: "monkey_claw.webhook.received",
          channel: :in_app,
          min_severity: :info
        })

      assert cs.valid?
    end

    test "requires name and event_pattern" do
      cs = NotificationRule.create_changeset(%NotificationRule{}, %{})

      errors = errors_on(cs)
      assert errors[:name]
      assert errors[:event_pattern]
    end

    test "validates name length (1–100)" do
      cs_empty =
        NotificationRule.create_changeset(%NotificationRule{}, %{
          name: "",
          event_pattern: "monkey_claw.webhook.received"
        })

      assert errors_on(cs_empty)[:name]

      cs_long =
        NotificationRule.create_changeset(%NotificationRule{}, %{
          name: String.duplicate("a", 101),
          event_pattern: "monkey_claw.webhook.received"
        })

      assert errors_on(cs_long)[:name]
    end

    test "validates event_pattern against allowlist" do
      for pattern <- NotificationRule.valid_event_patterns() do
        cs =
          NotificationRule.create_changeset(%NotificationRule{}, %{
            name: "Rule",
            event_pattern: pattern
          })

        assert cs.valid?, "expected pattern #{pattern} to be valid"
      end

      cs =
        NotificationRule.create_changeset(%NotificationRule{}, %{
          name: "Rule",
          event_pattern: "monkey_claw.unknown.event"
        })

      assert errors_on(cs)[:event_pattern]
    end

    test "validates channel enum" do
      for ch <- [:in_app, :email, :all] do
        cs =
          NotificationRule.create_changeset(%NotificationRule{}, %{
            name: "Rule",
            event_pattern: "monkey_claw.webhook.received",
            channel: ch
          })

        assert cs.valid?, "expected channel #{ch} to be valid"
      end

      cs =
        NotificationRule.create_changeset(%NotificationRule{}, %{
          name: "Rule",
          event_pattern: "monkey_claw.webhook.received",
          channel: :sms
        })

      assert errors_on(cs)[:channel]
    end

    test "validates min_severity enum" do
      for sev <- [:info, :warning, :error] do
        cs =
          NotificationRule.create_changeset(%NotificationRule{}, %{
            name: "Rule",
            event_pattern: "monkey_claw.webhook.received",
            min_severity: sev
          })

        assert cs.valid?, "expected severity #{sev} to be valid"
      end
    end

    test "defaults enabled to true, channel to :in_app, min_severity to :info" do
      cs =
        NotificationRule.create_changeset(%NotificationRule{}, %{
          name: "Rule",
          event_pattern: "monkey_claw.webhook.received"
        })

      assert Ecto.Changeset.get_field(cs, :enabled) == true
      assert Ecto.Changeset.get_field(cs, :channel) == :in_app
      assert Ecto.Changeset.get_field(cs, :min_severity) == :info
    end
  end

  # ──────────────────────────────────────────────
  # update_changeset/2
  # ──────────────────────────────────────────────

  describe "update_changeset/2" do
    test "allows updating name, channel, enabled, min_severity" do
      rule = %NotificationRule{
        name: "Original",
        event_pattern: "monkey_claw.webhook.received",
        channel: :in_app,
        enabled: true,
        min_severity: :info
      }

      cs =
        NotificationRule.update_changeset(rule, %{
          name: "Updated",
          channel: :email,
          enabled: false,
          min_severity: :warning
        })

      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :name) == "Updated"
      assert Ecto.Changeset.get_change(cs, :channel) == :email
      assert Ecto.Changeset.get_change(cs, :enabled) == false
      assert Ecto.Changeset.get_change(cs, :min_severity) == :warning
    end

    test "cannot change event_pattern after creation" do
      rule = %NotificationRule{
        name: "Rule",
        event_pattern: "monkey_claw.webhook.received"
      }

      cs =
        NotificationRule.update_changeset(rule, %{
          event_pattern: "monkey_claw.experiment.completed"
        })

      refute Ecto.Changeset.get_change(cs, :event_pattern)
    end

    test "validates name length on update" do
      rule = %NotificationRule{name: "Rule"}

      cs = NotificationRule.update_changeset(rule, %{name: String.duplicate("a", 101)})
      assert errors_on(cs)[:name]
    end
  end

  # ──────────────────────────────────────────────
  # valid_event_patterns/0
  # ──────────────────────────────────────────────

  describe "valid_event_patterns/0" do
    test "returns a non-empty list of strings" do
      patterns = NotificationRule.valid_event_patterns()
      assert is_list(patterns)
      assert patterns != []
      assert Enum.all?(patterns, &is_binary/1)
    end

    test "all patterns follow the dot-separated naming convention" do
      for pattern <- NotificationRule.valid_event_patterns() do
        parts = String.split(pattern, ".")
        assert length(parts) >= 3, "pattern #{pattern} should have at least 3 segments"
        assert hd(parts) == "monkey_claw", "pattern #{pattern} should start with monkey_claw"
      end
    end
  end
end
