defmodule MonkeyClawWeb.ErrorHTML do
  @moduledoc """
  This module is invoked by your endpoint in case of errors on HTML requests.

  See config/config.exs.
  """
  use MonkeyClawWeb, :html

  # If you want to customize your error pages,
  # uncomment the embed_templates/1 call below
  # and add pages to the error directory:
  #
  #   * lib/monkey_claw_web/controllers/error_html/404.html.heex
  #   * lib/monkey_claw_web/controllers/error_html/500.html.heex
  #
  # embed_templates "error_html/*"

  @doc """
  Renders an error page as plain text derived from the HTTP status.

  Returns the standard status message for the given template name
  (e.g., `"404.html"` becomes `"Not Found"`).
  """
  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
