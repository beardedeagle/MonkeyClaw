defmodule MonkeyClawWeb.Plugs.ContentSecurityPolicyTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias MonkeyClawWeb.Plugs.ContentSecurityPolicy

  describe "call/2 — application routes" do
    test "sets CSP header with nonce" do
      conn =
        conn(:get, "/chat")
        |> ContentSecurityPolicy.call(ContentSecurityPolicy.init([]))

      [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "default-src 'self'"
      assert csp =~ ~r/script-src 'self' 'nonce-[A-Za-z0-9+\/=]+'/
      assert csp =~ "style-src 'self' 'unsafe-inline'"
      assert csp =~ "connect-src 'self'"
      assert csp =~ "frame-src 'none'"
      assert csp =~ "object-src 'none'"
      assert csp =~ "base-uri 'self'"
    end

    test "assigns csp_nonce to conn" do
      conn =
        conn(:get, "/")
        |> ContentSecurityPolicy.call(ContentSecurityPolicy.init([]))

      assert is_binary(conn.assigns.csp_nonce)
      assert byte_size(conn.assigns.csp_nonce) > 0
    end

    test "nonce in header matches nonce in assigns" do
      conn =
        conn(:get, "/chat")
        |> ContentSecurityPolicy.call(ContentSecurityPolicy.init([]))

      nonce = conn.assigns.csp_nonce
      [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "nonce-#{nonce}"
    end

    test "generates unique nonce per request" do
      opts = ContentSecurityPolicy.init([])

      conn1 = conn(:get, "/") |> ContentSecurityPolicy.call(opts)
      conn2 = conn(:get, "/") |> ContentSecurityPolicy.call(opts)

      refute conn1.assigns.csp_nonce == conn2.assigns.csp_nonce
    end
  end

  # Dev route bypass is only compiled when dev_routes: true.
  # These tests mirror that compile-time gate.
  if Application.compile_env(:monkey_claw, :dev_routes) do
    describe "call/2 — dev routes" do
      test "skips CSP header for /dev paths" do
        conn =
          conn(:get, "/dev/dashboard")
          |> ContentSecurityPolicy.call(ContentSecurityPolicy.init([]))

        assert get_resp_header(conn, "content-security-policy") == []
      end

      test "assigns nil csp_nonce for /dev paths" do
        conn =
          conn(:get, "/dev/mailbox")
          |> ContentSecurityPolicy.call(ContentSecurityPolicy.init([]))

        assert conn.assigns.csp_nonce == nil
      end

      test "skips CSP header for bare /dev path" do
        conn =
          conn(:get, "/dev")
          |> ContentSecurityPolicy.call(ContentSecurityPolicy.init([]))

        assert get_resp_header(conn, "content-security-policy") == []
        assert conn.assigns.csp_nonce == nil
      end

      test "does NOT skip CSP for /dev-prefixed non-dev paths" do
        conn =
          conn(:get, "/devices")
          |> ContentSecurityPolicy.call(ContentSecurityPolicy.init([]))

        [csp] = get_resp_header(conn, "content-security-policy")
        assert csp =~ "default-src 'self'"
        assert is_binary(conn.assigns.csp_nonce)
      end
    end
  end

  describe "call/2 — dev paths without dev_routes" do
    # Regardless of dev_routes config, /dev-prefixed non-dev paths
    # must always receive a full CSP header.
    test "applies CSP to /dev-prefixed non-dev paths" do
      conn =
        conn(:get, "/devices")
        |> ContentSecurityPolicy.call(ContentSecurityPolicy.init([]))

      [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "default-src 'self'"
      assert is_binary(conn.assigns.csp_nonce)
    end
  end

  describe "generate_nonce/0" do
    test "returns a base64-encoded string" do
      nonce = ContentSecurityPolicy.generate_nonce()

      assert is_binary(nonce)
      assert {:ok, _} = Base.decode64(nonce, padding: false)
    end

    test "generates 16 bytes of entropy (22 base64 chars)" do
      nonce = ContentSecurityPolicy.generate_nonce()
      {:ok, raw} = Base.decode64(nonce, padding: false)

      assert byte_size(raw) == 16
    end

    test "generates unique values" do
      nonces = for _ <- 1..100, do: ContentSecurityPolicy.generate_nonce()

      assert length(Enum.uniq(nonces)) == 100
    end
  end

  describe "build_policy/1" do
    test "includes all required directives" do
      policy = ContentSecurityPolicy.build_policy("test-nonce")

      assert policy =~ "default-src 'self'"
      assert policy =~ "script-src 'self' 'nonce-test-nonce'"
      assert policy =~ "style-src 'self' 'unsafe-inline'"
      assert policy =~ "img-src 'self' data:"
      assert policy =~ "font-src 'self'"
      assert policy =~ "connect-src 'self'"
      assert policy =~ "frame-src 'none'"
      assert policy =~ "object-src 'none'"
      assert policy =~ "base-uri 'self'"
    end

    test "separates directives with semicolons" do
      policy = ContentSecurityPolicy.build_policy("n")
      parts = String.split(policy, "; ")

      assert length(parts) == 9
    end
  end
end
