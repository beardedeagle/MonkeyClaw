defmodule MonkeyClaw.Mailer do
  @moduledoc """
  Email delivery for MonkeyClaw.

  Configured via the `:monkey_claw, MonkeyClaw.Mailer` application
  environment. Uses the Swoosh adapter specified in config (local
  mailbox in dev, SMTP or API-based adapter in prod).
  """
  use Swoosh.Mailer, otp_app: :monkey_claw
end
