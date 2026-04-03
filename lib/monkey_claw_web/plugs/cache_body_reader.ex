defmodule MonkeyClawWeb.Plugs.CacheBodyReader do
  @moduledoc """
  Custom body reader that caches the raw request body in `conn.private`.

  `Plug.Parsers` consumes the request body during parsing, making
  it unavailable for downstream computations. Webhook HMAC
  verification requires the exact raw bytes that were signed, so
  this reader preserves them in `conn.private[:raw_body_chunks]`.

  ## Scoping

  Body caching is scoped to routes that require signature
  verification: webhook routes (`/api/webhooks/*`) and channel
  webhook routes (`/api/channels/*/webhook`). All other routes
  delegate to `Plug.Conn.read_body/2` without accumulating
  chunks, avoiding unnecessary memory overhead.

  Because `body_reader` is configured at the endpoint level in
  `Plug.Parsers` (before routing), the reader checks
  `conn.path_info` to determine whether to cache.

  ## Usage

  Configured as the `:body_reader` option for `Plug.Parsers` in
  the endpoint:

      plug Plug.Parsers,
        body_reader: {MonkeyClawWeb.Plugs.CacheBodyReader, :read_body, []},
        ...

  ## Chunked Reads

  `Plug.Parsers` may call the body reader multiple times for large
  payloads. Chunks are accumulated as iodata (a list of binaries)
  in `conn.private[:raw_body_chunks]` to avoid O(n^2) binary
  copying. `get_raw_body/1` converts to a flat binary once.

  ## Design

  This module is NOT a process. It is a stateless callback module
  invoked by `Plug.Parsers` during request processing.
  """

  @doc """
  Read the request body and cache raw bytes in conn.private.

  Delegates to `Plug.Conn.read_body/2` and, for webhook routes,
  accumulates the result in `conn.private[:raw_body_chunks]`.
  Non-webhook routes pass through without caching. Handles both
  complete reads (`{:ok, body, conn}`) and partial reads
  (`{:more, chunk, conn}`).
  """
  @spec read_body(Plug.Conn.t(), keyword()) ::
          {:ok, binary(), Plug.Conn.t()}
          | {:more, binary(), Plug.Conn.t()}
          | {:error, term()}
  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} ->
        conn = accumulate_body(conn, body)
        {:ok, body, conn}

      {:more, chunk, conn} ->
        conn = accumulate_body(conn, chunk)
        {:more, chunk, conn}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Retrieve the cached raw body from a conn.

  Returns the full raw body as a binary, or an empty binary if
  no body was cached (e.g., for GET requests).
  """
  @spec get_raw_body(Plug.Conn.t()) :: binary()
  def get_raw_body(conn) do
    case conn.private[:raw_body_chunks] do
      nil -> ""
      chunks -> chunks |> :lists.reverse() |> IO.iodata_to_binary()
    end
  end

  # Prepend a chunk to the accumulated list in conn.private.
  # Chunks are prepended (O(1)) and reversed once in get_raw_body/1
  # to produce a flat iodata list without nested structures.
  #
  # Only caches for routes requiring signature verification — all
  # other routes pass through without accumulating chunks.
  @spec accumulate_body(Plug.Conn.t(), binary()) :: Plug.Conn.t()
  defp accumulate_body(conn, chunk) do
    if signature_verified_path?(conn) do
      existing = conn.private[:raw_body_chunks] || []
      Plug.Conn.put_private(conn, :raw_body_chunks, [chunk | existing])
    else
      conn
    end
  end

  # Check whether the request targets a route that needs raw body
  # for signature verification. path_info is populated by Plug
  # before body parsing, so it is available at this point.
  @spec signature_verified_path?(Plug.Conn.t()) :: boolean()
  defp signature_verified_path?(%Plug.Conn{path_info: ["api", "webhooks" | _]}), do: true
  defp signature_verified_path?(%Plug.Conn{path_info: ["api", "channels" | _]}), do: true
  defp signature_verified_path?(_conn), do: false
end
