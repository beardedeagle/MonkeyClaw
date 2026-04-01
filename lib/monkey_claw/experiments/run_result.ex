defmodule MonkeyClaw.Experiments.RunResult do
  @moduledoc """
  Normalized run result from agent execution.

  The Runner normalizes raw BeamAgent output before passing it to
  `strategy.evaluate/3`. Strategies NEVER see raw SDK output — this
  prevents beam-agent internals from leaking into domain logic.

  ## Normalization

  Raw messages from `Backend.query/3` are transformed into a
  consistent shape:

    * `output` — Concatenated text content from response messages
    * `tool_calls` — Tool invocation records (name, input, output)
    * `files_changed` — Derived from observed tool activity (file_edit
      tool calls), NEVER trusted from model self-report
    * `metadata` — Usage stats, timing, model info

  ## Design

  This is NOT a process. Pure normalization functions. Safe for
  concurrent use.
  """

  @type t :: %{
          output: String.t(),
          tool_calls: [map()],
          files_changed: [String.t()],
          metadata: map()
        }

  @file_mutation_tools MapSet.new([
                         "file_edit",
                         "file_write",
                         "write_file",
                         "edit_file",
                         "create_file"
                       ])

  @doc """
  Normalize raw agent messages into a structured run result.

  The `metadata` parameter carries external context (timing, model
  info) that isn't part of the raw messages themselves.

  ## Examples

      raw = [
        %{type: :text, content: "I optimized the function."},
        %{type: :tool_use, name: "file_edit", input: %{"path" => "lib/foo.ex"}}
      ]

      RunResult.normalize(raw)
      # => %{
      #   output: "I optimized the function.",
      #   tool_calls: [%{name: "file_edit", input: %{"path" => "lib/foo.ex"}}],
      #   files_changed: ["lib/foo.ex"],
      #   metadata: %{}
      # }
  """
  @spec normalize([map()], map()) :: t()
  def normalize(raw_messages, metadata \\ %{})

  def normalize(raw_messages, metadata) when is_list(raw_messages) and is_map(metadata) do
    %{
      output: extract_output(raw_messages),
      tool_calls: extract_tool_calls(raw_messages),
      files_changed: derive_files_changed(raw_messages),
      metadata: metadata
    }
  end

  def normalize(_raw_messages, metadata) when is_map(metadata) do
    %{output: "", tool_calls: [], files_changed: [], metadata: metadata}
  end

  # ── Private ──────────────────────────────────────────────────

  # Concatenate text content from messages.
  #
  # Supports:
  #   * `:text` / "text" messages with binary `content`
  #   * `:assistant` / "assistant" messages with `content_blocks`
  #     (matches BeamAgent query response format)
  defp extract_output(messages) do
    messages
    |> Enum.flat_map(&extract_message_text/1)
    |> Enum.join("\n")
  end

  defp extract_message_text(msg) when is_map(msg) do
    type = Map.get(msg, :type, Map.get(msg, "type"))

    case type do
      t when t in [:text, "text"] ->
        content = Map.get(msg, :content, Map.get(msg, "content"))
        if is_binary(content), do: [content], else: []

      t when t in [:assistant, "assistant"] ->
        blocks = Map.get(msg, :content_blocks, Map.get(msg, "content_blocks", []))
        if is_list(blocks), do: extract_text_from_blocks(blocks), else: []

      _ ->
        []
    end
  end

  defp extract_message_text(_), do: []

  defp extract_text_from_blocks(blocks) do
    Enum.flat_map(blocks, fn block ->
      text =
        Map.get(
          block,
          :text,
          Map.get(block, "text", Map.get(block, :content, Map.get(block, "content")))
        )

      if is_binary(text) and byte_size(text) > 0, do: [text], else: []
    end)
  end

  # Extract tool_use messages into a clean list of tool call maps.
  defp extract_tool_calls(messages) do
    messages
    |> Enum.filter(&tool_use_message?/1)
    |> Enum.map(fn msg ->
      %{
        name: to_string(Map.get(msg, :name, Map.get(msg, "name", "unknown"))),
        input: Map.get(msg, :input, Map.get(msg, "input", %{})),
        output: Map.get(msg, :output, Map.get(msg, "output"))
      }
    end)
  end

  # Derive files_changed from tool activity — NEVER from model self-report.
  # Examines tool_use messages for file mutation tools and extracts paths.
  defp derive_files_changed(messages) do
    messages
    |> Enum.filter(fn msg ->
      tool_use_message?(msg) and
        MapSet.member?(
          @file_mutation_tools,
          to_string(Map.get(msg, :name, Map.get(msg, "name", "")))
        )
    end)
    |> Enum.flat_map(&extract_file_paths/1)
    |> Enum.uniq()
  end

  defp tool_use_message?(%{type: :tool_use}), do: true
  defp tool_use_message?(%{type: "tool_use"}), do: true
  defp tool_use_message?(%{"type" => "tool_use"}), do: true
  defp tool_use_message?(_), do: false

  # Extract file paths from a tool call message.
  # Handles various input shapes from different tool implementations.
  defp extract_file_paths(msg) do
    input = Map.get(msg, :input, Map.get(msg, "input", %{}))

    string_keys = ["path", "file_path", "filepath", "filename", "file"]
    atom_keys = [:path, :file_path, :filepath, :filename, :file]

    case extract_paths_from_keys(input, string_keys) do
      [] -> extract_paths_from_keys(input, atom_keys)
      found -> found
    end
  end

  defp extract_paths_from_keys(input, keys) do
    Enum.flat_map(keys, fn key ->
      case Map.get(input, key) do
        path when is_binary(path) and byte_size(path) > 0 -> [path]
        _ -> []
      end
    end)
  end
end
