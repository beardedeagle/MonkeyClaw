defmodule MonkeyClawWeb.PageController do
  use MonkeyClawWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
