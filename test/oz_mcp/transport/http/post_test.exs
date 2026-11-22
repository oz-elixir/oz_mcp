#
# The unit tests of the `POST` route: the guards of the body shape, the
# answers of the handler branches and the touch of the session. The
# route runs here on the `Plug` test connection, without the plugs of
# the router; the full plug (the host, the CORS origin, the gate, the
# parser) is under test in `OzMcp.RouterTest`.
#
defmodule OzMcp.Transport.Http.PostTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias OzMcp.Transport.Http.Post
  alias Support.Helpers.Utils
  alias Support.Servers

  @server Servers.Default
  @accept "application/json, text/event-stream"
  @parsers Plug.Parsers.init(parsers: [:json], json_decoder: {OzMcp.Wire, :decode!, []})

  # The instance that serves the server module of this file.
  #
  defp inst, do: Module.concat(@server, __MODULE__)

  setup do
    Utils.start_instance(@server, name: inst())
    %{session_id: Utils.create_session(inst(), initialized: true)}
  end

  describe "the shape of the body" do
    test "a batch array answers 400 with a refusal of the batching" do
      body = ~s([{"jsonrpc":"2.0","id":1,"method":"ping"}])

      conn =
        conn(:post, "/", body)
        |> put_req_header("content-type", "application/json")
        |> put_private(:instance, inst())
        |> parse()
        |> Post.call()

      assert conn.status == 400
      assert decoded(conn) == json_error(-32600, "batching is not supported")
    end

    test "a scalar JSON body answers 400 with an invalid request" do
      conn =
        conn(:post, "/", "42")
        |> put_req_header("content-type", "application/json")
        |> put_private(:instance, inst())
        |> parse()
        |> Post.call()

      assert conn.status == 400
      assert decoded(conn) == json_error(-32600, "invalid request")
    end
  end

  describe "the answers of the handler branches" do
    test "a request of an existing session gets the JSON-RPC result", %{
      session_id: session_id
    } do
      conn = rpc_request(session_id, 1, "ping")

      assert conn.status == 200
      assert decoded(conn) == %{"jsonrpc" => "2.0", "id" => 1, "result" => %{}}
    end

    test "a request of an unknown session answers 404" do
      conn = rpc_request("no-such-session", 1, "ping")

      assert conn.status == 404
      assert decoded(conn) == json_id_error(1, -32001, "invalid session")
    end

    test "a notification gets 202 with no body", %{session_id: session_id} do
      conn = rpc_request(session_id, nil, "notifications/initialized")

      assert conn.status == 202
      assert conn.resp_body == ""
    end

    test "the session id of an initialize goes into the response header" do
      conn =
        rpc_request(nil, 1, "initialize", %{
          "protocolVersion" => "2025-11-25",
          "clientInfo" => %{"name" => "test-client", "version" => "1.0.0"}
        })

      assert conn.status == 200
      assert [session_id] = get_resp_header(conn, "mcp-session-id")
      assert byte_size(session_id) > 0
    end

    test "an initialize over the session limit answers 429" do
      name = test_instance(max_sessions: 1)
      Utils.create_session(name, streams: [self()])

      conn =
        rpc_request(
          nil,
          1,
          "initialize",
          %{
            "protocolVersion" => "2025-11-25",
            "clientInfo" => %{"name" => "test-client", "version" => "1.0.0"}
          },
          name
        )

      assert conn.status == 429
      assert get_resp_header(conn, "mcp-session-id") == []
      assert decoded(conn) == json_id_error(1, -32000, "too many sessions")
    end

    test "a method whose callback can stream begins and closes a stream target" do
      name = Module.concat(Servers.ToolsOnly, __MODULE__)
      Utils.start_instance(Servers.ToolsOnly, name: name)
      session_id = Utils.create_session(name, initialized: true)

      conn = rpc_request(session_id, 1, "tools/call", %{"name" => "get_date"}, name)

      assert conn.status == 200
      assert decoded(conn)["result"]["content"]
    end

    test "a request registers in its session and frees the id when the answer is out", %{
      session_id: session_id
    } do
      conn = rpc_request(session_id, 1, "ping")

      assert conn.status == 200

      # The end of the registration is a cast: this request orders the
      # read after it.
      #
      rpc_request(session_id, 2, "ping")

      case Utils.session_data(inst(), session_id) do
        nil -> flunk("the session is gone")
        data -> assert data.requests == %{}
      end
    end
  end

  describe "the request and its stream" do
    test "a notification registers nothing", %{session_id: session_id} do
      conn =
        rpc_request(session_id, nil, "notifications/cancelled", %{"requestId" => 1})

      assert conn.status == 202
      assert conn.resp_body == ""

      Utils.sync_server(inst(), session_id)
      data = Utils.session_data(inst(), session_id)
      assert data.requests == %{}
      assert data.streams == %{}
    end

    test "a streamed request that crashes in its callback frees the request and the stream" do
      name = Module.concat(Servers.TasksTest, __MODULE__)
      Utils.start_instance(Servers.TasksTest, name: name)
      session_id = Utils.create_session(name, initialized: true)

      conn = rpc_request(session_id, 1, "tools/call", %{"name" => "task_crash"}, name)

      assert conn.status == 200
      assert decoded(conn)["error"]["code"] == -32603

      Utils.sync_server(name, session_id)
      data = Utils.session_data(name, session_id)
      assert data.requests == %{}
      assert data.streams == %{}
    end

    test "a duplicate id is refused and does not disturb the running request" do
      name = Module.concat(Servers.Outbound, __MODULE__)
      Utils.start_instance(Servers.Outbound, name: name)
      session_id = Utils.create_session(name, initialized: true)

      params = %{"name" => "log", "arguments" => %{"delay" => 500}}

      first =
        Task.async(fn -> rpc_request(session_id, 1, "tools/call", params, name) end)

      assert Utils.eventually(fn ->
               case Utils.session_data(name, session_id) do
                 %{requests: requests} -> map_size(requests) > 0
                 _none -> false
               end
             end)

      conn = rpc_request(session_id, 1, "tools/call", params, name)

      assert conn.status == 200
      assert decoded(conn)["error"]["code"] == -32600
      assert conn.private[:oz_mcp_error_code] == :rpc_duplicate_request_id

      assert Task.await(first, 10_000).status == 200

      Utils.sync_server(name, session_id)
      data = Utils.session_data(name, session_id)
      assert data.requests == %{}
      assert data.streams == %{}
    end
  end

  # The route runs without the plugs of the router: the instance comes
  # from the private of the conn and the parser runs as the router runs
  # it (a POST with a JSON content type).
  #

  defp rpc_request(session_id, id, method, params \\ %{}, instance \\ inst()) do
    message =
      %{"jsonrpc" => "2.0", "params" => params}
      |> maybe_put("id", id)
      |> maybe_put("method", method)

    conn =
      conn(:post, "/", :json.encode(message) |> IO.iodata_to_binary())
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", @accept)
      |> put_private(:instance, instance)
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

  defp json_error(code, message),
    do: %{"jsonrpc" => "2.0", "error" => %{"code" => code, "message" => message}}

  defp json_id_error(id, code, message),
    do: Map.put(json_error(code, message), "id", id)

  # The instance of a test that needs server opts of its own.
  #
  defp test_instance(opts) do
    name = Module.concat(@server, :"T#{System.unique_integer([:positive])}")
    Utils.start_instance(@server, Keyword.merge([name: name, allowed_origins: []], opts))

    name
  end
end
