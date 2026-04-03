defmodule MonkeyClawWeb.DashboardLive do
  @moduledoc """
  LiveView dashboard with auto-refreshing system metrics.

  Displays BEAM VM health, agent session status, extension hooks,
  and recent workspaces — refreshing every 5 seconds. Inspired by
  Phoenix LiveDashboard but focused on MonkeyClaw domain data.
  """

  use MonkeyClawWeb, :live_view

  alias MonkeyClaw.AgentBridge
  alias MonkeyClaw.Extensions
  alias MonkeyClaw.Workspaces

  @refresh_interval :timer.seconds(5)

  @impl true
  def mount(_params, _session, socket) do
    _ = if connected?(socket), do: schedule_refresh()

    {:ok, refresh_data(socket), layout: {MonkeyClawWeb.Layouts, :app}}
  end

  @impl true
  def handle_info(:refresh, socket) do
    schedule_refresh()
    {:noreply, refresh_data(socket)}
  end

  defp schedule_refresh do
    Process.send_after(self(), :refresh, @refresh_interval)
  end

  defp refresh_data(socket) do
    sessions = fetch_sessions()

    socket
    |> assign(:page_title, "Dashboard")
    |> assign(:system, system_metrics())
    |> assign(:sessions, sessions)
    |> assign(:session_count, length(sessions))
    |> assign(:backends, AgentBridge.backends())
    |> assign(:extensions, extension_info())
    |> assign(:workspaces, recent_workspaces())
  end

  # --- Data Fetching ---

  defp system_metrics do
    memory = :erlang.memory()
    {uptime_ms, _} = :erlang.statistics(:wall_clock)

    %{
      total_memory: memory[:total],
      process_memory: memory[:processes],
      atom_memory: memory[:atom],
      binary_memory: memory[:binary],
      ets_memory: memory[:ets],
      process_count: :erlang.system_info(:process_count),
      process_limit: :erlang.system_info(:process_limit),
      run_queue: :erlang.statistics(:run_queue),
      otp_release: :erlang.system_info(:otp_release) |> List.to_string(),
      elixir_version: System.version(),
      uptime_seconds: div(uptime_ms, 1000)
    }
  end

  defp fetch_sessions do
    AgentBridge.list_sessions()
    |> Enum.map(fn session_id ->
      case AgentBridge.session_info(session_id) do
        {:ok, info} -> info
        {:error, _} -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp extension_info do
    %{
      plugs: Extensions.list_plugs(),
      active_hooks: Extensions.active_hooks(),
      total_hooks: length(Extensions.Hook.all())
    }
  end

  defp recent_workspaces do
    Workspaces.list_workspaces()
    |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})
    |> Enum.take(5)
  end

  # --- Formatting Helpers ---

  @doc false
  def format_bytes(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824, 1)} GB"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 1)} MB"
      bytes >= 1_024 -> "#{Float.round(bytes / 1_024, 1)} KB"
      true -> "#{bytes} B"
    end
  end

  @doc false
  def format_uptime(seconds) when is_integer(seconds) do
    cond do
      seconds >= 86_400 ->
        days = div(seconds, 86_400)
        hours = seconds |> rem(86_400) |> div(3_600)
        "#{days}d #{hours}h"

      seconds >= 3_600 ->
        hours = div(seconds, 3_600)
        mins = seconds |> rem(3_600) |> div(60)
        "#{hours}h #{mins}m"

      seconds >= 60 ->
        mins = div(seconds, 60)
        secs = rem(seconds, 60)
        "#{mins}m #{secs}s"

      true ->
        "#{seconds}s"
    end
  end

  @doc false
  def format_number(n) when is_integer(n) and n < 0 do
    "-" <> format_number(abs(n))
  end

  def format_number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.join(",")
    |> String.reverse()
  end

  @doc false
  def time_ago(%DateTime{} = dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)
    format_uptime(diff) <> " ago"
  end

  def time_ago(_), do: "—"

  @doc false
  def status_color(:active), do: "badge-success"
  def status_color(:starting), do: "badge-warning"
  def status_color(:stopping), do: "badge-warning"
  def status_color(:stopped), do: "badge-ghost"
  def status_color(:terminated), do: "badge-error"
  def status_color(_), do: "badge-ghost"
end
