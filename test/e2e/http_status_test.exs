#
# The HTTP status codes of the endpoint over the wire: the refusals that
# do not depend on a feature of the server (the body shape, the headers,
# the session id, the origin) and the limit on the number of sessions.
#
defmodule OzMcp.E2E.HttpStatusTest do
  use OzMcp.E2ECase, async: true

  alias OzMcp.Sessions
  alias Support.Helpers.PersistentSnapshot
  alias Support.Helpers.Utils
  alias Support.Servers

  @json [{"content-type", "application/json"}]
  @authorized [{"authorization", "Bearer alice-token"}]
  @authorized_bob [{"authorization", "Bearer bob-token"}]

  test "a request with no session id gets 400", %{base_url: url} do
    client = Client.new(url)

    {_client, {400, _h, %{"error" => %{"code" => -32600, "message" => "missing session id"}}}} =
      Client.request(client, "tools/list")
  end

  test "a body that is not JSON gets 400", %{base_url: url} do
    client = Client.new(url)

    {_client, {400, _h, %{"error" => %{"code" => -32700, "message" => "parse error"}}}} =
      Client.send_raw(client, :post, "this is not json", headers: @json)
  end

  test "a batch body gets 400", %{base_url: url} do
    client = Client.new(url)

    body =
      ~s([{"jsonrpc":"2.0","id":1,"method":"ping"},{"jsonrpc":"2.0","id":2,"method":"ping"}])

    {_client,
     {400, _h, %{"error" => %{"code" => -32600, "message" => "batching is not supported"}}}} =
      Client.send_raw(client, :post, body, headers: @json)
  end

  test "a message with a method and an error gets 400", %{base_url: url} do
    client = Client.new(url)

    body = ~s({"jsonrpc":"2.0","method":"ping","error":{"code":-32603,"message":"boom"}})

    {_client, {400, _h, %{"error" => %{"code" => -32600}}}} =
      Client.send_raw(client, :post, body, headers: @json)
  end

  test "an unknown session id gets 404", %{base_url: url} do
    client = Client.new(url)

    {_client, {404, _h, %{"error" => %{"code" => -32001, "message" => "invalid session"}}}} =
      Client.request(client, "ping", %{}, headers: [{"mcp-session-id", "no-such-session"}])
  end

  test "a DELETE of an unknown session gets 404", %{base_url: url} do
    client = Client.new(url)

    {_client, {404, _h, %{"error" => %{"code" => -32001}}}} =
      Client.delete(client, headers: [{"mcp-session-id", "no-such-session"}])
  end

  test "an unsupported method gets 405 with the Allow header", %{base_url: url} do
    client = Client.new(url)

    {_client, {405, headers, %{"error" => %{"code" => -32600}}}} =
      Client.send_raw(client, :put, nil)

    assert ["GET, POST, DELETE, OPTIONS"] = for({"allow", [v]} <- headers, do: v)
  end

  test "a POST with no Accept header gets 406", %{base_url: url} do
    client = Client.new(url)

    {_client,
     {406, _h, %{"error" => %{"code" => -32600, "message" => "accept header is required"}}}} =
      Client.send_raw(client, :post, "{}", with_defaults: false, headers: @json)
  end

  test "a POST whose Accept header lacks application/json gets 406", %{base_url: url} do
    client = Client.new(url)

    {_client, {406, _h, %{"error" => %{"code" => -32600}}}} =
      Client.send_raw(client, :post, "{}",
        with_defaults: false,
        headers: @json ++ [{"accept", "text/event-stream"}]
      )
  end

  test "a POST with a content type that is not JSON gets 415", %{base_url: url} do
    client = Client.new(url)

    {_client,
     {415, _h,
      %{"error" => %{"code" => -32600, "message" => "content type must be application/json"}}}} =
      Client.send_raw(client, :post, "hello", headers: [{"content-type", "text/plain"}])
  end

  # A partial body gets 408 only from a host server with a read timeout
  # for a request body. Cowboy has none: it holds the connection until the
  # client gives up, so this test runs on Bandit only.
  #
  if OzMcp.E2E.HttpServer.env_kind() == :cowboy do
    @tag skip: "Bandit only: Cowboy has no read timeout for a request body"
  end

  @tag timeout: 40_000
  test "a body that never arrives in full gets 408, not 500", %{base_url: url} do
    #
    # A request head that promises 100 bytes of body and 10 bytes of it:
    # the read of the body times out (the read timeout of the parser)
    # and the endpoint answers 408 with the JSON-RPC error envelope.
    #
    uri = URI.parse(url)

    {:ok, socket} = RawHttp.connect(uri)

    :ok =
      RawHttp.request(
        socket,
        "POST",
        uri,
        [{"content-type", "application/json"}],
        String.duplicate("a", 10),
        content_length: 100
      )

    assert {:ok, response} = RawHttp.read_response(socket)
    assert String.starts_with?(response, "HTTP/1.1 408")
    assert response =~ "request body timeout"

    :ok = RawHttp.close(socket)
  end

  @tag server_opts: %{max_sessions: 1}
  test "an initialize over a pool that holds a live stream gets 429", %{base_url: url} do
    client = url |> Client.new() |> Client.ready!()
    {_response, _sse} = Client.open_get(client)

    {_client, {429, _h, %{"error" => %{"code" => -32000, "message" => "too many sessions"}}}} =
      Client.initialize(Client.new(url))
  end

  @tag server_opts: %{max_sessions: 20}
  test "an initialize over the full pool ends the oldest idle session", %{
    base_url: url,
    instance: instance
  } do
    clients =
      for n <- 1..20 do
        client = Client.new(url)

        {client, {200, _h, %{"result" => %{"protocolVersion" => "2025-11-25"}}}} =
          Client.initialize(client)

        Utils.set_last_active(instance, client.session_id, n)
        client
      end

    last = Client.new(url)

    {last, {200, _h, %{"result" => %{"protocolVersion" => "2025-11-25"}}}} =
      Client.initialize(last)

    {_, {404, _h, %{"error" => %{"code" => -32001}}}} =
      Client.request(hd(clients), "ping")

    for client <- tl(clients) do
      {_, {200, _h, %{"result" => %{}}}} = Client.request(client, "ping")
    end

    {_, {200, _h, %{"result" => %{}}}} = Client.request(last, "ping")
  end

  @tag server_opts: %{max_sessions: 20}
  test "the same holds for sessions that sent notifications/initialized", %{
    base_url: url,
    instance: instance
  } do
    clients =
      for n <- 1..20 do
        client = url |> Client.new() |> Client.ready!()
        Utils.set_last_active(instance, client.session_id, n)
        client
      end

    last = Client.new(url)

    {last, {200, _h, %{"result" => %{"protocolVersion" => "2025-11-25"}}}} =
      Client.initialize(last)

    {_, {404, _h, %{"error" => %{"code" => -32001}}}} =
      Client.request(hd(clients), "ping")

    for client <- tl(clients) do
      {_, {200, _h, %{"result" => %{}}}} = Client.request(client, "ping")
    end

    {_, {200, _h, %{"result" => %{}}}} = Client.request(last, "ping")
  end

  @tag server_opts: %{max_sessions: 20}
  test "a full pool of live streams gets 429 and no stream closes", %{
    base_url: url,
    instance: instance
  } do
    clients =
      for _ <- 1..20 do
        client = url |> Client.new() |> Client.ready!()
        {_response, _sse} = Client.open_get(client)
        client
      end

    {_client, {429, _h, %{"error" => %{"code" => -32000}}}} = Client.initialize(Client.new(url))

    for client <- clients do
      assert {:ok, _view} = Sessions.lookup(instance, client.session_id)
    end
  end

  @tag server_opts: %{max_sessions: 20}
  test "a full pool of requests in flight gets 429", %{base_url: url, instance: instance} do
    ref = make_ref()
    :ok = Support.Entities.Tools.GateTest.arm(instance, ref)
    on_exit(fn -> Support.Entities.Tools.GateTest.disarm(instance) end)

    calls =
      for _ <- 1..20 do
        client = url |> Client.new() |> Client.ready!()

        Task.async(fn ->
          Client.request(client, "tools/call", %{"name" => "gate", "arguments" => %{}})
        end)
      end

    runners =
      for _ <- 1..20 do
        assert_receive {^ref, :started, pid}, 5_000
        pid
      end

    {_client, {429, _h, %{"error" => %{"code" => -32000}}}} = Client.initialize(Client.new(url))

    for runner <- runners, do: send(runner, {:gate, ref})
    for call <- calls, do: Task.await(call, 5_000)
  end

  @tag server: Servers.Authorized
  @tag server_opts: %{
         resource_url: "https://mcp.example.com/mcp",
         max_sessions_per_principal: 3
       }
  test "a full principal limit ends the oldest idle session of that principal", %{
    base_url: url,
    instance: instance
  } do
    alice =
      for n <- 1..3 do
        client = url |> Client.new(@authorized) |> Client.ready!()
        Utils.set_last_active(instance, client.session_id, n)
        client
      end

    bob = url |> Client.new(@authorized_bob) |> Client.ready!()
    Utils.set_last_active(instance, bob.session_id, 50)

    fourth = Client.new(url, @authorized)

    {fourth, {200, _h, %{"result" => %{"protocolVersion" => "2025-11-25"}}}} =
      Client.initialize(fourth)

    {_, {404, _h, %{"error" => %{"code" => -32001}}}} = Client.request(hd(alice), "ping")
    assert {:error, :no_session} = Sessions.lookup(instance, Enum.at(alice, 0).session_id)

    for client <- tl(alice) ++ [bob, fourth] do
      assert {:ok, _view} = Sessions.lookup(instance, client.session_id)
    end
  end

  @tag server: Servers.Authorized
  @tag server_opts: %{
         resource_url: "https://mcp.example.com/mcp",
         max_sessions_per_principal: 3
       }
  test "a full principal limit of busy sessions gets 429", %{base_url: url} do
    for _ <- 1..3 do
      client = url |> Client.new(@authorized) |> Client.ready!()
      {_response, _sse} = Client.open_get(client, headers: @authorized)
    end

    {_client, {429, _h, %{"error" => %{"code" => -32000}}}} =
      Client.new(url, @authorized) |> Client.initialize()
  end

  @tag server_opts: %{max_sessions: 20}
  test "a flood of parallel initializes ends with at most 20 sessions", %{
    base_url: url,
    instance: instance
  } do
    statuses =
      1..50
      |> Task.async_stream(
        fn _ ->
          {_client, {status, _headers, _body}} = url |> Client.new() |> Client.initialize()
          status
        end,
        max_concurrency: 10,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, status} -> status end)

    assert Enum.all?(statuses, &(&1 in [200, 429]))
    assert Utils.session_count(instance) <= 20
  end

  @tag server_opts: %{max_sessions: 1, session_snapshot: PersistentSnapshot}
  test "a DELETE of a stored session with a full pool gets 429 and ends no session", %{
    base_url: url,
    instance: instance
  } do
    client = url |> Client.new() |> Client.ready!()
    :ok = PersistentSnapshot.put(instance, "stored-delete", snapshot())

    {_client, {429, _h, %{"error" => %{"code" => -32000}}}} =
      Client.delete(Client.new(url),
        headers: [{"mcp-session-id", "stored-delete"}, {"mcp-protocol-version", "2025-11-25"}]
      )

    assert {:ok, _view} = Sessions.lookup(instance, client.session_id)
  end

  @tag server_opts: %{max_sessions: 1, session_snapshot: PersistentSnapshot}
  test "a restore with a full pool ends the oldest idle session", %{
    base_url: url,
    instance: instance
  } do
    client = url |> Client.new() |> Client.ready!()
    :ok = PersistentSnapshot.put(instance, "stored-restore", snapshot())

    {_client, {200, _h, %{"result" => %{}}}} =
      Client.request(Client.new(url), "ping", %{},
        headers: [{"mcp-session-id", "stored-restore"}, {"mcp-protocol-version", "2025-11-25"}]
      )

    assert {:error, :no_session} = Sessions.lookup(instance, client.session_id)
  end

  test "an Origin the server does not allow gets 403 with an empty body", %{base_url: url} do
    client = Client.new(url)

    {_client, {403, headers, nil}} =
      Client.send_raw(client, :post, "{}",
        with_defaults: false,
        headers: [
          {"accept", "application/json, text/event-stream"},
          {"origin", "http://evil.example"},
          {"content-type", "application/json"}
        ]
      )

    assert for({"access-control-allow-origin", [v]} <- headers, do: v) == []
  end

  test "a tools/call with a _meta that is not an object gets a -32602 error with the id", %{
    base_url: url
  } do
    client = Client.new(url) |> Client.ready!()

    {client, {200, _h, body}} =
      Client.request(client, "tools/call", %{"name" => "get_temperature", "_meta" => "x"})

    assert body["id"] == client.next_id - 1

    assert body["error"] == %{"code" => -32602, "message" => "invalid _meta"}
  end

  test "a notification with a _meta that is not an object gets 400 and no id", %{base_url: url} do
    client = Client.new(url) |> Client.ready!()

    {_client, {400, _h, body}} =
      Client.notify(client, "notifications/cancelled", %{
        "requestId" => 1,
        "reason" => "test",
        "_meta" => "x"
      })

    assert body["error"] == %{"code" => -32602, "message" => "invalid _meta"}

    refute Map.has_key?(body, "id")
  end

  test "a POST with two MCP-Protocol-Version headers gets 400", %{base_url: url} do
    client = Client.new(url) |> Client.ready!()

    headers = [
      {"accept", "application/json, text/event-stream"},
      {"origin", "http://localhost"},
      {"content-type", "application/json"},
      {"mcp-session-id", client.session_id},
      {"mcp-protocol-version", client.protocol_version},
      {"mcp-protocol-version", client.protocol_version}
    ]

    body = ~s({"jsonrpc":"2.0","id":1,"method":"ping"})

    {_client,
     {400, _h, %{"error" => %{"code" => -32600, "message" => "unsupported MCP protocol version"}}}} =
      Client.send_raw(client, :post, body, with_defaults: false, headers: headers)
  end

  defp snapshot do
    %{
      principal_key: nil,
      protocol_version: "2025-11-25",
      client_info: %{"name" => "oz-mcp-e2e-client", "version" => "0.0.0"},
      client_capabilities: %{},
      log_level: nil,
      subscriptions: []
    }
  end
end
