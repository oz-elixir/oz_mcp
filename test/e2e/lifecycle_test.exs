#
# The lifecycle of a session over the wire: the negotiation of the
# protocol version, the start of the session, the refusal of the requests
# that come too early or too late and the deletion of the session.
#
defmodule OzMcp.E2E.LifecycleTest do
  use OzMcp.E2ECase, async: true

  @client_info %{"name" => "oz-mcp-e2e-client", "version" => "0.0.0"}

  test "initialize answers the version the client asked for", %{base_url: url} do
    client = Client.new(url)

    {client, {200, headers, %{"result" => %{"protocolVersion" => "2025-11-25"}}}} =
      Client.request(client, "initialize", %{
        "protocolVersion" => "2025-11-25",
        "capabilities" => %{},
        "clientInfo" => @client_info
      })

    assert [session_id] = for({"mcp-session-id", [v]} <- headers, do: v)
    assert byte_size(session_id) > 0
    assert client.session_id == session_id
  end

  test "initialize answers its latest version when the client asks an unsupported one",
       %{base_url: url} do
    client = Client.new(url)

    {client, {200, _h, %{"result" => %{"protocolVersion" => "2025-11-25"}}}} =
      Client.request(client, "initialize", %{
        "protocolVersion" => "2025-06-18",
        "capabilities" => %{},
        "clientInfo" => @client_info
      })

    assert is_binary(client.session_id)

    # The session of the negotiated version accepts the follow-up messages.
    #
    {client, {202, _h, nil}} = Client.notify(client, "notifications/initialized")
    {_client, {200, _h, %{"result" => %{}}}} = Client.request(client, "ping")
  end

  test "initialize without a protocol version is refused and creates no session",
       %{base_url: url} do
    client = Client.new(url)

    {client, {200, headers, %{"error" => %{"code" => -32602}}}} =
      Client.request(client, "initialize", %{"capabilities" => %{}, "clientInfo" => @client_info})

    assert client.session_id == nil
    assert for({"mcp-session-id", [v]} <- headers, do: v) == []
  end

  test "initialize without client info is refused", %{base_url: url} do
    client = Client.new(url)

    {client, {200, _h, %{"error" => %{"code" => -32602}}}} =
      Client.request(client, "initialize", %{
        "protocolVersion" => "2025-11-25",
        "capabilities" => %{}
      })

    assert client.session_id == nil
  end

  test "initialize with capabilities that are not an object is refused", %{base_url: url} do
    client = Client.new(url)

    {client,
     {200, headers, %{"error" => %{"code" => -32602, "message" => "invalid capabilities"}}}} =
      Client.initialize(client, capabilities: "x")

    assert client.session_id == nil
    assert for({"mcp-session-id", [v]} <- headers, do: v) == []
  end

  test "a request before notifications/initialized is refused, ping is not", %{base_url: url} do
    client = url |> Client.new() |> Client.initialize() |> elem(0)

    {client,
     {200, _h, %{"error" => %{"code" => -32600, "message" => "waiting session initialization"}}}} =
      Client.request(client, "tools/list")

    {client, {200, _h, %{"result" => %{}}}} = Client.request(client, "ping")

    {client, {202, _h, nil}} = Client.notify(client, "notifications/initialized")

    {_client, {200, _h, %{"result" => %{"tools" => [_ | _]}}}} =
      Client.request(client, "tools/list")
  end

  test "a duplicate notifications/initialized is accepted and the session stays", %{
    base_url: url
  } do
    client = url |> Client.new() |> Client.ready!()

    {client, {202, _h, nil}} = Client.notify(client, "notifications/initialized")

    {_client, {200, _h, %{"result" => %{}}}} = Client.request(client, "ping")
  end

  test "a notification method that carries an id gets -32601 over the wire", %{base_url: url} do
    client = url |> Client.new() |> Client.ready!()

    {client, {200, _h, answer}} = Client.request(client, "notifications/initialized")

    assert answer["id"] == client.next_id - 1
    assert answer["error"] == %{"code" => -32601, "message" => "method not found"}

    # The session stays usable.
    #
    {_client, {200, _h, %{"result" => %{}}}} = Client.request(client, "ping")
  end

  test "ping answers before and after notifications/initialized", %{base_url: url} do
    client = url |> Client.new() |> Client.initialize() |> elem(0)

    {client, {200, _h, %{"result" => %{}}}} = Client.request(client, "ping")

    {client, {202, _h, nil}} = Client.notify(client, "notifications/initialized")

    {_client, {200, _h, %{"result" => %{}}}} = Client.request(client, "ping")
  end

  test "DELETE ends the session", %{base_url: url} do
    client = url |> Client.new() |> Client.ready!()

    {_client, {200, _h, nil}} = Client.delete(client)

    {_client, {404, _h, %{"error" => %{"code" => -32001, "message" => "invalid session"}}}} =
      Client.request(client, "ping")

    {_client, {404, _h, %{"error" => %{"code" => -32001}}}} = Client.delete(client)
  end
end
