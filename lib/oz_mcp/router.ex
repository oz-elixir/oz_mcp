defmodule OzMcp.Router do
  @moduledoc """
  HTTP endpoint of an MCP server: the Streamable HTTP transport.

  A host mounts this plug on a single path and serves it with an HTTP
  server of its choice. The endpoint supports `POST` (client requests
  and notifications), `GET` (the server-to-client event stream),
  `DELETE` (session termination) and `OPTIONS` (CORS preflight). A
  request with another method gets `405` with an `Allow` header, a
  request for another path gets `404` and an instance that does not
  run gets `503`. The order of the checks is: the host, the CORS
  origin, authentication, then the route — so an unsupported method on
  a protected server gets `401` before any token and `405` with a
  valid one.

  The rules of the transport — the origins, the host check, the
  headers, the status codes, the `GET` stream and its resume — live in
  the guide [HTTP transport](guides/runtime/http_transport.md). The
  status rules of the `POST` answers are in OzMcp.Transport.Http.Post,
  the rules of the `GET` stream in OzMcp.Transport.Http.GetStream
  and the `DELETE` route in OzMcp.Transport.Http.Delete.

  ## The end of a session process

  A `GET` stream monitors the session process that owns it. When that
  process stops, the stream writes a `retry:` hint and ends. A resumer of
  a `POST` stream does the same. The client connects again with its
  `Last-Event-ID`:

    * When the session is lost (its process crashed and no snapshot keeps
      it) the client gets `404` and sends `initialize` again.
    * With a snapshot module (`OzMcp.Session.Snapshot`) that keeps the
      session, the session starts again at the next request of the client.

  One warning is written for each stream that closes this way. The
  warning holds no session id and no event id (these are client data).

  ## Disconnect

  The framework does **not** cancel a request when the client
  disconnects: the callback goes on and its later messages and its
  response are written to the event log of the session (see
  OzMcp.PostStream). The guide gives the contract of the host server
  and the table of the two supported servers.
  """

  use Plug.Router

  alias OzMcp.Auth.{Challenge, Gate}
  alias OzMcp.Context.Error
  alias OzMcp.Transport.Http.{Cors, Delete, GetStream, Host, Post, Response}

  require Logger

  # The gate runs before the parser: an anonymous client cannot make
  # the server read its body.
  #
  plug :match
  plug :authenticate
  plug :parse_body
  plug :dispatch

  # With no Content-Type, Plug.Parsers leaves an empty map and skips
  # the 415, so the route refuses it here.
  #
  defp parse_body(%Plug.Conn{method: "POST"} = conn, _opts) do
    case get_req_header(conn, "content-type") do
      [] ->
        conn
        |> Response.refuse_body(:http_unsupported_media_type)
        |> halt()

      _ ->
        length = conn.private.oz_mcp_max_body_bytes
        Plug.Parsers.call(conn, parsers(length))
    end
  end

  defp parse_body(conn, _opts), do: conn

  # The body limit is a runtime option: the options are built per
  # request. Cheap; measure before a change.
  #
  defp parsers(length) do
    Plug.Parsers.init(
      parsers: [:json],
      json_decoder: {OzMcp.Wire, :decode!, []},
      length: length
    )
  end

  # The shape of the failure, with no byte of the body in the log.
  #
  defp parse_error_shape(%Plug.Parsers.ParseError{exception: %module{}}), do: inspect(module)
  defp parse_error_shape(_error), do: "unknown"

  # Whether a response head went out, for the last resort. The keys are
  # reset before each request (keep-alive reuses the process).
  #
  @response_started_key :oz_mcp_response_started
  @request_id_key :oz_mcp_request_id

  @impl true
  def init(opts) do
    instance = Keyword.get(opts, :instance) || Keyword.fetch!(opts, :server)
    Keyword.put(opts, :instance, instance)
  end

  @impl true
  def call(conn, opts) do
    instance = Keyword.get(opts, :instance) || Keyword.fetch!(opts, :server)
    opts = Keyword.put(opts, :instance, instance)
    conn = put_private(conn, :instance, instance)

    with {:ok, config} <- OzMcp.Instance.config(instance),
         true <- Host.allowed?(conn, config.opts.allowed_hosts),
         {:ok, origin} <- Cors.validate_cors_origin(conn, opts, config) do
      #
      # The config travels on the conn: one Registry read per request.
      #
      conn =
        conn
        |> put_private(:oz_mcp_config, config)
        |> put_private(:oz_mcp_telemetry, config.telemetry)
        |> put_private(:oz_mcp_max_body_bytes, config.opts.max_body_bytes)
        |> put_private(:cors_origin, origin)

      # Whether a response head went out, for the last resort below.
      #
      Process.delete(@response_started_key)
      Process.delete(@request_id_key)
      conn = Plug.Conn.register_before_send(conn, &Response.mark_response_started/1)

      try do
        super(conn, opts)
      rescue
        #
        # A body the endpoint can never read keeps the JSON-RPC error
        # envelope. The warning holds no text of the request: the
        # message can hold bytes of the body.
        #
        Plug.Parsers.UnsupportedMediaTypeError ->
          Logger.warning("Unsupported request media type")
          Response.refuse_body(conn, :http_unsupported_media_type)

        error in Plug.Parsers.ParseError ->
          Logger.warning("Unparseable request body (#{parse_error_shape(error)})")
          Response.refuse_body(conn, :http_parse_error)

        Plug.Parsers.RequestTooLargeError ->
          Logger.warning("Request body over max_body_bytes")
          Response.refuse_body(conn, :http_payload_too_large)

        # Plug.Router wraps a raise in Plug.Conn.WrapperError.
        #
        error in Plug.Conn.WrapperError ->
          Response.last_resort(conn, error.kind, error.reason, error.stack)

        error ->
          #
          # A body that arrives too slowly raises with the plug status
          # 408; the classification goes by status and names no server
          # module. Every other failure: the last resort answers 500.
          #
          if Plug.Exception.status(error) == 408 do
            Logger.warning("Request body read timeout")
            Response.refuse_body(conn, :http_request_timeout)
          else
            Response.last_resort(conn, :error, error, __STACKTRACE__)
          end
      catch
        #
        # A throw, or an exit of a failed call (a GenServer that is gone or
        # too slow). Exits that mean "this process is being stopped" are
        # not ours to answer: they pass through.
        #
        :exit, reason when reason in [:normal, :shutdown] ->
          exit(reason)

        :exit, {:shutdown, _} = reason ->
          exit(reason)

        kind, reason ->
          Response.last_resort(conn, kind, reason, __STACKTRACE__)
      end
    else
      #
      # 503 before the host and the origin checks; a refused host or
      # origin gets 403 with an empty body.
      #
      :not_running ->
        conn
        |> Response.unavailable()
        |> halt()

      false ->
        conn
        |> Response.empty(403)
        |> halt()

      :forbidden ->
        conn
        |> Response.empty(403)
        |> halt()
    end
  end

  # CORS management (see `OzMcp.Transport.Http.Cors`).
  #
  options _ do
    Cors.preflight(conn)
  end

  # A CORS preflight carries no credentials: it is not checked.
  #
  defp authenticate(%Plug.Conn{method: "OPTIONS"} = conn, _opts), do: conn

  defp authenticate(conn, _opts) do
    instance = conn.private.instance
    config = conn.private[:oz_mcp_config]

    case Gate.run(conn, instance, config) do
      :disabled ->
        conn

      {:ok, principal} ->
        put_private(conn, :oz_mcp_principal, principal)

      {:refuse, challenge, metadata_url} ->
        refuse(conn, instance, challenge, metadata_url)

      # The instance stopped between the host check and the gate.
      #
      :not_running ->
        conn |> Response.unavailable() |> halt()

      :error ->
        {status, data} = Error.build(Error.new(:http_internal_error), nil)
        conn |> Response.json(status, data) |> halt()
    end
  end

  # The challenge travels in the WWW-Authenticate header; the body
  # holds no detail of the refusal.
  #
  defp refuse(conn, instance, challenge, metadata_url) do
    header = Gate.header(challenge, instance, metadata_url)
    {status, data} = Error.build(Error.new(Challenge.error_code(challenge)), nil)

    conn
    |> put_resp_header("www-authenticate", header)
    |> Response.json(status, data)
    |> halt()
  end

  post "/" do
    Post.call(conn)
  end

  get "/" do
    GetStream.call(conn)
  end

  delete "/" do
    Delete.call(conn)
  end

  # Any other method on the endpoint path, or any other path. OPTIONS
  # on any path keeps its 204: the preflight route answered earlier.
  #
  match "/" do
    Cors.method_not_allowed(conn)
  end

  match _ do
    {status, data} = Error.build(Error.new(:http_not_found), nil)
    conn |> Response.json(status, data) |> halt()
  end

  # The tests of the error table call it through the router.
  #
  @doc false
  def handle_context_error(context), do: Response.handle_context_error(context)
end
