defmodule MonkeyClaw.Vault.SecretScannerPlug do
  @moduledoc """
  Extension plug that scans and redacts secrets from pipeline events.

  SecretScannerPlug integrates `MonkeyClaw.Vault.SecretScanner` into
  the extension pipeline. It intercepts two hook points:

    * `:query_pre` — Scans the outbound prompt before it is sent to
      the AI model. Any discovered secrets are redacted in-place so
      the model never receives plaintext credentials.

    * `:query_post` — Scans the last message in the response message
      list (when it is an assistant message). Any discovered secrets
      are redacted before the response is returned to the caller.

  All other events pass through unchanged.

  ## Security Invariant

  Secrets in user-supplied prompts and model responses are redacted
  before they cross trust boundaries. This plug enforces that
  invariant at the pipeline level without requiring callers to
  pre-sanitize content.

  ## Assigns

  When redaction occurs, the plug sets `:secrets_redacted` in
  `context.assigns` with the count of secrets found. Downstream
  plugs can inspect this value to make policy decisions (e.g.,
  logging, alerting).

  ## Usage

      {:ok, pipeline} = Pipeline.compile(:query_pre, [
        {MonkeyClaw.Vault.SecretScannerPlug, timeout_ms: 150, max_bytes: 524_288}
      ])

  ## Design

  This is NOT a process. The plug is a plain module implementing the
  `MonkeyClaw.Extensions.Plug` behaviour. All state is passed through
  `init/1` and `call/2`.
  """

  @behaviour MonkeyClaw.Extensions.Plug

  alias MonkeyClaw.Extensions.Context
  alias MonkeyClaw.Vault.SecretScanner

  @type opts :: [timeout_ms: pos_integer(), max_bytes: pos_integer()]

  @doc """
  Initialize the plug with configuration options.

  Accepted options:

    * `:timeout_ms` — Maximum milliseconds for each scan (default: 100).
    * `:max_bytes` — Maximum byte size of content to scan
      (default: 1_048_576).

  Returns the options keyword list as runtime state, which is passed
  to `call/2` on every invocation.
  """
  @impl MonkeyClaw.Extensions.Plug
  @spec init(opts()) :: opts()
  def init(opts) when is_list(opts), do: opts

  @doc """
  Execute the plug on a pipeline context.

  Pattern-matches on `context.event`:

    * `:query_pre` — Scans `context.data.prompt`. If secrets are
      found, the prompt is redacted and `context.data` is updated.
      `:secrets_redacted` is set in `context.assigns` with the count.

    * `:query_post` — Scans the content of the last message in
      `context.data.messages` if it exists and is an assistant
      message. If secrets are found, the message content is redacted
      and `context.data.messages` is updated. `:secrets_redacted` is
      set in `context.assigns` with the count.

    * Any other event — the context is returned unchanged.

  Returns the (possibly updated) context.
  """
  @impl MonkeyClaw.Extensions.Plug
  @spec call(Context.t(), opts()) :: Context.t()
  def call(%Context{event: :query_pre} = context, opts) do
    prompt = Map.get(context.data, :prompt, "")

    case SecretScanner.scan_and_redact(prompt, opts) do
      {:ok, redacted_prompt, count} when count > 0 ->
        context
        |> Map.update!(:data, &Map.put(&1, :prompt, redacted_prompt))
        |> Context.assign(:secrets_redacted, count)

      {:ok, _prompt, 0} ->
        context

      {:error, reason} ->
        # Fail-closed: if scanning fails, do not allow potentially
        # secret-laden content through to the model.
        context
        |> Context.assign(:secret_scan_error, reason)
        |> Context.halt()
    end
  end

  def call(%Context{event: :query_post} = context, opts) do
    messages = Map.get(context.data, :messages, [])

    case List.last(messages) do
      %{role: "assistant", content: content} when is_binary(content) ->
        redact_last_message(context, messages, content, opts)

      _other ->
        context
    end
  end

  def call(%Context{} = context, _opts), do: context

  # ── Private ──────────────────────────────────────────────────────

  @spec redact_last_message(Context.t(), list(), String.t(), opts()) :: Context.t()
  defp redact_last_message(context, messages, content, opts) do
    case SecretScanner.scan_and_redact(content, opts) do
      {:ok, redacted_content, count} when count > 0 ->
        updated_messages =
          List.update_at(messages, -1, fn msg -> %{msg | content: redacted_content} end)

        context
        |> Map.update!(:data, &Map.put(&1, :messages, updated_messages))
        |> Context.assign(:secrets_redacted, count)

      {:ok, _content, 0} ->
        context

      {:error, reason} ->
        # Fail-closed: if scanning the assistant response fails,
        # halt to prevent potential secret leakage to the caller.
        context
        |> Context.assign(:secret_scan_error, reason)
        |> Context.halt()
    end
  end
end
