defmodule MonkeyClaw.UserModeling do
  @moduledoc """
  Context module for user profile management and observation processing.

  Provides CRUD operations for user profiles, topic extraction from
  prompts, observation merging, and injectable context generation for
  personalized agent queries.

  ## Privacy Levels

  Observation recording respects the profile's privacy level:

    * `:full` — Records both topic frequencies and behavioral patterns
    * `:limited` — Records topic frequencies only (no patterns)
    * `:none` — Skips all observation recording

  ## Injection

  The `build_injection_context/1` function generates a string suitable
  for prepending to agent prompts, summarizing the user's top interests
  and explicit preferences. Injection is gated by the profile's
  `injection_enabled` flag.

  ## Related Modules

    * `MonkeyClaw.UserModeling.UserProfile` — Ecto schema
    * `MonkeyClaw.UserModeling.Observer` — Async observation batching

  ## Design

  This module is NOT a process. It delegates persistence to
  `MonkeyClaw.Repo` (Ecto/SQLite3). All functions are pure
  (database I/O aside) and safe for concurrent use.
  """

  require Logger

  import Ecto.Query

  alias MonkeyClaw.Repo
  alias MonkeyClaw.UserModeling.UserProfile
  alias MonkeyClaw.Workspaces.Workspace

  @stopwords ~w(the and for that this with from have been will would could should about into through during before after)

  @max_topic_count 1000
  @max_topics 100
  @max_query_count 1_000_000
  @max_hour_count 100_000

  # ──────────────────────────────────────────────
  # Profile CRUD
  # ──────────────────────────────────────────────

  @doc """
  Get the existing profile for a workspace, or create one with defaults.

  Returns `{:ok, profile}` on success. If no profile exists for the
  workspace, inserts a new one with default field values.

  ## Examples

      {:ok, profile} = UserModeling.ensure_profile(workspace)
  """
  @spec ensure_profile(Workspace.t()) :: {:ok, UserProfile.t()} | {:error, Ecto.Changeset.t()}
  def ensure_profile(%Workspace{} = workspace) do
    case Repo.get_by(UserProfile, workspace_id: workspace.id) do
      nil ->
        workspace
        |> Ecto.build_assoc(:user_profile)
        |> UserProfile.create_changeset(%{})
        |> Repo.insert(on_conflict: :nothing, conflict_target: :workspace_id)
        |> case do
          {:ok, %UserProfile{}} ->
            # With :binary_id, on_conflict: :nothing returns a struct with
            # a client-generated id even when the insert was skipped.
            # Always re-fetch to guarantee we return the persisted row.
            get_profile(workspace.id)

          {:error, _} = err ->
            err
        end

      %UserProfile{} = profile ->
        {:ok, profile}
    end
  end

  @doc """
  Get a user profile by workspace ID.

  Returns `{:ok, profile}` if found, `{:error, :not_found}` otherwise.
  """
  @spec get_profile(Ecto.UUID.t()) :: {:ok, UserProfile.t()} | {:error, :not_found}
  def get_profile(workspace_id)
      when is_binary(workspace_id) and byte_size(workspace_id) > 0 do
    case Repo.one(from(p in UserProfile, where: p.workspace_id == ^workspace_id)) do
      nil -> {:error, :not_found}
      %UserProfile{} = profile -> {:ok, profile}
    end
  end

  @doc """
  Update an existing user profile.

  ## Examples

      {:ok, updated} = UserModeling.update_profile(profile, %{display_name: "Dev"})
  """
  @spec update_profile(UserProfile.t(), map()) ::
          {:ok, UserProfile.t()} | {:error, Ecto.Changeset.t()}
  def update_profile(%UserProfile{} = profile, attrs) when is_map(attrs) do
    profile
    |> UserProfile.update_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Delete a user profile.
  """
  @spec delete_profile(UserProfile.t()) ::
          {:ok, UserProfile.t()} | {:error, Ecto.Changeset.t()}
  def delete_profile(%UserProfile{} = profile) do
    Repo.delete(profile)
  end

  @doc """
  Toggle prompt injection for a user profile.

  When `enabled` is `false`, `get_injectable_context/1` returns an
  empty string even if the profile has observed topics and preferences.

  ## Examples

      {:ok, profile} = UserModeling.toggle_injection(profile, false)
      "" = UserModeling.get_injectable_context(workspace_id)
  """
  @spec toggle_injection(UserProfile.t(), boolean()) ::
          {:ok, UserProfile.t()} | {:error, Ecto.Changeset.t()}
  def toggle_injection(%UserProfile{} = profile, enabled) when is_boolean(enabled) do
    update_profile(profile, %{injection_enabled: enabled})
  end

  # ──────────────────────────────────────────────
  # Observation Processing
  # ──────────────────────────────────────────────

  @doc """
  Record an observation for a workspace's user profile.

  The observation map must contain a `:prompt` key (binary). An optional
  `:response` key is accepted for future pattern extraction.

  Respects the profile's privacy level:

    * `:none` — No-op, returns `:ok` immediately
    * `:limited` — Updates topic frequencies only
    * `:full` — Updates both topic frequencies and behavioral patterns

  Creates a default profile if one does not exist for the workspace.

  ## Examples

      :ok = UserModeling.record_observation(workspace_id, %{
        prompt: "How do I deploy an Elixir release?",
        response: "Use mix release..."
      })
  """
  @spec record_observation(Ecto.UUID.t(), %{
          required(:prompt) => String.t(),
          optional(:response) => String.t()
        }) ::
          :ok
  def record_observation(workspace_id, %{prompt: prompt} = observation)
      when is_binary(workspace_id) and byte_size(workspace_id) > 0 and
             is_binary(prompt) do
    case get_or_create_profile(workspace_id) do
      {:ok, profile} ->
        apply_observation(profile, observation)

      {:error, reason} ->
        Logger.warning(
          "Failed to get/create profile for observation: workspace_id=#{workspace_id} reason=#{inspect(reason)}"
        )
    end

    :ok
  end

  # ──────────────────────────────────────────────
  # Topic & Pattern Merging
  # ──────────────────────────────────────────────

  @doc """
  Extract topic frequencies from text.

  Downcases the text, splits on non-alphanumeric boundaries, filters
  stopwords and words shorter than 4 characters, and counts frequencies.

  ## Examples

      UserModeling.extract_topics("How do I deploy an Elixir release?")
      #=> %{"deploy" => 1, "elixir" => 1, "release" => 1}
  """
  @spec extract_topics(String.t()) :: %{String.t() => pos_integer()}
  def extract_topics(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.split(~r/[^a-z0-9]+/, trim: true)
    |> Enum.reject(&(&1 in @stopwords))
    |> Enum.filter(&(String.length(&1) >= 4))
    |> Enum.frequencies()
  end

  @doc """
  Merge two topic frequency maps.

  Adds counts for overlapping keys. Individual topic counts are capped
  at #{@max_topic_count} to prevent unbounded growth. The result is
  trimmed to the top #{@max_topics} topics by frequency.

  ## Examples

      UserModeling.merge_topics(%{"elixir" => 5}, %{"elixir" => 1, "deploy" => 1})
      #=> %{"elixir" => 6, "deploy" => 1}
  """
  @spec merge_topics(map(), map()) :: map()
  def merge_topics(existing, new) when is_map(existing) and is_map(new) do
    Map.merge(existing, new, fn _key, v1, v2 ->
      min(v1 + v2, @max_topic_count)
    end)
    |> top_n_by_value(@max_topics)
  end

  @doc """
  Merge two behavioral pattern maps.

  Tracked patterns:

    * `"query_count"` — Total observation count (capped at #{@max_query_count})
    * `"avg_prompt_length"` — Running average prompt length
    * `"active_hours"` — Map of hour (0-23 as string) to observation count
      (individual hour counts capped at #{@max_hour_count})

  ## Examples

      existing = %{"query_count" => 10, "avg_prompt_length" => 50.0, "active_hours" => %{"14" => 5}}
      new = %{"query_count" => 1, "avg_prompt_length" => 80.0, "active_hours" => %{"14" => 1}}
      UserModeling.merge_patterns(existing, new)
  """
  @spec merge_patterns(map(), map()) :: %{String.t() => non_neg_integer() | float() | map()}
  def merge_patterns(existing, new) when is_map(existing) and is_map(new) do
    existing_count = min(Map.get(existing, "query_count", 0), @max_query_count)
    new_count = Map.get(new, "query_count", 0)
    remaining_capacity = max(@max_query_count - existing_count, 0)
    effective_new_count = min(new_count, remaining_capacity)
    total_count = existing_count + effective_new_count

    existing_avg = Map.get(existing, "avg_prompt_length", 0.0)
    new_avg = Map.get(new, "avg_prompt_length", 0.0)

    merged_avg =
      if total_count > 0 do
        (existing_avg * existing_count + new_avg * effective_new_count) / total_count
      else
        0.0
      end

    existing_hours = Map.get(existing, "active_hours", %{})
    new_hours = Map.get(new, "active_hours", %{})

    merged_hours =
      Map.merge(existing_hours, new_hours, fn _key, v1, v2 ->
        min(v1 + v2, @max_hour_count)
      end)

    %{
      "query_count" => total_count,
      "avg_prompt_length" => Float.round(merged_avg, 2),
      "active_hours" => merged_hours
    }
  end

  # ──────────────────────────────────────────────
  # Context Injection
  # ──────────────────────────────────────────────

  @doc """
  Build an injectable context string from a user profile.

  Returns a string summarizing the user's top interests and explicit
  preferences, formatted for prepending to agent prompts. Returns
  an empty string if the profile has no useful data.

  This is a pure formatting function — it does NOT check
  `injection_enabled`. Callers are responsible for gating on
  that flag (see `get_injectable_context/1`).

  ## Examples

      UserModeling.build_injection_context(profile)
      #=> "[User context]\\nTop interests: elixir, testing, deployment\\nPreferences: verbose_output=true"
  """
  @spec build_injection_context(UserProfile.t()) :: String.t()
  def build_injection_context(%UserProfile{} = profile) do
    parts = []

    parts =
      case format_top_interests(profile.observed_topics) do
        "" -> parts
        interests -> parts ++ ["Top interests: " <> interests]
      end

    parts =
      case format_preferences(profile.preferences) do
        "" -> parts
        prefs -> parts ++ ["Preferences: " <> prefs]
      end

    case parts do
      [] -> ""
      lines -> "[User context]\n" <> Enum.join(lines, "\n")
    end
  end

  @doc """
  Get the injectable context string for a workspace.

  Fetches the workspace's profile and builds the injection context.
  Returns an empty string if no profile exists or injection is disabled.

  ## Examples

      context = UserModeling.get_injectable_context(workspace_id)
  """
  @spec get_injectable_context(Ecto.UUID.t()) :: String.t()
  def get_injectable_context(workspace_id)
      when is_binary(workspace_id) and byte_size(workspace_id) > 0 do
    case get_profile(workspace_id) do
      {:ok, %UserProfile{injection_enabled: true} = profile} ->
        build_injection_context(profile)

      _ ->
        ""
    end
  end

  # ──────────────────────────────────────────────
  # Private — Observation Application
  # ──────────────────────────────────────────────

  defp apply_observation(%UserProfile{privacy_level: :none}, _observation), do: :ok

  defp apply_observation(%UserProfile{} = profile, %{prompt: prompt} = _observation) do
    new_topics = extract_topics(prompt)
    merged_topics = merge_topics(profile.observed_topics, new_topics)

    attrs =
      if UserProfile.tracks_patterns?(profile.privacy_level) do
        new_patterns = build_patterns_from_prompt(prompt)
        merged_patterns = merge_patterns(profile.observed_patterns, new_patterns)

        %{
          observed_topics: merged_topics,
          observed_patterns: merged_patterns,
          last_observed_at: DateTime.utc_now()
        }
      else
        %{
          observed_topics: merged_topics,
          last_observed_at: DateTime.utc_now()
        }
      end

    case update_profile(profile, attrs) do
      {:ok, _updated} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Failed to update profile observation: profile_id=#{profile.id} reason=#{inspect(reason)}"
        )

        :ok
    end
  end

  defp build_patterns_from_prompt(prompt) do
    hour = DateTime.utc_now() |> Map.get(:hour) |> Integer.to_string()

    %{
      "query_count" => 1,
      "avg_prompt_length" => String.length(prompt) * 1.0,
      "active_hours" => %{hour => 1}
    }
  end

  # ──────────────────────────────────────────────
  # Private — Profile Retrieval
  # ──────────────────────────────────────────────

  defp get_or_create_profile(workspace_id) do
    case get_profile(workspace_id) do
      {:ok, profile} ->
        {:ok, profile}

      {:error, :not_found} ->
        case Repo.get(Workspace, workspace_id) do
          nil ->
            {:error, :workspace_not_found}

          %Workspace{} = workspace ->
            ensure_profile(workspace)
        end
    end
  end

  # ──────────────────────────────────────────────
  # Private — Formatting
  # ──────────────────────────────────────────────

  defp format_top_interests(topics) when is_map(topics) and map_size(topics) > 0 do
    topics
    |> Enum.sort_by(fn {_k, v} -> v end, :desc)
    |> Enum.take(10)
    |> Enum.map_join(", ", fn {topic, _count} -> topic end)
  end

  defp format_top_interests(_), do: ""

  defp format_preferences(prefs) when is_map(prefs) and map_size(prefs) > 0 do
    prefs
    |> Enum.sort_by(fn {k, _v} -> k end)
    |> Enum.map_join(", ", fn {k, v} -> "#{k}=#{v}" end)
  end

  defp format_preferences(_), do: ""

  # Return the top N entries from a map by value (descending).
  defp top_n_by_value(map, n) when map_size(map) <= n, do: map

  defp top_n_by_value(map, n) do
    map
    |> Enum.sort_by(fn {_k, v} -> v end, :desc)
    |> Enum.take(n)
    |> Map.new()
  end
end
