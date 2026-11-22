#
# The `request` span and the `session` span over a real connection: a
# request of the client gives one `:start` and one `:stop` on the
# endpoint, with the status of the answer, the result and the metadata
# of the instance and the life of a session gives the span of the
# session with the reason of its end.
#
defmodule OzMcp.E2E.TelemetryTest do
  use OzMcp.E2ECase, async: true

  alias Support.Helpers.TelemetryCapture

  @tag server: OzMcp.E2E.Server
  test "a ping over the endpoint gives the request span", %{
    base_url: url,
    instance: instance,
    server: server
  } do
    ref = TelemetryCapture.attach()

    client = Client.new(url)
    {client, {200, _h, %{"result" => %{}}}} = Client.initialize(client)
    {_client, {200, _h, %{"result" => %{}}}} = Client.request(client, "ping")

    assert_receive(
      {[:oz_mcp, :request, :start], ^ref, %{system_time: _t, monotonic_time: _now},
       %{instance: ^instance, method: "ping"} = start_meta},
      5_000
    )

    assert start_meta.server == server
    assert start_meta.transport == :http_streamable
    assert start_meta.kind == :request
    assert is_reference(start_meta.telemetry_span_context)

    assert_receive(
      {[:oz_mcp, :request, :stop], ^ref, %{duration: duration},
       %{instance: ^instance, method: "ping"} = stop_meta},
      5_000
    )

    assert stop_meta.server == server
    assert stop_meta.transport == :http_streamable
    assert stop_meta.method == "ping"
    assert stop_meta.kind == :request
    assert stop_meta.result == :ok
    assert stop_meta.status == 200
    assert stop_meta.error_code == nil
    assert duration >= 0

    assert stop_meta.telemetry_span_context == start_meta.telemetry_span_context
  end

  @tag server: OzMcp.E2E.Server
  test "a tool that answers an error gives a JSON-RPC error result", %{
    base_url: url,
    instance: instance
  } do
    ref = TelemetryCapture.attach()

    client = Client.new(url)
    {client, {200, _h, %{"result" => %{}}}} = Client.initialize(client)
    {client, {202, _h, nil}} = Client.notify(client, "notifications/initialized")

    {_client, {200, _h, %{"error" => %{"code" => -32601}}}} =
      Client.request(client, "tools/call", %{"name" => "gamma_1"})

    assert_receive(
      {[:oz_mcp, :request, :stop], ^ref, %{duration: _d},
       %{instance: ^instance, method: "tools/call"} = stop_meta},
      5_000
    )

    assert stop_meta.kind == :request
    assert stop_meta.result == :rpc_error
    assert stop_meta.status == 200
    assert stop_meta.error_code == nil
  end

  @tag server: OzMcp.E2E.Server
  test "a notification gives the acceptance and the metadata holds no caller data", %{
    base_url: url,
    instance: instance
  } do
    ref = TelemetryCapture.attach()

    client = Client.new(url)
    {client, {200, _h, %{"result" => %{}}}} = Client.initialize(client)
    {client, {202, _h, nil}} = Client.notify(client, "notifications/initialized")
    {_client, {202, _h, nil}} = Client.notify(client, "notifications/roots/list_changed")

    assert_receive(
      {[:oz_mcp, :request, :stop], ^ref, %{duration: _d},
       %{instance: ^instance, method: "notifications/roots/list_changed"} = stop_meta},
      5_000
    )

    assert stop_meta.kind == :notification
    assert stop_meta.result == :ok
    assert stop_meta.status == 202

    assert_receive(
      {[:oz_mcp, :request, :start], ^ref, _measurements,
       %{instance: ^instance, method: "notifications/roots/list_changed"} = start_meta},
      5_000
    )

    for meta <- [start_meta, stop_meta] do
      refute Map.has_key?(meta, :session_id)
      refute Map.has_key?(meta, :principal)
      refute Map.has_key?(meta, :params)
      refute Map.has_key?(meta, :token)
    end
  end

  @tag server: OzMcp.E2E.Server
  test "an initialize gives the start of the session span", %{
    base_url: url,
    instance: instance,
    server: server
  } do
    ref = TelemetryCapture.attach()

    client = Client.new(url)
    {client, {200, _h, %{"result" => %{}}}} = Client.initialize(client)

    assert_receive(
      {[:oz_mcp, :session, :start], ^ref, %{system_time: _t, monotonic_time: _now},
       %{instance: ^instance} = start_meta},
      5_000
    )

    assert start_meta.instance == instance
    assert start_meta.server == server
    assert start_meta.transport == :http_streamable
    assert start_meta.restored? == false
    assert is_reference(start_meta.telemetry_span_context)

    # A DELETE ends the session: the `:stop` event carries the reason and
    # the span context of the start.
    #
    {_client, {200, _h, nil}} = Client.delete(client)

    assert_receive(
      {[:oz_mcp, :session, :stop], ^ref, %{duration: duration},
       %{instance: ^instance} = stop_meta},
      5_000
    )

    assert stop_meta.instance == instance
    assert stop_meta.server == server
    assert stop_meta.transport == :http_streamable
    assert stop_meta.restored? == false
    assert stop_meta.reason == :terminated
    assert duration >= 0

    assert stop_meta.telemetry_span_context == start_meta.telemetry_span_context
  end

  @tag server: OzMcp.E2E.Server, server_opts: %{max_sessions: 1}
  test "a second initialize over max_sessions gives the limit event", %{
    base_url: url,
    instance: instance,
    server: server
  } do
    ref = TelemetryCapture.attach()

    client = url |> Client.new() |> Client.ready!()
    {_response, _sse} = Client.open_get(client)

    {_other, {429, _headers, %{"error" => error}}} = Client.initialize(Client.new(url))

    assert error["code"] == -32000
    assert error["message"] == "too many sessions"

    assert_receive(
      {[:oz_mcp, :limit, :reached], ^ref, %{count: 1}, %{instance: ^instance} = meta},
      5_000
    )

    assert meta.server == server
    assert meta.limit == :max_sessions
    assert meta.limit_value == 1
    assert meta.scope == :instance
    assert meta.outcome == :refused

    assert MapSet.new(Map.keys(meta)) ==
             MapSet.new([:instance, :server, :limit, :limit_value, :scope, :outcome])
  end

  @tag server: OzMcp.E2E.Server, server_opts: %{max_streams_per_session: 2}
  test "a GET stream over max_streams_per_session gives the limit event of the replacement", %{
    base_url: url,
    instance: instance,
    server: server
  } do
    ref = TelemetryCapture.attach()

    client = Client.new(url) |> Client.ready!()

    {_resp1, _sse1} = Client.open_get(client)
    {_resp2, _sse2} = Client.open_get(client)

    # The third GET goes over the limit of two: the session ends the
    # oldest stream and opens the new one.
    #
    {resp3, _sse3} = Client.open_get(client)
    assert resp3.status == 200

    Client.cancel_stream(resp3)

    assert_receive(
      {[:oz_mcp, :limit, :reached], ^ref, %{count: 1}, %{instance: ^instance} = meta},
      5_000
    )

    assert meta.server == server
    assert meta.limit == :max_streams_per_session
    assert meta.limit_value == 2
    assert meta.scope == :session
    assert meta.outcome == :replaced

    assert MapSet.new(Map.keys(meta)) ==
             MapSet.new([:instance, :server, :limit, :limit_value, :scope, :outcome])
  end
end
