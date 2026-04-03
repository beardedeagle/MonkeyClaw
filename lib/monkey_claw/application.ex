defmodule MonkeyClaw.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  alias MonkeyClaw.Notifications.Router, as: NotificationRouter
  alias MonkeyClaw.Skills.Cache, as: SkillsCache
  alias MonkeyClaw.Webhooks.RateLimiter

  @impl true
  def start(_type, _args) do
    # Initialize BeamAgent ETS table ownership before any SDK calls.
    # Hardened mode (the default) uses protected tables with write
    # proxying through shard owner processes — process-isolated write
    # control. Must happen before the supervision tree starts, since
    # SessionSupervisor children will touch BeamAgent ETS tables.
    :ok = :beam_agent_table_owner.init()

    # Initialize Skills ETS cache before supervision tree starts.
    # Skills cache is an application-owned ETS table (not a process)
    # used for low-latency per-workspace skill lookups.
    :ok = SkillsCache.init()

    # Initialize webhook rate limiter ETS table before supervision tree
    # starts. Uses atomic counters for lock-free concurrent rate checking.
    :ok = RateLimiter.init()

    # Initialize notification rule cache ETS table before supervision tree
    # starts. Application-owned table survives NotificationRouter restarts.
    :ok = NotificationRouter.init_cache()

    children =
      [
        MonkeyClawWeb.Telemetry,
        MonkeyClaw.Repo,
        {Ecto.Migrator,
         repos: Application.fetch_env!(:monkey_claw, :ecto_repos), skip: skip_migrations?()},
        {DNSCluster, query: Application.get_env(:monkey_claw, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: MonkeyClaw.PubSub},
        # AgentBridge: session registry and supervisor
        {Registry, keys: :unique, name: MonkeyClaw.AgentBridge.SessionRegistry},
        MonkeyClaw.AgentBridge.SessionSupervisor,
        # Experiments: registry, task supervisor, and runner supervisor.
        # Order matters — RunnerRegistry and TaskSupervisor must start
        # before the Supervisor, since Runner processes register themselves
        # and use TaskSupervisor for async agent queries.
        {Registry, keys: :unique, name: MonkeyClaw.Experiments.RunnerRegistry},
        {Task.Supervisor, name: MonkeyClaw.Experiments.TaskSupervisor},
        MonkeyClaw.Experiments.Supervisor,
        # LiveView async task supervisor for fire-and-forget operations
        # (e.g. set_model calls from ChatLive) that need crash isolation
        # without silently swallowing errors.
        {Task.Supervisor, name: MonkeyClaw.TaskSupervisor}
      ] ++
        maybe_child(MonkeyClaw.Notifications.Router, :start_notification_router) ++
        maybe_child(MonkeyClaw.Scheduling.Scheduler, :start_scheduler) ++
        maybe_child(MonkeyClaw.UserModeling.Observer, :start_observer) ++
        [
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

  # Include a child spec only when the config flag is not explicitly false.
  # Defaults to true (started) — test.exs sets these to false so tests
  # control GenServer lifecycle via start_supervised!/1.
  defp maybe_child(child_spec, config_key) do
    if Application.get_env(:monkey_claw, config_key, true) do
      [child_spec]
    else
      []
    end
  end
end
