defmodule MonkeyClawWeb.ErrorJSON do
  @moduledoc """
  This module is invoked by your endpoint in case of errors on JSON requests.

  See config/config.exs.
  """

  # If you want to customize a particular status code,
  # you may add your own clauses, such as:
  #
  # def render("500.json", _assigns) do
  #   %{errors: %{detail: "Internal Server Error"}}
  # end

  @doc """
  Renders an error response as JSON with the HTTP status message.

  Returns `%{errors: %{detail: message}}` where `message` is
  derived from the template name (e.g., `"404.json"` becomes
  `"Not Found"`).
  """
  def render(template, _assigns) do
    %{errors: %{detail: Phoenix.Controller.status_message_from_template(template)}}
  end
end
