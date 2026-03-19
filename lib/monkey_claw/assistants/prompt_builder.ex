defmodule MonkeyClaw.Assistants.PromptBuilder do
  @moduledoc """
  Composes assistant prompt layers into a single system prompt.

  Assistants define up to three prompt layers that compose
  top-to-bottom into the final system prompt sent to BeamAgent:

    1. `system_prompt` — Core identity ("You are MonkeyClaw...")
    2. `persona_prompt` — Personality overlay ("Be concise, prefer functional...")
    3. `context_prompt` — Contextual instructions ("Working on the Elixir project...")

  Non-nil, non-empty layers are joined with double newlines. If all
  layers are nil or empty, the result is `nil` (no system prompt
  sent to BeamAgent).

  ## Design

  This is a pure function module — no side effects, no processes,
  no database access. Safe to call from any process at any time.
  """

  alias MonkeyClaw.Assistants.Assistant

  @doc """
  Build a composed system prompt from an assistant's prompt layers.

  Concatenates non-nil, non-empty layers in order with double newlines.
  Returns `nil` if all layers are nil or empty.

  ## Examples

      iex> assistant = %MonkeyClaw.Assistants.Assistant{
      ...>   system_prompt: "You are helpful.",
      ...>   persona_prompt: "Be concise.",
      ...>   context_prompt: nil
      ...> }
      iex> MonkeyClaw.Assistants.PromptBuilder.build_system_prompt(assistant)
      "You are helpful.\\n\\nBe concise."

      iex> assistant = %MonkeyClaw.Assistants.Assistant{
      ...>   system_prompt: nil,
      ...>   persona_prompt: nil,
      ...>   context_prompt: nil
      ...> }
      iex> MonkeyClaw.Assistants.PromptBuilder.build_system_prompt(assistant)
      nil
  """
  @spec build_system_prompt(Assistant.t()) :: String.t() | nil
  def build_system_prompt(%Assistant{} = assistant) do
    [assistant.system_prompt, assistant.persona_prompt, assistant.context_prompt]
    |> Enum.reject(fn layer -> is_nil(layer) or layer == "" end)
    |> case do
      [] -> nil
      layers -> Enum.join(layers, "\n\n")
    end
  end
end
