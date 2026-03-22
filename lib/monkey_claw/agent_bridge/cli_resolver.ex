defmodule MonkeyClaw.AgentBridge.CliResolver do
  @moduledoc """
  Resolves CLI executable paths for BeamAgent backends at runtime.

  The Erlang VM may not inherit the user's full shell PATH (e.g.,
  `~/.local/bin` is often missing when started from a non-interactive
  context). This module resolves backend CLI binaries by:

    1. Honoring an explicit `:cli_path` if the user provided one
    2. Searching the system PATH via `System.find_executable/1`
    3. Probing well-known installation directories as fallbacks

  ## Supported Backends

  | Backend     | Binary Name | Transport |
  |-------------|-------------|-----------|
  | `:claude`   | `claude`    | stdio     |
  | `:codex`    | `codex`     | stdio     |
  | `:gemini`   | `gemini`    | stdio     |
  | `:copilot`  | `copilot`   | stdio     |
  | `:opencode` | N/A         | HTTP      |

  HTTP-based backends (`:opencode`) use `base_url` instead of
  `cli_path` and are passed through unchanged.

  ## Design

  This module is NOT a process. It is a pure utility module called
  during session initialization in `MonkeyClaw.AgentBridge.Session`.
  """

  require Logger

  # Backend atom → CLI binary name.
  # Only CLI-based backends are listed; HTTP backends (opencode) are omitted.
  @cli_binaries %{
    claude: "claude",
    codex: "codex",
    gemini: "gemini",
    copilot: "copilot"
  }

  # Well-known installation directories that may not be in the
  # Erlang VM's PATH. Expanded at runtime via Path.expand/1.
  @fallback_dirs [
    "~/.local/bin",
    "/usr/local/bin",
    "/opt/homebrew/bin",
    "~/.nix-profile/bin"
  ]

  @doc """
  Enrich session opts with a resolved `:cli_path`.

  If opts already contain a non-empty `:cli_path`, it is honored
  as-is — the user explicitly chose a path. Otherwise, the backend's
  CLI binary is located dynamically via PATH and fallback probing.

  Returns the opts map unchanged for HTTP-based or unknown backends.

  ## Examples

      # User-specified path is preserved
      resolve(%{backend: :claude, cli_path: "/custom/claude"})
      #=> %{backend: :claude, cli_path: "/custom/claude"}

      # Dynamic resolution adds cli_path
      resolve(%{backend: :claude})
      #=> %{backend: :claude, cli_path: "/Users/me/.local/bin/claude"}

      # HTTP backends pass through
      resolve(%{backend: :opencode, base_url: "http://localhost:4096"})
      #=> %{backend: :opencode, base_url: "http://localhost:4096"}
  """
  @spec resolve(map()) :: map()
  def resolve(%{cli_path: path} = opts) when is_binary(path) and byte_size(path) > 0 do
    opts
  end

  def resolve(%{backend: backend} = opts) when is_map_key(@cli_binaries, backend) do
    binary = Map.fetch!(@cli_binaries, backend)

    case find_binary(binary) do
      {:ok, path} ->
        Logger.debug("CliResolver: #{binary} resolved to #{path}")
        Map.put(opts, :cli_path, path)

      :not_found ->
        Logger.warning(
          "CliResolver: #{binary} not found in PATH or fallback directories " <>
            "(searched: PATH, #{Enum.join(@fallback_dirs, ", ")})"
        )

        opts
    end
  end

  def resolve(opts), do: opts

  @doc """
  Find a CLI binary by name.

  Searches the system PATH first via `System.find_executable/1`,
  then probes well-known fallback directories. Returns
  `{:ok, absolute_path}` or `:not_found`.

  ## Examples

      find_binary("claude")
      #=> {:ok, "/Users/me/.local/bin/claude"}

      find_binary("nonexistent")
      #=> :not_found
  """
  @spec find_binary(String.t()) :: {:ok, String.t()} | :not_found
  def find_binary(name) when is_binary(name) and byte_size(name) > 0 do
    case System.find_executable(name) do
      nil -> probe_fallback_dirs(name)
      path -> {:ok, path}
    end
  end

  @doc """
  Return the known CLI binary name for a backend atom, or `nil`.

  ## Examples

      binary_for_backend(:claude)  #=> "claude"
      binary_for_backend(:opencode) #=> nil
  """
  @spec binary_for_backend(atom()) :: String.t() | nil
  def binary_for_backend(backend) when is_atom(backend) do
    Map.get(@cli_binaries, backend)
  end

  # Probe well-known directories for the binary.
  # Returns {:ok, path} for the first match, or :not_found.
  defp probe_fallback_dirs(name) do
    Enum.find_value(@fallback_dirs, :not_found, fn dir ->
      path = dir |> Path.expand() |> Path.join(name)

      if File.regular?(path) do
        {:ok, path}
      end
    end)
  end
end
