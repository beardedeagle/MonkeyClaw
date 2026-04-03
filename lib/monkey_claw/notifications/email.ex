defmodule MonkeyClaw.Notifications.Email do
  @moduledoc """
  Builds Swoosh email structs for notification delivery.

  Pure functions that construct `Swoosh.Email` structs from
  notification data. No side effects — actual delivery is
  performed by `MonkeyClaw.Mailer` in the NotificationRouter.

  ## Email Configuration

  The sender and recipient addresses are read from application
  config at call time:

      config :monkey_claw, MonkeyClaw.Notifications.Email,
        from: {"MonkeyClaw", "notifications@example.com"},
        to: "user@example.com"

  If not configured, emails cannot be built and `build/1` returns
  `{:error, :not_configured}`.

  ## Design

  This is NOT a process. Pure email construction functions.
  """

  import Swoosh.Email

  alias MonkeyClaw.Notifications.Notification

  @type build_result :: {:ok, Swoosh.Email.t()} | {:error, :not_configured}

  @doc """
  Build a notification email.

  Constructs a `Swoosh.Email` struct from a notification record.
  Returns `{:error, :not_configured}` if sender or recipient
  addresses are not configured.

  ## Examples

      {:ok, email} = Email.build(notification)
      MonkeyClaw.Mailer.deliver(email)
  """
  @spec build(Notification.t()) :: build_result()
  def build(%Notification{} = notification) do
    config = Application.get_env(:monkey_claw, __MODULE__, [])
    from_addr = Keyword.get(config, :from)
    to_addr = Keyword.get(config, :to)

    case {from_addr, to_addr} do
      {nil, _} -> {:error, :not_configured}
      {_, nil} -> {:error, :not_configured}
      {from, to} -> {:ok, build_email(notification, from, to)}
    end
  end

  # ── Private ─────────────────────────────────────────────────

  @spec build_email(Notification.t(), Swoosh.Email.address(), Swoosh.Email.address()) ::
          Swoosh.Email.t()
  defp build_email(%Notification{} = notification, from, to) do
    new()
    |> to(to)
    |> from(from)
    |> subject(email_subject(notification))
    |> text_body(email_body(notification))
  end

  defp email_subject(%Notification{severity: severity, title: title}) do
    prefix = severity_prefix(severity)
    "[MonkeyClaw#{prefix}] #{title}"
  end

  defp email_body(%Notification{} = notification) do
    body_text = notification.body || "(no details)"

    """
    #{notification.title}

    #{body_text}

    Category: #{notification.category}
    Severity: #{notification.severity}
    Time: #{format_time(notification.inserted_at)}
    """
    |> String.trim()
  end

  defp severity_prefix(:error), do: " ERROR"
  defp severity_prefix(:warning), do: " Warning"
  defp severity_prefix(:info), do: ""

  defp format_time(nil), do: "N/A"

  defp format_time(%DateTime{} = dt) do
    DateTime.to_iso8601(dt)
  end
end
