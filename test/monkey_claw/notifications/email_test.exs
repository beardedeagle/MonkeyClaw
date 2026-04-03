defmodule MonkeyClaw.Notifications.EmailTest do
  use ExUnit.Case, async: true

  alias MonkeyClaw.Notifications.Email
  alias MonkeyClaw.Notifications.Notification

  # Store original config and restore after each test.
  setup do
    original = Application.get_env(:monkey_claw, Email)

    on_exit(fn ->
      if original do
        Application.put_env(:monkey_claw, Email, original)
      else
        Application.delete_env(:monkey_claw, Email)
      end
    end)

    :ok
  end

  defp configure_email do
    Application.put_env(:monkey_claw, Email,
      from: {"MonkeyClaw", "notifications@monkeyclaw.dev"},
      to: "user@example.com"
    )
  end

  defp build_notification(overrides \\ %{}) do
    struct!(
      %Notification{
        id: Ecto.UUID.generate(),
        workspace_id: Ecto.UUID.generate(),
        title: "Test notification",
        body: "Something happened",
        category: :webhook,
        severity: :info,
        status: :unread,
        metadata: %{},
        inserted_at: ~U[2026-04-03 12:00:00.000000Z]
      },
      overrides
    )
  end

  # ──────────────────────────────────────────────
  # build/1
  # ──────────────────────────────────────────────

  describe "build/1" do
    test "returns {:ok, email} when configured" do
      configure_email()
      notification = build_notification()

      assert {:ok, email} = Email.build(notification)
      assert email.to == [{"", "user@example.com"}]
      assert email.from == {"MonkeyClaw", "notifications@monkeyclaw.dev"}
    end

    test "returns {:error, :not_configured} when from is missing" do
      Application.put_env(:monkey_claw, Email, to: "user@example.com")
      notification = build_notification()

      assert {:error, :not_configured} = Email.build(notification)
    end

    test "returns {:error, :not_configured} when to is missing" do
      Application.put_env(:monkey_claw, Email, from: {"MC", "noreply@mc.dev"})
      notification = build_notification()

      assert {:error, :not_configured} = Email.build(notification)
    end

    test "returns {:error, :not_configured} when no config at all" do
      Application.delete_env(:monkey_claw, Email)
      notification = build_notification()

      assert {:error, :not_configured} = Email.build(notification)
    end
  end

  # ──────────────────────────────────────────────
  # Subject severity prefix
  # ──────────────────────────────────────────────

  describe "subject severity prefix" do
    test "error severity adds ERROR prefix" do
      configure_email()
      notification = build_notification(%{severity: :error, title: "Crash"})

      {:ok, email} = Email.build(notification)
      assert email.subject == "[MonkeyClaw ERROR] Crash"
    end

    test "warning severity adds Warning prefix" do
      configure_email()
      notification = build_notification(%{severity: :warning, title: "Rejected"})

      {:ok, email} = Email.build(notification)
      assert email.subject == "[MonkeyClaw Warning] Rejected"
    end

    test "info severity has no prefix" do
      configure_email()
      notification = build_notification(%{severity: :info, title: "Received"})

      {:ok, email} = Email.build(notification)
      assert email.subject == "[MonkeyClaw] Received"
    end
  end

  # ──────────────────────────────────────────────
  # Body formatting
  # ──────────────────────────────────────────────

  describe "body formatting" do
    test "includes title, body, category, severity, and time" do
      configure_email()

      notification =
        build_notification(%{
          title: "Webhook received",
          body: "Push event accepted",
          category: :webhook,
          severity: :info
        })

      {:ok, email} = Email.build(notification)
      body = email.text_body

      assert body =~ "Webhook received"
      assert body =~ "Push event accepted"
      assert body =~ "webhook"
      assert body =~ "info"
      assert body =~ "2026-04-03"
    end

    test "handles nil body with placeholder" do
      configure_email()
      notification = build_notification(%{body: nil})

      {:ok, email} = Email.build(notification)
      assert email.text_body =~ "(no details)"
    end

    test "handles nil inserted_at" do
      configure_email()
      notification = build_notification(%{inserted_at: nil})

      {:ok, email} = Email.build(notification)
      assert email.text_body =~ "N/A"
    end
  end
end
