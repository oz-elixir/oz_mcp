defmodule OzMcp.Transport.Http.ResponseTest do
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias OzMcp.Context
  alias OzMcp.Context.Error
  alias OzMcp.Transport.Http.Response
  alias Support.Helpers.Utils
  alias Support.Servers

  # The instance that serves a server module in this file.
  #
  defp inst(module), do: Module.concat(module, __MODULE__)

  @origin "http://localhost:3000"
  @server Servers.Default

  # Unit tests with plain connection structs. A connection built by
  # `Plug.Test.conn/2` carries no origin: the answers carry no CORS
  # headers. A test that checks them puts the origin in the private key
  # that the router sets.
  #
  describe "json/3" do
    test "a map is encoded and carries the JSON content type" do
      conn = Response.json(conn(:post, "/"), 200, %{"jsonrpc" => "2.0", "id" => 1})

      assert conn.status == 200
      assert conn.resp_body =~ ~s("jsonrpc":"2.0")
      assert conn.resp_body =~ ~s("id":1)
      assert get_resp_header(conn, "content-type") == ["application/json;charset=UTF-8"]
    end

    test "a JSON-RPC error body keeps its JSON media type" do
      {status, body} = Error.build(Error.new(:http_invalid_session), 1)
      conn = Response.json(conn(:post, "/"), status, body)

      assert conn.status == 404
      assert get_resp_header(conn, "content-type") == ["application/json;charset=UTF-8"]
      assert conn.resp_body =~ "invalid session"
    end

    test "a connection with an allowed origin gets the CORS headers" do
      conn =
        conn(:post, "/")
        |> put_private(:cors_origin, @origin)
        |> Response.json(200, %{"ok" => true})

      assert get_resp_header(conn, "access-control-allow-origin") == [@origin]
      assert get_resp_header(conn, "vary") == ["Origin"]
    end
  end

  describe "empty/2" do
    test "a 202 carries no content-type: the body is empty" do
      conn = Response.empty(conn(:post, "/"), 202)

      assert conn.status == 202
      assert conn.resp_body == ""
      assert get_resp_header(conn, "content-type") == []
    end

    test "the 200 of a DELETE carries no content-type" do
      conn = Response.empty(conn(:delete, "/"), 200)

      assert conn.status == 200
      assert conn.resp_body == ""
      assert get_resp_header(conn, "content-type") == []
    end

    test "the answer carries the CORS headers of the request" do
      conn =
        conn(:post, "/")
        |> put_private(:cors_origin, @origin)
        |> Response.empty(202)

      assert get_resp_header(conn, "access-control-allow-origin") == [@origin]
      assert get_resp_header(conn, "vary") == ["Origin"]
      assert get_resp_header(conn, "content-type") == []
    end
  end

  describe "unwrap/1" do
    test "a cont goes on" do
      context = context_with_conn()

      assert Response.unwrap({:cont, context}) == context
    end

    test "a halt gets its error answer and the connection comes back" do
      context =
        context_with_conn()
        |> Context.put_error(:http_invalid_session, nil)

      conn = Response.unwrap({:halt, context}) |> Map.fetch!(:conn)

      assert conn.status == 404
      assert conn.halted
      assert conn.resp_body =~ "invalid session"
    end
  end

  describe "handle_context_error/1" do
    test "a context without an error goes back unchanged" do
      context = context_with_conn()

      assert Response.handle_context_error(context) == context
    end

    test "the HTTP status comes from the error table" do
      conn = error_answer(:http_internal_error)

      assert conn.status == 500
      assert conn.resp_body =~ "internal server error"
    end

    test "an error of a request echoes its id" do
      context =
        context_with_conn()
        |> Map.put(:rpc_id, 42)
        |> Context.put_error(:rpc_missing_params, nil)

      conn = Response.handle_context_error(context).conn

      assert conn.status == 200

      assert conn.resp_body =~ ~s("jsonrpc":"2.0")
      assert conn.resp_body =~ ~s("id":42)
      assert conn.resp_body =~ ~s("code":-32602)
    end

    test "the answer of a message that is not a request carries no id" do
      context =
        context_with_conn()
        |> Map.put(:rpc_kind, :notification)
        |> Map.put(:rpc_id, nil)
        |> Context.put_error(:http_invalid_session, nil)

      conn = Response.handle_context_error(context).conn

      assert conn.resp_body == json_rpc_error(nil, -32001, "invalid session")
    end

    test "the headers of the error go out with the response head" do
      context =
        context_with_conn()
        |> Context.put_error(:http_unauthorized, nil, [
          {"www-authenticate", ~s(Bearer error="invalid_token")},
          {"cache-control", "no-store"}
        ])

      conn = Response.handle_context_error(context).conn

      assert get_resp_header(conn, "www-authenticate") == [~s(Bearer error="invalid_token")]
      assert get_resp_header(conn, "cache-control") == ["no-store"]
    end

    defp error_answer(code) do
      context_with_conn()
      |> Context.put_error(code, nil)
      |> Response.handle_context_error()
      |> Map.fetch!(:conn)
    end
  end

  describe "put_error_headers/2" do
    test "no header changes nothing" do
      conn = conn(:get, "/")

      assert Response.put_error_headers(conn, []) == conn
    end

    test "the headers go out in the order of the list" do
      conn =
        Response.put_error_headers(conn(:get, "/"), [
          {"www-authenticate", "Bearer"},
          {"cache-control", "no-store"}
        ])

      assert get_resp_header(conn, "www-authenticate") == ["Bearer"]
      assert get_resp_header(conn, "cache-control") == ["no-store"]
    end
  end

  describe "internal_error/2 and unavailable/2" do
    test "the internal error is a 500 with -32603" do
      conn = Response.internal_error(conn(:post, "/"), 7)

      assert conn.status == 500
      assert conn.resp_body == json_rpc_error(7, -32603, "internal server error")
    end

    test "the internal error of a message that is not a request carries no id" do
      conn = Response.internal_error(conn(:post, "/"))

      assert conn.resp_body == json_rpc_error(nil, -32603, "internal server error")
    end

    test "the unavailable error is a 503 with -32603" do
      conn = Response.unavailable(conn(:post, "/"), 7)

      assert conn.status == 503
      assert conn.resp_body == json_rpc_error(7, -32603, "server unavailable")
    end
  end

  describe "refuse_body/2 and invalid_session/1" do
    test "the refusal of a body carries no id" do
      conn = Response.refuse_body(conn(:post, "/"), :http_parse_error)

      assert conn.status == 400
      assert conn.resp_body == json_rpc_error(nil, -32700, "parse error")
    end

    test "the refusal of an unknown session" do
      conn = Response.invalid_session(conn(:get, "/"))

      assert conn.status == 404
      assert conn.resp_body == json_rpc_error(nil, -32001, "invalid session")
    end
  end

  describe "reply_id/1" do
    test "a request echoes its id" do
      context =
        context_with_conn()
        |> Map.put(:rpc_id, 5)
        |> Map.put(:rpc_kind, :request)

      assert Response.reply_id(context) == 5
    end

    test "a message that is not a request carries no id" do
      context =
        context_with_conn()
        |> Map.put(:rpc_id, 5)
        |> Map.put(:rpc_kind, :notification)

      assert Response.reply_id(context) == nil
    end
  end

  describe "last_resort/4" do
    test "a failure before the head went out answers the internal error" do
      conn = Response.last_resort(conn(:post, "/"), :error, %RuntimeError{}, [])

      assert conn.status == 500
      assert conn.resp_body == json_rpc_error(nil, -32603, "internal server error")
    after
      Process.delete(:oz_mcp_response_started)
    end

    test "a failure after the head went out raises again: the connection closes" do
      Response.mark_response_started(conn(:post, "/"))

      assert_raise RuntimeError, fn ->
        Response.last_resort(conn(:post, "/"), :error, %RuntimeError{}, [])
      end
    after
      Process.delete(:oz_mcp_response_started)
    end
  end

  describe "the router answers" do
    setup do
      Utils.start_instances([@server], __MODULE__, allowed_origins: [@origin])
      :ok
    end

    test "a notification gets 202 with no body and no content-type" do
      session_id = Utils.create_session(inst(@server), initialized: true)

      conn =
        post_raw(~s({"jsonrpc":"2.0","method":"notifications/roots/list_changed"}))
        |> put_session_header(session_id)
        |> call_router()

      assert conn.status == 202
      assert conn.resp_body == ""
      assert get_resp_header(conn, "content-type") == []
      assert get_resp_header(conn, "access-control-allow-origin") == [@origin]
    end

    test "the DELETE of a session gets 200 with no body and no content-type" do
      session_id = Utils.create_session(inst(@server), initialized: true)

      conn =
        conn(:delete, "/")
        |> put_req_header("origin", @origin)
        |> put_session_header(session_id)
        |> call_router()

      assert conn.status == 200
      assert conn.resp_body == ""
      assert get_resp_header(conn, "content-type") == []
      assert get_resp_header(conn, "access-control-allow-origin") == [@origin]
    end

    test "the DELETE of an unknown session gets 404 with the JSON-RPC body" do
      conn =
        conn(:delete, "/")
        |> put_req_header("origin", @origin)
        |> put_session_header("gone-session")
        |> call_router()

      assert conn.status == 404
      assert conn.resp_body == json_rpc_error(nil, -32001, "invalid session")
      assert get_resp_header(conn, "content-type") == ["application/json;charset=UTF-8"]
    end

    test "a request gets 200 with the JSON body and the content-type" do
      session_id = Utils.create_session(inst(@server), initialized: true)

      conn =
        post_raw(~s({"jsonrpc":"2.0","id":1,"method":"ping"}))
        |> put_session_header(session_id)
        |> call_router()

      assert conn.status == 200
      assert conn.resp_body == json_rpc_result(1, %{})
      assert get_resp_header(conn, "content-type") == ["application/json;charset=UTF-8"]
      assert get_resp_header(conn, "access-control-allow-origin") == [@origin]
    end
  end

  defp context_with_conn,
    do: Context.new(inst(@server), :http_streamable, :rpc) |> Map.put(:conn, conn(:post, "/"))

  defp call_router(conn) do
    OzMcp.Router.call(
      conn,
      OzMcp.Router.init(server: inst(@server), allowed_origins: [@origin])
    )
  end

  defp post_raw(body) do
    conn(:post, "/", body)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json, text/event-stream")
    |> put_req_header("origin", @origin)
  end

  defp put_session_header(conn, session_id) do
    put_req_header(conn, "mcp-session-id", session_id)
  end

  defp json_rpc_error(id, code, message) do
    json = %{"jsonrpc" => "2.0", "error" => %{"code" => code, "message" => message}}

    case id do
      nil -> :json.encode(json) |> IO.iodata_to_binary()
      id -> :json.encode(Map.put(json, "id", id)) |> IO.iodata_to_binary()
    end
  end

  defp json_rpc_result(id, result) do
    %{"jsonrpc" => "2.0", "id" => id, "result" => result}
    |> :json.encode()
    |> IO.iodata_to_binary()
  end
end
