defmodule MonkeyClawWeb.DashboardLive do
  @moduledoc """
  LiveView for the dashboard landing page.

  Displays at-a-glance system information including the number of active
  agent sessions and the list of configured backends.
  """

  use MonkeyClawWeb, :live_view

  alias MonkeyClaw.AgentBridge

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Dashboard")
      |> assign(:active_sessions, AgentBridge.session_count())
      |> assign(:backends, AgentBridge.backends())

    {:ok, socket, layout: {MonkeyClawWeb.Layouts, :app}}
  end
end
