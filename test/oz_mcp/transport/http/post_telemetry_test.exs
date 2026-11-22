#
# The `request` span of the `POST` route: one `:start` before the
# validation and one `:stop` after the answer, with the status, the
# result and the code of a refusal. The route runs here on the `Plug`
# test connection: the handle of the telemetry travels on the conn, as
# `OzMcp.Router` puts it there.
#
defmodule OzMcp.Transport.Http.PostTelemetryTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias OzMcp.Transport.Http.Post
  alias Support.Helpers.TelemetryCapture
  alias Support.Helpers.Utils
  alias Support.Servers

  @server Servers.Default
  @accept "application/json, text/event-stream"
  @parsers Plug.Parsers.init(parsers: [:json], json_decoder: {OzMcp.Wire, :decode!, []})

  # The instance that serves the server module of this file.
  #
  defp inst, do: Module.concat(@server, __MODULE__)

  setup do
    ref = TelemetryCapture.attach()
    Utils.start_instance(@server, name: inst())
    {:ok, config} = OzMcp.Instance.config(inst())
    session_id = Utils.create_session(inst(), initialized: true)

    %{
      ref: ref,
      telemetry: config.telemetry,
      session_id: session_id
    }
  end

  test "a ping gives one start and one stop with the answer", %{
    ref: ref,
    telemetry: telemetry,
    session_id: session_id
  } do
    conn = rpc_request(session_id, 1, "ping", telemetry)

    assert conn.status == 200

    events = TelemetryCapture.drain(ref, inst())
    assert [start] = named(events, [:request, :start])
    assert [stop] = named(events, [:request, :stop])

    {_, start_measurements, start_meta} = start
    {_, %{duration: duration}, stop_meta} = stop

    assert start_meta ==
             Map.merge(start_meta, %{
               instance: inst(),
               server: @server,
               transport: :http_streamable,
               method: "ping",
               kind: :request
             })

    assert is_integer(start_measurements.system_time)
    assert is_integer(start_measurements.monotonic_time)

    assert stop_meta.method == "ping"
    assert stop_meta.kind == :request
    assert stop_meta.transport == :http_streamable
    assert stop_meta.result == :ok
    assert stop_meta.status == 200
    assert stop_meta.error_code == nil
    assert duration >= 0

    assert stop_meta.telemetry_span_context == start_meta.telemetry_span_context
  end

  test "a method that the server does not serve is reported as unknown", %{
    ref: ref,
    telemetry: telemetry,
    session_id: session_id
  } do
    conn = rpc_request(session_id, 1, "x/y", telemetry)

    assert conn.status == 200
    assert decoded(conn)["error"]["code"] == -32601

    assert [stop] = named(TelemetryCapture.drain(ref, inst()), [:request, :stop])
    {_, _, meta} = stop

    # The text of the method of the client never goes out: the handler
    # answered the JSON-RPC error, so the result is its own.
    #
    assert meta.method == :unknown
    assert meta.kind == :request
    assert meta.status == 200
    assert meta.result == :rpc_error
    assert meta.error_code == nil
  end

  test "a request without the accept header is refused in the span", %{
    ref: ref,
    telemetry: telemetry,
    session_id: session_id
  } do
    message = :json.encode(%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})

    conn =
      conn(:post, "/", IO.iodata_to_binary(message))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("mcp-session-id", session_id)
      |> put_private(:instance, inst())
      |> put_private(:oz_mcp_telemetry, telemetry)
      |> parse()
      |> Post.call()

    assert conn.status == 406

    assert [stop] = named(TelemetryCapture.drain(ref, inst()), [:request, :stop])
    {_, _, meta} = stop

    assert meta.method == "ping"
    assert meta.kind == :request
    assert meta.status == 406
    assert meta.result == :error
    assert meta.error_code == :http_no_accept_header
  end

  test "a refusal of the entity carries the code of the pipeline", %{
    ref: ref,
    telemetry: telemetry,
    session_id: session_id
  } do
    conn = rpc_request(session_id, 1, "tools/call", telemetry, %{"name" => "no_such_tool"})

    assert conn.status == 200
    assert decoded(conn)["error"]["code"] == -32602

    assert [stop] = named(TelemetryCapture.drain(ref, inst()), [:request, :stop])
    {_, _, meta} = stop

    assert meta.method == "tools/call"
    assert meta.status == 200
    assert meta.result == :error
    assert meta.error_code == :rpc_tool_not_found
  end

  test "a batch body is in the span as an invalid message", %{
    ref: ref,
    telemetry: telemetry
  } do
    conn =
      conn(:post, "/", ~s([{"jsonrpc":"2.0","id":1,"method":"ping"}]))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", @accept)
      |> put_private(:instance, inst())
      |> put_private(:oz_mcp_telemetry, telemetry)
      |> parse()
      |> Post.call()

    assert conn.status == 400

    assert [stop] = named(TelemetryCapture.drain(ref, inst()), [:request, :stop])
    {_, _, meta} = stop

    assert meta.method == nil
    assert meta.kind == :invalid
    assert meta.status == 400
    assert meta.result == :error
    assert meta.error_code == :http_batch_not_supported
  end

  test "a request whose id is null has the kind invalid in the span", %{
    ref: ref,
    telemetry: telemetry,
    session_id: session_id
  } do
    message = ~s({"jsonrpc":"2.0","id":null,"method":"ping"})

    conn =
      conn(:post, "/", message)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", @accept)
      |> put_req_header("mcp-session-id", session_id)
      |> put_private(:instance, inst())
      |> put_private(:oz_mcp_telemetry, telemetry)
      |> parse()
      |> Post.call()

    assert conn.status == 400

    assert [start] = named(TelemetryCapture.drain(ref, inst()), [:request, :start])
    {_, _, meta} = start

    assert meta.method == "ping"
    assert meta.kind == :invalid
  end

  test "a notification gives the kind of a notification and the acceptance", %{
    ref: ref,
    telemetry: telemetry,
    session_id: session_id
  } do
    conn = rpc_request(session_id, nil, "notifications/initialized", telemetry)

    assert conn.status == 202

    assert [stop] = named(TelemetryCapture.drain(ref, inst()), [:request, :stop])
    {_, _, meta} = stop

    assert meta.method == "notifications/initialized"
    assert meta.kind == :notification
    assert meta.status == 202
    assert meta.result == :ok
    assert meta.error_code == nil
  end

  test "the metadata of the span holds no data of the caller", %{
    ref: ref,
    telemetry: telemetry,
    session_id: session_id
  } do
    rpc_request(session_id, 1, "ping", telemetry)

    for {_, _, meta} <- TelemetryCapture.drain(ref, inst()) do
      refute Map.has_key?(meta, :session_id)
      refute Map.has_key?(meta, :principal)
      refute Map.has_key?(meta, :params)
      refute Map.has_key?(meta, :token)
    end
  end

  test "a conn without the handle emits nothing", %{ref: ref, session_id: session_id} do
    #
    # The route on the conn of a request that the router refused earlier
    # (the instance, the host, the origin): no handle, no span.
    #
    # The start of the session of the setup is in the mailbox: the drain
    # clears it, so the test sees the events of the route only.
    #
    assert TelemetryCapture.drain(ref, inst()) != []

    conn =
      conn(
        :post,
        "/",
        :json.encode(%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})
        |> IO.iodata_to_binary()
      )
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", @accept)
      |> put_req_header("mcp-session-id", session_id)
      |> put_private(:instance, inst())
      |> parse()
      |> Post.call()

    assert conn.status == 200
    assert TelemetryCapture.drain(ref, inst()) == []
  end

  # The events of one name in the drained list. The drain consumes the
  # mailbox, so the test drains one time and picks the events here.
  #
  defp named(events, tail) do
    event = [:oz_mcp | tail]
    Enum.filter(events, fn {name, _, _} -> name == event end)
  end

  # The route runs without the plugs of the router: the instance and the
  # handle of the telemetry come from the private of the conn and the
  # parser runs as the router runs it.
  #
  defp rpc_request(session_id, id, method, telemetry, params \\ %{}, instance \\ inst()) do
    message =
      %{"jsonrpc" => "2.0", "params" => params}
      |> maybe_put("id", id)
      |> maybe_put("method", method)

    conn =
      conn(:post, "/", :json.encode(message) |> IO.iodata_to_binary())
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", @accept)
      |> put_private(:instance, instance)
      |> put_private(:oz_mcp_telemetry, telemetry)
      |> parse()

    conn =
      if session_id do
        put_req_header(conn, "mcp-session-id", session_id)
      else
        conn
      end

    Post.call(conn)
  end

  defp parse(conn), do: Plug.Parsers.call(conn, @parsers)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp decoded(conn), do: :json.decode(conn.resp_body)
end
