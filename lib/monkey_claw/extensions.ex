defmodule MonkeyClaw.Extensions do
  @moduledoc """
  Context module for MonkeyClaw's plug-based extension system.

  Provides the public API for configuring, compiling, and executing
  extension pipelines. Extensions use the plug pattern — `init/1`
  called once at compile time, `call/2` called per event — to hook
  into MonkeyClaw's lifecycle.

  ## What Extensions Do

  Extensions extend MonkeyClaw the application: policy engines,
  audit logging, content filtering, rate limiting. They do NOT
  replace agent-level extensions (MCP, skills, plugins) which
  flow through BeamAgent.

  ## Configuration

  Extensions are configured in application config:

      config :monkey_claw, MonkeyClaw.Extensions,
        global: [
          {MyApp.Extensions.AuditLog, level: :info}
        ],
        hooks: %{
          query_pre: [{MyApp.Extensions.RateLimit, max: 60}]
        }

  Global plugs run on every hook point. Hook-specific plugs run
  only on their declared hook. Execution order: global plugs first,
  then hook-specific plugs, in declaration order.

  ## Pipeline Lifecycle

  1. At application start, `compile_pipelines/0` reads config and
     calls `init/1` on all plug modules
  2. Compiled pipelines are cached in `:persistent_term` for fast
     runtime lookup
  3. `execute/2` retrieves the compiled pipeline and threads a
     `Context` through each plug's `call/2`

  ## Usage

      # From MonkeyClaw internals (e.g., AgentBridge):
      case MonkeyClaw.Extensions.execute(:query_pre, %{prompt: prompt}) do
        {:ok, %{halted: true} = ctx} -> {:error, {:halted, ctx}}
        {:ok, ctx} -> proceed_with(ctx)
      end

  ## Design

  This module is NOT a process. Compiled pipelines are stored in
  `:persistent_term` — a read-optimized store designed for data
  that is written once and read many times.

  ## Related Modules

    * `MonkeyClaw.Extensions.Plug` — Behaviour for extension modules
    * `MonkeyClaw.Extensions.Context` — Context struct flowing through pipelines
    * `MonkeyClaw.Extensions.Pipeline` — Pipeline compilation and execution
    * `MonkeyClaw.Extensions.Hook` — Hook point definitions
  """

  require Logger

  alias MonkeyClaw.Extensions.{Context, Hook, Pipeline}

  @persistent_term_key {__MODULE__, :pipelines}

  # --- Pipeline Compilation ---

  @doc """
  Compile all extension pipelines from application configuration.

  Reads the `:global` and `:hooks` config under
  `{:monkey_claw, MonkeyClaw.Extensions}`, calls `init/1` on all
  plug modules, and caches the compiled pipelines in
  `:persistent_term`.

  Called once at application startup (from the Application
  module's `start/2` callback). Idempotent — calling it
  multiple times overwrites the cached pipelines.

  ## Configuration Format

      config :monkey_claw, MonkeyClaw.Extensions,
        global: [{module, opts}, ...],
        hooks: %{
          hook_point: [{module, opts}, ...]
        }
  """
  @spec compile_pipelines() :: :ok
  def compile_pipelines do
    config = Application.get_env(:monkey_claw, __MODULE__, [])
    global_specs = Keyword.get(config, :global, [])
    hook_specs = Keyword.get(config, :hooks, %{})

    pipelines =
      Hook.all()
      |> Map.new(fn event ->
        event_specs = Map.get(hook_specs, event, [])
        combined = global_specs ++ event_specs

        {:ok, pipeline} = Pipeline.compile(event, combined)
        {event, pipeline}
      end)

    :persistent_term.put(@persistent_term_key, pipelines)

    plug_count =
      pipelines
      |> Map.values()
      |> Enum.map(&Pipeline.size/1)
      |> Enum.sum()

    if plug_count > 0 do
      hook_count =
        pipelines
        |> Enum.count(fn {_event, pipeline} -> not Pipeline.empty?(pipeline) end)

      Logger.info("Extensions: compiled #{plug_count} plug(s) across #{hook_count} hook(s)")
    end

    :ok
  end

  # --- Pipeline Execution ---

  @doc """
  Execute the extension pipeline for a hook event.

  Creates a `Context` from the event and data, retrieves the
  compiled pipeline, and threads the context through each plug.

  Returns `{:ok, context}` with the final context after all
  plugs have executed (or after halting).

  ## Examples

      {:ok, ctx} = MonkeyClaw.Extensions.execute(:query_pre, %{prompt: "Hello"})

      case ctx.halted do
        true -> handle_halted(ctx)
        false -> proceed(ctx)
      end
  """
  @spec execute(Hook.t(), map()) :: {:ok, Context.t()} | {:error, term()}
  def execute(event, data \\ %{})
      when is_atom(event) and is_map(data) do
    with {:ok, context} <- Context.new(event, data),
         {:ok, pipeline} <- get_pipeline(event) do
      Pipeline.execute(pipeline, context)
    end
  end

  # --- Query Functions ---

  @doc """
  List all configured plug module specs (unique, across all hooks).

  Returns a list of `{module, opts}` tuples as they appear in the
  application config (before `init/1` is called).
  """
  @spec list_plugs() :: [{module(), term()}]
  def list_plugs do
    config = Application.get_env(:monkey_claw, __MODULE__, [])
    global = Keyword.get(config, :global, [])

    hook_plugs =
      config
      |> Keyword.get(:hooks, %{})
      |> Map.values()
      |> List.flatten()

    Enum.uniq(global ++ hook_plugs)
  end

  @doc """
  List all hook points that have at least one plug configured.

  ## Examples

      MonkeyClaw.Extensions.active_hooks()
      #=> [:query_pre, :session_starting]
  """
  @spec active_hooks() :: [Hook.t()]
  def active_hooks do
    pipelines()
    |> Enum.reject(fn {_event, pipeline} -> Pipeline.empty?(pipeline) end)
    |> Enum.map(fn {event, _pipeline} -> event end)
    |> Enum.sort()
  end

  @doc """
  Check if any plugs are registered for a given hook point.
  """
  @spec has_plugs?(Hook.t()) :: boolean()
  def has_plugs?(event) when is_atom(event) do
    case get_pipeline(event) do
      {:ok, pipeline} -> not Pipeline.empty?(pipeline)
      {:error, _} -> false
    end
  end

  @doc """
  Clear compiled pipelines from the cache.

  After clearing, `compile_pipelines/0` must be called again
  before `execute/2` will work. Primarily used in tests.
  """
  @spec clear_pipelines() :: :ok
  def clear_pipelines do
    :persistent_term.erase(@persistent_term_key)
    :ok
  rescue
    # :persistent_term.erase raises ArgumentError if the key doesn't exist
    ArgumentError -> :ok
  end

  # --- Private ---

  @spec get_pipeline(Hook.t()) :: {:ok, Pipeline.t()} | {:error, {:unknown_hook, atom()}}
  defp get_pipeline(event) do
    case pipelines() do
      %{^event => pipeline} -> {:ok, pipeline}
      _ -> {:error, {:unknown_hook, event}}
    end
  end

  @spec pipelines() :: %{Hook.t() => Pipeline.t()}
  defp pipelines do
    :persistent_term.get(@persistent_term_key, %{})
  end
end
