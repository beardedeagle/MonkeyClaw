defmodule MonkeyClaw.TestPlugs do
  @moduledoc """
  Test extension plug modules for pipeline tests.

  These are real implementations of the `MonkeyClaw.Extensions.Plug`
  behaviour — no mocks. Each plug exercises a specific pipeline
  capability (pass-through, assign, halt, count, crash).
  """

  defmodule PassThrough do
    @moduledoc false
    @behaviour MonkeyClaw.Extensions.Plug

    @impl true
    def init(opts), do: opts

    @impl true
    def call(context, _opts), do: context
  end

  defmodule Assigner do
    @moduledoc false
    @behaviour MonkeyClaw.Extensions.Plug

    alias MonkeyClaw.Extensions.Context

    @impl true
    def init(opts), do: Map.new(opts)

    @impl true
    def call(context, assigns) do
      Context.merge_assigns(context, assigns)
    end
  end

  defmodule Halter do
    @moduledoc false
    @behaviour MonkeyClaw.Extensions.Plug

    alias MonkeyClaw.Extensions.Context

    @impl true
    def init(opts), do: opts

    @impl true
    def call(context, _opts) do
      Context.halt(context)
    end
  end

  defmodule Counter do
    @moduledoc false
    @behaviour MonkeyClaw.Extensions.Plug

    alias MonkeyClaw.Extensions.Context

    @impl true
    def init(opts), do: Keyword.get(opts, :key, :count)

    @impl true
    def call(context, key) do
      current = Map.get(context.assigns, key, 0)
      Context.assign(context, key, current + 1)
    end
  end

  defmodule Exploder do
    @moduledoc false
    @behaviour MonkeyClaw.Extensions.Plug

    @impl true
    def init(opts), do: opts

    @impl true
    def call(_context, _opts) do
      raise "boom"
    end
  end
end
