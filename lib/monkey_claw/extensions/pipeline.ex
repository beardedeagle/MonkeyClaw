defmodule MonkeyClaw.Extensions.Pipeline do
  @moduledoc """
  Builds and executes ordered extension pipelines.

  A pipeline is an ordered list of compiled plugs for a specific
  hook point. Plugs are compiled by calling `init/1` at build time
  and storing the result. At execution time, the context is threaded
  through each plug's `call/2` in order.

  ## Compilation

  Pipelines are compiled from a list of `{module, opts}` tuples:

      {:ok, pipeline} = Pipeline.compile(:query_pre, [
        {RateLimit, max_per_minute: 60},
        {ContentFilter, []}
      ])

  Compilation calls each module's `init/1` with the provided opts
  and stores the result for runtime use.

  ## Execution

  Execution threads a `Context` through each compiled plug:

      {:ok, result} = Pipeline.execute(pipeline, context)

  If a plug halts the context, remaining plugs are skipped.
  If a plug raises, the exception propagates to the caller —
  idiomatic "let it crash" behavior.

  ## Design

  This is NOT a process. Pipelines are immutable data structures
  that are compiled once and executed many times. No state, no
  side effects in the pipeline module itself.
  """

  alias MonkeyClaw.Extensions.{Context, Hook}

  @type plug_spec :: {module(), term()}
  @type compiled_plug :: {module(), term()}

  @type t :: %__MODULE__{
          event: Hook.t(),
          plugs: [compiled_plug()]
        }

  @enforce_keys [:event]
  defstruct [
    :event,
    plugs: []
  ]

  @doc """
  Compile a pipeline from a list of plug specifications.

  Each spec is a `{module, opts}` tuple. The module must implement
  the `MonkeyClaw.Extensions.Plug` behaviour — specifically, it
  must export `init/1` and `call/2`. Compilation calls `init/1`
  on each module with its options and stores the result.

  Returns `{:ok, pipeline}` on success.

  Raises `ArgumentError` if the event is not a valid hook point
  or if any module does not export the required functions.

  ## Examples

      iex> {:ok, pipeline} = MonkeyClaw.Extensions.Pipeline.compile(:query_pre, [])
      iex> pipeline.event
      :query_pre
  """
  @spec compile(Hook.t(), [plug_spec()]) :: {:ok, t()}
  def compile(event, plug_specs)
      when is_atom(event) and is_list(plug_specs) do
    unless Hook.valid?(event) do
      raise ArgumentError, "invalid hook point: #{inspect(event)}"
    end

    compiled =
      Enum.map(plug_specs, fn {module, opts} ->
        validate_plug_module!(module)
        initialized = module.init(opts)
        {module, initialized}
      end)

    {:ok, %__MODULE__{event: event, plugs: compiled}}
  end

  @doc """
  Execute a compiled pipeline with the given context.

  Threads the context through each plug's `call/2` in order. If
  a plug sets `halted: true` on the context, remaining plugs are
  skipped and the halted context is returned immediately.

  Exceptions in plugs propagate to the caller — no rescue wrapper.
  This is by design: buggy extensions should fail loudly.

  Returns `{:ok, context}` with the final context.

  ## Examples

      {:ok, pipeline} = Pipeline.compile(:query_pre, [{MyPlug, []}])
      context = Context.new!(:query_pre, %{prompt: "Hello"})
      {:ok, result} = Pipeline.execute(pipeline, context)
  """
  @spec execute(t(), Context.t()) :: {:ok, Context.t()}
  def execute(%__MODULE__{plugs: plugs}, %Context{} = context) do
    result =
      Enum.reduce_while(plugs, context, fn {module, opts}, ctx ->
        updated = module.call(ctx, opts)

        if updated.halted do
          {:halt, updated}
        else
          {:cont, updated}
        end
      end)

    {:ok, result}
  end

  @doc """
  Return the number of plugs in the pipeline.

  ## Examples

      iex> {:ok, p} = MonkeyClaw.Extensions.Pipeline.compile(:query_pre, [])
      iex> MonkeyClaw.Extensions.Pipeline.size(p)
      0
  """
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{plugs: plugs}), do: length(plugs)

  @doc """
  Check if the pipeline has no plugs.

  ## Examples

      iex> {:ok, p} = MonkeyClaw.Extensions.Pipeline.compile(:query_pre, [])
      iex> MonkeyClaw.Extensions.Pipeline.empty?(p)
      true
  """
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{plugs: []}), do: true
  def empty?(%__MODULE__{}), do: false

  # --- Private ---

  @spec validate_plug_module!(module()) :: :ok
  defp validate_plug_module!(module) when is_atom(module) do
    # Ensure the module is loaded before checking exports.
    # function_exported?/3 does not trigger module loading —
    # without this, lazy-loaded modules would falsely fail
    # validation.
    case Code.ensure_loaded(module) do
      {:module, _} ->
        :ok

      {:error, reason} ->
        raise ArgumentError,
              "#{inspect(module)} could not be loaded (#{reason}) — " <>
                "ensure it implements the MonkeyClaw.Extensions.Plug behaviour"
    end

    unless function_exported?(module, :init, 1) do
      raise ArgumentError,
            "#{inspect(module)} does not export init/1 — " <>
              "ensure it implements the MonkeyClaw.Extensions.Plug behaviour"
    end

    unless function_exported?(module, :call, 2) do
      raise ArgumentError,
            "#{inspect(module)} does not export call/2 — " <>
              "ensure it implements the MonkeyClaw.Extensions.Plug behaviour"
    end

    :ok
  end
end
