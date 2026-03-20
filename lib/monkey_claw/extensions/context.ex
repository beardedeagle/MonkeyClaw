defmodule MonkeyClaw.Extensions.Context do
  @moduledoc """
  Context struct that flows through the extension pipeline.

  The context carries the event type, domain data, and accumulated
  state through each plug in the pipeline. It follows the same
  pattern as `Plug.Conn` — a struct that plugs receive, transform,
  and return.

  ## Fields

    * `:event` — The hook point atom (e.g., `:query_pre`)
    * `:data` — Event-specific domain data (e.g., prompt, session config)
    * `:assigns` — Scratch space for plug-to-plug communication
    * `:halted` — When `true`, remaining plugs in the pipeline are skipped
    * `:private` — Reserved for MonkeyClaw internals; extensions should
      not read or write this field
    * `:timestamp` — When the context was created (UTC)

  ## Data Field

  The `:data` map carries domain data relevant to the current event.
  Each hook point defines its own data shape:

    * `:query_pre` — `%{session_id: String.t(), prompt: String.t()}`
    * `:session_starting` — `%{session_id: String.t(), config: map()}`
    * `:workspace_created` — `%{workspace: Workspace.t()}`

  Extensions pattern-match on `:event` and extract data accordingly.

  ## Design

  This is NOT a process. Contexts are immutable data structures
  created at the start of pipeline execution and threaded through
  each plug.
  """

  alias MonkeyClaw.Extensions.Hook

  @type t :: %__MODULE__{
          event: Hook.t() | nil,
          data: map(),
          assigns: map(),
          halted: boolean(),
          private: map(),
          timestamp: DateTime.t() | nil
        }

  @enforce_keys [:event]
  defstruct [
    :event,
    :timestamp,
    data: %{},
    assigns: %{},
    halted: false,
    private: %{}
  ]

  @doc """
  Create a new context for a hook event with domain data.

  Validates that the event is a known hook point. Returns
  `{:ok, context}` on success or `{:error, reason}` on failure.

  ## Examples

      iex> {:ok, ctx} = MonkeyClaw.Extensions.Context.new(:query_pre, %{prompt: "Hello"})
      iex> ctx.event
      :query_pre
      iex> ctx.data
      %{prompt: "Hello"}
  """
  @spec new(Hook.t(), map()) :: {:ok, t()} | {:error, {:invalid_hook, term()}}
  def new(event, data \\ %{}) when is_atom(event) and is_map(data) do
    if Hook.valid?(event) do
      {:ok,
       %__MODULE__{
         event: event,
         data: data,
         timestamp: DateTime.utc_now()
       }}
    else
      {:error, {:invalid_hook, event}}
    end
  end

  @doc """
  Create a new context, raising on invalid hook.

  ## Examples

      iex> ctx = MonkeyClaw.Extensions.Context.new!(:query_pre, %{prompt: "Hi"})
      iex> ctx.halted
      false
  """
  @spec new!(Hook.t(), map()) :: t()
  def new!(event, data \\ %{}) when is_atom(event) and is_map(data) do
    case new(event, data) do
      {:ok, context} -> context
      {:error, reason} -> raise ArgumentError, "invalid hook: #{inspect(reason)}"
    end
  end

  @doc """
  Store a key-value pair in the context's assigns.

  Assigns are scratch space for plug-to-plug communication.
  Each plug can read assigns set by previous plugs and set
  new ones for downstream plugs.

  ## Examples

      iex> ctx = MonkeyClaw.Extensions.Context.new!(:query_pre)
      iex> ctx = MonkeyClaw.Extensions.Context.assign(ctx, :user_id, "abc")
      iex> ctx.assigns.user_id
      "abc"
  """
  @spec assign(t(), atom(), term()) :: t()
  def assign(%__MODULE__{} = context, key, value) when is_atom(key) do
    %{context | assigns: Map.put(context.assigns, key, value)}
  end

  @doc """
  Halt the pipeline.

  When a context is halted, remaining plugs in the pipeline
  are skipped. The halted context is returned as the pipeline
  result.

  ## Examples

      iex> ctx = MonkeyClaw.Extensions.Context.new!(:query_pre)
      iex> ctx = MonkeyClaw.Extensions.Context.halt(ctx)
      iex> ctx.halted
      true
  """
  @spec halt(t()) :: t()
  def halt(%__MODULE__{} = context) do
    %{context | halted: true}
  end

  @doc """
  Store a key-value pair in the context's private map.

  Private storage is reserved for MonkeyClaw internals.
  Extensions should NOT use this function — use `assign/3`
  instead.

  ## Examples

      iex> ctx = MonkeyClaw.Extensions.Context.new!(:query_pre)
      iex> ctx = MonkeyClaw.Extensions.Context.put_private(ctx, :internal, true)
      iex> ctx.private.internal
      true
  """
  @spec put_private(t(), atom(), term()) :: t()
  def put_private(%__MODULE__{} = context, key, value) when is_atom(key) do
    %{context | private: Map.put(context.private, key, value)}
  end

  @doc """
  Merge multiple key-value pairs into assigns.

  ## Examples

      iex> ctx = MonkeyClaw.Extensions.Context.new!(:query_pre)
      iex> ctx = MonkeyClaw.Extensions.Context.merge_assigns(ctx, %{a: 1, b: 2})
      iex> ctx.assigns
      %{a: 1, b: 2}
  """
  @spec merge_assigns(t(), map()) :: t()
  def merge_assigns(%__MODULE__{} = context, assigns) when is_map(assigns) do
    %{context | assigns: Map.merge(context.assigns, assigns)}
  end
end
