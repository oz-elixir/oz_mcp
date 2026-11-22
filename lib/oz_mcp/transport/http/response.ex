#
# One writer for every answer of the endpoint: the JSON answers, the
# empty answers and the answers of a halted pipeline stage. An answer
# with no body carries no `content-type`.
#
defmodule OzMcp.Transport.Http.Response do
  @moduledoc false

  import Plug.Conn

  alias OzMcp.Transport.Http.Cors
  alias OzMcp.Wire

  require Logger

  @response_started_key :oz_mcp_response_started

  # The id travels in the process dictionary: the `rescue` clauses of the
  # router keep the entry conn and a private member put deeper is lost.
  #
  @request_id_key :oz_mcp_request_id

  @error_code_key :oz_mcp_error_code

  @doc false
  @spec put_error_code(Plug.Conn.t(), atom()) :: Plug.Conn.t()
  def put_error_code(conn, code), do: put_private(conn, @error_code_key, code)

  # An answer with no body and no `content-type`.
  #
  @spec empty(Plug.Conn.t(), pos_integer()) :: Plug.Conn.t()
  def empty(conn, status) do
    conn
    |> Cors.put_cors_headers()
    |> send_resp(status, "")
  end

  # A JSON answer. `body` is encoded text, or a term that
  # `OzMcp.Wire.encode_answer/1` encodes.
  #
  @spec json(Plug.Conn.t(), pos_integer(), iodata() | map()) :: Plug.Conn.t()
  def json(conn, status, body) when is_map(body),
    do: json(conn, status, Wire.encode_answer(body))

  def json(conn, status, body) do
    conn
    |> Cors.put_cors_headers()
    |> put_resp_header("content-type", "application/json;charset=UTF-8")
    |> send_resp(status, body)
  end

  # The answer of a pipeline: a passed context goes on, a halted one gets
  # its error answer.
  #
  @spec unwrap(OzMcp.Pipeline.result()) :: OzMcp.Context.t()
  def unwrap({:cont, context}), do: context

  def unwrap({:halt, context}), do: handle_context_error(context)

  # The error answer of a halted context, from the error table; the code
  # travels on the conn as `:oz_mcp_error_code`.
  #
  @spec handle_context_error(OzMcp.Context.t()) :: OzMcp.Context.t()
  def handle_context_error(context) when is_nil(context.error), do: context

  def handle_context_error(context) do
    {status, data} = OzMcp.Context.Error.build(context.error, context.rpc_id, context.rpc_kind)

    conn =
      context.conn
      |> put_error_headers(OzMcp.Context.Error.headers(context.error))
      |> put_private(@error_code_key, context.error.code)
      |> json(status, data)
      |> halt()

    Map.put(context, :conn, conn)
  end

  # Headers carried by an error, with lower-case names, as Plug requires.
  #
  @spec put_error_headers(Plug.Conn.t(), [OzMcp.Context.Error.header()]) :: Plug.Conn.t()
  def put_error_headers(conn, []), do: conn

  def put_error_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {name, value}, acc ->
      put_resp_header(acc, name, value)
    end)
  end

  # Last resort: a failure outside the guarded callbacks gives the generic
  # JSON-RPC internal error with an HTTP 500. The log names the failure by
  # its type (the frames can hold the authorization header). When the
  # response head is on the wire, the failure is re-raised.
  #
  @spec last_resort(Plug.Conn.t(), atom(), term(), list()) :: Plug.Conn.t() | no_return()
  def last_resort(conn, kind, reason, stacktrace) do
    Logger.error(
      "Unexpected failure while handling the request: " <>
        OzMcp.Utils.Log.describe(kind, reason, stacktrace) <>
        "\n" <> OzMcp.Utils.Log.format_stacktrace(stacktrace)
    )

    Logger.debug(fn ->
      "Unexpected failure text: " <> OzMcp.Utils.Log.banner(kind, reason, stacktrace)
    end)

    if Process.get(@response_started_key) do
      :erlang.raise(kind, reason, stacktrace)
    else
      internal_error(conn, Process.get(@request_id_key))
    end
  end

  @doc false
  @spec remember_request_id(term()) :: :ok
  def remember_request_id(id) when is_binary(id) or is_integer(id) do
    Process.put(@request_id_key, id)
    :ok
  end

  def remember_request_id(_id), do: :ok

  @doc false
  @spec mark_response_started(Plug.Conn.t()) :: Plug.Conn.t()
  def mark_response_started(conn) do
    Process.put(@response_started_key, true)
    conn
  end

  # The answer of a store failure. GET and DELETE have no id.
  #
  @spec internal_error(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def internal_error(conn, rpc_id \\ nil) do
    {status, data} =
      OzMcp.Context.Error.build(OzMcp.Context.Error.new(:http_internal_error), rpc_id)

    conn
    |> put_error_code(:http_internal_error)
    |> json(status, data)
  end

  # The answer when the instance cannot answer (503): the caller may
  # retry later.
  #
  @spec unavailable(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def unavailable(conn, rpc_id \\ nil) do
    {status, data} = OzMcp.Context.Error.build(OzMcp.Context.Error.new(:http_unavailable), rpc_id)

    conn
    |> put_error_code(:http_unavailable)
    |> json(status, data)
  end

  # The answer to a body that is not a JSON-RPC message; it carries no id.
  #
  @spec refuse_body(Plug.Conn.t(), atom()) :: Plug.Conn.t()
  def refuse_body(conn, code) do
    {status, data} = OzMcp.Context.Error.build(OzMcp.Context.Error.new(code), nil)
    conn |> put_error_code(code) |> json(status, data)
  end

  # The id a POST may echo. A message that is not a request carries no id.
  #
  @spec reply_id(OzMcp.Context.t()) :: term()
  def reply_id(context) do
    if OzMcp.Context.request?(context), do: context.rpc_id, else: nil
  end

  # 404 answered outside of the validation pipeline.
  #
  @spec invalid_session(Plug.Conn.t()) :: Plug.Conn.t()
  def invalid_session(conn) do
    {status, data} =
      OzMcp.Context.Error.build(OzMcp.Context.Error.new(:http_invalid_session), nil)

    conn
    |> put_error_code(:http_invalid_session)
    |> json(status, data)
  end
end
