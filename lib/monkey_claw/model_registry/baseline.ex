defmodule MonkeyClaw.ModelRegistry.Baseline do
  @moduledoc """
  Runtime-config reader for the ModelRegistry baseline loader.

  Users define baseline entries in `config/runtime.exs`:

      config :monkey_claw, MonkeyClaw.ModelRegistry.Baseline,
        entries: [
          %{
            backend: "claude",
            provider: "anthropic",
            models: [
              %{model_id: "claude-sonnet-4-5", display_name: "Claude Sonnet 4.5", capabilities: %{}}
            ]
          }
        ]

  ## Design

  This is NOT a process. `Baseline` is a pure module: no state, no
  supervision. `MonkeyClaw.ModelRegistry.init/1` invokes `load!/0` once
  at boot to seed SQLite before any probe runs.

  `load!/0` performs a structural pre-check (required keys, list shape)
  and drops entries that fail. The full trust-boundary validation
  happens downstream in `CachedModel.changeset/2` when the registry's
  upsert funnel processes baseline writes. Structural errors are
  logged with the offending entry so config typos are easy to catch.
  """

  require Logger

  @type entry :: %{
          required(:backend) => String.t(),
          required(:provider) => String.t(),
          required(:models) => [map()]
        }

  @doc """
  Return the raw list of configured baseline entries.

  Does not validate — use `load!/0` for the validated view.
  """
  @spec all() :: [map()]
  def all do
    :monkey_claw
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:entries, [])
  end

  @doc """
  Load baseline entries, dropping any that fail the structural check.

  Returns `{:ok, valid_entries}`. Invalid entries are logged with
  enough detail to identify the offending config key.
  """
  @spec load!() :: {:ok, [entry()]}
  def load! do
    all_entries = all()
    valid = Enum.filter(all_entries, &valid_entry?/1)
    dropped = length(all_entries) - length(valid)

    if dropped > 0 do
      Logger.warning(
        "ModelRegistry.Baseline: dropped #{dropped} invalid baseline entries (structural check failed); " <>
          "see earlier warnings for offending entries"
      )
    end

    {:ok, valid}
  end

  # ── Private ─────────────────────────────────────────────────

  @required_keys [:backend, :provider, :models]

  defp valid_entry?(entry) when is_map(entry) do
    missing = Enum.reject(@required_keys, &Map.has_key?(entry, &1))

    cond do
      missing != [] ->
        Logger.warning(
          "ModelRegistry.Baseline: entry missing required keys #{inspect(missing)}: #{inspect(entry)}"
        )

        false

      not is_list(entry.models) ->
        Logger.warning(
          "ModelRegistry.Baseline: entry :models must be a list, got: #{inspect(entry.models)}"
        )

        false

      true ->
        true
    end
  end

  defp valid_entry?(other) do
    Logger.warning("ModelRegistry.Baseline: entry is not a map: #{inspect(other)}")
    false
  end
end
