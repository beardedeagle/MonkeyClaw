defmodule MonkeyClawWeb.Router do
  @moduledoc """
  Request routing for MonkeyClawWeb.

  Defines two pipelines — `:browser` for HTML/LiveView requests
  and `:api` for JSON endpoints. Both pipelines include
  `MTLSAudit` for client-certificate telemetry. Development-only
  routes expose Phoenix LiveDashboard and the Swoosh mailbox
  preview under `/dev`.
  """
  use MonkeyClawWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {MonkeyClawWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug MonkeyClawWeb.Plugs.ContentSecurityPolicy
    plug MonkeyClawWeb.Plugs.MTLSAudit
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug MonkeyClawWeb.Plugs.MTLSAudit
  end

  # Webhook ingress — JSON API for receiving external webhook deliveries.
  # Uses the :api pipeline (MTLSAudit in production). HMAC-SHA256
  # signature verification is handled by the controller, not a plug,
  # because verification requires both the raw body and the endpoint's
  # decrypted signing secret (database lookup).
  scope "/api/webhooks", MonkeyClawWeb do
    pipe_through :api

    post "/:endpoint_id", WebhookController, :receive
  end

  # Channel webhook ingress — receives inbound messages from external
  # platforms (Slack, Discord, Telegram). Each adapter verifies its
  # own request signature. The channel_config_id maps to the adapter
  # configuration used for verification and routing.
  scope "/api/channels", MonkeyClawWeb do
    pipe_through :api

    # Webhook verification challenge (GET) — used by platforms like
    # WhatsApp that verify ownership via a GET with a challenge token.
    get "/:channel_config_id/webhook", ChannelWebhookController, :verify
    post "/:channel_config_id/webhook", ChannelWebhookController, :receive
  end

  # Notification API — workspace-scoped notification management.
  scope "/api/workspaces/:workspace_id/notifications", MonkeyClawWeb do
    pipe_through :api

    get "/", NotificationController, :index
    patch "/:id/read", NotificationController, :mark_read
    patch "/:id/dismiss", NotificationController, :dismiss
    post "/read_all", NotificationController, :mark_all_read
  end

  # Notification rules API — workspace-scoped rule management.
  scope "/api/workspaces/:workspace_id/notification_rules", MonkeyClawWeb do
    pipe_through :api

    get "/", NotificationRuleController, :index
    post "/", NotificationRuleController, :create
    patch "/:id", NotificationRuleController, :update
    delete "/:id", NotificationRuleController, :delete
  end

  scope "/", MonkeyClawWeb do
    pipe_through :browser

    live_session :default, on_mount: [MonkeyClawWeb.NotificationHook] do
      live "/", DashboardLive
      live "/chat", ChatLive
      live "/chat/:workspace_id", ChatLive
      live "/channels", ChannelLive
      live "/channels/:workspace_id", ChannelLive
      live "/vault", VaultLive
      live "/vault/:workspace_id", VaultLive
    end
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development.
  # In production, all routes are gated by mTLS at the transport layer —
  # only connections with a valid client certificate reach any route.
  if Application.compile_env(:monkey_claw, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: MonkeyClawWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
