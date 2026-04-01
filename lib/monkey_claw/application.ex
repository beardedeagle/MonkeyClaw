defmodule MonkeyClaw.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Initialize BeamAgent ETS table ownership before any SDK calls.
    # Hardened mode (the default) uses protected tables with write
    # proxying through shard owner processes — process-isolated write
    # control. Must happen before the supervision tree starts, since
    # SessionSupervisor children will touch BeamAgent ETS tables.
    :ok = :beam_agent_table_owner.init()

    children = [
      MonkeyClawWeb.Telemetry,
      MonkeyClaw.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:monkey_claw, :ecto_repos), skip: skip_migrations?()},
      {DNSCluster, query: Application.get_env(:monkey_claw, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: MonkeyClaw.PubSub},
      # AgentBridge: session registry and supervisor
      {Registry, keys: :unique, name: MonkeyClaw.AgentBridge.SessionRegistry},
      MonkeyClaw.AgentBridge.SessionSupervisor,
      # Start to serve requests, typically the last entry
      MonkeyClawWeb.Endpoint
    ]

    # Compile extension pipelines from config before serving requests.
    # Pure config read — no processes or DB access required.
    MonkeyClaw.Extensions.compile_pipelines()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: MonkeyClaw.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    MonkeyClawWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations? do
    # By default, sqlite migrations are run when using a release
    System.get_env("RELEASE_NAME") == nil
  end
end
