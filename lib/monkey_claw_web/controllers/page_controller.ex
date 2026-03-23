defmodule MonkeyClawWeb.PageController do
  @moduledoc """
  Fallback controller for static page routes.

  Provides a `home/2` action that renders the default landing page
  template. Currently unused — `/` routes to `DashboardLive` — but
  retained for future static page needs.
  """
  use MonkeyClawWeb, :controller

  @doc "Renders the home page template."
  def home(conn, _params) do
    render(conn, :home)
  end
end
