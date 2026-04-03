defmodule MonkeyClaw.UserModeling.ObservationPlug do
  @moduledoc """
  Extension plug that observes user interactions for profile building.

  When registered on the `:query_post` hook, this plug extracts
  observation data from the completed query and sends it to the
  `MonkeyClaw.UserModeling.Observer` GenServer for batched
  processing.

  ## How It Works

  1. Receives a `:query_post` context with prompt and messages
  2. Extracts the workspace ID from the context data
  3. Builds an observation map from the prompt and response
  4. Sends the observation to the Observer via async cast

  ## Configuration

  Register in application config AFTER other query_post plugs:

      config :monkey_claw, MonkeyClaw.Extensions,
        hooks: %{
          query_post: [
            {MonkeyClaw.UserModeling.ObservationPlug, []}
          ]
        }

  ## Design

  This is NOT a process. It implements `MonkeyClaw.Extensions.Plug`
  — `init/1` is called once at pipeline compilation, `call/2` is
  called per query event. The plug is intentionally lightweight:
  it extracts data and delegates to the Observer, never performing
  DB writes or heavy computation inline.
  """

  @behaviour MonkeyClaw.Extensions.Plug

  alias MonkeyClaw.Extensions.Context
  alias MonkeyClaw.UserModeling.Observer

  @doc """
  Initialize the observation plug.

  No configuration required. Options are accepted for
  compatibility with the plug interface.
  """
  @impl true
  @spec init(keyword()) :: keyword()
  def init(opts) when is_list(opts), do: opts

  @doc """
  Observe a completed query interaction.

  Only processes `:query_post` events with a valid workspace ID
  and non-empty prompt. Sends observations to the Observer
  asynchronously — never blocks the pipeline or performs DB writes.

  For non-`:query_post` events, passes the context through unchanged.
  """
  @impl true
  @spec call(Context.t(), keyword()) :: Context.t()
  def call(%Context{event: :query_post} = ctx, _opts) do
    prompt = Map.get(ctx.data, :prompt, "")
    workspace_id = Map.get(ctx.data, :workspace_id)
    messages = Map.get(ctx.data, :messages, [])

    if is_binary(workspace_id) and byte_size(workspace_id) > 0 and
         is_binary(prompt) and byte_size(prompt) > 0 do
      observation = build_observation(prompt, messages)
      Observer.observe(workspace_id, observation)
    end

    ctx
  end

  # Pass through non-query_post events unchanged.
  def call(ctx, _opts), do: ctx

  # ──────────────────────────────────────────────
  # Private
  # ──────────────────────────────────────────────

  @spec build_observation(String.t(), list()) :: Observer.observation()
  defp build_observation(prompt, messages) do
    response = extract_assistant_response(messages)

    if is_binary(response) and byte_size(response) > 0 do
      %{prompt: prompt, response: response}
    else
      %{prompt: prompt}
    end
  end

  # Extract the last assistant message content from the response.
  @spec extract_assistant_response(list()) :: String.t() | nil
  defp extract_assistant_response(messages) when is_list(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{role: :assistant, content: content} when is_binary(content) -> content
      %{"role" => "assistant", "content" => content} when is_binary(content) -> content
      _ -> nil
    end)
  end

  defp extract_assistant_response(_), do: nil
end
