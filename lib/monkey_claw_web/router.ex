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
    plug MonkeyClawWeb.Plugs.MTLSAudit
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug MonkeyClawWeb.Plugs.MTLSAudit
  end

  scope "/", MonkeyClawWeb do
    pipe_through :browser

    live "/", DashboardLive
    live "/chat", ChatLive
    live "/chat/:workspace_id", ChatLive
  end

  # Other scopes may use custom stacks.
  # scope "/api", MonkeyClawWeb do
  #   pipe_through :api
  # end

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
