defmodule MonkeyClaw.Notifications.Notification do
  @moduledoc """
  Ecto schema for notification records.

  A notification represents a user-facing alert generated from a
  system event (webhook delivery, experiment completion, session
  error, etc.). Notifications are workspace-scoped and persist in
  SQLite3 for audit and history.

  ## Categories

    * `:webhook` — Events from the webhook ingress pipeline
    * `:experiment` — Experiment lifecycle events
    * `:session` — Agent session errors and exceptions
    * `:system` — System-level events (startup, config changes)

  ## Severity

    * `:info` — Informational (successful operations)
    * `:warning` — Warnings (rejections, rollbacks)
    * `:error` — Errors (exceptions, failures)

  ## Status

    * `:unread` — Not yet seen by the user
    * `:read` — Viewed but still in the list
    * `:dismissed` — Explicitly dismissed by the user

  ## Source Tracking

  Notifications optionally reference the entity that triggered them
  via `source_id` and `source_type`. This enables linking back to
  the originating webhook delivery, experiment, or session.

  ## Design

  This is NOT a process. Notifications are data entities persisted
  in SQLite3 via Ecto. They are created by the NotificationRouter
  and read by the web layer.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias MonkeyClaw.Workspaces.Workspace

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          workspace_id: Ecto.UUID.t() | nil,
          title: String.t() | nil,
          body: String.t() | nil,
          category: category() | nil,
          severity: severity() | nil,
          status: status() | nil,
          metadata: map(),
          source_id: String.t() | nil,
          source_type: String.t() | nil,
          read_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @type category :: :webhook | :experiment | :session | :system
  @type severity :: :info | :warning | :error
  @type status :: :unread | :read | :dismissed

  @categories [:webhook, :experiment, :session, :system]
  @severities [:info, :warning, :error]
  @statuses [:unread, :read, :dismissed]

  @create_fields [
    :title,
    :body,
    :category,
    :severity,
    :status,
    :metadata,
    :source_id,
    :source_type
  ]
  @update_fields [:status, :read_at]

  @max_title_length 255
  @max_body_length 5_000
  @max_source_id_length 255
  @max_source_type_length 100

  # Allowed source types — prevents arbitrary strings from being stored.
  @valid_source_types ~w(webhook_delivery webhook_endpoint experiment session)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "notifications" do
    field :title, :string
    field :body, :string
    field :category, Ecto.Enum, values: @categories
    field :severity, Ecto.Enum, values: @severities, default: :info
    field :status, Ecto.Enum, values: @statuses, default: :unread
    field :metadata, :map, default: %{}
    field :source_id, :string
    field :source_type, :string
    field :read_at, :utc_datetime_usec

    belongs_to :workspace, Workspace

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Changeset for creating a new notification.

  Required fields: `:title`, `:category`.
  The `:workspace_id` is set via `Ecto.build_assoc/3`.

  ## Validation

    * Title: 1–255 characters
    * Body: max 5,000 characters
    * Category: one of #{inspect(@categories)}
    * Severity: one of #{inspect(@severities)}
    * Source type: one of #{inspect(@valid_source_types)} (if provided)
    * Source ID: max 255 characters
    * Metadata: must be a map
  """
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(%__MODULE__{} = notification, attrs) when is_map(attrs) do
    notification
    |> cast(attrs, @create_fields)
    |> validate_required([:title, :category])
    |> validate_length(:title, min: 1, max: @max_title_length)
    |> validate_length(:body, max: @max_body_length)
    |> validate_length(:source_id, max: @max_source_id_length)
    |> validate_length(:source_type, max: @max_source_type_length)
    |> validate_source_type()
    |> validate_metadata()
    |> assoc_constraint(:workspace)
  end

  @doc """
  Changeset for updating notification status.

  Only `:status` and `:read_at` can be changed after creation.
  When status transitions to `:read`, `read_at` is set automatically
  if not provided.
  """
  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(%__MODULE__{} = notification, attrs) when is_map(attrs) do
    notification
    |> cast(attrs, @update_fields)
    |> maybe_set_read_at()
  end

  # ── Private ─────────────────────────────────────────────────

  # Automatically set read_at when transitioning to :read status.
  defp maybe_set_read_at(changeset) do
    case get_change(changeset, :status) do
      :read ->
        if get_field(changeset, :read_at) == nil do
          put_change(changeset, :read_at, DateTime.utc_now())
        else
          changeset
        end

      _ ->
        changeset
    end
  end

  # Validate source_type only when present (field is optional).
  defp validate_source_type(changeset) do
    case fetch_change(changeset, :source_type) do
      :error -> changeset
      {:ok, nil} -> changeset
      {:ok, value} when value in @valid_source_types -> changeset
      {:ok, _} -> add_error(changeset, :source_type, "is invalid")
    end
  end

  # Ensure metadata is a map (not a list, string, or other type).
  # Ecto's :map type handles JSON encoding, but we validate the
  # Elixir-side value to catch programming errors early.
  defp validate_metadata(changeset) do
    case fetch_change(changeset, :metadata) do
      :error -> changeset
      {:ok, value} when is_map(value) -> changeset
      {:ok, _} -> add_error(changeset, :metadata, "must be a map")
    end
  end
end
