defmodule MonkeyClawWeb.EndpointTest do
  use MonkeyClawWeb.ConnCase, async: true

  # Must match the :length in Plug.Parsers (endpoint.ex)
  @max_body_length 1_000_000

  describe "Plug.Parsers body size limit" do
    test "rejects request body exceeding 1 MB", %{conn: conn} do
      oversized = String.duplicate("a", @max_body_length + 1)

      # In production, Cowboy/Bandit catches this and returns 413 via
      # the Plug.Exception protocol. In test mode, the exception
      # propagates — assert_raise is the idiomatic verification.
      assert_raise Plug.Parsers.RequestTooLargeError, fn ->
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/", oversized)
      end
    end

    test "accepts request body within 1 MB limit", %{conn: conn} do
      body = Jason.encode!(%{"data" => "ok"})

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/", body)

      # Parser accepted the body — no 413.
      # Route returns whatever the router decides, but NOT 413.
      refute conn.status == 413
    end
  end
end
