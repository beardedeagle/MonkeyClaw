defmodule MonkeyClaw.Notifications.Router do
  @moduledoc """
  GenServer that routes telemetry events to notifications.

  The Router subscribes to telemetry events and creates notifications
  based on workspace-scoped rules. It handles the full pipeline:

    1. Receive telemetry event (via cast from handler)
    2. Map event to notification attributes (EventMapper)
    3. Match against workspace rules (ETS cache)
    4. Check severity threshold
    5. Create notification (Ecto)
    6. Deliver via channels (PubSub, email)

  ## Process Justification

  A GenServer is the correct abstraction because the Router is:

    * **Lifecycle-bound** — telemetry handlers must be attached on start
      and detached on terminate
    * **Stateful** — holds the ETS table reference and cache refresh timer
    * **Single instance** — one router per node; MonkeyClaw is a
      single-user, single-instance application
    * **Async delivery** — telemetry handlers send casts to avoid
      blocking the emitting process

  ## Telemetry Handler Design

  Telemetry handlers run in the CALLER's process. To avoid blocking
  webhook requests, experiment runners, or agent sessions, the handler
  immediately casts to this GenServer. The GenServer then performs the
  (potentially slow) DB operations in its own process.

  ## Rule Caching

  Rules are cached in an ETS table (`MonkeyClaw.Notifications.RuleCache`)
  to avoid querying the database on every telemetry event. The cache is
  refreshed:

    * On startup
    * On a periodic timer (default: 60 seconds)
    * On demand via `refresh_cache/0`

  ## Configuration

      config :monkey_claw, :notification_cache_refresh_ms, 60_000

  ## Related Modules

    * `MonkeyClaw.Notifications` — Context module for persistence
    * `MonkeyClaw.Notifications.EventMapper` — Event → attrs translation
    * `MonkeyClaw.Notifications.Email` — Email builder
    * `MonkeyClaw.Notifications.Telemetry` — Notification telemetry emission
  """

  use GenServer

  require Logger

  alias MonkeyClaw.Mailer
  alias MonkeyClaw.Notifications
  alias MonkeyClaw.Notifications.Email
  alias MonkeyClaw.Notifications.EventMapper
  alias MonkeyClaw.Notifications.NotificationRule
  alias MonkeyClaw.Notifications.Telemetry, as: NotifTelemetry

  @default_cache_refresh_ms 60_000
  @ets_table MonkeyClaw.Notifications.RuleCache
  @handler_id "monkey_claw_notification_router"

  @type t :: %__MODULE__{
          timer_ref: reference() | nil,
          cache_refresh_ms: pos_integer(),
          attached_events: [[atom()]]
        }

  defstruct [:timer_ref, :cache_refresh_ms, attached_events: []]

  # ── Telemetry Event Registry ─────────────────────────────────
  # Maps dot-separated pattern strings to telemetry event names.
  # Only events listed here can be subscribed to via rules.

  @event_registry %{
    "monkey_claw.webhook.received" => [:monkey_claw, :webhook, :received],
    "monkey_claw.webhook.rejected" => [:monkey_claw, :webhook, :rejected],
    "monkey_claw.webhook.dispatched" => [:monkey_claw, :webhook, :dispatched],
    "monkey_claw.experiment.completed" => [:monkey_claw, :experiment, :completed],
    "monkey_claw.experiment.rollback" => [:monkey_claw, :experiment, :rollback],
    "monkey_claw.agent_bridge.session.exception" => [
      :monkey_claw,
      :agent_bridge,
      :session,
      :exception
    ],
    "monkey_claw.agent_bridge.query.exception" => [
      :monkey_claw,
      :agent_bridge,
      :query,
      :exception
    ]
  }

  # ── Client API ───────────────────────────────────────────────

  @doc """
  Start the NotificationRouter as a linked process.

  Registers as a named process under `__MODULE__` (single instance).

  ## Options

    * `:cache_refresh_ms` — Override the cache refresh interval
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Force a synchronous cache refresh.

  Reloads all enabled rules from the database and re-attaches
  telemetry handlers. Useful after creating or modifying rules.
  """
  @spec refresh_cache() :: :ok | {:error, :not_running}
  def refresh_cache do
    case Process.whereis(__MODULE__) do
      nil -> {:error, :not_running}
      pid -> GenServer.call(pid, :refresh_cache, 10_000)
    end
  end

  @doc """
  Initialize the ETS table for the rule cache.

  Called from `Application.start/2` before the supervision tree
  starts, so the table is owned by the application process (not
  the GenServer). This survives GenServer restarts.
  """
  @spec init_cache() :: :ok
  def init_cache do
    _ =
      if :ets.whereis(@ets_table) == :undefined do
        :ets.new(@ets_table, [:set, :public, :named_table, read_concurrency: true])
      end

    :ok
  end

  # ── GenServer Callbacks ──────────────────────────────────────

  @impl true
  @spec init(keyword()) :: {:ok, t()}
  def init(opts) when is_list(opts) do
    cache_refresh_ms =
      Keyword.get_lazy(opts, :cache_refresh_ms, fn ->
        Application.get_env(
          :monkey_claw,
          :notification_cache_refresh_ms,
          @default_cache_refresh_ms
        )
      end)

    if not is_integer(cache_refresh_ms) or cache_refresh_ms <= 0 do
      raise ArgumentError,
            "cache_refresh_ms must be a positive integer, got: #{inspect(cache_refresh_ms)}"
    end

    state = %__MODULE__{
      timer_ref: nil,
      cache_refresh_ms: cache_refresh_ms,
      attached_events: []
    }

    state = load_and_attach(state)
    {:ok, schedule_refresh(state)}
  end

  @impl true
  def handle_cast({:telemetry_event, event, measurements, metadata}, %__MODULE__{} = state) do
    handle_telemetry_event(event, measurements, metadata)
    {:noreply, state}
  end

  @impl true
  def handle_call(:refresh_cache, _from, %__MODULE__{} = state) do
    state = state |> cancel_timer() |> load_and_attach()
    {:reply, :ok, schedule_refresh(state)}
  end

  @impl true
  def handle_info(:refresh_cache, %__MODULE__{} = state) do
    state = %{state | timer_ref: nil} |> load_and_attach()
    {:noreply, schedule_refresh(state)}
  end

  def handle_info(msg, %__MODULE__{} = state) do
    Logger.debug("NotificationRouter received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %__MODULE__{} = state) do
    _ = detach_all(state)
    :ok
  end

  # ── Private — Cache and Attachment ──────────────────────────

  # Load rules from DB, update ETS cache, and re-attach telemetry handlers.
  defp load_and_attach(%__MODULE__{} = state) do
    state = detach_all(state)

    rules_by_pattern = load_rules()
    update_ets_cache(rules_by_pattern)
    attach_handlers(state, rules_by_pattern)
  end

  @spec load_rules() :: %{String.t() => [NotificationRule.t()]}
  defp load_rules do
    Notifications.list_enabled_rules_by_pattern()
  rescue
    error ->
      Logger.error(
        "NotificationRouter failed to load rules: #{Exception.format(:error, error, __STACKTRACE__)}"
      )

      %{}
  end

  defp update_ets_cache(rules_by_pattern) do
    # Clear and repopulate atomically (ETS ops are per-key atomic).
    :ets.delete_all_objects(@ets_table)

    Enum.each(rules_by_pattern, fn {pattern, rules} ->
      :ets.insert(@ets_table, {pattern, rules})
    end)
  end

  @spec attach_handlers(t(), %{String.t() => [NotificationRule.t()]}) :: t()
  defp attach_handlers(%__MODULE__{} = state, rules_by_pattern) do
    events_to_attach =
      rules_by_pattern
      |> Map.keys()
      |> Enum.flat_map(fn pattern ->
        case Map.get(@event_registry, pattern) do
          nil ->
            Logger.warning("NotificationRouter: unknown event pattern #{inspect(pattern)}")
            []

          event ->
            [event]
        end
      end)
      |> Enum.uniq()

    Enum.each(events_to_attach, fn event ->
      handler_id = "#{@handler_id}_#{Enum.join(event, ".")}"

      :telemetry.attach(
        handler_id,
        event,
        &telemetry_handler/4,
        nil
      )
    end)

    %{state | attached_events: events_to_attach}
  end

  @spec detach_all(t()) :: t()
  defp detach_all(%__MODULE__{attached_events: events} = state) do
    Enum.each(events, fn event ->
      handler_id = "#{@handler_id}_#{Enum.join(event, ".")}"
      :telemetry.detach(handler_id)
    end)

    %{state | attached_events: []}
  end

  # ── Private — Telemetry Handler ─────────────────────────────

  # This function runs in the CALLER's process (not the GenServer).
  # It immediately casts to the GenServer to avoid blocking.
  @spec telemetry_handler([atom()], map(), map(), nil) :: :ok
  defp telemetry_handler(event, measurements, metadata, _config) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      _pid -> GenServer.cast(__MODULE__, {:telemetry_event, event, measurements, metadata})
    end
  end

  # ── Private — Event Processing ──────────────────────────────

  @spec handle_telemetry_event([atom()], map(), map()) :: :ok
  defp handle_telemetry_event(event, measurements, metadata) do
    case EventMapper.map_event(event, measurements, metadata) do
      {:ok, attrs} ->
        process_mapped_event(event, attrs)

      :skip ->
        :ok
    end
  rescue
    error ->
      Logger.warning(
        "NotificationRouter event processing failed: #{Exception.format(:error, error, __STACKTRACE__)}"
      )

      :ok
  end

  @spec process_mapped_event([atom()], EventMapper.notification_attrs()) :: :ok
  defp process_mapped_event(event, attrs) do
    event_pattern = Enum.join(event, ".")

    rules = lookup_rules(event_pattern, attrs.workspace_id)

    Enum.each(rules, fn rule ->
      if EventMapper.severity_meets_threshold?(attrs.severity, rule.min_severity) do
        create_and_deliver(attrs, rule)
      end
    end)
  end

  @spec lookup_rules(String.t(), String.t()) :: [NotificationRule.t()]
  defp lookup_rules(event_pattern, workspace_id) do
    case :ets.lookup(@ets_table, event_pattern) do
      [{^event_pattern, rules}] ->
        Enum.filter(rules, &(&1.workspace_id == workspace_id))

      [] ->
        []
    end
  end

  @spec create_and_deliver(EventMapper.notification_attrs(), NotificationRule.t()) :: :ok
  defp create_and_deliver(attrs, %NotificationRule{} = rule) do
    notification_attrs = Map.drop(attrs, [:workspace_id])

    case Notifications.create_notification_by_workspace_id(attrs.workspace_id, notification_attrs) do
      {:ok, notification} ->
        NotifTelemetry.created(
          notification.id,
          notification.workspace_id,
          notification.category,
          notification.severity
        )

        deliver(notification, rule.channel)

      {:error, changeset} ->
        Logger.warning(
          "NotificationRouter failed to create notification: #{inspect(changeset.errors)}"
        )
    end

    :ok
  end

  # ── Private — Delivery ──────────────────────────────────────

  @spec deliver(Notifications.Notification.t(), NotificationRule.channel()) :: :ok
  defp deliver(notification, channel) do
    deliver_in_app(notification, channel)
    deliver_email(notification, channel)
    :ok
  end

  defp deliver_in_app(notification, channel) when channel in [:in_app, :all] do
    case Notifications.broadcast_created(notification) do
      :ok ->
        NotifTelemetry.delivered(
          notification.id,
          notification.workspace_id,
          notification.category,
          notification.severity,
          :in_app
        )

      {:error, reason} ->
        Logger.warning("NotificationRouter PubSub broadcast failed: #{inspect(reason)}")

        NotifTelemetry.delivery_failed(
          notification.id,
          notification.workspace_id,
          notification.category,
          notification.severity,
          :in_app
        )
    end
  end

  defp deliver_in_app(_notification, _channel), do: :ok

  defp deliver_email(notification, channel) when channel in [:email, :all] do
    _ = Task.Supervisor.start_child(MonkeyClaw.TaskSupervisor, fn ->
      case Email.build(notification) do
        {:ok, email} -> send_email(email, notification)
        {:error, :not_configured} ->
          Logger.debug("NotificationRouter email not configured — skipping email delivery")
      end
    end)

    :ok
  end

  defp deliver_email(_notification, _channel), do: :ok

  defp send_email(email, notification) do
    case Mailer.deliver(email) do
      {:ok, _} ->
        NotifTelemetry.delivered(
          notification.id,
          notification.workspace_id,
          notification.category,
          notification.severity,
          :email
        )

      {:error, reason} ->
        Logger.warning("NotificationRouter email delivery failed: #{inspect(reason)}")

        NotifTelemetry.delivery_failed(
          notification.id,
          notification.workspace_id,
          notification.category,
          notification.severity,
          :email
        )
    end
  end

  # ── Private — Timer Management ──────────────────────────────

  defp schedule_refresh(%__MODULE__{cache_refresh_ms: ms} = state) do
    ref = Process.send_after(self(), :refresh_cache, ms)
    %{state | timer_ref: ref}
  end

  defp cancel_timer(%__MODULE__{timer_ref: nil} = state), do: state

  defp cancel_timer(%__MODULE__{timer_ref: ref} = state) when is_reference(ref) do
    _remaining = Process.cancel_timer(ref, info: false)

    receive do
      :refresh_cache -> :ok
    after
      0 -> :ok
    end

    %{state | timer_ref: nil}
  end
end
