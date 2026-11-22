#
# The CORS checks, the CORS headers of the answers and the preflight of
# `OzMcp.Router`.
#
# A request with an `Origin` must name an allowed origin: the plug option
# `allowed_origins`, else the instance config. A server that does not run
# allows no origin. A refused origin gets `403` with an empty body. The
# rules are in the guide "HTTP transport".
#
defmodule OzMcp.Transport.Http.Cors do
  @moduledoc false

  import Plug.Conn

  alias OzMcp.Transport.Http.Response

  # The `Allow` headers name this list.
  #
  @allow_methods "GET, POST, DELETE, OPTIONS"

  # The wildcard covers the simple headers; `Authorization` is not one of
  # them (the Fetch standard). The metadata document plug uses this value.
  #
  @allow_headers "*, authorization"

  # The `access-control-allow-headers` value of a preflight.
  #
  @spec allow_headers() :: String.t()
  def allow_headers, do: @allow_headers

  # The origin list: the plug option wins, else the instance config.
  #
  @spec allowed_origins(keyword(), OzMcp.Instance.Config.t() | nil) :: [String.t()]
  def allowed_origins(opts, config \\ nil) do
    case Keyword.fetch(opts, :allowed_origins) do
      {:ok, list} ->
        list

      :error ->
        case OzMcp.Instance.config(Keyword.fetch!(opts, :instance), config) do
          {:ok, %{opts: %{allowed_origins: list}}} -> list
          _ -> []
        end
    end
  end

  # The check of the `Origin` header: `{:ok, origin}` (`nil` with no
  # header), or `:forbidden`.
  #
  @spec validate_cors_origin(Plug.Conn.t(), keyword(), OzMcp.Instance.Config.t() | nil) ::
          {:ok, String.t() | nil} | :forbidden
  def validate_cors_origin(conn, opts, config \\ nil) do
    case get_req_header(conn, "origin") do
      [] ->
        {:ok, nil}

      [origin] ->
        if origin in allowed_origins(opts, config), do: {:ok, origin}, else: :forbidden

      _multiple ->
        :forbidden
    end
  end

  # The CORS headers of an answer, when the request carried an allowed
  # origin.
  #
  @spec put_cors_headers(Plug.Conn.t()) :: Plug.Conn.t()
  def put_cors_headers(conn) do
    case conn.private[:cors_origin] do
      nil ->
        conn

      origin ->
        conn
        |> put_resp_header("access-control-allow-origin", origin)
        |> put_resp_header(
          "access-control-expose-headers",
          "mcp-session-id, mcp-protocol-version, www-authenticate"
        )
        |> put_resp_header("vary", "Origin")
    end
  end

  # The answer of an `OPTIONS` preflight: `204` with no body.
  #
  @spec preflight(Plug.Conn.t()) :: Plug.Conn.t()
  def preflight(conn) do
    conn
    |> put_cors_headers()
    |> put_resp_header("access-control-allow-methods", @allow_methods)
    |> put_resp_header("access-control-allow-headers", @allow_headers)
    |> send_resp(204, "")
    |> halt()
  end

  # The answer of a method that the endpoint does not serve: `405` with an
  # `Allow` header. No error log: a client mistake.
  #
  @spec method_not_allowed(Plug.Conn.t()) :: Plug.Conn.t()
  def method_not_allowed(conn) do
    error = OzMcp.Context.Error.new(:http_method_not_allowed, nil, [{"allow", @allow_methods}])
    {status, data} = OzMcp.Context.Error.build(error, nil)

    conn
    |> Response.put_error_headers(OzMcp.Context.Error.headers(error))
    |> Response.json(status, data)
    |> halt()
  end
end
