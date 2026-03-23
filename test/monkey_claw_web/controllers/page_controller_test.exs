defmodule MonkeyClawWeb.PageControllerTest do
  use MonkeyClawWeb.ConnCase

  test "GET / renders the dashboard", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "MonkeyClaw"
  end

  test "GET /chat renders the chat interface", %{conn: conn} do
    conn = get(conn, ~p"/chat")
    assert html_response(conn, 200) =~ "MonkeyClaw"
  end
end
