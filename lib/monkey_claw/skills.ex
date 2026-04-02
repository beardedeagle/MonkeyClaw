defmodule MonkeyClaw.Skills do
  @moduledoc """
  Context module for the skills library.

  Provides CRUD operations, FTS5 full-text search, effectiveness
  scoring, and cache management for reusable skill procedures.
  Skills are extracted from successful experiments and injected
  into agent queries via the extension plug system.

  ## Related Modules

    * `MonkeyClaw.Skills.Skill` — Skill Ecto schema
    * `MonkeyClaw.Skills.Extractor` — Extract procedures from experiments
    * `MonkeyClaw.Skills.Plug` — Extension plug for query injection
    * `MonkeyClaw.Skills.Cache` — ETS hot cache management
    * `MonkeyClaw.Skills.Formatter` — Format skills for injection

  ## Design

  This module is NOT a process. It delegates persistence to
  `MonkeyClaw.Repo` (Ecto/SQLite3). All functions are pure
  (database I/O aside) and safe for concurrent use.
  """

  require Logger

  import Ecto.Query

  alias MonkeyClaw.Recall
  alias MonkeyClaw.Repo
  alias MonkeyClaw.Skills.{Cache, Skill}
  alias MonkeyClaw.Workspaces.Workspace

  @default_search_limit 10
  @max_search_limit 100

  # ──────────────────────────────────────────────
  # Skill CRUD
  # ──────────────────────────────────────────────

  @doc """
  Create a new skill within a workspace.

  The workspace association is set automatically via `Ecto.build_assoc/3`.
  Invalidates the workspace skill cache on success.

  ## Examples

      {:ok, skill} = Skills.create_skill(workspace, %{
        title: "Optimize Parser Performance",
        description: "Steps to profile and optimize Elixir parsers",
        procedure: "1. Profile with :fprof\\n2. Identify hot paths...",
        tags: ["code", "optimization"]
      })
  """
  @spec create_skill(Workspace.t(), map()) :: {:ok, Skill.t()} | {:error, Ecto.Changeset.t()}
  def create_skill(%Workspace{} = workspace, attrs) when is_map(attrs) do
    result =
      workspace
      |> Ecto.build_assoc(:skills)
      |> Skill.create_changeset(attrs)
      |> Repo.insert()

    case result do
      {:ok, skill} ->
        Cache.invalidate(workspace.id)
        {:ok, skill}

      error ->
        error
    end
  end

  @doc """
  Get a skill by ID.

  Returns `{:ok, skill}` if found, `{:error, :not_found}` otherwise.
  """
  @spec get_skill(Ecto.UUID.t()) :: {:ok, Skill.t()} | {:error, :not_found}
  def get_skill(id) when is_binary(id) and byte_size(id) > 0 do
    case Repo.get(Skill, id) do
      nil -> {:error, :not_found}
      skill -> {:ok, skill}
    end
  end

  @doc """
  Get a skill by ID, raising on not found.
  """
  @spec get_skill!(Ecto.UUID.t()) :: Skill.t()
  def get_skill!(id) when is_binary(id) and byte_size(id) > 0 do
    Repo.get!(Skill, id)
  end

  @doc """
  List skills for a workspace, ordered by effectiveness score.
  """
  @spec list_skills(Workspace.t() | Ecto.UUID.t()) :: [Skill.t()]
  def list_skills(%Workspace{id: workspace_id}), do: list_skills(workspace_id)

  def list_skills(workspace_id)
      when is_binary(workspace_id) and byte_size(workspace_id) > 0 do
    list_skills(workspace_id, %{})
  end

  @doc """
  List skills for a workspace with filtering options.

  ## Options

    * `:limit` — Maximum number of skills to return
    * `:tags` — Filter by tag (skills containing this tag)
  """
  @spec list_skills(Ecto.UUID.t(), map()) :: [Skill.t()]
  def list_skills(workspace_id, opts)
      when is_binary(workspace_id) and byte_size(workspace_id) > 0 and is_map(opts) do
    Skill
    |> where([s], s.workspace_id == ^workspace_id)
    |> apply_tags_filter(opts)
    |> order_by([s], desc: s.effectiveness_score, desc: s.inserted_at)
    |> apply_limit(opts)
    |> Repo.all()
  end

  @doc """
  Update an existing skill.

  Invalidates the workspace skill cache on success.
  """
  @spec update_skill(Skill.t(), map()) :: {:ok, Skill.t()} | {:error, Ecto.Changeset.t()}
  def update_skill(%Skill{} = skill, attrs) when is_map(attrs) do
    result =
      skill
      |> Skill.update_changeset(attrs)
      |> Repo.update()

    case result do
      {:ok, updated} ->
        Cache.invalidate(skill.workspace_id)
        {:ok, updated}

      error ->
        error
    end
  end

  @doc """
  Delete a skill.

  Invalidates the workspace skill cache on success.
  """
  @spec delete_skill(Skill.t()) :: {:ok, Skill.t()} | {:error, Ecto.Changeset.t()}
  def delete_skill(%Skill{} = skill) do
    result = Repo.delete(skill)

    case result do
      {:ok, deleted} ->
        Cache.invalidate(skill.workspace_id)
        {:ok, deleted}

      error ->
        error
    end
  end

  # ──────────────────────────────────────────────
  # Search
  # ──────────────────────────────────────────────

  @doc """
  Search skills via FTS5 full-text search within a workspace.

  The query is sanitized for FTS5 syntax safety via
  `MonkeyClaw.Recall.sanitize_query/1`. Returns an empty list
  if no usable keywords remain after sanitization or if the
  FTS5 query fails.

  ## Examples

      skills = Skills.search_skills(workspace_id, "parser optimization")
  """
  @spec search_skills(Ecto.UUID.t(), String.t()) :: [Skill.t()]
  def search_skills(workspace_id, query)
      when is_binary(workspace_id) and byte_size(workspace_id) > 0 and
             is_binary(query) and byte_size(query) > 0 do
    search_skills(workspace_id, query, %{})
  end

  @doc """
  Search skills with options.

  ## Options

    * `:limit` — Maximum number of results (default: 10, max: 100)

  ## Examples

      skills = Skills.search_skills(workspace_id, "deploy*", %{limit: 5})
  """
  @spec search_skills(Ecto.UUID.t(), String.t(), map()) :: [Skill.t()]
  def search_skills(workspace_id, query, opts)
      when is_binary(workspace_id) and byte_size(workspace_id) > 0 and
             is_binary(query) and byte_size(query) > 0 and is_map(opts) do
    case Recall.sanitize_query(query) do
      nil ->
        []

      sanitized ->
        workspace_id
        |> build_search_sql(sanitized, opts)
        |> execute_fts_search()
    end
  end

  # ──────────────────────────────────────────────
  # Usage Tracking
  # ──────────────────────────────────────────────

  @doc """
  Record a usage of a skill and update its effectiveness score.

  Increments `usage_count` by 1. When `success: true` is passed,
  also increments `success_count` by 1. Recalculates the
  effectiveness score as `success_count / usage_count`, clamped
  to [0.0, 1.0].

  Invalidates the workspace skill cache on success.

  ## Options

    * `:success` — Whether this usage was successful (default: false)

  ## Examples

      {:ok, skill} = Skills.record_usage(skill, success: true)
      skill.usage_count
      #=> 1
      skill.effectiveness_score
      #=> 1.0
  """
  @spec record_usage(Skill.t(), keyword()) :: {:ok, Skill.t()} | {:error, Ecto.Changeset.t()}
  def record_usage(%Skill{} = skill, opts \\ []) when is_list(opts) do
    success? = Keyword.get(opts, :success, false)

    inc_fields =
      if success?,
        do: [usage_count: 1, success_count: 1],
        else: [usage_count: 1]

    query = from(s in Skill, where: s.id == ^skill.id)

    case Repo.update_all(query, inc: inc_fields) do
      {1, _} ->
        # Reload to compute effectiveness_score from stored values,
        # avoiding read-modify-write race on concurrent updates.
        updated = Repo.get!(Skill, skill.id)
        score = min(1.0, max(0.0, updated.success_count / max(updated.usage_count, 1)))

        result =
          updated
          |> Skill.update_changeset(%{effectiveness_score: score})
          |> Repo.update()

        case result do
          {:ok, scored} ->
            Cache.invalidate(scored.workspace_id)
            {:ok, scored}

          error ->
            error
        end

      {0, _} ->
        {:error,
         skill
         |> Ecto.Changeset.change()
         |> Ecto.Changeset.add_error(:id, "not found")}
    end
  end

  # ──────────────────────────────────────────────
  # Queries
  # ──────────────────────────────────────────────

  @doc """
  Get the top N skills by effectiveness score for a workspace.

  ## Examples

      top = Skills.top_skills(workspace_id, 5)
  """
  @spec top_skills(Ecto.UUID.t(), pos_integer()) :: [Skill.t()]
  def top_skills(workspace_id, n)
      when is_binary(workspace_id) and byte_size(workspace_id) > 0 and
             is_integer(n) and n > 0 do
    Skill
    |> where([s], s.workspace_id == ^workspace_id)
    |> order_by([s], desc: s.effectiveness_score)
    |> limit(^n)
    |> Repo.all()
  end

  # ──────────────────────────────────────────────
  # Private — FTS5 Search Execution
  # ──────────────────────────────────────────────

  defp execute_fts_search({sql, params}) do
    case Repo.query(sql, params) do
      {:ok, %{rows: rows, columns: columns}} ->
        Enum.map(rows, fn row ->
          columns |> Enum.zip(row) |> Map.new() |> load_skill()
        end)

      {:error, reason} ->
        log_search_error(reason)
        []
    end
  end

  defp log_search_error(%{message: msg}) when is_binary(msg) do
    if String.contains?(msg, "fts5: syntax error") do
      Logger.debug("FTS5 syntax error for skill search: #{inspect(msg)}")
    else
      Logger.warning("Skill search query failed: #{inspect(msg)}")
    end
  end

  defp log_search_error(reason) do
    Logger.warning("Skill search query failed: #{inspect(reason)}")
  end

  # ──────────────────────────────────────────────
  # Private — Search SQL Builder
  # ──────────────────────────────────────────────

  # Builds a parameterized FTS5 search query for skills.
  # Parameters use SQLite's ?N positional syntax (1-indexed).
  # Base query includes FTS5 MATCH and workspace ownership;
  # limit is appended as the final parameter.
  @spec build_search_sql(Ecto.UUID.t(), String.t(), map()) :: {String.t(), [term()]}
  defp build_search_sql(workspace_id, query, opts) do
    limit = opts |> Map.get(:limit, @default_search_limit) |> clamp_search_limit()

    # ?1 = query, ?2 = workspace_id, ?3 = limit
    {conditions, params, next_idx} =
      {["skills_fts MATCH ?1", "s.workspace_id = ?2"], [query, workspace_id], 3}

    sql = """
    SELECT s.id, s.title, s.description, s.procedure, s.tags,
           s.source_experiment_id, s.effectiveness_score,
           s.usage_count, s.success_count, s.fts_rowid,
           s.workspace_id, s.inserted_at, s.updated_at
    FROM skills_fts AS fts
    JOIN skills AS s ON s.fts_rowid = fts.rowid
    WHERE #{Enum.join(conditions, "\n    AND ")}
    ORDER BY fts.rank
    LIMIT ?#{next_idx}
    """

    {sql, params ++ [limit]}
  end

  # ──────────────────────────────────────────────
  # Private — Result Loading
  # ──────────────────────────────────────────────

  # Load a raw SQL row map into a Skill struct.
  # Handles type coercion for JSON and datetime fields.
  defp load_skill(row) do
    %Skill{
      id: row["id"],
      title: row["title"],
      description: row["description"],
      procedure: row["procedure"],
      tags: decode_tags(row["tags"]),
      source_experiment_id: row["source_experiment_id"],
      effectiveness_score: row["effectiveness_score"],
      usage_count: row["usage_count"],
      success_count: row["success_count"],
      fts_rowid: row["fts_rowid"],
      workspace_id: row["workspace_id"],
      inserted_at: parse_datetime(row["inserted_at"]),
      updated_at: parse_datetime(row["updated_at"])
    }
  end

  defp decode_tags(nil), do: []
  defp decode_tags(tags) when is_list(tags), do: tags

  defp decode_tags(tags) when is_binary(tags) do
    case Jason.decode(tags) do
      {:ok, decoded} when is_list(decoded) -> decoded
      _ -> []
    end
  end

  defp parse_datetime(nil), do: nil

  defp parse_datetime(dt) when is_binary(dt) do
    case DateTime.from_iso8601(dt) do
      {:ok, parsed, _offset} -> parsed
      {:error, _} -> nil
    end
  end

  defp parse_datetime(%DateTime{} = dt), do: dt

  # ──────────────────────────────────────────────
  # Private — Filters
  # ──────────────────────────────────────────────

  defp apply_tags_filter(query, %{tags: tag}) when is_binary(tag) and byte_size(tag) > 0 do
    where(
      query,
      [s],
      fragment("EXISTS (SELECT 1 FROM json_each(?) WHERE value = ?)", s.tags, ^tag)
    )
  end

  defp apply_tags_filter(query, _opts), do: query

  defp apply_limit(query, %{limit: limit}) when is_integer(limit) and limit > 0 do
    limit(query, ^limit)
  end

  defp apply_limit(query, _opts), do: query

  defp clamp_search_limit(n) when is_integer(n) and n > 0 and n <= @max_search_limit, do: n
  defp clamp_search_limit(n) when is_integer(n) and n > @max_search_limit, do: @max_search_limit
  defp clamp_search_limit(_), do: @default_search_limit
end
