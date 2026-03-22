defmodule MonkeyClawWeb.PageControllerTest do
  use MonkeyClawWeb.ConnCase

  test "GET / redirects to LiveView chat", %{conn: conn} do
    conn = get(conn, ~p"/")
    # LiveView routes return a 200 with the LiveView mount
    assert html_response(conn, 200) =~ "MonkeyClaw"
  end
end
