defmodule MonkeyClaw.Notifications.NotificationRule do
  @moduledoc """
  Ecto schema for notification routing rules.

  A notification rule defines how telemetry events are routed to
  notification channels. Rules are workspace-scoped and determine:

    * Which events generate notifications (via `event_pattern`)
    * Where notifications are delivered (via `channel`)
    * Minimum severity threshold for delivery (via `min_severity`)

  ## Event Patterns

  Event patterns are dot-separated strings that correspond to
  telemetry event names. Examples:

    * `"monkey_claw.webhook.received"` — Webhook received events
    * `"monkey_claw.experiment.completed"` — Experiment completions
    * `"monkey_claw.agent_bridge.session.exception"` — Session crashes

  ## Channels

    * `:in_app` — PubSub broadcast to LiveView (real-time bell)
    * `:email` — Async email delivery via Swoosh
    * `:all` — Both in-app and email

  ## Severity Filtering

  The `min_severity` field acts as a threshold. A rule with
  `min_severity: :warning` will only fire for `:warning` and
  `:error` events, not `:info`.

  Severity ordering: `:info` < `:warning` < `:error`

  ## Uniqueness

  Each workspace can have at most one rule per event pattern,
  enforced by a composite unique index on `(workspace_id, event_pattern)`.

  ## Design

  This is NOT a process. Rules are data entities persisted in
  SQLite3 via Ecto. They are read by the NotificationRouter
  (cached in ETS) and managed through the Notifications context.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias MonkeyClaw.Workspaces.Workspace

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          workspace_id: Ecto.UUID.t() | nil,
          name: String.t() | nil,
          event_pattern: String.t() | nil,
          channel: channel() | nil,
          enabled: boolean(),
          min_severity: severity() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @type channel :: :in_app | :email | :all
  @type severity :: :info | :warning | :error

  @channels [:in_app, :email, :all]
  @severities [:info, :warning, :error]

  @create_fields [:name, :event_pattern, :channel, :enabled, :min_severity]
  @update_fields [:name, :channel, :enabled, :min_severity]

  @max_name_length 100
  @max_event_pattern_length 255

  # Allowed event patterns — only events with known mappers.
  # Prevents rules referencing events the router cannot handle.
  @valid_event_patterns [
    "monkey_claw.webhook.received",
    "monkey_claw.webhook.rejected",
    "monkey_claw.webhook.dispatched",
    "monkey_claw.experiment.completed",
    "monkey_claw.experiment.rollback",
    "monkey_claw.agent_bridge.session.exception",
    "monkey_claw.agent_bridge.query.exception",
    "monkey_claw.agent_bridge.query.stop",
    "monkey_claw.agent_bridge.stream.stop",
    "monkey_claw.channel.message.inbound",
    "monkey_claw.channel.message.outbound",
    "monkey_claw.channel.delivery.failed"
  ]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "notification_rules" do
    field :name, :string
    field :event_pattern, :string
    field :channel, Ecto.Enum, values: @channels, default: :in_app
    field :enabled, :boolean, default: true
    field :min_severity, Ecto.Enum, values: @severities, default: :info

    belongs_to :workspace, Workspace

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Returns the list of supported event patterns.

  Used by the NotificationRouter to validate that rules reference
  events the system can actually handle.
  """
  @spec valid_event_patterns() :: [String.t()]
  def valid_event_patterns, do: @valid_event_patterns

  @doc """
  Changeset for creating a new notification rule.

  Required fields: `:name`, `:event_pattern`.
  The `:workspace_id` is set via `Ecto.build_assoc/3`.

  ## Validation

    * Name: 1–100 characters
    * Event pattern: must be one of the supported patterns
    * Channel: one of #{inspect(@channels)}
    * Min severity: one of #{inspect(@severities)}
  """
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(%__MODULE__{} = rule, attrs) when is_map(attrs) do
    rule
    |> cast(attrs, @create_fields)
    |> validate_required([:name, :event_pattern])
    |> validate_length(:name, min: 1, max: @max_name_length)
    |> validate_length(:event_pattern, max: @max_event_pattern_length)
    |> validate_inclusion(:event_pattern, @valid_event_patterns)
    |> assoc_constraint(:workspace)
    |> unique_constraint([:workspace_id, :event_pattern])
  end

  @doc """
  Changeset for updating an existing notification rule.

  The `event_pattern` cannot be changed after creation — delete
  and recreate to change the pattern.
  """
  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(%__MODULE__{} = rule, attrs) when is_map(attrs) do
    rule
    |> cast(attrs, @update_fields)
    |> validate_length(:name, min: 1, max: @max_name_length)
  end
end
