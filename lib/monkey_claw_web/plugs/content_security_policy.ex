defmodule MonkeyClawWeb.Plugs.ContentSecurityPolicy do
  @moduledoc """
  Sets Content-Security-Policy header with a per-request nonce.

  Generates a cryptographically random nonce for each request and
  stores it in `conn.assigns[:csp_nonce]`. Templates use this nonce
  to allowlist inline `<script>` blocks while blocking injected
  scripts (XSS defense-in-depth on top of the Markdown sanitizer).

  ## Policy

    * `default-src 'self'` — same-origin only by default
    * `script-src 'self' 'nonce-<nonce>'` — bundled + nonced inline scripts
    * `style-src 'self' 'unsafe-inline'` — Tailwind/DaisyUI inline styles
    * `img-src 'self' data:` — self-hosted images + data URIs
    * `font-src 'self'` — self-hosted fonts only
    * `connect-src 'self'` — LiveView WebSocket connects to same origin
    * `frame-src 'none'` — no iframes
    * `object-src 'none'` — no plugins
    * `base-uri 'self'` — prevent `<base>` hijacking

  ## Dev Routes

  Requests to `/dev` and `/dev/…` paths (LiveDashboard, Swoosh
  mailbox) are skipped — those tools render their own inline scripts
  that cannot be nonced. The bypass matches `/dev` exactly and
  `/dev/` as a prefix to avoid disabling CSP on unrelated routes
  like `/devices`. Dev routes are only enabled when `dev_routes: true`.

  ## Usage in Templates

  Inline scripts must include the nonce attribute:

      <script nonce={@csp_nonce}>
        // allowed by CSP
      </script>

  Scripts loaded via `src=` from the same origin do not need a nonce.

  ## Design

  This is NOT a process. It is a stateless Plug that runs once per
  HTTP request in the `:browser` pipeline.
  """

  import Plug.Conn

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%{request_path: "/dev"} = conn, _opts) do
    assign(conn, :csp_nonce, nil)
  end

  def call(%{request_path: "/dev/" <> _} = conn, _opts) do
    assign(conn, :csp_nonce, nil)
  end

  def call(conn, _opts) do
    nonce = generate_nonce()

    conn
    |> assign(:csp_nonce, nonce)
    |> put_resp_header("content-security-policy", build_policy(nonce))
  end

  @doc false
  @spec generate_nonce() :: String.t()
  def generate_nonce do
    16
    |> :crypto.strong_rand_bytes()
    |> Base.encode64(padding: false)
  end

  @doc false
  @spec build_policy(String.t()) :: String.t()
  def build_policy(nonce) do
    [
      "default-src 'self'",
      "script-src 'self' 'nonce-#{nonce}'",
      "style-src 'self' 'unsafe-inline'",
      "img-src 'self' data:",
      "font-src 'self'",
      "connect-src 'self'",
      "frame-src 'none'",
      "object-src 'none'",
      "base-uri 'self'"
    ]
    |> Enum.join("; ")
  end
end
