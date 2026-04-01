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

  # Concatenate text content from all text-type messages.
  defp extract_output(messages) do
    messages
    |> Enum.filter(&text_message?/1)
    |> Enum.map_join("\n", fn msg ->
      to_string(Map.get(msg, :content, Map.get(msg, "content", "")))
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
    |> Enum.filter(&tool_use_message?/1)
    |> Enum.filter(fn msg ->
      name = to_string(Map.get(msg, :name, Map.get(msg, "name", "")))
      MapSet.member?(@file_mutation_tools, name)
    end)
    |> Enum.flat_map(&extract_file_paths/1)
    |> Enum.uniq()
  end

  defp text_message?(%{type: :text}), do: true
  defp text_message?(%{type: "text"}), do: true
  defp text_message?(%{"type" => "text"}), do: true
  defp text_message?(_), do: false

  defp tool_use_message?(%{type: :tool_use}), do: true
  defp tool_use_message?(%{type: "tool_use"}), do: true
  defp tool_use_message?(%{"type" => "tool_use"}), do: true
  defp tool_use_message?(_), do: false

  # Extract file paths from a tool call message.
  # Handles various input shapes from different tool implementations.
  defp extract_file_paths(msg) do
    input = Map.get(msg, :input, Map.get(msg, "input", %{}))

    path_keys = ["path", "file_path", "filepath", "filename", "file"]

    paths =
      Enum.flat_map(path_keys, fn key ->
        case Map.get(input, key) do
          path when is_binary(path) and byte_size(path) > 0 -> [path]
          _ -> []
        end
      end)

    case paths do
      [] ->
        # Try atom keys as fallback
        Enum.flat_map([:path, :file_path, :filepath, :filename, :file], fn key ->
          case Map.get(input, key) do
            path when is_binary(path) and byte_size(path) > 0 -> [path]
            _ -> []
          end
        end)

      found ->
        found
    end
  end
end
