defmodule MonkeyClawWeb.CacheBodyReader do
  @moduledoc """
  Custom body reader that caches the raw request body in `conn.private`.

  `Plug.Parsers` consumes the request body during parsing, making
  it unavailable for downstream computations. Webhook HMAC
  verification requires the exact raw bytes that were signed, so
  this reader preserves them in `conn.private[:raw_body]`.

  ## Usage

  Configured as the `:body_reader` option for `Plug.Parsers` in
  the endpoint:

      plug Plug.Parsers,
        body_reader: {MonkeyClawWeb.CacheBodyReader, :read_body, []},
        ...

  ## Chunked Reads

  `Plug.Parsers` may call the body reader multiple times for large
  payloads. Each chunk is appended to the accumulated body in
  `conn.private[:raw_body]`. After parsing completes, the full
  raw body is available as a single binary.

  ## Design

  This module is NOT a process. It is a stateless callback module
  invoked by `Plug.Parsers` during request processing.
  """

  @doc """
  Read the request body and cache raw bytes in conn.private.

  Delegates to `Plug.Conn.read_body/2` and accumulates the result
  in `conn.private[:raw_body]`. Handles both complete reads
  (`{:ok, body, conn}`) and partial reads (`{:more, chunk, conn}`).
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
    conn.private[:raw_body] || ""
  end

  # Append a chunk to the accumulated raw body in conn.private.
  @spec accumulate_body(Plug.Conn.t(), binary()) :: Plug.Conn.t()
  defp accumulate_body(conn, chunk) do
    existing = conn.private[:raw_body] || ""
    Plug.Conn.put_private(conn, :raw_body, existing <> chunk)
  end
end
