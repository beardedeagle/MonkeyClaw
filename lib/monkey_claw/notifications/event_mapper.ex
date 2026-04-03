defmodule MonkeyClaw.Notifications.EventMapper do
  @moduledoc """
  Maps telemetry events to notification attributes.

  Pure functions that translate a telemetry event name and metadata
  into the attributes needed to create a `Notification`. Each
  supported event has a dedicated mapper clause that extracts the
  workspace context, determines category/severity, and builds a
  human-readable title and body.

  ## Workspace Resolution

  Different events carry workspace context in different ways:

    * Webhook events: `endpoint_id` in metadata → DB lookup
    * Experiment events: `experiment_id` in metadata → DB lookup
    * Agent bridge events: `session_id` in metadata (IS the workspace ID)

  When workspace context cannot be determined, the mapper returns
  `:skip` and no notification is created.

  ## Severity Ordering

  Severity is used for rule filtering. The ordering is:

      :info < :warning < :error

  ## Design

  This is NOT a process. All functions are pure (except workspace
  lookups, which are reads). The module is called by the
  NotificationRouter GenServer in its own process context.
  """

  alias MonkeyClaw.Notifications.Notification
  alias MonkeyClaw.Webhooks

  @type notification_attrs :: %{
          workspace_id: String.t(),
          title: String.t(),
          body: String.t() | nil,
          category: Notification.category(),
          severity: Notification.severity(),
          metadata: map(),
          source_id: String.t() | nil,
          source_type: String.t() | nil
        }

  @type map_result :: {:ok, notification_attrs()} | :skip

  @severity_levels %{info: 0, warning: 1, error: 2}

  @doc """
  Map a telemetry event to notification attributes.

  Returns `{:ok, attrs}` if the event can be mapped, or `:skip`
  if the event lacks sufficient context (e.g., no workspace ID).
  """
  @spec map_event([atom()], map(), map()) :: map_result()
  def map_event(event, measurements, metadata)

  # ── Webhook Events ──────────────────────────────────────────

  def map_event(
        [:monkey_claw, :webhook, :received],
        _measurements,
        %{endpoint_id: endpoint_id, source: source, event_type: event_type}
      ) do
    with {:ok, workspace_id} <- resolve_webhook_workspace(endpoint_id) do
      {:ok,
       %{
         workspace_id: workspace_id,
         title: "Webhook received: #{event_type}",
         body: "#{source} webhook event '#{event_type}' accepted and dispatched.",
         category: :webhook,
         severity: :info,
         metadata: %{
           "endpoint_id" => endpoint_id,
           "source" => to_string(source),
           "event_type" => event_type
         },
         source_id: endpoint_id,
         source_type: "webhook_endpoint"
       }}
    end
  end

  def map_event(
        [:monkey_claw, :webhook, :rejected],
        _measurements,
        %{status: status} = metadata
      ) do
    # Rejected webhooks may not have workspace context (rejection
    # can happen before endpoint lookup). These become system-level
    # notifications only if an endpoint_id is present.
    case Map.get(metadata, :endpoint_id) do
      nil ->
        :skip

      endpoint_id ->
        with {:ok, workspace_id} <- resolve_webhook_workspace(endpoint_id) do
          {:ok,
           %{
             workspace_id: workspace_id,
             title: "Webhook rejected (#{status})",
             body: "A webhook request was rejected with HTTP #{status}.",
             category: :webhook,
             severity: :warning,
             metadata: %{"status" => status, "endpoint_id" => endpoint_id},
             source_id: endpoint_id,
             source_type: "webhook_endpoint"
           }}
        end
    end
  end

  def map_event(
        [:monkey_claw, :webhook, :dispatched],
        _measurements,
        %{endpoint_id: endpoint_id, event_type: event_type}
      ) do
    with {:ok, workspace_id} <- resolve_webhook_workspace(endpoint_id) do
      {:ok,
       %{
         workspace_id: workspace_id,
         title: "Webhook dispatched: #{event_type}",
         body: "Event '#{event_type}' dispatched to agent workflow.",
         category: :webhook,
         severity: :info,
         metadata: %{"endpoint_id" => endpoint_id, "event_type" => event_type},
         source_id: endpoint_id,
         source_type: "webhook_endpoint"
       }}
    end
  end

  # ── Experiment Events ───────────────────────────────────────

  def map_event(
        [:monkey_claw, :experiment, :completed],
        _measurements,
        %{experiment_id: experiment_id, strategy: strategy, decision: decision}
      ) do
    with {:ok, workspace_id} <- resolve_experiment_workspace(experiment_id) do
      {:ok,
       %{
         workspace_id: workspace_id,
         title: "Experiment completed: #{decision}",
         body:
           "Experiment #{short_id(experiment_id)} finished with decision '#{decision}' using #{strategy} strategy.",
         category: :experiment,
         severity: :info,
         metadata: %{
           "experiment_id" => experiment_id,
           "strategy" => strategy,
           "decision" => decision
         },
         source_id: experiment_id,
         source_type: "experiment"
       }}
    end
  end

  def map_event(
        [:monkey_claw, :experiment, :rollback],
        _measurements,
        %{experiment_id: experiment_id, strategy: strategy, iteration: iteration}
      ) do
    with {:ok, workspace_id} <- resolve_experiment_workspace(experiment_id) do
      {:ok,
       %{
         workspace_id: workspace_id,
         title: "Experiment rollback at iteration #{iteration}",
         body:
           "Experiment #{short_id(experiment_id)} rolled back at iteration #{iteration} (#{strategy} strategy).",
         category: :experiment,
         severity: :warning,
         metadata: %{
           "experiment_id" => experiment_id,
           "strategy" => strategy,
           "iteration" => iteration
         },
         source_id: experiment_id,
         source_type: "experiment"
       }}
    end
  end

  # ── Agent Bridge Events ─────────────────────────────────────

  def map_event(
        [:monkey_claw, :agent_bridge, :session, :exception],
        _measurements,
        %{session_id: session_id} = metadata
      ) do
    {:ok,
     %{
       workspace_id: session_id,
       title: "Agent session exception",
       body:
         "Session #{short_id(session_id)} encountered an exception: #{format_reason(metadata)}",
       category: :session,
       severity: :error,
       metadata: %{
         "session_id" => session_id,
         "kind" => to_string(Map.get(metadata, :kind, :error))
       },
       source_id: session_id,
       source_type: "session"
     }}
  end

  def map_event(
        [:monkey_claw, :agent_bridge, :query, :exception],
        _measurements,
        %{session_id: session_id} = metadata
      ) do
    {:ok,
     %{
       workspace_id: session_id,
       title: "Agent query exception",
       body: "A query in session #{short_id(session_id)} failed: #{format_reason(metadata)}",
       category: :session,
       severity: :error,
       metadata: %{
         "session_id" => session_id,
         "kind" => to_string(Map.get(metadata, :kind, :error))
       },
       source_id: session_id,
       source_type: "session"
     }}
  end

  # ── Agent Activity Events (user should see these everywhere) ─

  def map_event(
        [:monkey_claw, :agent_bridge, :query, :stop],
        %{duration: duration},
        %{session_id: session_id}
      ) do
    duration_ms = System.convert_time_unit(duration, :native, :millisecond)

    {:ok,
     %{
       workspace_id: session_id,
       title: "Agent query completed",
       body: "Query finished in #{duration_ms}ms.",
       category: :session,
       severity: :info,
       metadata: %{"session_id" => session_id, "duration_ms" => duration_ms},
       source_id: session_id,
       source_type: "session"
     }}
  end

  def map_event(
        [:monkey_claw, :agent_bridge, :stream, :stop],
        %{duration: duration},
        %{session_id: session_id}
      ) do
    duration_ms = System.convert_time_unit(duration, :native, :millisecond)

    {:ok,
     %{
       workspace_id: session_id,
       title: "Agent response complete",
       body: "Streaming response finished in #{duration_ms}ms.",
       category: :session,
       severity: :info,
       metadata: %{"session_id" => session_id, "duration_ms" => duration_ms},
       source_id: session_id,
       source_type: "session"
     }}
  end

  # ── Channel Events ────────────────────────────────────────────

  def map_event(
        [:monkey_claw, :channel, :message, :inbound],
        _measurements,
        %{adapter_type: adapter_type, workspace_id: workspace_id, channel_config_id: config_id}
      ) do
    {:ok,
     %{
       workspace_id: workspace_id,
       title: "Message received via #{adapter_type}",
       body: "A new message arrived from the #{adapter_type} channel.",
       category: :channel,
       severity: :info,
       metadata: %{
         "adapter_type" => to_string(adapter_type),
         "channel_config_id" => config_id
       },
       source_id: config_id,
       source_type: "channel"
     }}
  end

  def map_event(
        [:monkey_claw, :channel, :message, :outbound],
        _measurements,
        %{adapter_type: adapter_type, workspace_id: workspace_id, channel_config_id: config_id}
      ) do
    {:ok,
     %{
       workspace_id: workspace_id,
       title: "Message sent via #{adapter_type}",
       body: "A response was delivered to the #{adapter_type} channel.",
       category: :channel,
       severity: :info,
       metadata: %{
         "adapter_type" => to_string(adapter_type),
         "channel_config_id" => config_id
       },
       source_id: config_id,
       source_type: "channel"
     }}
  end

  def map_event(
        [:monkey_claw, :channel, :delivery, :failed],
        _measurements,
        %{adapter_type: adapter_type, workspace_id: workspace_id} = metadata
      ) do
    {:ok,
     %{
       workspace_id: workspace_id,
       title: "Channel delivery failed: #{adapter_type}",
       body:
         "Failed to deliver message via #{adapter_type}: #{inspect(Map.get(metadata, :reason))}",
       category: :channel,
       severity: :error,
       metadata: %{
         "adapter_type" => to_string(adapter_type),
         "reason" => inspect(Map.get(metadata, :reason))
       },
       source_id: nil,
       source_type: "channel"
     }}
  end

  # ── Catch-all ───────────────────────────────────────────────

  def map_event(_event, _measurements, _metadata), do: :skip

  # ── Severity Comparison ─────────────────────────────────────

  @doc """
  Check if a severity level meets or exceeds the minimum threshold.

  Returns `true` if `severity >= min_severity` in the ordering
  `:info` < `:warning` < `:error`.

  ## Examples

      iex> severity_meets_threshold?(:warning, :info)
      true

      iex> severity_meets_threshold?(:info, :warning)
      false
  """
  @spec severity_meets_threshold?(Notification.severity(), Notification.severity()) :: boolean()
  def severity_meets_threshold?(severity, min_severity) do
    Map.get(@severity_levels, severity, 0) >= Map.get(@severity_levels, min_severity, 0)
  end

  # ── Private ─────────────────────────────────────────────────

  @spec resolve_webhook_workspace(String.t()) :: {:ok, String.t()} | :skip
  defp resolve_webhook_workspace(endpoint_id) do
    case Webhooks.get_endpoint(endpoint_id) do
      {:ok, endpoint} -> {:ok, endpoint.workspace_id}
      {:error, _} -> :skip
    end
  end

  @spec resolve_experiment_workspace(String.t()) :: {:ok, String.t()} | :skip
  defp resolve_experiment_workspace(experiment_id) do
    alias MonkeyClaw.Experiments

    case Experiments.get_experiment(experiment_id) do
      {:ok, experiment} -> {:ok, experiment.workspace_id}
      {:error, _} -> :skip
    end
  end

  defp short_id(id) when is_binary(id) and byte_size(id) >= 8 do
    String.slice(id, 0, 8)
  end

  defp short_id(id) when is_binary(id), do: id

  defp format_reason(%{reason: reason}), do: inspect(reason, limit: 100)
  defp format_reason(%{kind: kind}), do: to_string(kind)
  defp format_reason(_metadata), do: "unknown"
end
