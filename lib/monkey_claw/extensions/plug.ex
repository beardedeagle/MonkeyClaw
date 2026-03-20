defmodule MonkeyClaw.Extensions.Plug do
  @moduledoc """
  Behaviour for MonkeyClaw extension plugs.

  A plug is the fundamental building block of MonkeyClaw's extension
  system. It follows the init/call pattern: `init/1` is called once
  at pipeline compilation time, and `call/2` is called for each
  event that passes through the pipeline.

  ## Implementing a Plug

      defmodule MyApp.Extensions.AuditLog do
        @behaviour MonkeyClaw.Extensions.Plug

        @impl true
        def init(opts), do: Keyword.get(opts, :level, :info)

        @impl true
        def call(context, level) do
          Logger.log(level, "Extension event: \#{context.event}")
          context
        end
      end

  ## Contract

    * `init/1` — Receives configuration options, returns runtime
      state. Called once when the pipeline is compiled. Must be a
      pure function — no side effects, no process spawning, no
      database access.

    * `call/2` — Receives the context and the runtime state from
      `init/1`. Must return an updated context struct. May call
      `Context.halt/1` to stop the pipeline.

  ## What Plugs Extend

  Plugs extend MonkeyClaw the application — policy engines, audit
  logging, content filtering, rate limiting, channel adapters. They
  do NOT replace agent-level extensions (MCP, skills, plugins) which
  flow through BeamAgent.

  ## Design

  This is a behaviour definition, not a process. Plug modules are
  plain Elixir modules that implement the two callbacks.
  """

  alias MonkeyClaw.Extensions.Context

  @doc """
  Initialize the plug with configuration options.

  Called once when the extension pipeline is compiled. The return
  value is passed as the second argument to `call/2` on every
  invocation.

  Must be a pure function — no side effects, no process spawning,
  no database access.
  """
  @callback init(opts :: term()) :: term()

  @doc """
  Execute the plug on a context.

  Receives the current pipeline context and the runtime state from
  `init/1`. Must return an updated `MonkeyClaw.Extensions.Context.t()`.

  To halt the pipeline (preventing downstream plugs from executing),
  call `MonkeyClaw.Extensions.Context.halt/1` on the context before
  returning it.
  """
  @callback call(context :: Context.t(), opts :: term()) :: Context.t()
end
