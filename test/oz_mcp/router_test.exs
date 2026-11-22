defmodule OzMcp.RouterTest do
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias OzMcp.Session
  alias OzMcp.Sessions
  alias OzMcp.Tasks
  alias OzMcp.Transport.Http.Response
  alias Support.Helpers.PersistentSnapshot
  alias Support.Helpers.SessionProbe
  alias Support.Helpers.Utils
  alias Support.Servers

  # The instance that serves a server module in this file.
  #
  defp inst(module), do: Module.concat(module, __MODULE__)

  @cors_origin "http://localhost:3000"

  @tools_only Servers.ToolsOnly

  setup context do
    servers =
      if context[:tasks] do
        #
        # MCP Tasks end-to-end suite: the runtime runs the
        # tasks-capable servers plus the gating fixtures (no capability,
        # required/forbidden toolSupport).
        #
        [
          {Servers.TasksTest, Map.get(context, :task_opts, %{})},
          Servers.TasksRequiredTool,
          Servers.TasksForbiddenTool,
          Servers.TasksNoCapability,
          @tools_only
        ]
      else
        [
          #
          # Per-test server opts hook (`@tag task_opts:`), used e.g. to run
          # the GET SSE tests with a fast heartbeat or with it disabled.
          #
          {Servers.Default, Map.get(context, :task_opts, %{})},
          Servers.ResourcesSingle,
          Servers.ResourcesMultipleSubscribed,
          Servers.TemplatesMultiple,
          @tools_only,
          Servers.ToolsMultiple,
          Servers.WithLogging,
          Servers.WithTemplates,
          Servers.Completions,
          Servers.CompletionsNoCallback,
          Servers.Outbound
        ]
      end

    Utils.start_instances(servers, __MODULE__, allowed_origins: [])
    Support.Entities.Tools.TaskSlowTest.use_instance(inst(Servers.TasksTest))
  end

  describe "OPTIONS / (CORS preflight)" do
    test "returns 204 with CORS headers" do
      conn = conn(:options, "/") |> call_router()

      assert conn.status == 204

      headers = Enum.into(conn.resp_headers, %{})
      assert headers["access-control-allow-origin"] == @cors_origin
      assert headers["vary"] == "Origin"
      assert headers["access-control-allow-headers"] == "*, authorization"
      assert headers["access-control-allow-methods"] == "GET, POST, DELETE, OPTIONS"

      assert headers["access-control-expose-headers"] ==
               "mcp-session-id, mcp-protocol-version, www-authenticate"
    end

    test "works for any path" do
      conn = conn(:options, "/any/path") |> call_router()
      assert conn.status == 204
    end
  end

  describe "CORS / allowed_origins" do
    test "echoes a listed Origin and sets Vary on every response" do
      conn =
        post_raw("{}")
        |> put_req_header("origin", @cors_origin)
        |> call_router_with([@cors_origin])

      headers = Enum.into(conn.resp_headers, %{})
      assert headers["access-control-allow-origin"] == @cors_origin
      assert headers["vary"] == "Origin"
      refute headers["access-control-allow-origin"] == "*"
    end

    test "rejects an unlisted Origin with 403 and an empty body before parsing" do
      conn =
        post_raw("{not json")
        |> put_req_header("origin", "http://evil.example")
        |> call_router_with([@cors_origin])

      assert conn.status == 403
      assert conn.resp_body == ""
      refute Map.has_key?(Enum.into(conn.resp_headers, %{}), "access-control-allow-origin")
    end

    test "rejects an unlisted Origin for GET, DELETE and OPTIONS" do
      for method <- [:get, :delete, :options] do
        conn =
          conn(method, "/")
          |> put_req_header("origin", "http://evil.example")
          |> call_router_with([@cors_origin])

        assert conn.status == 403, "expected #{method} to be rejected"
      end
    end

    test "rejects two Origin header fields" do
      conn = conn(:get, "/")

      conn = %{
        conn
        | req_headers: [{"origin", @cors_origin}, {"origin", @cors_origin} | conn.req_headers]
      }

      conn = call_router_with(conn, [@cors_origin])

      assert conn.status == 403
    end

    test "rejects any Origin when the allowlist is empty" do
      conn =
        conn(:get, "/")
        |> put_req_header("origin", @cors_origin)
        |> call_router_with([])

      assert conn.status == 403
    end

    test "allows a request without an Origin and emits no CORS headers" do
      conn = call_router_with(post_raw("{}"), [@cors_origin])

      headers = Enum.into(conn.resp_headers, %{})
      refute Map.has_key?(headers, "access-control-allow-origin")
      refute Map.has_key?(headers, "vary")
      refute Map.has_key?(headers, "access-control-expose-headers")
    end
  end

  describe "CORS / browser client reads the challenge" do
    test "the preflight lets the browser send the Authorization header" do
      conn = conn(:options, "/") |> call_router()

      headers = Enum.into(conn.resp_headers, %{})
      assert headers["access-control-allow-headers"] =~ "authorization"
    end

    test "a 401 of the gate exposes www-authenticate for an allowed origin" do
      #
      # A browser client can only read a response header that the expose
      # list names. The WWW-Authenticate challenge must be readable, or
      # the client never learns where the authorization server is.
      #
      Utils.stop_instances()

      Utils.start_instances(
        [{Servers.Authorized, %{resource_url: "https://mcp.example.com/mcp"}}],
        __MODULE__,
        allowed_origins: [@cors_origin]
      )

      conn =
        post_raw("{}")
        |> put_req_header("origin", @cors_origin)
        |> OzMcp.Router.call(
          OzMcp.Router.init(
            server: inst(Servers.Authorized),
            allowed_origins: [@cors_origin]
          )
        )

      assert conn.status == 401

      headers = Enum.into(conn.resp_headers, %{})
      assert headers["access-control-allow-origin"] == @cors_origin

      assert headers["access-control-expose-headers"] ==
               "mcp-session-id, mcp-protocol-version, www-authenticate"

      assert headers["www-authenticate"] =~ "Bearer"
    end
  end

  describe "Accept header validation" do
    test "returns 406 with a JSON-RPC error body when Accept header is missing" do
      json = :json.encode(%{"method" => "initialize"}) |> IO.iodata_to_binary()

      conn =
        conn(:post, "/", json)
        |> put_req_header("content-type", "application/json")
        |> call_router()

      assert conn.status == 406
      assert decode_resp(conn) == json_rpc_error(-32600, "accept header is required")
      assert_cors_headers(conn)
    end

    test "returns 406 with a JSON-RPC error body when Accept header lacks application/json" do
      json = :json.encode(%{"method" => "initialize"}) |> IO.iodata_to_binary()

      conn =
        conn(:post, "/", json)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "text/event-stream")
        |> call_router()

      assert conn.status == 406

      assert decode_resp(conn) ==
               json_rpc_error(
                 -32600,
                 "client must accept both application/json and text/event-stream"
               )

      assert_cors_headers(conn)
    end

    test "returns 406 with a JSON-RPC error body when Accept header lacks text/event-stream" do
      json = :json.encode(%{"method" => "initialize"}) |> IO.iodata_to_binary()

      conn =
        conn(:post, "/", json)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "application/json")
        |> call_router()

      assert conn.status == 406

      assert decode_resp(conn) ==
               json_rpc_error(
                 -32600,
                 "client must accept both application/json and text/event-stream"
               )

      assert_cors_headers(conn)
    end
  end

  describe "JSON-RPC hygiene - body shape" do
    test "returns 400 with -32700 without an id for an invalid JSON body" do
      conn =
        post_raw("this is not json")
        |> call_router()

      assert conn.status == 400
      assert decode_resp(conn) == json_rpc_error(-32700, "parse error")
      assert_cors_headers(conn)
    end

    test "a number of more than 100 characters in the body gets 400 and -32700" do
      long = String.duplicate("7", 1_000)

      body =
        ~s({"jsonrpc":"2.0","id":1,"method":"ping","params":{"_meta":{"n":#{long}}}})

      log =
        Utils.capture_log([level: :warning], fn ->
          conn = body |> post_raw() |> call_router()

          assert conn.status == 400
          assert decode_resp(conn) == json_rpc_error(-32700, "parse error")
          assert_cors_headers(conn)
        end)

      assert log =~ "Unparseable request body"
      refute log =~ long
    end

    test "a 1 MiB integer is a parse error, not a body that is too large" do
      body =
        ~s({"jsonrpc":"2.0","id":1,"method":"ping","params":{"_meta":{"n":) <>
          String.duplicate("7", 1_040_000) <> ~s(}}})

      assert byte_size(body) < 1_048_576

      conn = body |> post_raw() |> call_router()

      assert conn.status == 400
      assert decode_resp(conn) == json_rpc_error(-32700, "parse error")
      assert_cors_headers(conn)
    end

    test "a body that is the JSON value null gets 400" do
      conn =
        post_raw("null")
        |> call_router()

      assert conn.status == 400
      assert decode_resp(conn) == json_rpc_error(-32600, "invalid request")
      assert_cors_headers(conn)
    end

    test "returns 415 with -32600 for a non-JSON content type" do
      conn =
        conn(:post, "/", "hello")
        |> put_req_header("content-type", "text/plain")
        |> put_req_header("accept", "application/json, text/event-stream")
        |> call_router()

      assert conn.status == 415
      assert decode_resp(conn) == json_rpc_error(-32600, "content type must be application/json")
      assert_cors_headers(conn)
    end

    test "returns 415 with -32600 when the POST has no Content-Type header" do
      conn =
        conn(:post, "/", "{}")
        |> put_req_header("accept", "application/json, text/event-stream")
        |> call_router()

      assert conn.status == 415
      assert decode_resp(conn) == json_rpc_error(-32600, "content type must be application/json")
      assert_cors_headers(conn)
    end

    test "the log of a broken JSON body holds no body text" do
      log =
        Utils.capture_log([level: :warning], fn ->
          conn =
            post_raw(~s({"secret": "abc123",))
            |> call_router()

          assert conn.status == 400
          assert decode_resp(conn) == json_rpc_error(-32700, "parse error")
          assert_cors_headers(conn)
        end)

      # The log names the module of the decoder exception only: no byte
      # of the body and no stack trace.
      #
      assert log =~ "Unparseable request body"
      refute log =~ "abc123"
      refute log =~ "secret"
      refute String.contains?(String.trim_trailing(log, "\n"), "\n")
    end

    test "the log of an unsupported media type holds no header value" do
      long_type = "application/x-" <> String.duplicate("very-long-", 112)

      log =
        Utils.capture_log([level: :warning], fn ->
          conn =
            conn(:post, "/", "hello")
            |> put_req_header("content-type", long_type)
            |> put_req_header("accept", "application/json, text/event-stream")
            |> call_router()

          assert conn.status == 415

          assert decode_resp(conn) ==
                   json_rpc_error(-32600, "content type must be application/json")

          assert_cors_headers(conn)
        end)

      # The whole log is one fixed line: the header value is absent.
      #
      assert log == "[warning] Unsupported request media type\n"
    end

    test "accepts a POST with an application/json; charset=utf-8 content type" do
      session_id = Utils.create_session(inst(Servers.Default), initialized: true)

      body = ~s({"jsonrpc":"2.0","id":1,"method":"ping"})

      conn =
        conn(:post, "/", body)
        |> put_req_header("content-type", "application/json; charset=utf-8")
        |> put_req_header("accept", "application/json, text/event-stream")
        |> put_session_header(session_id)
        |> call_router()

      assert conn.status == 200
      assert decode_resp(conn) == %{"jsonrpc" => "2.0", "id" => 1, "result" => %{}}
    end

    test "returns 400 with -32600 for a JSON-RPC batch array body" do
      body =
        ~s([{"jsonrpc":"2.0","id":1,"method":"ping"},{"jsonrpc":"2.0","id":2,"method":"ping"}])

      conn =
        post_raw(body)
        |> call_router()

      assert conn.status == 400
      assert decode_resp(conn) == json_rpc_error(-32600, "batching is not supported")
      assert_cors_headers(conn)
    end

    test "returns 400 with -32600 for a scalar JSON body (number)" do
      conn =
        post_raw("42")
        |> call_router()

      assert conn.status == 400
      assert decode_resp(conn) == json_rpc_error(-32600, "invalid request")
      assert_cors_headers(conn)
    end

    test "returns 400 with -32600 for a scalar JSON body (string)" do
      conn =
        post_raw(~s("x"))
        |> call_router()

      assert conn.status == 400
      assert decode_resp(conn) == json_rpc_error(-32600, "invalid request")
      assert_cors_headers(conn)
    end
  end

  describe "JSON-RPC hygiene - body size" do
    #
    # The read of the body stops at the limit, before the decode: the
    # body of the test needs no valid JSON to go over the limit.
    #
    test "a body over the default limit gets 413 with -32600 and a log with no body text" do
      body = String.duplicate("secret-body ", 180_000)
      assert byte_size(body) > 1_048_576

      log =
        Utils.capture_log([level: :warning], fn ->
          conn =
            post_raw(body)
            |> call_router()

          assert conn.status == 413
          assert decode_resp(conn) == json_rpc_error(-32600, "request body too large")
          assert_cors_headers(conn)
        end)

      # The whole log is one fixed line: no body text, no stack trace.
      #
      assert log == "[warning] Request body over max_body_bytes\n"
    end

    @tag task_opts: %{max_body_bytes: 100}
    test "a body of exactly max_body_bytes bytes is read, a body of one byte more gets 413" do
      #
      # A valid ping request padded with spaces to exactly 100 bytes.
      #
      within = ~s({"jsonrpc":"2.0","id":1,"method":"ping"}#{String.duplicate(" ", 60)})
      assert byte_size(within) == 100

      conn =
        post_raw(within)
        |> call_router()

      refute conn.status == 413
      assert decode_resp(conn) == json_rpc_error(1, -32600, "missing session id")

      over = ~s({"jsonrpc":"2.0","id":1,"method":"ping"}#{String.duplicate(" ", 61)})
      assert byte_size(over) == 101

      conn =
        post_raw(over)
        |> call_router()

      assert conn.status == 413
      assert decode_resp(conn) == json_rpc_error(-32600, "request body too large")
    end

    test "a body that never arrives gets 408 with -32600 and a warning with no stack trace" do
      log =
        Utils.capture_log([level: :warning], fn ->
          conn =
            post_raw(~s({"jsonrpc":"2.0","id":1,"method":"ping"}))
            |> Support.Helpers.TimeoutBody.wrap()
            |> call_router()

          assert conn.status == 408
          assert decode_resp(conn) == json_rpc_error(-32600, "request body timeout")
          assert_cors_headers(conn)
        end)

      # The whole log is one fixed line: no stack trace, no server error.
      #
      assert log == "[warning] Request body read timeout\n"
    end

    test "a body of an unknown media type does not read the body, so no size refusal" do
      conn =
        conn(:post, "/", String.duplicate("secret-body ", 180_000))
        |> put_req_header("content-type", "text/plain")
        |> put_req_header("accept", "application/json, text/event-stream")
        |> call_router()

      assert conn.status == 415
      assert decode_resp(conn) == json_rpc_error(-32600, "content type must be application/json")
    end
  end

  describe "POST / with unknown notifications" do
    test "a notification method with an id gets 200 with -32601 and the id echoed" do
      session_id = Utils.create_session(inst(Servers.Default), initialized: true)

      conn =
        post_json_rpc(1, "notifications/roots/list_changed")
        |> put_session_header(session_id)
        |> call_router()

      assert conn.status == 200
      assert decode_resp(conn) == json_rpc_error(1, -32601, "method not found")
      assert_cors_headers(conn)
    end

    test "a notification method with an id gets -32601 before the session id check" do
      #
      # The JSON-RPC stage runs before the session id stage: a caller
      # without a session learns nothing new and the id is echoed.
      #
      conn = post_json_rpc(2, "notifications/initialized") |> call_router()

      assert conn.status == 200
      assert decode_resp(conn) == json_rpc_error(2, -32601, "method not found")
      assert_cors_headers(conn)
    end

    test "unknown notification returns 202 with no JSON-RPC body" do
      session_id = Utils.create_session(inst(Servers.Default), initialized: true)

      conn =
        post_json_rpc(nil, "notifications/roots/list_changed")
        |> put_session_header(session_id)
        |> call_router()

      assert conn.status == 202
      assert conn.resp_body == ""
      assert_cors_headers(conn)
    end

    test "inbound notifications/progress from a client returns 202 with no JSON-RPC body" do
      session_id = Utils.create_session(inst(Servers.Default), initialized: true)

      conn =
        post_json_rpc(nil, "notifications/progress", %{
          "progressToken" => "tok-42",
          "progress" => 1
        })
        |> put_session_header(session_id)
        |> call_router()

      assert conn.status == 202
      assert conn.resp_body == ""
      assert_cors_headers(conn)
    end
  end

  describe "POST / with method notifications/cancelled" do
    test "returns 202 with no JSON-RPC body when params carry requestId and reason" do
      session_id = Utils.create_session(inst(Servers.Default), initialized: true)

      conn =
        post_json_rpc(nil, "notifications/cancelled", %{
          "requestId" => 42,
          "reason" => "user aborted"
        })
        |> put_session_header(session_id)
        |> call_router()

      assert conn.status == 202
      assert conn.resp_body == ""
      assert_cors_headers(conn)
    end

    test "returns 202 with no JSON-RPC body when params are empty" do
      session_id = Utils.create_session(inst(Servers.Default), initialized: true)

      conn =
        post_json_rpc(nil, "notifications/cancelled")
        |> put_session_header(session_id)
        |> call_router()

      assert conn.status == 202
      assert conn.resp_body == ""
      assert_cors_headers(conn)
    end

    test "returns 400 with no id when the session is not initialized" do
      session_id = Utils.create_session(inst(Servers.Default), initialized: false)

      conn =
        post_json_rpc(nil, "notifications/cancelled", %{"requestId" => 7})
        |> put_session_header(session_id)
        |> call_router()

      assert conn.status == 400

      assert decode_resp(conn) ==
               json_rpc_error(-32600, "waiting session initialization")
    end
  end

  describe "POST / with missing method" do
    test "returns rpc error when method key is missing" do
      conn = post_json_rpc(nil, nil) |> call_router()

      # The message has no method: not a request, the refusal has no id.
      #
      assert conn.status == 400
      assert decode_resp(conn) == json_rpc_error(-32600, "invalid request")
      assert_cors_headers(conn)
    end
  end

  describe "JSON-RPC envelope validation" do
    test "returns -32600 and echoes the id when jsonrpc is not 2.0" do
      body = ~s({"jsonrpc":"1.0","id":1,"method":"ping"})

      conn = post_raw(body) |> call_router()

      assert conn.status == 200
      assert decode_resp(conn) == json_rpc_error(1, -32600, "invalid request")
      assert_cors_headers(conn)
    end

    test "returns -32600 when the jsonrpc member is missing" do
      body = ~s({"id":1,"method":"ping"})

      conn = post_raw(body) |> call_router()

      assert conn.status == 200
      assert decode_resp(conn) == json_rpc_error(1, -32600, "invalid request")
      assert_cors_headers(conn)
    end

    test "returns -32600 when method is an empty string" do
      body = ~s({"jsonrpc":"2.0","id":1,"method":""})

      conn = post_raw(body) |> call_router()

      assert conn.status == 200
      assert decode_resp(conn) == json_rpc_error(1, -32600, "invalid request")
      assert_cors_headers(conn)
    end

    test "returns -32600 when method is not a string, even without an id" do
      body = ~s({"jsonrpc":"2.0","method":42})

      conn = post_raw(body) |> call_router()

      # A message without a valid id is not a request: HTTP error status.
      #
      assert conn.status == 400
      assert decode_resp(conn) == json_rpc_error(-32600, "invalid request")
      assert_cors_headers(conn)
    end

    test "returns -32600 without an id when id is an object" do
      body = ~s({"jsonrpc":"2.0","id":{"x":1},"method":"ping"})

      conn = post_raw(body) |> call_router()

      assert conn.status == 400
      assert decode_resp(conn) == json_rpc_error(-32600, "invalid request")
      assert_cors_headers(conn)
    end

    test "an id of null on a notification method gets 400, not 202" do
      body = ~s({"jsonrpc":"2.0","id":null,"method":"notifications/initialized"})

      conn = post_raw(body) |> call_router()

      assert conn.status == 400
      assert decode_resp(conn) == json_rpc_error(-32600, "invalid request")
      assert_cors_headers(conn)
    end

    test "returns -32600 without an id when id is null" do
      body = ~s({"jsonrpc":"2.0","id":null,"method":"ping"})

      conn = post_raw(body) |> call_router()

      assert conn.status == 400
      assert decode_resp(conn) == json_rpc_error(-32600, "invalid request")
      assert_cors_headers(conn)
    end

    test "returns -32600 when params are an array" do
      body = ~s({"jsonrpc":"2.0","id":1,"method":"tools/call","params":[]})

      conn = post_raw(body) |> call_router(inst(@tools_only))

      assert conn.status == 200
      assert decode_resp(conn) == json_rpc_error(1, -32600, "invalid request")
      assert_cors_headers(conn)
    end

    test "returns -32600 when params are a string" do
      body = ~s({"jsonrpc":"2.0","id":1,"method":"tools/call","params":"nope"})

      conn = post_raw(body) |> call_router(inst(@tools_only))

      assert conn.status == 200
      assert decode_resp(conn) == json_rpc_error(1, -32600, "invalid request")
      assert_cors_headers(conn)
    end

    test "accepts a string id and echoes it back" do
      session_id = Utils.create_session(inst(Servers.Default), initialized: true)

      body = ~s({"jsonrpc":"2.0","id":"abc-123","method":"ping"})

      conn =
        post_raw(body)
        |> put_session_header(session_id)
        |> call_router()

      assert conn.status == 200
      assert decode_resp(conn) == %{"jsonrpc" => "2.0", "id" => "abc-123", "result" => %{}}
      assert_cors_headers(conn)
    end
  end

  describe "POST / with missing params" do
    test "returns rpc error when params are missing for a method that requires them" do
      session_id = Utils.create_session(inst(Servers.Default), initialized: true)

      body =
        %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/call"}
        |> :json.encode()
        |> IO.iodata_to_binary()

      conn =
        post_raw(body)
        |> put_session_header(session_id)
        |> call_router()

      assert conn.status == 200
      assert decode_resp(conn) == json_rpc_error(1, -32602, "missing params")
      assert_cors_headers(conn)
    end
  end

  describe "POST / with method logging/setLevel" do
    test "returns rpc error when the logging capability is not declared" do
      session_id = Utils.create_session(inst(Servers.Default), initialized: true)

      conn =
        post_json_rpc(1, "logging/setLevel", %{"level" => "info"})
        |> put_session_header(session_id)
        |> call_router()

      assert conn.status == 200
      assert decode_resp(conn) == json_rpc_error(1, -32601, "method not found")
      assert_cors_headers(conn)
    end

    test "returns rpc error for an unknown level" do
      session_id = Utils.create_session(inst(Servers.WithLogging), initialized: true)

      conn =
        post_json_rpc(1, "logging/setLevel", %{"level" => "verbose"})
        |> put_session_header(session_id)
        |> call_router(inst(Servers.WithLogging))

      assert conn.status == 200
      assert decode_resp(conn) == json_rpc_error(1, -32602, "invalid log level")
      assert_cors_headers(conn)
    end

    test "returns rpc error when the level is missing" do
      session_id = Utils.create_session(inst(Servers.WithLogging), initialized: true)

      conn =
        post_json_rpc(1, "logging/setLevel", %{})
        |> put_session_header(session_id)
        |> call_router(inst(Servers.WithLogging))

      assert conn.status == 200
      assert decode_resp(conn) == json_rpc_error(1, -32602, "invalid log level")
      assert_cors_headers(conn)
    end

    test "stores the level and returns an empty result" do
      session_id = Utils.create_session(inst(Servers.WithLogging), initialized: true)

      conn =
        post_json_rpc(1, "logging/setLevel", %{"level" => "warning"})
        |> put_session_header(session_id)
        |> call_router(inst(Servers.WithLogging))

      assert conn.status == 200
      assert decode_resp(conn) == json_rpc_result(1, %{})
      assert_cors_headers(conn)

      assert {:ok, %{log_level: :warning}} =
               Sessions.lookup(inst(Servers.WithLogging), session_id)
    end
  end

  describe "POST / with method initialize" do
    @initialize_params %{
      "protocolVersion" => "2025-11-25",
      "clientInfo" => %{"name" => "test-client", "version" => "1.0.0"}
    }

    test "returns correct rpc initialize response" do
      conn = post_json_rpc(0, "initialize", @initialize_params) |> call_router()

      expected =
        json_rpc_result(0, Servers.Default.initialize_result())
        |> normalize_map_keys_to_string()

      assert conn.status == 200
      assert decode_resp(conn) == expected
      assert_cors_headers(conn)
    end

    test "preserves rpc id in response" do
      conn = post_json_rpc(42, "initialize", @initialize_params) |> call_router()

      assert conn.status == 200
      assert decode_resp(conn)["id"] == 42
      assert_cors_headers(conn)
    end

    test "returns rpc error when rpc id is missing" do
      conn = post_json_rpc(nil, "initialize") |> call_router()

      # A message without a valid id is not a request: HTTP error status.
      #
      assert conn.status == 400
      assert decode_resp(conn) == json_rpc_error(-32600, "missing id")
      assert_cors_headers(conn)
    end

    test "returns session id in response header" do
      conn = post_json_rpc(1, "initialize", @initialize_params) |> call_router()

      assert conn.status == 200
      assert [session_id] = get_resp_header(conn, "mcp-session-id")
      assert byte_size(session_id) > 0
    end

    test "returns 400 when initialize is called with a session id" do
      before = Utils.session_count(inst(Servers.Default))

      conn =
        post_json_rpc(1, "initialize", @initialize_params)
        |> put_session_header("some-client-session-id")
        |> call_router()

      assert conn.status == 400

      assert decode_resp(conn) ==
               json_rpc_error(1, -32600, "cannot call initialize and provide a mcp session id")

      # the request created no session
      #
      assert Utils.session_count(inst(Servers.Default)) ==
               before
    end

    test "answers 429 with too many sessions when max_sessions is reached" do
      Utils.stop_instances()

      Utils.start_instances([{Servers.Default, %{max_sessions: 1}}], __MODULE__,
        allowed_origins: []
      )

      Utils.create_session(inst(Servers.Default), streams: [self()])

      conn = post_json_rpc(1, "initialize", @initialize_params) |> call_router()

      assert conn.status == 429
      assert get_resp_header(conn, "mcp-session-id") == []
      assert decode_resp(conn) == json_rpc_error(1, -32000, "too many sessions")

      # The refused session leaves no record in the store (the Server
      # removes it a moment after the refusal).
      #
      wait_until(fn ->
        Utils.session_count(inst(Servers.Default)) == 1
      end)
    end

    @tag task_opts: %{max_sessions: 2}
    test "answers 429 on the third initialize when max_sessions is 2 and both are busy" do
      for id <- 1..2 do
        conn = post_json_rpc(id, "initialize", @initialize_params) |> call_router()
        assert conn.status == 200
        assert [session_id] = get_resp_header(conn, "mcp-session-id")

        assert {:ok, _} =
                 Session.open_stream(
                   inst(Servers.Default),
                   session_id,
                   :get,
                   self(),
                   nil
                 )
      end

      conn = post_json_rpc(3, "initialize", @initialize_params) |> call_router()

      assert conn.status == 429
      assert get_resp_header(conn, "mcp-session-id") == []
      assert decode_resp(conn) == json_rpc_error(3, -32000, "too many sessions")
    end

    @tag task_opts: %{session_init_timeout_ms: 100}
    test "a session that gets no notifications/initialized in time gets 404 afterwards" do
      conn = post_json_rpc(1, "initialize", @initialize_params) |> call_router()
      assert conn.status == 200
      assert [session_id] = get_resp_header(conn, "mcp-session-id")

      wait_until(fn ->
        Sessions.lookup(inst(Servers.Default), session_id) == {:error, :no_session}
      end)

      conn =
        post_json_rpc(nil, "notifications/initialized")
        |> put_session_header(session_id)
        |> call_router()

      assert conn.status == 404

      conn =
        post_json_rpc(2, "ping")
        |> put_session_header(session_id)
        |> call_router()

      assert conn.status == 404
    end

    test "returns 200 with a result when client requests an unsupported protocol version" do
      params =
        @initialize_params
        |> Map.put("protocolVersion", "2024-11-05")

      conn = post_json_rpc(1, "initialize", params) |> call_router()

      assert conn.status == 200
      decoded = decode_resp(conn)
      assert decoded["error"] == nil
      assert decoded["result"]["protocolVersion"] == "2025-11-25"
    end

    test "persists negotiated version, client info and capabilities in the session" do
      params =
        Map.put(@initialize_params, "capabilities", %{"roots" => %{"listChanged" => true}})

      conn = post_json_rpc(1, "initialize", params) |> call_router()

      assert conn.status == 200
      assert [session_id] = get_resp_header(conn, "mcp-session-id")

      assert {:ok, data} = OzMcp.Sessions.lookup(inst(Servers.Default), session_id)

      assert data.initialized == false
      assert data.protocol_version == "2025-11-25"
      assert data.client_info == %{"name" => "test-client", "version" => "1.0.0"}
      assert data.client_capabilities == %{"roots" => %{"listChanged" => true}}
    end

    test "persists the latest supported version when client requests an unsupported one" do
      params =
        @initialize_params
        |> Map.put("protocolVersion", "2024-11-05")

      conn = post_json_rpc(1, "initialize", params) |> call_router()

      assert conn.status == 200
      assert [session_id] = get_resp_header(conn, "mcp-session-id")

      assert {:ok, data} = OzMcp.Sessions.lookup(inst(Servers.Default), session_id)

      assert data.protocol_version == "2025-11-25"
    end

    test "returns rpc error when params are missing" do
      conn = post_json_rpc(1, "initialize") |> call_router()

      assert conn.status == 200
      assert decode_resp(conn) == json_rpc_error(1, -32602, "missing or invalid protocol version")
      assert_cors_headers(conn)
    end

    test "returns rpc error when protocolVersion is missing" do
      params = Map.delete(@initialize_params, "protocolVersion")

      conn = post_json_rpc(1, "initialize", params) |> call_router()

      assert conn.status == 200
      assert decode_resp(conn) == json_rpc_error(1, -32602, "missing or invalid protocol version")
    end

    test "returns rpc error when protocolVersion is not a string" do
      params = Map.put(@initialize_params, "protocolVersion", 123)

      conn = post_json_rpc(1, "initialize", params) |> call_router()

      assert conn.status == 200
      assert decode_resp(conn) == json_rpc_error(1, -32602, "missing or invalid protocol version")
    end

    test "returns rpc error when clientInfo is missing" do
      params = Map.delete(@initialize_params, "clientInfo")

      conn = post_json_rpc(1, "initialize", params) |> call_router()

      assert conn.status == 200
      assert decode_resp(conn) == json_rpc_error(1, -32602, "missing or invalid client info")
    end

    test "returns rpc error when clientInfo is not a map" do
      params = Map.put(@initialize_params, "clientInfo", "not-a-map")

      conn = post_json_rpc(1, "initialize", params) |> call_router()

      assert conn.status == 200
      assert decode_resp(conn) == json_rpc_error(1, -32602, "missing or invalid client info")
    end

    test "returns rpc error when clientInfo name key is missing" do
      params =
        Map.put(@initialize_params, "clientInfo", %{"version" => "1.0.0"})

      conn = post_json_rpc(1, "initialize", params) |> call_router()

      assert conn.status == 200
      assert decode_resp(conn) == json_rpc_error(1, -32602, "missing or invalid client info")

      # a failed initialize must not create a session
      #
      headers = Enum.into(conn.resp_headers, %{})
      assert headers["mcp-session-id"] == nil
    end

    test "returns rpc error when clientInfo version key is missing" do
      params =
        Map.put(@initialize_params, "clientInfo", %{"name" => "test-client"})

      conn = post_json_rpc(1, "initialize", params) |> call_router()

      assert conn.status == 200
      assert decode_resp(conn) == json_rpc_error(1, -32602, "missing or invalid client info")

      headers = Enum.into(conn.resp_headers, %{})
      assert headers["mcp-session-id"] == nil
    end

    test "returns 200 when clientInfo name and version are empty strings (presence only)" do
      params =
        Map.put(@initialize_params, "clientInfo", %{"name" => "", "version" => ""})

      conn = post_json_rpc(1, "initialize", params) |> call_router()

      assert conn.status == 200
      assert decode_resp(conn)["error"] == nil

      headers = Enum.into(conn.resp_headers, %{})
      assert is_binary(headers["mcp-session-id"])
    end

    test "returns rpc error when clientInfo name is not a string" do
      params =
        Map.put(@initialize_params, "clientInfo", %{"name" => 123, "version" => "1.0.0"})

      conn = post_json_rpc(1, "initialize", params) |> call_router()

      assert conn.status == 200
      assert decode_resp(conn) == json_rpc_error(1, -32602, "missing or invalid client info")
    end

    test "returns rpc error when clientInfo version is null" do
      params =
        Map.put(@initialize_params, "clientInfo", %{"name" => "test-client", "version" => nil})

      conn = post_json_rpc(1, "initialize", params) |> call_router()

      assert conn.status == 200
      assert decode_resp(conn) == json_rpc_error(1, -32602, "missing or invalid client info")
    end
  end

  describe "POST / with method notifications/initialized" do
    test "returns 202" do
      session_id = Utils.create_session(inst(Servers.Default))

      conn =
        post_json_rpc(nil, "notifications/initialized")
        |> put_session_header(session_id)
        |> call_router()

      assert conn.status == 202
      assert_cors_headers(conn)
      assert conn.resp_body == ""
    end

    test "does not require an id" do
      session_id = Utils.create_session(inst(Servers.Default))

      conn =
        post_json_rpc(nil, "notifications/initialized")
        |> put_session_header(session_id)
        |> call_router()

      assert conn.status == 202
      assert conn.resp_body == ""
    end

    test "a second notification on the same session gets 202 two times" do
      session_id = Utils.create_session(inst(Servers.Default))

      first =
        post_json_rpc(nil, "notifications/initialized")
        |> put_session_header(session_id)
        |> call_router()

      second =
        post_json_rpc(nil, "notifications/initialized")
        |> put_session_header(session_id)
        |> call_router()

      assert first.status == 202
      assert first.resp_body == ""
      assert second.status == 202
      assert second.resp_body == ""
      assert_cors_headers(second)
    end

    test "the session stays valid after a duplicate notification" do
      session_id = Utils.create_session(inst(Servers.Default))

      conn =
        post_json_rpc(nil, "notifications/initialized")
        |> put_session_header(session_id)
        |> call_router()

      assert conn.status == 202

      conn =
        post_json_rpc(nil, "notifications/initialized")
        |> put_session_header(session_id)
        |> call_router()

      assert conn.status == 202

      conn =
        post_json_rpc(1, "ping")
        |> put_session_header(session_id)
        |> call_router()

      assert conn.status == 200
      assert decode_resp(conn) == %{"jsonrpc" => "2.0", "id" => 1, "result" => %{}}
    end
  end

  describe "POST / with method ping" do
    test "returns 200 with empty result" do
      session_id = Utils.create_session(inst(Servers.Default), initialized: true)

      conn =
        post_json_rpc(1, "ping")
        |> put_session_header(session_id)
        |> call_router()

      assert conn.status == 200
      assert decode_resp(conn) == %{"jsonrpc" => "2.0", "id" => 1, "result" => %{}}
    end

    test "answers a negative integer id with the same id" do
      session_id = Utils.create_session(inst(Servers.Default), initialized: true)

      conn =
        post_json_rpc(-5, "ping")
        |> put_session_header(session_id)
        |> call_router()

      assert conn.status == 200
      assert decode_resp(conn) == %{"jsonrpc" => "2.0", "id" => -5, "result" => %{}}
    end

    test "returns 200 for a session that waits for notifications/initialized" do
      session_id = Utils.create_session(inst(Servers.Default))

      conn =
        post_json_rpc(1, "ping")
        |> put_session_header(session_id)
        |> call_router()

      assert conn.status == 200
      assert decode_resp(conn) == %{"jsonrpc" => "2.0", "id" => 1, "result" => %{}}
    end

    test "returns rpc error when id is missing" do
      session_id = Utils.create_session(inst(Servers.Default), initialized: true)

      conn =
        post_json_rpc(nil, "ping")
        |> put_session_header(session_id)
        |> call_router()

      # A message without a valid id is not a request: HTTP error status.
      #
      assert conn.status == 400
      assert decode_resp(conn) == json_rpc_error(-32600, "missing id")
    end
  end

  describe "POST / session activity" do
    @tag task_opts: %{session_timeout_ms: 1_000}
    test "a request starts the idle timer of the session again" do
      server = inst(Servers.Default)

      conn = post_json_rpc(1, "initialize", @initialize_params) |> call_router()
      assert [session_id] = get_resp_header(conn, "mcp-session-id")

      conn =
        post_json_rpc(nil, "notifications/initialized")
        |> put_session_header(session_id)
        |> call_router()

      assert conn.status == 202

      # The session lives longer than its timeout (one second) because each
      # request starts the timer again. Each wait is the check that the
      # DOWN of the session did not arrive before the request.
      #
      {:ok, view} = Sessions.lookup(server, session_id)
      session_ref = Process.monitor(view.pid)

      for id <- 2..5 do
        refute_receive {:DOWN, ^session_ref, :process, _, _}, 400

        conn =
          post_json_rpc(id, "ping")
          |> put_session_header(session_id)
          |> call_router()

        assert conn.status == 200
      end

      # An idle session ends: a request after the timeout gets 404.
      #
      wait_until(fn -> Sessions.lookup(server, session_id) == {:error, :no_session} end, 3_000)

      conn =
        post_json_rpc(6, "ping")
        |> put_session_header(session_id)
        |> call_router()

      assert conn.status == 404
    end

    test "returns 404 for a ping of an unknown session" do
      conn =
        post_json_rpc(1, "ping")
        |> put_session_header("unknown-session")
        |> call_router()

      assert conn.status == 404
      assert decode_resp(conn) == json_rpc_error(1, -32001, "invalid session")
    end
  end

  # A session that cannot answer (here: suspended) must not stop the
  # request process: the GET stream answers 503, whose JSON-RPC error body
  # tells the caller to try again.
  #
  describe "when the session does not answer the GET" do
    test "a GET stream answers 503" do
      server = inst(Servers.Default)
      session_id = Utils.create_session(server, initialized: true)
      {:ok, session_pid} = OzMcp.Instance.whereis(server, {:session, session_id})

      :ok = :sys.suspend(session_pid)
      on_exit(fn -> if Process.alive?(session_pid), do: :sys.resume(session_pid) end)

      conn =
        conn(:get, "/")
        |> put_req_header("accept", "text/event-stream")
        |> put_req_header("mcp-protocol-version", "2025-11-25")
        |> put_session_header(session_id)
        |> call_router()

      assert conn.status == 503
      assert decode_resp(conn) == json_rpc_error(-32603, "server unavailable")
    end
  end

  describe "a request while the session ends" do
    test "gets 200 or 404, never an error of the server" do
      server = inst(Servers.Default)
      session_id = Utils.create_session(server, initialized: true)

      requests =
        for id <- 1..30 do
          Task.async(fn ->
            post_json_rpc(id, "ping")
            |> put_session_header(session_id)
            |> call_router()
          end)
        end

      assert :ok = Sessions.terminate(server, session_id)

      statuses = requests |> Task.await_many() |> Enum.map(& &1.status)
      assert Enum.all?(statuses, &(&1 in [200, 404]))

      conn =
        post_json_rpc(99, "ping")
        |> put_session_header(session_id)
        |> call_router()

      assert conn.status == 404
    end
  end

  describe "an open GET stream and the idle timer" do
    @tag task_opts: %{session_timeout_ms: 1_000}
    test "a session with a GET stream does not expire" do
      server = inst(Servers.Default)
      session_id = Utils.create_session(server, initialized: true)
      parent = self()

      requester =
        spawn(fn ->
          conn =
            conn(:get, "/")
            |> put_req_header("accept", "text/event-stream")
            |> put_session_header(session_id)
            |> call_router()

          send(parent, {:sse_conn, conn})
        end)

      wait_for_stream(server, session_id, requester)

      # The open GET stream holds the idle timer: no DOWN within the span
      # of the timeout.
      #
      {:ok, view} = Sessions.lookup(server, session_id)
      session_ref = Process.monitor(view.pid)
      refute_receive {:DOWN, ^session_ref, :process, _, _}, 1_500

      Process.exit(requester, :kill)
      wait_until(fn -> Sessions.lookup(server, session_id) == {:error, :no_session} end, 3_000)
    end
  end

  describe "when the session does not answer" do
    setup do
      server = inst(Servers.Default)
      session_id = Utils.create_session(server)
      {:ok, session_pid} = OzMcp.Instance.whereis(server, {:session, session_id})

      :ok = :sys.suspend(session_pid)

      on_exit(fn ->
        if Process.alive?(session_pid), do: :sys.resume(session_pid)
      end)

      %{session_id: session_id}
    end

    test "a DELETE answers 503 with the error body of :http_unavailable", %{
      session_id: session_id
    } do
      conn =
        conn(:delete, "/")
        |> put_session_header(session_id)
        |> call_router()

      assert conn.status == 503
      assert decode_resp(conn) == json_rpc_error(-32603, "server unavailable")
    end
  end

  describe "POST / with method resources/list" do
    test "returns 200 with correct files list (one resource module)" do
      session_id =
        Utils.create_session(inst(Servers.ResourcesSingle), initialized: true)

      conn =
        post_json_rpc(1, "resources/list")
        |> put_session_header(session_id)
        |> call_router(inst(Servers.ResourcesSingle))

      assert conn.status == 200

      expected_resources =
        listed(Servers.ResourcesSingle, :resources)
        |> Enum.map(&OzMcp.Structs.Resource.build/1)
        |> normalize_map_keys_to_string()

      assert decode_resp(conn) == json_rpc_result(1, %{"resources" => expected_resources})
    end

    test "returns 200 with correct files list (two resource modules)" do
      session_id =
        Utils.create_session(inst(Servers.ResourcesMultipleSubscribed),
          initialized: true
        )

      conn =
        post_json_rpc(1, "resources/list")
        |> put_session_header(session_id)
        |> call_router(inst(Servers.ResourcesMultipleSubscribed))

      assert conn.status == 200

      expected_resources =
        listed(Servers.ResourcesMultipleSubscribed, :resources)
        |> Enum.map(&OzMcp.Structs.Resource.build/1)
        |> normalize_map_keys_to_string()

      assert decode_resp(conn) == json_rpc_result(1, %{"resources" => expected_resources})
    end
  end

  describe "POST / with method resources/templates/list" do
    test "returns 200 with correct templates list (one template module)" do
      session_id =
        Utils.create_session(inst(Servers.WithTemplates), initialized: true)

      conn =
        post_json_rpc(1, "resources/templates/list")
        |> put_session_header(session_id)
        |> call_router(inst(Servers.WithTemplates))

      assert conn.status == 200

      expected_templates =
        listed(Servers.WithTemplates, :templates)
        |> Enum.map(&OzMcp.Structs.ResourceTemplate.build/1)
        |> normalize_map_keys_to_string()

      assert decode_resp(conn) == json_rpc_result(1, %{"resourceTemplates" => expected_templates})
    end

    test "returns 200 with correct templates list (two template modules)" do
      session_id =
        Utils.create_session(inst(Servers.TemplatesMultiple), initialized: true)

      conn =
        post_json_rpc(1, "resources/templates/list")
        |> put_session_header(session_id)
        |> call_router(inst(Servers.TemplatesMultiple))

      assert conn.status == 200

      expected_templates =
        listed(Servers.TemplatesMultiple, :templates)
        |> Enum.map(&OzMcp.Structs.ResourceTemplate.build/1)
        |> normalize_map_keys_to_string()

      assert decode_resp(conn) == json_rpc_result(1, %{"resourceTemplates" => expected_templates})
    end

    test "returns 200 with empty templates list when server has no templates configured" do
      session_id =
        Utils.create_session(inst(Servers.ResourcesSingle), initialized: true)

      conn =
        post_json_rpc(1, "resources/templates/list")
        |> put_session_header(session_id)
        |> call_router(inst(Servers.ResourcesSingle))

      assert conn.status == 200
      assert decode_resp(conn) == json_rpc_result(1, %{"resourceTemplates" => []})
    end

    test "returns rpc error when id is missing" do
      session_id =
        Utils.create_session(inst(Servers.WithTemplates), initialized: true)

      conn =
        post_json_rpc(nil, "resources/templates/list")
        |> put_session_header(session_id)
        |> call_router(inst(Servers.WithTemplates))

      # A message without a valid id is not a request: HTTP error status.
      #
      assert conn.status == 400
      assert decode_resp(conn) == json_rpc_error(-32600, "missing id")
    end
  end

  describe "POST / with method resources/read" do
    test "returns 200 with correct files content (one resource module)" do
      session_id =
        Utils.create_session(inst(Servers.ResourcesSingle), initialized: true)

      uri = "file:///marketing.md"

      conn =
        post_json_rpc(1, "resources/read", %{"uri" => uri})
        |> put_session_header(session_id)
        |> call_router(inst(Servers.ResourcesSingle))

      assert conn.status == 200

      ctx = %{
        server: inst(Servers.ResourcesSingle),
        session_id: session_id,
        request_id: 1,
        progress_token: nil,
        task_id: nil
      }

      {:ok, result} = Support.Entities.Resources.FirstTest.read(ctx, %{"uri" => uri})
      expected_result = normalize_map_keys_to_string(result)

      assert decode_resp(conn) == json_rpc_result(1, expected_result)
    end

    test "returns 200 with correct files content from first module (two resource modules)" do
      session_id =
        Utils.create_session(inst(Servers.ResourcesMultipleSubscribed),
          initialized: true
        )

      uri = "file:///marketing.md"

      conn =
        post_json_rpc(1, "resources/read", %{"uri" => uri})
        |> put_session_header(session_id)
        |> call_router(inst(Servers.ResourcesMultipleSubscribed))

      assert conn.status == 200

      ctx = %{
        server: inst(Servers.ResourcesMultipleSubscribed),
        session_id: session_id,
        request_id: 1,
        progress_token: nil,
        task_id: nil
      }

      {:ok, result} = Support.Entities.Resources.FirstTest.read(ctx, %{"uri" => uri})
      expected_result = normalize_map_keys_to_string(result)

      assert decode_resp(conn) == json_rpc_result(1, expected_result)
    end

    test "returns 200 with correct files content from second module (two resource modules)" do
      session_id =
        Utils.create_session(inst(Servers.ResourcesMultipleSubscribed),
          initialized: true
        )

      uri = "file:///definitions.md"

      conn =
        post_json_rpc(1, "resources/read", %{"uri" => uri})
        |> put_session_header(session_id)
        |> call_router(inst(Servers.ResourcesMultipleSubscribed))

      assert conn.status == 200

      ctx = %{
        server: inst(Servers.ResourcesMultipleSubscribed),
        session_id: session_id,
        request_id: 1,
        progress_token: nil,
        task_id: nil
      }

      {:ok, result} = Support.Entities.Resources.SecondTest.read(ctx, %{"uri" => uri})
      expected_result = normalize_map_keys_to_string(result)

      assert decode_resp(conn) == json_rpc_result(1, expected_result)
    end

    test "returns jsonrpc error when resource read returns an error" do
      session_id =
        Utils.create_session(inst(Servers.ResourcesMultipleSubscribed),
          initialized: true
        )

      uri = "file:///api_call.md"

      conn =
        post_json_rpc(1, "resources/read", %{"uri" => uri})
        |> put_session_header(session_id)
        |> call_router(inst(Servers.ResourcesMultipleSubscribed))

      assert conn.status == 200
      assert decode_resp(conn) == json_rpc_error(1, -32000, "resource temporarily unavailable")
    end

    test "returns rpc error when file content is not found" do
      session_id =
        Utils.create_session(inst(Servers.ResourcesSingle), initialized: true)

      uri = "file:///nonexistent.md"

      conn =
        post_json_rpc(1, "resources/read", %{"uri" => uri})
        |> put_session_header(session_id)
        |> call_router(inst(Servers.ResourcesSingle))

      assert conn.status == 200
      assert decode_resp(conn) == json_rpc_error(1, -32002, "resource not found", %{"uri" => uri})
    end

    test "returns rpc error when uri param is missing" do
      session_id =
        Utils.create_session(inst(Servers.ResourcesSingle), initialized: true)

      conn =
        post_json_rpc(1, "resources/read")
        |> put_session_header(session_id)
        |> call_router(inst(Servers.ResourcesSingle))

      assert conn.status == 200
      assert decode_resp(conn) == json_rpc_error(1, -32602, "missing uri parameter")
    end

    test "returns rpc error when uri param is nil" do
      session_id =
        Utils.create_session(inst(Servers.ResourcesSingle), initialized: true)

      conn =
        post_json_rpc(1, "resources/read", %{"uri" => nil})
        |> put_session_header(session_id)
        |> call_router(inst(Servers.ResourcesSingle))

      assert conn.status == 200
      assert decode_resp(conn) == json_rpc_error(1, -32602, "missing uri parameter")
    end

    test "returns rpc error when uri param is not a string" do
      session_id =
        Utils.create_session(inst(Servers.ResourcesSingle), initialized: true)

      conn =
        post_json_rpc(1, "resources/read", %{"uri" => 123})
        |> put_session_header(session_id)
        |> call_router(inst(Servers.ResourcesSingle))

      assert conn.status == 200
      assert decode_resp(conn) == json_rpc_error(1, -32602, "missing uri parameter")
    end
  end

  describe "POST / with method tools/call - param validation" do
    test "returns rpc error when name param is missing" do
      session_id = Utils.create_session(inst(Servers.Default), initialized: true)

      conn =
        post_json_rpc(1, "tools/call")
        |> put_session_header(session_id)
        |> call_router()

      assert conn.status == 200
      assert decode_resp(conn) == json_rpc_error(1, -32602, "missing name parameter")
    end

    test "returns rpc error when name param is nil" do
      session_id = Utils.create_session(inst(Servers.Default), initialized: true)

      conn =
        post_json_rpc(1, "tools/call", %{"name" => nil})
        |> put_session_header(session_id)
        |> call_router()

      assert conn.status == 200
      assert decode_resp(conn) == json_rpc_error(1, -32602, "missing name parameter")
    end

    test "returns rpc error when name param is not a string" do
      session_id = Utils.create_session(inst(Servers.Default), initialized: true)

      conn =
        post_json_rpc(1, "tools/call", %{"name" => 123})
        |> put_session_header(session_id)
        |> call_router()

      assert conn.status == 200
      assert decode_resp(conn) == json_rpc_error(1, -32602, "missing name parameter")
    end
  end

  describe "POST / with method tools/list" do
    test "returns 200 with correct tools list (one tool module)" do
      session_id = Utils.create_session(inst(@tools_only), initialized: true)

      conn =
        post_json_rpc(1, "tools/list")
        |> put_session_header(session_id)
        |> call_router(inst(@tools_only))

      assert conn.status == 200

      expected_tools =
        listed(@tools_only, :tools)
        |> Enum.map(&OzMcp.Structs.Tool.build/1)
        |> normalize_map_keys_to_string()

      assert decode_resp(conn) == json_rpc_result(1, %{"tools" => expected_tools})
    end

    test "returns 200 with correct tools list (two tool modules)" do
      session_id =
        Utils.create_session(inst(Servers.ToolsMultiple), initialized: true)

      conn =
        post_json_rpc(1, "tools/list")
        |> put_session_header(session_id)
        |> call_router(inst(Servers.ToolsMultiple))

      assert conn.status == 200

      expected_tools =
        listed(Servers.ToolsMultiple, :tools)
        |> Enum.map(&OzMcp.Structs.Tool.build/1)
        |> normalize_map_keys_to_string()

      assert decode_resp(conn) == json_rpc_result(1, %{"tools" => expected_tools})
    end
  end

  describe "POST / with method tools/call" do
    test "returns 200 with correct content (one tool module)" do
      session_id = Utils.create_session(inst(@tools_only), initialized: true)

      conn =
        post_json_rpc(1, "tools/call", %{"name" => "get_date"})
        |> put_session_header(session_id)
        |> call_router(inst(@tools_only))

      assert conn.status == 200

      ctx = %{
        server: inst(@tools_only),
        session_id: session_id,
        request_id: 1,
        progress_token: nil,
        task_id: nil
      }

      {:ok, result} = Support.Entities.Tools.SecondTest.call(ctx, %{"name" => "get_date"})
      expected_content = normalize_map_keys_to_string(result.content)

      assert decode_resp(conn) == json_rpc_result(1, %{"content" => expected_content})
    end

    test "returns 200 with correct content from first module (two tool modules)" do
      session_id =
        Utils.create_session(inst(Servers.ToolsMultiple), initialized: true)

      conn =
        post_json_rpc(1, "tools/call", %{"name" => "get_time"})
        |> put_session_header(session_id)
        |> call_router(inst(Servers.ToolsMultiple))

      assert conn.status == 200

      ctx = %{
        server: inst(Servers.ToolsMultiple),
        session_id: session_id,
        request_id: 1,
        progress_token: nil,
        task_id: nil
      }

      {:ok, result} = Support.Entities.Tools.SecondTest.call(ctx, %{"name" => "get_time"})
      expected_content = normalize_map_keys_to_string(result.content)

      assert decode_resp(conn) == json_rpc_result(1, %{"content" => expected_content})
    end

    test "returns 200 with correct content from second module (two tool modules)" do
      session_id =
        Utils.create_session(inst(Servers.ToolsMultiple), initialized: true)

      conn =
        post_json_rpc(1, "tools/call", %{
          "name" => "get_temperature",
          "arguments" => %{"location" => "Paris"}
        })
        |> put_session_header(session_id)
        |> call_router(inst(Servers.ToolsMultiple))

      assert conn.status == 200

      ctx = %{
        server: inst(Servers.ToolsMultiple),
        session_id: session_id,
        request_id: 1,
        progress_token: nil,
        task_id: nil
      }

      {:ok, result} =
        Support.Entities.Tools.FirstTest.call(ctx, %{
          "name" => "get_temperature",
          "arguments" => %{"location" => "Paris"}
        })

      expected_content = normalize_map_keys_to_string(result.content)

      assert decode_resp(conn) == json_rpc_result(1, %{"content" => expected_content})
    end

    test "returns jsonrpc error when tool is not found" do
      session_id = Utils.create_session(inst(@tools_only), initialized: true)

      conn =
        post_json_rpc(1, "tools/call", %{"name" => "nonexistent_tool"})
        |> put_session_header(session_id)
        |> call_router(inst(@tools_only))

      assert conn.status == 200

      assert decode_resp(conn) ==
               json_rpc_error(1, -32602, "tool not found", %{"name" => "nonexistent_tool"})
    end

    test "returns jsonrpc error when tool returns an error" do
      session_id =
        Utils.create_session(inst(Servers.ToolsMultiple), initialized: true)

      conn =
        post_json_rpc(1, "tools/call", %{"name" => "failing_tool"})
        |> put_session_header(session_id)
        |> call_router(inst(Servers.ToolsMultiple))

      assert conn.status == 200

      assert decode_resp(conn) ==
               json_rpc_error(1, -32602, "tool not found", %{"name" => "failing_tool"})
    end

    test "returns a tool execution error result when arguments violate the input schema" do
      session_id =
        Utils.create_session(inst(Servers.ToolsMultiple), initialized: true)

      conn =
        post_json_rpc(1, "tools/call", %{
          "name" => "get_temperature",
          "arguments" => %{"location" => 123}
        })
        |> put_session_header(session_id)
        |> call_router(inst(Servers.ToolsMultiple))

      assert conn.status == 200

      # Schema violations are tool execution errors: a successful response
      # whose result carries isError: true and the violation messages as
      # text content, never a JSON-RPC protocol error.
      #
      assert decode_resp(conn) == %{
               "jsonrpc" => "2.0",
               "id" => 1,
               "result" => %{
                 "content" => [
                   %{"type" => "text", "text" => "'location' value is not of type string"}
                 ],
                 "isError" => true
               }
             }
    end

    test "accepts extra arguments when the tool schema allows them" do
      session_id =
        Utils.create_session(inst(Servers.ToolsMultiple), initialized: true)

      conn =
        post_json_rpc(1, "tools/call", %{
          "name" => "get_temperature",
          "arguments" => %{"location" => "Paris", "unit" => "metric"}
        })
        |> put_session_header(session_id)
        |> call_router(inst(Servers.ToolsMultiple))

      assert conn.status == 200

      assert decode_resp(conn) == %{
               "jsonrpc" => "2.0",
               "id" => 1,
               "result" => %{
                 "content" => [
                   %{"type" => "text", "text" => "Temperature in Paris is 24°C"}
                 ]
               }
             }
    end

    test "returns jsonrpc error when arguments is not an object" do
      session_id =
        Utils.create_session(inst(Servers.ToolsMultiple), initialized: true)

      conn =
        post_json_rpc(1, "tools/call", %{
          "name" => "get_temperature",
          "arguments" => ["Paris"]
        })
        |> put_session_header(session_id)
        |> call_router(inst(Servers.ToolsMultiple))

      assert conn.status == 200

      assert decode_resp(conn) == %{
               "jsonrpc" => "2.0",
               "id" => 1,
               "error" => %{
                 "code" => -32602,
                 "message" => "bad argument(s)",
                 "data" => [
                   "invalid type for argument 'arguments': expected 'object', got 'array'"
                 ]
               }
             }
    end
  end

  describe "Response.json/3" do
    @tag :capture_log
    test "with an unencodable map keeps the status and gives a valid JSON body" do
      conn = Response.json(conn(:post, "/"), 202, %{"result" => %{"text" => <<0xFF>>}})

      assert conn.status == 202
      assert %{"error" => %{"code" => -32603}} = :json.decode(conn.resp_body)
    end
  end

  describe "last resort for unexpected failures" do
    setup do
      Utils.start_instances([Servers.Failing], __MODULE__, allowed_origins: [])
      :ok
    end

    # config/0 of the server fails: a failure of the framework itself,
    # outside of the guarded user callbacks.
    #
    defp post_failing_initialize(failure) do
      Process.put(:test_server_failure, failure)

      post_json_rpc(1, "initialize", %{
        "protocolVersion" => "2025-11-25",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "t", "version" => "1"}
      })
      |> call_router(inst(Servers.Failing))
    end

    @tag :capture_log
    test "a raise is answered with a JSON-RPC internal error and HTTP 500" do
      conn = post_failing_initialize(:raise)

      assert conn.status == 500
      assert decode_resp(conn)["error"]["code"] == -32603
      assert decode_resp(conn)["error"]["message"] == "internal server error"
      assert_cors_headers(conn)
    end

    @tag :capture_log
    test "the last-resort body keeps the id of the request" do
      conn = post_failing_initialize(:raise)

      assert conn.status == 500
      assert decode_resp(conn)["id"] == 1
    end

    @tag :capture_log
    test "a notification after a failed request leaves no remembered id" do
      _conn = post_failing_initialize(:raise)
      assert Process.get(:oz_mcp_request_id) == 1

      Process.delete(:test_server_failure)

      _conn =
        post_json_rpc(nil, "notifications/initialized")
        |> call_router(inst(Servers.Failing))

      assert Process.get(:oz_mcp_request_id) == nil
    end

    @tag :capture_log
    test "a throw is answered with a JSON-RPC internal error and HTTP 500" do
      conn = post_failing_initialize(:throw)

      assert conn.status == 500
      assert decode_resp(conn)["error"]["code"] == -32603
    end

    @tag :capture_log
    test "an exit of a failed call is answered with a JSON-RPC internal error and HTTP 500" do
      conn = post_failing_initialize(:exit)

      assert conn.status == 500
      assert decode_resp(conn)["error"]["code"] == -32603
    end

    test "the details are logged, never sent to the client" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          conn = post_failing_initialize(:raise)
          refute conn.resp_body =~ "boom from config"
        end)

      assert log =~ "Unexpected failure while handling the request"
      assert log =~ "boom from config"
    end

    test "an exit that stops the process is not swallowed" do
      assert catch_exit(post_failing_initialize(:exit_shutdown)) == :shutdown
    end

    @tag :capture_log
    test "a failure while the response is being committed is re-raised, not answered twice" do
      session_id = Utils.create_session(inst(Servers.Default), initialized: true)
      test_pid = self()

      # The before_send callback of the test runs after the one of the
      # router, which marks the response as started and fails.
      #
      conn =
        post_json_rpc(1, "ping")
        |> put_session_header(session_id)
        |> register_before_send(fn _conn ->
          send(test_pid, :commit_attempt)
          raise "boom while sending"
        end)

      assert_raise RuntimeError, "boom while sending", fn -> call_router(conn) end

      # The commit was attempted once: the failure was not answered by a
      # second response.
      #
      assert_received :commit_attempt
      refute_received :commit_attempt
    end

    test "a request after a failed one is answered normally" do
      session_id = Utils.create_session(inst(Servers.Default), initialized: true)
      conn = post_json_rpc(1, "ping") |> put_session_header(session_id)

      assert_raise RuntimeError, fn ->
        conn |> register_before_send(fn _ -> raise "boom while sending" end) |> call_router()
      end

      # Same process (a kept-alive connection): the marker was reset.
      #
      ExUnit.CaptureLog.capture_log(fn ->
        assert post_failing_initialize(:raise).status == 500
      end)
    end

    # A before_send callback runs inside Router.call/2, after the router
    # marked the response as started. Its FunctionClauseError carries the
    # conn as argument and the conn holds the marker in its header.
    #
    defp clause_failure(%{never: :matches}), do: :ok

    test "the log at level :error holds no argument of the failed function" do
      session_id = Utils.create_session(inst(Servers.Default), initialized: true)

      conn =
        post_json_rpc(1, "ping")
        |> put_session_header(session_id)
        |> put_req_header("authorization", "Bearer SECRET-TOKEN")
        |> register_before_send(&clause_failure/1)

      log =
        Utils.capture_log([level: :error], fn ->
          assert_raise FunctionClauseError, fn -> call_router(conn) end
        end)

      assert log =~ "Unexpected failure while handling the request: raised FunctionClauseError"
      assert log =~ "clause_failure/1"
      refute log =~ "SECRET-TOKEN"
    end

    test "the text of a last-resort failure appears only at level :debug" do
      session_id = Utils.create_session(inst(Servers.Default), initialized: true)

      conn =
        post_json_rpc(1, "ping")
        |> put_session_header(session_id)
        |> register_before_send(fn _ -> raise "boom while sending" end)

      error_log =
        Utils.capture_log([level: :error], fn ->
          assert_raise RuntimeError, fn -> call_router(conn) end
        end)

      assert error_log =~ "Unexpected failure while handling the request: raised RuntimeError"
      refute error_log =~ "boom while sending"

      debug_log =
        Utils.capture_log([level: :debug], fn ->
          assert_raise RuntimeError, fn -> call_router(conn) end
        end)

      assert debug_log =~ "Unexpected failure text: ** (RuntimeError) boom while sending"
    end
  end

  describe "unknown method" do
    test "returns jsonrpc error for unknown method" do
      session_id = Utils.create_session(inst(Servers.Default), initialized: true)

      conn =
        post_json_rpc(1, "unknown/method")
        |> put_session_header(session_id)
        |> call_router()

      assert conn.status == 200
      assert decode_resp(conn) == json_rpc_error(1, -32601, "method not found")
      assert_cors_headers(conn)
    end

    test "the client method name is escaped and bounded in the log" do
      session_id = Utils.create_session(inst(Servers.Default), initialized: true)
      method = "bad\nINJECTED" <> String.duplicate("x", 5_000)

      log =
        Utils.capture_log(fn ->
          conn =
            post_json_rpc(1, method)
            |> put_session_header(session_id)
            |> call_router()

          assert decode_resp(conn) == json_rpc_error(1, -32601, "method not found")
        end)

      assert log =~ "Unsupported method: \"bad\\nINJECTED"
      refute log =~ "\nINJECTED"
      assert byte_size(log) < 2_000
    end
  end

  describe "session management" do
    test "returns 400 with a JSON-RPC error body when session id is missing for non-initialize method" do
      conn = post_json_rpc(1, "resources/list") |> call_router()

      assert conn.status == 400
      assert decode_resp(conn) == json_rpc_error(1, -32600, "missing session id")
      assert_cors_headers(conn)
    end

    test "returns 404 with a JSON-RPC error body when session does not exist" do
      conn =
        post_json_rpc(1, "resources/list")
        |> put_req_header("mcp-session-id", "nonexistent-session")
        |> call_router()

      assert conn.status == 404
      assert decode_resp(conn) == json_rpc_error(1, -32001, "invalid session")
      assert_cors_headers(conn)
    end

    test "returns jsonrpc error when session is not initialized" do
      session_id = Utils.create_session(inst(Servers.Default))

      conn =
        post_json_rpc(1, "resources/list")
        |> put_session_header(session_id)
        |> call_router()

      assert conn.status == 200
      assert decode_resp(conn) == json_rpc_error(1, -32600, "waiting session initialization")
    end
  end

  describe "validate_capabilities - tools" do
    test "returns rpc error when tools not configured and method is tools/list" do
      session_id =
        Utils.create_session(inst(Servers.ResourcesSingle), initialized: true)

      conn =
        post_json_rpc(1, "tools/list", %{"name" => "get_weather"})
        |> put_session_header(session_id)
        |> call_router(inst(Servers.ResourcesSingle))

      assert conn.status == 200
      assert decode_resp(conn) == json_rpc_error(1, -32601, "method not found")
    end

    test "returns rpc error when tools not configured and method is tools/call" do
      session_id =
        Utils.create_session(inst(Servers.ResourcesSingle), initialized: true)

      conn =
        post_json_rpc(1, "tools/call", %{"name" => "get_weather"})
        |> put_session_header(session_id)
        |> call_router(inst(Servers.ResourcesSingle))

      assert conn.status == 200
      assert decode_resp(conn) == json_rpc_error(1, -32601, "method not found")
    end
  end

  describe "validate_capabilities - resources" do
    test "returns jsonrpc error when resources not configured and method is resources/list" do
      session_id =
        Utils.create_session(inst(Servers.ResourcesSingle), initialized: true)

      conn =
        post_json_rpc(1, "resources/list")
        |> put_session_header(session_id)
        |> call_router(inst(@tools_only))

      assert conn.status == 200
      assert decode_resp(conn) == json_rpc_error(1, -32601, "method not found")
    end

    test "returns jsonrpc error when resources not configured and method is resources/read" do
      session_id =
        Utils.create_session(inst(Servers.ResourcesSingle), initialized: true)

      conn =
        post_json_rpc(1, "resources/read", %{"uri" => "file:///test.md"})
        |> put_session_header(session_id)
        |> call_router(inst(@tools_only))

      assert conn.status == 200
      #
      # assert decode_resp(conn)["error"]["code"] == -32601
      #
      assert decode_resp(conn) == json_rpc_error(1, -32601, "method not found")
    end

    test "returns rpc error when resources not configured and method is resources/templates/list" do
      session_id =
        Utils.create_session(inst(Servers.ResourcesSingle), initialized: true)

      conn =
        post_json_rpc(nil, "resources/templates/list")
        |> put_session_header(session_id)
        |> call_router(inst(@tools_only))

      # A message without a valid id is not a request: HTTP error status.
      #
      assert conn.status == 400
      assert decode_resp(conn) == json_rpc_error(-32601, "method not found")
    end

    test "returns rpc error when resources not configured and method is resources/subscribe" do
      session_id = Utils.create_session(inst(@tools_only), initialized: true)

      conn =
        post_json_rpc(nil, "resources/subscribe")
        |> put_session_header(session_id)
        |> call_router(inst(@tools_only))

      # A message without a valid id is not a request: HTTP error status.
      #
      assert conn.status == 400
      assert decode_resp(conn) == json_rpc_error(-32601, "method not found")
    end

    test "returns rpc error when resources not configured and method is resources/unsubscribe" do
      session_id = Utils.create_session(inst(@tools_only), initialized: true)

      conn =
        post_json_rpc(nil, "resources/unsubscribe")
        |> put_session_header(session_id)
        |> call_router(inst(@tools_only))

      # A message without a valid id is not a request: HTTP error status.
      #
      assert conn.status == 400
      assert decode_resp(conn) == json_rpc_error(-32601, "method not found")
    end
  end

  describe "validate_capabilities - resources subscribe" do
    test "returns rpc error when subscribe is false and method is resources/subscribe" do
      session_id = Utils.create_session(inst(Servers.Default), initialized: true)

      conn =
        post_json_rpc(nil, "resources/subscribe")
        |> put_session_header(session_id)
        |> call_router()

      # A message without a valid id is not a request: HTTP error status.
      #
      assert conn.status == 400
      assert decode_resp(conn) == json_rpc_error(-32601, "method not found")
    end

    test "returns rpc error when subscribe is false and method is resources/unsubscribe" do
      session_id = Utils.create_session(inst(Servers.Default), initialized: true)

      conn =
        post_json_rpc(nil, "resources/unsubscribe")
        |> put_session_header(session_id)
        |> call_router()

      # A message without a valid id is not a request: HTTP error status.
      #
      assert conn.status == 400
      assert decode_resp(conn) == json_rpc_error(-32601, "method not found")
    end

    test "allows resources/subscribe when subscribe capability is true" do
      session_id =
        Utils.create_session(inst(Servers.ResourcesMultipleSubscribed),
          initialized: true
        )

      conn =
        post_json_rpc(1, "resources/subscribe", %{"uri" => "file:///marketing.md"})
        |> put_session_header(session_id)
        |> call_router(inst(Servers.ResourcesMultipleSubscribed))

      assert conn.status == 200
      assert decode_resp(conn) == %{"jsonrpc" => "2.0", "id" => 1, "result" => %{}}
    end
  end

  describe "resources subscribe flow" do
    @server_module Servers.ResourcesMultipleSubscribed
    @server Module.concat(@server_module, __MODULE__)
    test "subscribe records the subscription for the session" do
      session_id = Utils.create_session(@server, initialized: true)

      conn =
        post_json_rpc(1, "resources/subscribe", %{"uri" => "file:///marketing.md"})
        |> put_session_header(session_id)
        |> call_router(@server)

      assert conn.status == 200
      assert decode_resp(conn) == json_rpc_result(1, %{})
      assert Utils.subscriptions(@server, session_id) == ["file:///marketing.md"]
    end

    test "double subscribe keeps a single subscription entry" do
      session_id = Utils.create_session(@server, initialized: true)

      conn =
        post_json_rpc(1, "resources/subscribe", %{"uri" => "file:///marketing.md"})
        |> put_session_header(session_id)
        |> call_router(@server)

      assert decode_resp(conn) == json_rpc_result(1, %{})

      conn =
        post_json_rpc(2, "resources/subscribe", %{"uri" => "file:///marketing.md"})
        |> put_session_header(session_id)
        |> call_router(@server)

      assert decode_resp(conn) == json_rpc_result(2, %{})

      assert Utils.subscriptions(@server, session_id) == ["file:///marketing.md"]
    end

    test "answers too many subscriptions when max_subscriptions_per_session is reached" do
      Utils.stop_instances()

      Utils.start_instances(
        [{Servers.ResourcesMultipleSubscribed, %{max_subscriptions_per_session: 1}}],
        __MODULE__,
        allowed_origins: []
      )

      session_id = Utils.create_session(@server, initialized: true)

      conn =
        post_json_rpc(1, "resources/subscribe", %{"uri" => "file:///marketing.md"})
        |> put_session_header(session_id)
        |> call_router(@server)

      assert decode_resp(conn) == json_rpc_result(1, %{})

      conn =
        post_json_rpc(2, "resources/subscribe", %{"uri" => "file:///definitions.md"})
        |> put_session_header(session_id)
        |> call_router(@server)

      assert conn.status == 200

      assert decode_resp(conn) ==
               json_rpc_error(2, -32000, "too many subscriptions", %{
                 "limit" => "max_subscriptions_per_session"
               })

      assert Utils.subscriptions(@server, session_id) == ["file:///marketing.md"]

      # The unsubscribe of a held uri makes room again.
      #
      conn =
        post_json_rpc(3, "resources/unsubscribe", %{"uri" => "file:///marketing.md"})
        |> put_session_header(session_id)
        |> call_router(@server)

      assert decode_resp(conn) == json_rpc_result(3, %{})

      conn =
        post_json_rpc(4, "resources/subscribe", %{"uri" => "file:///definitions.md"})
        |> put_session_header(session_id)
        |> call_router(@server)

      assert decode_resp(conn) == json_rpc_result(4, %{})
    end

    test "subscribe with unknown uri returns rpc error resource not found" do
      session_id = Utils.create_session(@server, initialized: true)

      conn =
        post_json_rpc(1, "resources/subscribe", %{"uri" => "file:///nonexistent.md"})
        |> put_session_header(session_id)
        |> call_router(@server)

      assert conn.status == 200

      assert decode_resp(conn) ==
               json_rpc_error(1, -32002, "resource not found", %{
                 "uri" => "file:///nonexistent.md"
               })
    end

    test "subscribe without uri returns rpc error missing uri parameter" do
      session_id = Utils.create_session(@server, initialized: true)

      conn =
        post_json_rpc(1, "resources/subscribe")
        |> put_session_header(session_id)
        |> call_router(@server)

      assert conn.status == 200
      assert decode_resp(conn) == json_rpc_error(1, -32602, "missing uri parameter")
    end

    test "unsubscribe removes the subscription" do
      session_id = Utils.create_session(@server, initialized: true)

      conn =
        post_json_rpc(1, "resources/subscribe", %{"uri" => "file:///definitions.md"})
        |> put_session_header(session_id)
        |> call_router(@server)

      assert decode_resp(conn) == json_rpc_result(1, %{})

      conn =
        post_json_rpc(2, "resources/unsubscribe", %{"uri" => "file:///definitions.md"})
        |> put_session_header(session_id)
        |> call_router(@server)

      assert conn.status == 200
      assert decode_resp(conn) == json_rpc_result(2, %{})
      refute "file:///definitions.md" in Utils.subscriptions(@server, session_id)
    end

    test "unsubscribe of a non subscribed uri returns empty result" do
      session_id = Utils.create_session(@server, initialized: true)

      conn =
        post_json_rpc(1, "resources/unsubscribe", %{"uri" => "file:///definitions.md"})
        |> put_session_header(session_id)
        |> call_router(@server)

      assert conn.status == 200
      assert decode_resp(conn) == json_rpc_result(1, %{})
    end

    test "unsubscribe of an unknown uri returns empty result" do
      session_id = Utils.create_session(@server, initialized: true)

      conn =
        post_json_rpc(1, "resources/unsubscribe", %{"uri" => "file:///nonexistent.md"})
        |> put_session_header(session_id)
        |> call_router(@server)

      assert conn.status == 200
      assert decode_resp(conn) == json_rpc_result(1, %{})
    end

    test "subscribed session receives resources/updated notification" do
      session_id =
        Utils.create_session(@server, initialized: true, streams: [self()])

      conn =
        post_json_rpc(1, "resources/subscribe", %{"uri" => "file:///marketing.md"})
        |> put_session_header(session_id)
        |> call_router(@server)

      assert decode_resp(conn) == json_rpc_result(1, %{})

      assert :ok = OzMcp.Notify.resource_updated(@server, "file:///marketing.md")

      expected = %{
        "jsonrpc" => "2.0",
        "method" => "notifications/resources/updated",
        "params" => %{"uri" => "file:///marketing.md"}
      }

      {_, ^expected} = Utils.receive_event(5_000)
    end
  end

  describe "validate capabilities - allowed methods" do
    test "allows resources/list when resources capability is present" do
      session_id = Utils.create_session(inst(Servers.Default), initialized: true)

      conn =
        post_json_rpc(1, "resources/list")
        |> put_session_header(session_id)
        |> call_router()

      assert conn.status == 200
    end

    test "allows resources/read when resources capability is present" do
      session_id = Utils.create_session(inst(Servers.Default), initialized: true)

      conn =
        post_json_rpc(1, "resources/read", %{"uri" => "file:///stations.md"})
        |> put_session_header(session_id)
        |> call_router()

      assert conn.status == 200
    end
  end

  describe "POST / with method completion/complete" do
    test "returns prompt completion values" do
      session_id = Utils.create_session(inst(Servers.Completions), initialized: true)

      conn =
        post_json_rpc(1, "completion/complete", %{
          "ref" => %{"type" => "ref/prompt", "name" => "code_review"},
          "argument" => %{"name" => "language", "value" => "el"}
        })
        |> put_session_header(session_id)
        |> call_router(inst(Servers.Completions))

      assert conn.status == 200

      assert decode_resp(conn) ==
               json_rpc_result(1, %{
                 "completion" => %{
                   "values" => ["elixir", "python"],
                   "total" => 2,
                   "hasMore" => false
                 }
               })
    end

    test "returns resource template completion values" do
      session_id = Utils.create_session(inst(Servers.Completions), initialized: true)

      conn =
        post_json_rpc(1, "completion/complete", %{
          "ref" => %{"type" => "ref/resource", "uri" => "file://docs/{path}"},
          "argument" => %{"name" => "path", "value" => "in"}
        })
        |> put_session_header(session_id)
        |> call_router(inst(Servers.Completions))

      assert conn.status == 200

      assert decode_resp(conn) ==
               json_rpc_result(1, %{
                 "completion" => %{"values" => ["intro.md", "index.md"]}
               })
    end

    test "forwards context arguments to the callback" do
      session_id = Utils.create_session(inst(Servers.Completions), initialized: true)

      conn =
        post_json_rpc(1, "completion/complete", %{
          "ref" => %{"type" => "ref/prompt", "name" => "code_review"},
          "argument" => %{"name" => "language", "value" => ""},
          "context" => %{"arguments" => %{"focus" => "security"}}
        })
        |> put_session_header(session_id)
        |> call_router(inst(Servers.Completions))

      assert decode_resp(conn)["result"]["completion"]["values"] == ["elixir", "erlang"]
    end

    test "returns -32601 when the completions capability is absent" do
      session_id = Utils.create_session(inst(Servers.Default), initialized: true)

      conn =
        post_json_rpc(1, "completion/complete", %{
          "ref" => %{"type" => "ref/prompt", "name" => "code_review"},
          "argument" => %{"name" => "language", "value" => "el"}
        })
        |> put_session_header(session_id)
        |> call_router()

      assert decode_resp(conn) == json_rpc_error(1, -32601, "method not found")
    end

    test "returns -32602 for an invalid ref" do
      session_id = Utils.create_session(inst(Servers.Completions), initialized: true)

      conn =
        post_json_rpc(1, "completion/complete", %{
          "ref" => %{"type" => "ref/other", "name" => "code_review"},
          "argument" => %{"name" => "language", "value" => "el"}
        })
        |> put_session_header(session_id)
        |> call_router(inst(Servers.Completions))

      assert decode_resp(conn) == json_rpc_error(1, -32602, "invalid ref")
    end

    test "returns -32601 when the referenced prompt has no completer" do
      session_id =
        Utils.create_session(inst(Servers.CompletionsNoCallback), initialized: true)

      conn =
        post_json_rpc(1, "completion/complete", %{
          "ref" => %{"type" => "ref/prompt", "name" => "no_complete"},
          "argument" => %{"name" => "language", "value" => "el"}
        })
        |> put_session_header(session_id)
        |> call_router(inst(Servers.CompletionsNoCallback))

      assert decode_resp(conn) == json_rpc_error(1, -32601, "method not found")
    end
  end

  describe "MCP-Protocol-Version header validation" do
    test "returns 400 when the header contains an unsupported version" do
      session_id = Utils.create_session(inst(Servers.Default), initialized: true)

      conn =
        post_json_rpc(1, "resources/list")
        |> put_session_header(session_id)
        |> put_req_header("mcp-protocol-version", "2025-06-18")
        |> call_router()

      assert conn.status == 400
      assert decode_resp(conn) == json_rpc_error(1, -32600, "unsupported MCP protocol version")
      assert_cors_headers(conn)
    end

    test "accepts requests without the header" do
      session_id = Utils.create_session(inst(Servers.Default), initialized: true)

      conn =
        post_json_rpc(1, "resources/list")
        |> put_session_header(session_id)
        |> call_router()

      assert conn.status == 200
    end

    test "skips validation for initialize" do
      conn =
        post_json_rpc(1, "initialize", %{
          "protocolVersion" => "2025-11-25",
          "clientInfo" => %{"name" => "test-client", "version" => "1.0.0"}
        })
        |> put_req_header("mcp-protocol-version", "2025-06-18")
        |> call_router()

      assert conn.status == 200
      assert decode_resp(conn)["error"] == nil
    end

    # The version of the session lives in the ETS table of the store: it
    # is changed by hand to simulate a store that keeps another version
    # (only one version is supported today, so no client can see this).
    #
    test "returns 400 when the header differs from the version of the session (POST)" do
      session_id = Utils.create_session(inst(Servers.Default), initialized: true)
      put_session_version(inst(Servers.Default), session_id, "2025-06-18")

      conn =
        post_json_rpc(1, "resources/list")
        |> put_session_header(session_id)
        |> put_req_header("mcp-protocol-version", "2025-11-25")
        |> call_router()

      assert conn.status == 400

      assert decode_resp(conn) ==
               json_rpc_error(1, -32600, "MCP protocol version does not match the session")

      assert_cors_headers(conn)
    end

    test "returns 400 when the header differs from the version of the session (GET)" do
      session_id = Utils.create_session(inst(Servers.Default), initialized: true)
      put_session_version(inst(Servers.Default), session_id, "2025-06-18")

      conn =
        conn(:get, "/")
        |> put_req_header("accept", "text/event-stream")
        |> put_session_header(session_id)
        |> put_req_header("mcp-protocol-version", "2025-11-25")
        |> call_router()

      assert conn.status == 400

      assert decode_resp(conn) ==
               json_rpc_error(-32600, "MCP protocol version does not match the session")
    end

    test "returns 400 when the header differs from the version of the session (ping)" do
      server = inst(Servers.Default)
      session_id = Utils.create_session(server, initialized: true)
      put_session_version(server, session_id, "2025-06-18")

      conn =
        post_json_rpc(1, "ping")
        |> put_session_header(session_id)
        |> put_req_header("mcp-protocol-version", "2025-11-25")
        |> call_router(server)

      assert conn.status == 400

      assert decode_resp(conn) ==
               json_rpc_error(1, -32600, "MCP protocol version does not match the session")
    end

    test "a ping of the owner on an uninitialized session with a version that differs gets 400" do
      server = inst(Servers.Default)
      session_id = Utils.create_session(server)
      put_session_version(server, session_id, "2025-06-18")

      conn =
        post_json_rpc(1, "ping")
        |> put_session_header(session_id)
        |> put_req_header("mcp-protocol-version", "2025-11-25")
        |> call_router(server)

      assert conn.status == 400

      assert decode_resp(conn) ==
               json_rpc_error(1, -32600, "MCP protocol version does not match the session")
    end

    test "accepts a header equal to the version of the session" do
      session_id = Utils.create_session(inst(Servers.Default), initialized: true)
      put_session_version(inst(Servers.Default), session_id, "2025-11-25")

      conn =
        post_json_rpc(1, "resources/list")
        |> put_session_header(session_id)
        |> put_req_header("mcp-protocol-version", "2025-11-25")
        |> call_router()

      assert conn.status == 200
    end

    test "accepts a header when the session keeps no version" do
      session_id = Utils.create_session(inst(Servers.Default), initialized: true)

      assert {:ok, session} = OzMcp.Sessions.lookup(inst(Servers.Default), session_id)

      assert session.protocol_version == nil

      conn =
        post_json_rpc(1, "resources/list")
        |> put_session_header(session_id)
        |> put_req_header("mcp-protocol-version", "2025-11-25")
        |> call_router()

      assert conn.status == 200
    end

    test "the unsupported-version check still runs before the compare" do
      session_id = Utils.create_session(inst(Servers.Default), initialized: true)
      put_session_version(inst(Servers.Default), session_id, "2025-06-18")

      conn =
        post_json_rpc(1, "resources/list")
        |> put_session_header(session_id)
        |> put_req_header("mcp-protocol-version", "2025-06-18")
        |> call_router()

      assert conn.status == 400
      assert decode_resp(conn) == json_rpc_error(1, -32600, "unsupported MCP protocol version")
    end
  end

  describe "DELETE / (session termination)" do
    test "returns 200 and terminates an existing session" do
      session_id = Utils.create_session(inst(Servers.Default), initialized: true)

      conn =
        conn(:delete, "/")
        |> put_session_header(session_id)
        |> call_router()

      assert conn.status == 200
      assert_cors_headers(conn)

      assert Sessions.lookup(inst(Servers.Default), session_id) == {:error, :no_session}
    end

    test "a bad JSON body is not parsed: the session ends (no parse error)" do
      session_id = Utils.create_session(inst(Servers.Default), initialized: true)

      conn =
        conn(:delete, "/", "{not json")
        |> put_req_header("content-type", "application/json")
        |> put_session_header(session_id)
        |> call_router()

      assert conn.status == 200
      refute conn.resp_body =~ "-32700"

      assert Sessions.lookup(inst(Servers.Default), session_id) == {:error, :no_session}
    end

    test "returns 404 with a JSON-RPC error body when the session does not exist" do
      conn =
        conn(:delete, "/")
        |> put_session_header("nonexistent-session")
        |> call_router()

      assert conn.status == 404
      assert decode_resp(conn) == json_rpc_error(-32001, "invalid session")
      assert_cors_headers(conn)
    end

    test "returns 400 when the header contains an unsupported version" do
      session_id = Utils.create_session(inst(Servers.Default), initialized: true)

      conn =
        conn(:delete, "/")
        |> put_session_header(session_id)
        |> put_req_header("mcp-protocol-version", "2025-06-18")
        |> call_router()

      assert conn.status == 400
      assert decode_resp(conn) == json_rpc_error(-32600, "unsupported MCP protocol version")
    end

    test "accepts when the header is missing" do
      session_id = Utils.create_session(inst(Servers.Default), initialized: true)

      conn =
        conn(:delete, "/")
        |> put_session_header(session_id)
        |> call_router()

      assert conn.status == 200
    end

    test "passes when the header contains a supported version" do
      session_id = Utils.create_session(inst(Servers.Default), initialized: true)

      conn =
        conn(:delete, "/")
        |> put_session_header(session_id)
        |> put_req_header("mcp-protocol-version", "2025-11-25")
        |> call_router()

      assert conn.status == 200
    end

    # The DELETE route compares the version of the session like a `POST`:
    # a header that differs gets `400` and the session stays.
    #
    test "a DELETE whose header differs from the version of the session gets 400" do
      server = inst(Servers.Default)
      session_id = Utils.create_session(inst(Servers.Default), initialized: true)
      put_session_version(server, session_id, "2025-06-18")

      conn =
        conn(:delete, "/")
        |> put_session_header(session_id)
        |> put_req_header("mcp-protocol-version", "2025-11-25")
        |> call_router(server)

      assert conn.status == 400

      assert decode_resp(conn) ==
               json_rpc_error(-32600, "MCP protocol version does not match the session")

      # The session stays: the DELETE did not run.
      #
      assert {:ok, _} = Sessions.lookup(server, session_id)
    end

    test "a DELETE of the owner with the version of the session ends it" do
      server = inst(Servers.Default)
      session_id = Utils.create_session(server, initialized: true)
      put_session_version(server, session_id, "2025-11-25")

      conn =
        conn(:delete, "/")
        |> put_session_header(session_id)
        |> put_req_header("mcp-protocol-version", "2025-11-25")
        |> call_router(server)

      assert conn.status == 200

      assert Sessions.lookup(server, session_id) == {:error, :no_session}
    end

    test "closes open GET SSE streams with a retry hint and invalidates the session" do
      server = inst(Servers.Default)
      session_id = Utils.create_session(server, initialized: true)
      parent = self()

      requester =
        spawn(fn ->
          conn =
            conn(:get, "/")
            |> put_req_header("accept", "text/event-stream")
            |> put_session_header(session_id)
            |> call_router(server)

          send(parent, {:sse_conn, conn})
        end)

      wait_for_stream(server, session_id, requester)

      conn =
        conn(:delete, "/")
        |> put_session_header(session_id)
        |> call_router(server)

      assert conn.status == 200
      assert_cors_headers(conn)

      assert_receive {:sse_conn, sse}, 5_000
      assert sse.status == 200
      assert sse.resp_body =~ "retry: 1000"

      assert SessionProbe.initialized?(server, session_id) == {:error, :no_session}

      followup =
        post_json_rpc(1, "tools/list")
        |> put_session_header(session_id)
        |> call_router(server)

      assert followup.status == 404
      assert decode_resp(followup) == json_rpc_error(1, -32001, "invalid session")
    end

    test "a DELETE of the session ends a resumer with a retry field" do
      server = inst(Servers.Outbound)
      session_id = Utils.create_session(server, initialized: true)
      parent = self()

      # A POST stream that waits for the answer of the client: the ping of
      # the callback is logged under the id of its own stream.
      #
      start_call(server, session_id, 5)
      _id = wait_for_pending(server, session_id)
      assert {ping_id, _} = wait_for_post_event(server, session_id)
      assert [stream_id, _seq] = String.split(ping_id, ":")

      # A GET resumes the stream and waits for the events.
      #
      spawn(fn ->
        conn =
          conn(:get, "/")
          |> put_req_header("accept", "text/event-stream")
          |> put_req_header("last-event-id", "#{stream_id}:0")
          |> put_session_header(session_id)
          |> call_router(server)

        send(parent, {:resumed, conn})
      end)

      wait_for_resumer(server, session_id, stream_id)

      # The DELETE of the session ends the resumer with a retry field.
      #
      conn =
        conn(:delete, "/")
        |> put_session_header(session_id)
        |> call_router(server)

      assert conn.status == 200
      assert_receive {:resumed, resume_conn}, 5_000
      assert resume_conn.resp_body =~ ~r/retry: \d+\n\n\z/
    end
  end

  describe "unsupported methods and unknown paths" do
    test "PUT / answers 405 with the Allow header, the JSON-RPC body and no error log" do
      log =
        Utils.capture_log([level: :error], fn ->
          conn = conn(:put, "/") |> call_router()

          assert conn.status == 405
          assert get_resp_header(conn, "allow") == ["GET, POST, DELETE, OPTIONS"]
          assert decode_resp(conn) == json_rpc_error(-32600, "method not allowed")
          assert_cors_headers(conn)
        end)

      # An unsupported method is a client mistake: the server does not log it.
      #
      assert log == ""
    end

    test "PATCH / answers 405 with the Allow header" do
      conn = conn(:patch, "/") |> call_router()

      assert conn.status == 405
      assert get_resp_header(conn, "allow") == ["GET, POST, DELETE, OPTIONS"]
      assert decode_resp(conn) == json_rpc_error(-32600, "method not allowed")
      assert_cors_headers(conn)
    end

    test "HEAD / answers 405 with the Allow header" do
      conn = conn(:head, "/") |> call_router()

      assert conn.status == 405
      assert get_resp_header(conn, "allow") == ["GET, POST, DELETE, OPTIONS"]
      assert_cors_headers(conn)
    end

    test "a PUT with a bad JSON body gets 405, not the parse error" do
      conn =
        conn(:put, "/", "{not json")
        |> put_req_header("content-type", "application/json")
        |> call_router()

      assert conn.status == 405
      assert decode_resp(conn) == json_rpc_error(-32600, "method not allowed")
    end

    test "GET /other and POST /other answer 404 with the JSON-RPC body" do
      for method <- [:get, :post] do
        conn =
          conn(method, "/other", "{}")
          |> put_req_header("content-type", "application/json")
          |> call_router()

        assert conn.status == 404, "expected #{method} /other to be refused"
        assert decode_resp(conn) == json_rpc_error(-32600, "not found")
        assert_cors_headers(conn)
      end
    end

    test "a bad origin with an unsupported method still gets 403" do
      conn =
        conn(:put, "/")
        |> put_req_header("origin", "http://evil.example")
        |> call_router_with([])

      assert conn.status == 403
      assert conn.resp_body == ""
    end

    # A pin, not a discriminating test: Plug.Parsers reads POST, PUT, PATCH
    # and DELETE only, so a GET never had its body parsed. The test of
    # DELETE below is the one that fails when the router parses every method.
    #
    test "a GET with a bad JSON body is not parsed: the stream starts" do
      server = inst(Servers.Default)
      session_id = Utils.create_session(server, initialized: true)
      parent = self()

      requester =
        spawn(fn ->
          conn =
            conn(:get, "/", "{not json")
            |> put_req_header("content-type", "application/json")
            |> put_req_header("accept", "text/event-stream")
            |> put_session_header(session_id)
            |> call_router(server)

          send(parent, {:sse_conn, conn})
        end)

      wait_for_stream(server, session_id, requester)
      Utils.terminate_stream(server, session_id, requester)

      assert_receive {:sse_conn, sse}, 5_000
      assert sse.status == 200
      assert sse.resp_body =~ "retry: 1000"
    end
  end

  describe "handle_context_error - error to response mapping" do
    #
    # These branches live in `handle_context_error/1` because they can't be simulated
    # through the public HTTP API.
    #
    test ":http_internal_error returns 500 with a JSON-RPC error body" do
      context = error_context(conn(:post, "/"), :http_internal_error)

      result = OzMcp.Router.handle_context_error(context)

      assert result.conn.status == 500
      assert decode_resp(result.conn) == json_rpc_error(-32603, "internal server error")
      assert result.conn.halted
      assert_cors_headers(result.conn)
    end

    test ":rpc_internal_error returns 200 with rpc error" do
      context = error_context(conn(:post, "/"), :rpc_internal_error, 42)

      result = OzMcp.Router.handle_context_error(context)

      assert result.conn.status == 200
      assert decode_resp(result.conn) == json_rpc_error(42, -32603, "internal server error")
      assert result.conn.halted
      assert_cors_headers(result.conn)
    end

    test ":rpc_internal_error preserves a nil rpc id" do
      context = error_context(conn(:post, "/"), :rpc_internal_error)

      result = OzMcp.Router.handle_context_error(context)

      assert result.conn.status == 200
      assert decode_resp(result.conn) == json_rpc_error(-32603, "internal server error")
    end

    test ":rpc_missing_params returns 200 with rpc error" do
      context = error_context(conn(:post, "/"), :rpc_missing_params, 42)

      result = OzMcp.Router.handle_context_error(context)

      assert result.conn.status == 200
      assert decode_resp(result.conn) == json_rpc_error(42, -32602, "missing params")
      assert result.conn.halted
      assert_cors_headers(result.conn)
    end

    test "an error with response headers sends them with the response" do
      headers = [
        {"www-authenticate",
         ~s(Bearer error="invalid_token", resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource")},
        {"cache-control", "no-store"}
      ]

      context = error_context(conn(:post, "/"), :http_unauthorized, nil, headers)

      result = OzMcp.Router.handle_context_error(context)

      assert result.conn.status == 401

      resp_headers = Enum.into(result.conn.resp_headers, %{})
      assert resp_headers["www-authenticate"] =~ ~s(error="invalid_token")
      assert resp_headers["www-authenticate"] =~ "resource_metadata"
      assert resp_headers["cache-control"] == "no-store"

      assert decode_resp(result.conn) == json_rpc_error(-32010, "unauthorized")
      assert result.conn.halted
      assert_cors_headers(result.conn)
    end

    test "an error without response headers adds none" do
      context = error_context(conn(:post, "/"), :http_unauthorized)

      result = OzMcp.Router.handle_context_error(context)

      resp_headers = Enum.into(result.conn.resp_headers, %{})
      refute Map.has_key?(resp_headers, "www-authenticate")
    end
  end

  # "Not found" error-code contract: an unknown tool or prompt is an
  # invalid-params problem (-32602), an unknown resource gets the
  # dedicated -32002 code with the requested uri as data.
  #

  describe "not found error codes" do
    test "prompts/get with an unknown prompt returns -32602" do
      session_id = Utils.create_session(inst(Servers.Completions), initialized: true)

      conn =
        post_json_rpc(1, "prompts/get", %{"name" => "unknown_prompt"})
        |> put_session_header(session_id)
        |> call_router(inst(Servers.Completions))

      assert conn.status == 200
      assert decode_resp(conn) == json_rpc_error(1, -32602, "prompt not found")
      assert_cors_headers(conn)
    end

    test "completion on an unknown prompt ref returns -32602" do
      session_id = Utils.create_session(inst(Servers.Completions), initialized: true)

      conn =
        post_json_rpc(1, "completion/complete", %{
          "ref" => %{"type" => "ref/prompt", "name" => "unknown_prompt"},
          "argument" => %{"name" => "language", "value" => "el"}
        })
        |> put_session_header(session_id)
        |> call_router(inst(Servers.Completions))

      assert conn.status == 200
      assert decode_resp(conn) == json_rpc_error(1, -32602, "prompt not found")
      assert_cors_headers(conn)
    end

    test "completion on an unknown resource ref returns -32002 with the uri as data" do
      session_id = Utils.create_session(inst(Servers.Completions), initialized: true)

      conn =
        post_json_rpc(1, "completion/complete", %{
          "ref" => %{"type" => "ref/resource", "uri" => "file:///nonexistent.md"},
          "argument" => %{"name" => "path", "value" => "in"}
        })
        |> put_session_header(session_id)
        |> call_router(inst(Servers.Completions))

      assert conn.status == 200

      assert decode_resp(conn) ==
               json_rpc_error(1, -32002, "resource not found", %{
                 "uri" => "file:///nonexistent.md"
               })

      assert_cors_headers(conn)
    end

    test "completion on an unknown template string ref returns -32002 with the uri as data" do
      session_id = Utils.create_session(inst(Servers.Completions), initialized: true)

      conn =
        post_json_rpc(1, "completion/complete", %{
          "ref" => %{"type" => "ref/resource", "uri" => "app://unknown/{id}"},
          "argument" => %{"name" => "id", "value" => "4"}
        })
        |> put_session_header(session_id)
        |> call_router(inst(Servers.Completions))

      assert conn.status == 200

      assert decode_resp(conn) ==
               json_rpc_error(1, -32002, "resource not found", %{
                 "uri" => "app://unknown/{id}"
               })

      assert_cors_headers(conn)
    end

    test "completion on a concrete uri that a template matches returns the values" do
      session_id = Utils.create_session(inst(Servers.Completions), initialized: true)

      conn =
        post_json_rpc(1, "completion/complete", %{
          "ref" => %{"type" => "ref/resource", "uri" => "file://docs/intro.md"},
          "argument" => %{"name" => "path", "value" => "in"}
        })
        |> put_session_header(session_id)
        |> call_router(inst(Servers.Completions))

      assert conn.status == 200

      assert decode_resp(conn) ==
               json_rpc_result(1, %{
                 "completion" => %{"values" => ["intro.md", "index.md"]}
               })

      assert_cors_headers(conn)
    end

    test "every HTTP-level error body is a JSON-RPC error envelope with a usable id or none" do
      #
      # 406 (no accept) / 400 (no session id) / 404 (unknown session),
      # sampled through three distinct status families. A usable request
      # id is echoed; an undeterminable one leaves no "id" member at all
      # (never a forced null).
      #
      samples = [
        {conn(:get, "/"), :no_id},
        {conn(:get, "/") |> put_req_header("accept", "text/event-stream"), :no_id},
        {post_json_rpc(1, "resources/list")
         |> put_session_header("nonexistent-session"), {:id, 1}}
      ]

      for {conn, id} <- samples do
        conn = call_router(conn)
        response = decode_resp(conn)

        assert conn.status in [400, 404, 406]
        assert response["jsonrpc"] == "2.0"

        case id do
          :no_id -> refute Map.has_key?(response, "id")
          {:id, rpc_id} -> assert response["id"] == rpc_id
        end

        assert is_integer(response["error"]["code"])
        assert is_binary(response["error"]["message"])
      end
    end
  end

  # The lookup of the entity runs after the session checks: the answer to
  # a caller without a valid session must not depend on the entity that
  # the request names.
  #
  describe "the lookup of the entity runs after the session checks" do
    @tools_server Module.concat(@tools_only, __MODULE__)
    @completions_server_module Servers.Completions
    @completions_server Module.concat(@completions_server_module, __MODULE__)
    test "tools/call without a session id gets 400 for a known tool and for an unknown tool" do
      known =
        post_json_rpc(1, "tools/call", %{"name" => "get_date"})
        |> call_router(@tools_server)

      unknown =
        post_json_rpc(1, "tools/call", %{"name" => "nope"})
        |> call_router(@tools_server)

      assert known.status == 400
      assert unknown.status == 400
      assert decode_resp(known) == decode_resp(unknown)
    end

    test "tools/call with an unknown session id gets 404 for a known tool and for an unknown tool" do
      known =
        post_json_rpc(1, "tools/call", %{"name" => "get_date"})
        |> put_session_header("no-such-session")
        |> call_router(@tools_server)

      unknown =
        post_json_rpc(1, "tools/call", %{"name" => "nope"})
        |> put_session_header("no-such-session")
        |> call_router(@tools_server)

      assert known.status == 404
      assert unknown.status == 404
      assert decode_resp(known) == decode_resp(unknown)
    end

    test "resources/read without a session id gets 400 for a known uri and for an unknown uri" do
      known =
        post_json_rpc(1, "resources/read", %{"uri" => "file:///marketing.md"})
        |> call_router()

      unknown =
        post_json_rpc(1, "resources/read", %{"uri" => "file:///nope.md"})
        |> call_router()

      assert known.status == 400
      assert unknown.status == 400
      assert decode_resp(known) == decode_resp(unknown)
    end

    test "prompts/get without a session id gets 400 for a known prompt and for an unknown prompt" do
      known =
        post_json_rpc(1, "prompts/get", %{"name" => "code_review"})
        |> call_router(@completions_server)

      unknown =
        post_json_rpc(1, "prompts/get", %{"name" => "nope"})
        |> call_router(@completions_server)

      assert known.status == 400
      assert unknown.status == 400
      assert decode_resp(known) == decode_resp(unknown)
    end

    test "completion/complete without a session id gets 400 for a known ref and for an unknown ref" do
      params = fn name ->
        %{
          "ref" => %{"type" => "ref/prompt", "name" => name},
          "argument" => %{"name" => "language", "value" => "el"}
        }
      end

      known =
        post_json_rpc(1, "completion/complete", params.("code_review"))
        |> call_router(@completions_server)

      unknown =
        post_json_rpc(1, "completion/complete", params.("nope"))
        |> call_router(@completions_server)

      assert known.status == 400
      assert unknown.status == 400
      assert decode_resp(known) == decode_resp(unknown)
    end
  end

  describe "GET / (SSE stream)" do
    test "returns 406 with a JSON-RPC error body when accept header is missing" do
      conn =
        conn(:get, "/")
        |> call_router()

      assert conn.status == 406
      assert decode_resp(conn) == json_rpc_error(-32600, "accept header is required")
      assert_cors_headers(conn)
    end

    test "returns 406 with a JSON-RPC error body when accept header lacks text/event-stream" do
      conn =
        conn(:get, "/")
        |> put_req_header("accept", "application/json")
        |> call_router()

      assert conn.status == 406
      assert decode_resp(conn) == json_rpc_error(-32600, "client must accept text/event-stream")
      assert_cors_headers(conn)
    end

    test "returns 400 with a JSON-RPC error body when session id is missing" do
      conn =
        conn(:get, "/")
        |> put_req_header("accept", "text/event-stream")
        |> call_router()

      assert conn.status == 400
      assert decode_resp(conn) == json_rpc_error(-32600, "missing session id")
      assert_cors_headers(conn)
    end

    test "returns 404 with a JSON-RPC error body when session does not exist" do
      conn =
        conn(:get, "/")
        |> put_req_header("accept", "text/event-stream")
        |> put_session_header("nonexistent-session")
        |> call_router()

      assert conn.status == 404
      assert decode_resp(conn) == json_rpc_error(-32001, "invalid session")
      assert_cors_headers(conn)
    end

    test "returns 400 with a JSON-RPC error body when session is not initialized" do
      session_id = Utils.create_session(inst(Servers.Default), initialized: false)

      conn =
        conn(:get, "/")
        |> put_req_header("accept", "text/event-stream")
        |> put_session_header(session_id)
        |> call_router()

      assert conn.status == 400
      assert decode_resp(conn) == json_rpc_error(-32600, "waiting session initialization")
      assert_cors_headers(conn)
    end

    test "a GET over max_streams_per_session ends the oldest stream" do
      Utils.stop_instances()

      Utils.start_instances(
        [{Servers.Default, %{max_streams_per_session: 1}}],
        __MODULE__,
        allowed_origins: []
      )

      server = inst(Servers.Default)
      session_id = Utils.create_session(server, initialized: true)
      parent = self()

      open_get = fn ->
        spawn(fn ->
          conn =
            conn(:get, "/")
            |> put_req_header("accept", "text/event-stream")
            |> put_session_header(session_id)
            |> call_router()

          send(parent, {:sse_conn, conn})
        end)
      end

      first = open_get.()
      wait_for_stream(server, session_id, first)

      # The second GET ends the oldest stream and takes the only slot.
      #
      second = open_get.()
      wait_for_stream(server, session_id, second)
      assert Utils.stream_pids(server, session_id) == [second]

      assert_receive {:sse_conn, first_conn}, 5_000
      assert first_conn.status == 200
      assert first_conn.resp_body =~ ~r/retry: 1000\n\n\z/

      Utils.terminate_stream(server, session_id, second)

      assert_receive {:sse_conn, second_conn}, 5_000
      assert second_conn.status == 200
      assert second_conn.resp_body =~ ~r/retry: 1000\n\n\z/
    end

    test "returns 400 with a JSON-RPC error body when MCP-Protocol-Version contains an unsupported version" do
      session_id = Utils.create_session(inst(Servers.Default), initialized: true)

      conn =
        conn(:get, "/")
        |> put_req_header("accept", "text/event-stream")
        |> put_session_header(session_id)
        |> put_req_header("mcp-protocol-version", "2025-06-18")
        |> call_router()

      assert conn.status == 400
      assert decode_resp(conn) == json_rpc_error(-32600, "unsupported MCP protocol version")
    end

    test "returns 400 with a JSON-RPC error body when MCP-Protocol-Version is not a version string" do
      session_id = Utils.create_session(inst(Servers.Default), initialized: true)

      conn =
        conn(:get, "/")
        |> put_req_header("accept", "text/event-stream")
        |> put_session_header(session_id)
        |> put_req_header("mcp-protocol-version", "garbage")
        |> call_router()

      assert conn.status == 400
      assert decode_resp(conn) == json_rpc_error(-32600, "unsupported MCP protocol version")
    end

    test "opens the stream when MCP-Protocol-Version is missing" do
      server = inst(Servers.Default)
      session_id = Utils.create_session(server, initialized: true)
      parent = self()

      requester =
        spawn(fn ->
          conn =
            conn(:get, "/")
            |> put_req_header("accept", "text/event-stream")
            |> put_session_header(session_id)
            |> call_router()

          send(parent, {:sse_conn, conn})
        end)

      wait_for_stream(server, session_id, requester)

      Utils.terminate_stream(server, session_id, requester)

      assert_receive {:sse_conn, conn}, 5_000

      headers = Enum.into(conn.resp_headers, %{})
      assert conn.status == 200
      assert String.contains?(headers["content-type"], "text/event-stream")
    end

    test "opens the stream when MCP-Protocol-Version is supported" do
      server = inst(Servers.Default)
      session_id = Utils.create_session(server, initialized: true)
      parent = self()

      requester =
        spawn(fn ->
          conn =
            conn(:get, "/")
            |> put_req_header("accept", "text/event-stream")
            |> put_session_header(session_id)
            |> put_req_header("mcp-protocol-version", "2025-11-25")
            |> call_router()

          send(parent, {:sse_conn, conn})
        end)

      wait_for_stream(server, session_id, requester)

      Utils.terminate_stream(server, session_id, requester)

      assert_receive {:sse_conn, conn}, 5_000

      headers = Enum.into(conn.resp_headers, %{})
      assert conn.status == 200
      assert String.contains?(headers["content-type"], "text/event-stream")
    end

    test "opens a 200 chunked text/event-stream and sends notification as SSE event" do
      server = inst(Servers.Default)
      session_id = Utils.create_session(server, initialized: true)
      parent = self()

      requester =
        spawn(fn ->
          conn =
            conn(:get, "/")
            |> put_req_header("accept", "text/event-stream")
            |> put_session_header(session_id)
            |> call_router()

          send(parent, {:sse_conn, conn})
        end)

      # Ensure the requester has registered its stream before notifying.
      #
      wait_for_stream(server, session_id, requester)

      notification = %{"jsonrpc" => "2.0", "method" => "notifications/tools/list_changed"}
      :ok = Sessions.notify_all(server, notification)

      # Sync barrier: a call is handled after the earlier notify cast, so once
      # this returns the Server has already sent the event message to the
      # requester. Sending the terminate message afterwards preserves mailbox order.
      #
      Utils.sync_server(server, session_id)

      Utils.terminate_stream(server, session_id, requester)

      assert_receive {:sse_conn, conn}, 5_000

      headers = Enum.into(conn.resp_headers, %{})
      assert conn.status == 200
      assert String.contains?(headers["content-type"], "text/event-stream")
      assert conn.resp_body =~ "event: message"
      assert conn.resp_body =~ "notifications/tools/list_changed"

      ids = extract_event_ids(conn.resp_body)
      refute ids == []
    end

    test "sends a unique event id per notification on the same stream" do
      server = inst(Servers.Default)
      session_id = Utils.create_session(server, initialized: true)
      parent = self()

      requester =
        spawn(fn ->
          conn =
            conn(:get, "/")
            |> put_req_header("accept", "text/event-stream")
            |> put_session_header(session_id)
            |> call_router()

          send(parent, {:sse_conn, conn})
        end)

      # Ensure the requester has registered its stream before notifying.
      #
      wait_for_stream(server, session_id, requester)

      notification = %{"jsonrpc" => "2.0", "method" => "notifications/tools/list_changed"}

      :ok = Sessions.notify_all(server, notification)
      Utils.sync_server(server, session_id)

      :ok = Sessions.notify_all(server, notification)
      Utils.sync_server(server, session_id)

      Utils.terminate_stream(server, session_id, requester)

      assert_receive {:sse_conn, conn}, 5_000

      ids = extract_event_ids(conn.resp_body)

      assert length(ids) == 2
      assert length(Enum.uniq(ids)) == 2
    end

    test "sends the retry hint as the first chunk of the stream" do
      server = inst(Servers.Default)
      session_id = Utils.create_session(server, initialized: true)
      parent = self()

      requester =
        spawn(fn ->
          conn =
            conn(:get, "/")
            |> put_req_header("accept", "text/event-stream")
            |> put_session_header(session_id)
            |> call_router()

          send(parent, {:sse_conn, conn})
        end)

      # Ensure the requester has registered its stream before closing.
      #
      wait_for_stream(server, session_id, requester)

      Utils.terminate_stream(server, session_id, requester)

      assert_receive {:sse_conn, conn}, 5_000

      # A retry chunk, then the priming event (an id with an empty data
      # field), then the retry chunk of the termination: a fresh session
      # replays nothing and no heartbeat fires (default 30 s).
      #
      assert Regex.match?(
               ~r|\Aretry: 1000\n\nid: g\.[A-Za-z0-9]+:0\ndata: \n\nretry: 1000\n\n\z|,
               conn.resp_body
             )
    end

    test "a stream that starts with a replay has no priming event: the first id is a replayed event" do
      server = inst(Servers.Default)
      session_id = Utils.create_session(server, initialized: true)
      notification = %{"jsonrpc" => "2.0", "method" => "notifications/tools/list_changed"}

      conn_a = open_and_close_sse(server, session_id, nil)
      priming_id = extract_priming_id(conn_a.resp_body)

      :ok = Sessions.notify_all(server, notification)
      Utils.sync_server(server, session_id)

      conn_b = open_and_close_sse(server, session_id, priming_id)

      # The wire order of the ids is the log order: the replayed event
      # comes first, so a client that holds the first id of this stream
      # still finds the later events.
      #
      assert [replayed_id] = extract_message_event_ids(conn_b.resp_body)

      assert Regex.scan(~r/^id: (\S+)$/m, conn_b.resp_body, capture: :all_but_first) ==
               [[replayed_id]]
    end

    test "open_stream registers and reads the log in one step: no event is lost or doubled" do
      server = inst(Servers.Default)
      session_id = Utils.create_session(server, initialized: true)
      notification = %{"jsonrpc" => "2.0", "method" => "notifications/tools/list_changed"}

      conn_a = open_and_close_sse(server, session_id, nil)
      priming_id = extract_priming_id(conn_a.resp_body)

      :ok = Sessions.emit(server, session_id, :session, notification)
      Utils.sync_server(server, session_id)

      # The event of the gap is in the replay and no marker is added.
      #
      assert {:ok, %{replay: [{replayed_id, _}], priming_id: nil}} =
               Session.open_stream(server, session_id, :get, self(), priming_id)

      # An event logged right after the attach goes to the stream, once.
      #
      :ok = Sessions.emit(server, session_id, :session, notification)
      {live_id, _data} = Utils.receive_event(5_000)
      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 50

      assert {:ok, events} = SessionProbe.events_after(server, session_id, "")
      assert [^replayed_id, ^live_id] = Enum.map(events, fn {id, _} -> id end)
    end

    test "open_stream with nothing to replay numbers the stream from its own id" do
      server = inst(Servers.Default)
      session_id = Utils.create_session(server, initialized: true)
      notification = %{"jsonrpc" => "2.0", "method" => "notifications/tools/list_changed"}

      assert {:ok, %{stream_id: stream_id, replay: [], priming_id: priming_id}} =
               Session.open_stream(server, session_id, :get, self(), nil)

      assert priming_id == "#{stream_id}:0"

      :ok = Sessions.emit(server, session_id, :session, notification)
      {live_id, _data} = Utils.receive_event(5_000)
      assert live_id == "#{stream_id}:1"

      # The log holds the event under the stream and no marker.
      #
      assert {:ok, [{^live_id, data}]} = SessionProbe.events_after(server, session_id, "")

      assert data != ""

      # An unknown id also starts fresh, with the first position of its own
      # new stream.
      #
      assert {:ok, %{stream_id: other_stream, replay: [], priming_id: other}} =
               Session.open_stream(server, session_id, :get, self(), "nope")

      assert other == "#{other_stream}:0" and other != priming_id
    end

    test "open_stream answers {:error, :no_session} for an unknown session" do
      assert {:error, :no_session} =
               Session.open_stream(inst(Servers.Default), "nope", :get, self(), nil)
    end

    test "the stream loop leaves the messages of the host server in its mailbox" do
      server = inst(Servers.Default)
      session_id = Utils.create_session(server, initialized: true)
      parent = self()

      requester =
        spawn(fn ->
          conn =
            conn(:get, "/")
            |> put_req_header("accept", "text/event-stream")
            |> put_session_header(session_id)
            |> call_router()

          {:messages, messages} = Process.info(self(), :messages)
          send(parent, {:sse_done, conn, messages})
        end)

      wait_for_stream(server, session_id, requester)

      # Bandit reads these two itself; a plug must never receive them.
      #
      send(requester, {:plug_conn, :sent})
      send(requester, {:bandit, :other})
      Utils.terminate_stream(server, session_id, requester)

      assert_receive {:sse_done, conn, messages}, 5_000
      assert conn.status == 200
      assert {:plug_conn, :sent} in messages
      assert {:bandit, :other} in messages
    end

    test "a stream that the client closes before the priming write ends without an error" do
      server = inst(Servers.Default)
      session_id = Utils.create_session(server, initialized: true)

      # The retry chunk is written, the priming chunk fails: the client is gone.
      #
      conn =
        conn(:get, "/")
        |> put_req_header("accept", "text/event-stream")
        |> Support.Helpers.AdapterClosed.wrap(1)
        |> put_session_header(session_id)
        |> call_router()

      assert conn.state == :chunked

      # The stream did register in the Server and it left the session again.
      #
      assert Utils.stream_pids(server, session_id) == []
    end

    test "the priming id is the first position of the stream and the log holds no marker" do
      server = inst(Servers.Default)
      session_id = Utils.create_session(server, initialized: true)

      conn = open_and_close_sse(server, session_id, nil)
      priming_id = extract_priming_id(conn.resp_body)
      assert String.starts_with?(priming_id, "g.") and String.ends_with?(priming_id, ":0")

      # No marker: the log holds nothing until the first event of the stream.
      #
      assert {:ok, []} = SessionProbe.events_after(server, session_id, "")
    end

    test "a resume from the priming id replays the events logged after it" do
      server = inst(Servers.Default)
      session_id = Utils.create_session(server, initialized: true)

      notification = %{"jsonrpc" => "2.0", "method" => "notifications/tools/list_changed"}

      conn_a = open_and_close_sse(server, session_id, nil)
      priming_id = extract_priming_id(conn_a.resp_body)

      # The event is logged after the priming marker, with no stream alive.
      #
      :ok = Sessions.notify_all(server, notification)
      Utils.sync_server(server, session_id)

      conn_b = open_and_close_sse(server, session_id, priming_id)

      # The marker is never sent again: only the real event is replayed.
      #
      assert [replayed_id] = extract_message_event_ids(conn_b.resp_body)
      refute replayed_id == priming_id

      assert {:ok, events} = SessionProbe.events_after(server, session_id, "")
      assert Enum.any?(events, fn {id, data} -> id == replayed_id and data != "" end)
    end

    test "a connect with a replay has no priming event and the event is logged once" do
      server = inst(Servers.Default)
      session_id = Utils.create_session(server, initialized: true)

      notification = %{"jsonrpc" => "2.0", "method" => "notifications/tools/list_changed"}

      conn_a = open_and_close_sse(server, session_id, nil)
      priming_id_a = extract_priming_id(conn_a.resp_body)

      # The event is logged while no stream is alive.
      #
      :ok = Sessions.notify_all(server, notification)
      Utils.sync_server(server, session_id)

      conn_b = open_and_close_sse(server, session_id, priming_id_a)

      # The replayed event carries its own id, so this stream has no
      # priming event: the id of the client is its position.
      #
      assert [replayed_id] = extract_message_event_ids(conn_b.resp_body)
      refute conn_b.resp_body =~ "data: \n\n"

      assert {:ok, events} = SessionProbe.events_after(server, session_id, "")
      assert Enum.count(events, fn {id, _} -> id == replayed_id end) == 1
    end

    @tag task_opts: %{sse_retry_ms: 250}
    test "uses sse_retry_ms for the retry hints of the stream" do
      conn =
        open_and_close_sse(
          inst(Servers.Default),
          Utils.create_session(inst(Servers.Default), initialized: true),
          nil
        )

      # The retry hint of the start and the one of the termination both
      # carry the configured value.
      #
      assert Regex.match?(
               ~r|\Aretry: 250\n\nid: g\.[A-Za-z0-9]+:0\ndata: \n\nretry: 250\n\n\z|,
               conn.resp_body
             )
    end

    @tag task_opts: %{sse_heartbeat_ms: 20}
    test "sends heartbeat comments while the stream is idle" do
      server = inst(Servers.Default)
      session_id = Utils.create_session(server, initialized: true)
      parent = self()

      requester =
        spawn(fn ->
          conn =
            conn(:get, "/")
            |> put_req_header("accept", "text/event-stream")
            |> put_session_header(session_id)
            |> call_router()

          send(parent, {:sse_conn, conn})
        end)

      # Ensure the requester has registered its stream before idling.
      #
      wait_for_stream(server, session_id, requester)

      # No traffic at all: only the heartbeat keeps the stream busy. The
      # wait is 50 times the interval and the test needs 2 heartbeats, so
      # a loaded machine does not make the count fall short.
      #
      Process.sleep(1_000)

      Utils.terminate_stream(server, session_id, requester)

      assert_receive {:sse_conn, conn}, 5_000

      heartbeat_count =
        conn.resp_body
        |> :binary.matches(": heartbeat")
        |> length()

      assert heartbeat_count >= 2

      # The termination retry chunk still closes the stream.
      #
      assert conn.resp_body =~ "retry: 1000"
    end

    @tag task_opts: %{sse_heartbeat_ms: :infinity}
    test "does not send heartbeats when sse_heartbeat_ms is :infinity" do
      server = inst(Servers.Default)
      session_id = Utils.create_session(server, initialized: true)
      parent = self()

      requester =
        spawn(fn ->
          conn =
            conn(:get, "/")
            |> put_req_header("accept", "text/event-stream")
            |> put_session_header(session_id)
            |> call_router()

          send(parent, {:sse_conn, conn})
        end)

      # Ensure the requester has registered its stream before idling.
      #
      wait_for_stream(server, session_id, requester)

      # The wait is part of the check: within the span of many heartbeat
      # intervals, no heartbeat is written when the interval is :infinity.
      #
      Process.sleep(300)

      Utils.terminate_stream(server, session_id, requester)

      assert_receive {:sse_conn, conn}, 5_000
      refute conn.resp_body =~ ": heartbeat"
    end

    # An open server has no principal: an expiry message that nobody armed
    # (a stray message) must be ignored, never answered with a crash.
    #
    test "a stray expiry message does not crash a stream of an open server" do
      server = inst(Servers.Default)
      session_id = Utils.create_session(server, initialized: true)
      parent = self()

      requester =
        spawn(fn ->
          conn =
            conn(:get, "/")
            |> put_req_header("accept", "text/event-stream")
            |> put_session_header(session_id)
            |> call_router()

          send(parent, {:sse_conn, conn})
        end)

      wait_for_stream(server, session_id, requester)

      # The stray message must not end the stream: the DOWN of the
      # requester does not arrive.
      #
      requester_ref = Process.monitor(requester)
      send(requester, {:principal_expired, make_ref()})
      refute_receive {:DOWN, ^requester_ref, :process, ^requester, _}, 200

      assert requester in Utils.stream_pids(server, session_id)

      Utils.terminate_stream(server, session_id, requester)

      assert_receive {:sse_conn, conn}, 5_000
      assert conn.status == 200
    end

    test "replays missed notifications on reconnect with their original ids" do
      server = inst(Servers.Default)
      session_id = Utils.create_session(server, initialized: true)
      parent = self()

      notification = %{"jsonrpc" => "2.0", "method" => "notifications/tools/list_changed"}

      # Stream A receives the first notification live.
      #
      stream_a =
        spawn(fn ->
          conn =
            conn(:get, "/")
            |> put_req_header("accept", "text/event-stream")
            |> put_session_header(session_id)
            |> call_router()

          send(parent, {:sse_conn_a, conn})
        end)

      wait_for_stream(server, session_id, stream_a)

      :ok = Sessions.notify_all(server, notification)
      Utils.sync_server(server, session_id)

      Utils.terminate_stream(server, session_id, stream_a)
      assert_receive {:sse_conn_a, conn_a}, 5_000
      wait_for_stream_gone(server, session_id, stream_a)

      assert [event_id] = extract_event_ids(conn_a.resp_body)

      # The second notification is logged while no stream is alive.
      #
      :ok = Sessions.notify_all(server, notification)
      Utils.sync_server(server, session_id)

      # Stream B reconnects with the id of the first event: it recovers the
      # missed notification (with its original id) before any live event.
      #
      stream_b =
        spawn(fn ->
          conn =
            conn(:get, "/")
            |> put_req_header("accept", "text/event-stream")
            |> put_req_header("last-event-id", event_id)
            |> put_session_header(session_id)
            |> call_router()

          send(parent, {:sse_conn_b, conn})
        end)

      wait_for_stream(server, session_id, stream_b)

      # A live notification flows after the replay.
      #
      :ok = Sessions.notify_all(server, notification)
      Utils.sync_server(server, session_id)

      Utils.terminate_stream(server, session_id, stream_b)

      assert_receive {:sse_conn_b, conn_b}, 5_000

      assert String.starts_with?(conn_b.resp_body, "retry: 1000\n\n")
      assert conn_b.resp_body =~ "notifications/tools/list_changed"

      # The first event's id is not replayed; missed + live are there.
      #
      ids = extract_event_ids(conn_b.resp_body)
      assert length(ids) == 2
      refute event_id in ids
      assert length(Enum.uniq(ids)) == 2
    end

    test "takes the events that waited for a last-event-id that cannot be parsed" do
      server = inst(Servers.Default)
      session_id = Utils.create_session(server, initialized: true)
      parent = self()

      notification = %{"jsonrpc" => "2.0", "method" => "notifications/tools/list_changed"}

      # Two notifications logged while no stream is alive.
      #
      :ok = Sessions.notify_all(server, notification)
      :ok = Sessions.notify_all(server, notification)
      Utils.sync_server(server, session_id)

      requester =
        spawn(fn ->
          conn =
            conn(:get, "/")
            |> put_req_header("accept", "text/event-stream")
            |> put_req_header("last-event-id", "no-such-event-id0")
            |> put_session_header(session_id)
            |> call_router()

          send(parent, {:sse_conn, conn})
        end)

      wait_for_stream(server, session_id, requester)

      # A live event after the start still flows.
      #
      :ok = Sessions.notify_all(server, notification)
      Utils.sync_server(server, session_id)

      Utils.terminate_stream(server, session_id, requester)

      assert_receive {:sse_conn, conn}, 5_000

      # The id has no readable stream and number (the form of an older
      # version), so the session cannot resume from it: the stream starts
      # with the events that waited, then the live one follows.
      #
      assert length(extract_event_ids(conn.resp_body)) == 3
    end

    test "the log of the session is readable in one call for a resume" do
      server = inst(Servers.Default)
      session_id = Utils.create_session(server, initialized: true)

      notification = %{"jsonrpc" => "2.0", "method" => "notifications/tools/list_changed"}

      :ok = Sessions.notify_all(server, notification)
      :ok = Sessions.notify_all(server, notification)
      Utils.sync_server(server, session_id)

      assert {:ok, events} = SessionProbe.events_after(server, session_id, "")
      assert {:ok, ^events} = SessionProbe.events_after(server, session_id, "")
    end

    test "a resume never replays the events of another stream kind" do
      server = inst(Servers.Default)
      session_id = Utils.create_session(server, initialized: true)
      parent = self()

      notification = %{"jsonrpc" => "2.0", "method" => "notifications/tools/list_changed"}
      ping = ~s({"jsonrpc":"2.0","id":7,"method":"ping"})

      # An event of one GET stream, then an event of a POST stream, then an
      # event of another GET stream.
      #
      encoded = :json.encode(notification) |> IO.iodata_to_binary()

      :ok = SessionProbe.log_event(server, session_id, "g.getone0000001:1", encoded)
      :ok = SessionProbe.log_event(server, session_id, "poststrm000001:1", ping)
      :ok = SessionProbe.log_event(server, session_id, "g.gettwo0000001:1", encoded)
      Utils.sync_server(server, session_id)

      # The id of a GET stream that the session never had (only its events
      # were logged by hand): the stream starts fresh and it replays
      # nothing of the other streams.
      #
      stream_a =
        spawn(fn ->
          conn =
            conn(:get, "/")
            |> put_req_header("accept", "text/event-stream")
            |> put_req_header("last-event-id", "g.getone0000001:0")
            |> put_session_header(session_id)
            |> call_router()

          send(parent, {:sse_conn_a, conn})
        end)

      wait_for_stream(server, session_id, stream_a)
      Utils.terminate_stream(server, session_id, stream_a)
      assert_receive {:sse_conn_a, conn_a}, 5_000

      assert extract_message_event_ids(conn_a.resp_body) == []
      assert conn_a.resp_body =~ ~r/id: g\.[A-Za-z0-9]+:0/

      # The POST stream resumed from its priming id: the GET events are not
      # replayed on it. No owner process is live for the stream, so the
      # resume ends after the replay, with no retry field.
      #
      spawn(fn ->
        conn =
          conn(:get, "/")
          |> put_req_header("accept", "text/event-stream")
          |> put_req_header("last-event-id", "poststrm000001:0")
          |> put_session_header(session_id)
          |> call_router()

        send(parent, {:sse_conn_b, conn})
      end)

      assert_receive {:sse_conn_b, conn_b}, 5_000

      assert extract_message_event_ids(conn_b.resp_body) == ["poststrm000001:1"]
      refute conn_b.resp_body =~ ~r/retry: \d+\n\n\z/
    end

    test "a resume of a POST stream that the session never had gets 204" do
      server = inst(Servers.Default)
      session_id = Utils.create_session(server, initialized: true)
      parent = self()

      spawn(fn ->
        conn =
          conn(:get, "/")
          |> put_req_header("accept", "text/event-stream")
          |> put_req_header("last-event-id", "forged-stream:3")
          |> put_session_header(session_id)
          |> call_router()

        send(parent, {:sse_conn, conn})
      end)

      assert_receive {:sse_conn, conn}, 5_000

      assert conn.status == 204
      assert conn.resp_body == ""
    end

    @tag task_opts: %{sse_resume_window_ms: 0}
    test "a resume after sse_resume_window_ms gets 204" do
      server = inst(Servers.Default)
      session_id = Utils.create_session(server, initialized: true)
      parent = self()

      :ok = Utils.open_request(server, session_id, 1, self(), {"st", :sse})
      :ok = Sessions.emit(server, session_id, {:request, 1}, "{}")

      assert {:sse, "st:2"} =
               Utils.close_request(server, session_id, 1, "st", {:response, "{}", false})

      # The window is over: the ring of the ended stream is dropped.
      #
      assert Utils.eventually(fn ->
               Utils.events_after(server, session_id, "st", nil) == :gap
             end)

      spawn(fn ->
        conn =
          conn(:get, "/")
          |> put_req_header("accept", "text/event-stream")
          |> put_req_header("last-event-id", "st:0")
          |> put_session_header(session_id)
          |> call_router()

        send(parent, {:sse_conn, conn})
      end)

      assert_receive {:sse_conn, conn}, 5_000

      assert conn.status == 204
      assert conn.resp_body == ""
    end

    test "the session stays: a POST after a 204 resume still works" do
      server = inst(Servers.Default)
      session_id = Utils.create_session(server, initialized: true)
      parent = self()

      spawn(fn ->
        conn =
          conn(:get, "/")
          |> put_req_header("accept", "text/event-stream")
          |> put_req_header("last-event-id", "forged-stream:3")
          |> put_session_header(session_id)
          |> call_router()

        send(parent, {:sse_conn, conn})
      end)

      assert_receive {:sse_conn, conn}, 5_000
      assert conn.status == 204

      conn =
        post_json_rpc(1, "ping")
        |> put_session_header(session_id)
        |> call_router()

      assert conn.status == 200
    end

    test "a notification with no GET stream open reaches the first GET that opens" do
      server = inst(Servers.Default)
      session_id = Utils.create_session(server, initialized: true)
      parent = self()

      notification = %{"jsonrpc" => "2.0", "method" => "notifications/tools/list_changed"}

      # No GET stream is open: the session keeps the notification for the
      # first GET that opens and the GET gets it as its replay.
      #
      :ok = Sessions.notify_all(server, notification)
      Utils.sync_server(server, session_id)

      requester =
        spawn(fn ->
          conn =
            conn(:get, "/")
            |> put_req_header("accept", "text/event-stream")
            |> put_session_header(session_id)
            |> call_router()

          send(parent, {:sse_conn, conn})
        end)

      wait_for_stream(server, session_id, requester)

      Utils.terminate_stream(server, session_id, requester)

      assert_receive {:sse_conn, conn}, 5_000
      assert [_waiting] = extract_event_ids(conn.resp_body)
    end

    test "returns 404 for a terminated session even with a last-event-id" do
      server = inst(Servers.Default)
      session_id = Utils.create_session(server, initialized: true)
      :ok = Sessions.terminate(server, session_id)

      conn =
        conn(:get, "/")
        |> put_req_header("accept", "text/event-stream")
        |> put_req_header("last-event-id", "evt-1")
        |> put_session_header(session_id)
        |> call_router()

      assert conn.status == 404
      assert decode_resp(conn) == json_rpc_error(-32001, "invalid session")
    end

    # Resumability interaction pins.
    #

    test "replay goes to the reconnecting stream only and live delivery stays single-delivery" do
      server = inst(Servers.Default)
      session_id = Utils.create_session(server, initialized: true)
      parent = self()

      notification = %{"jsonrpc" => "2.0", "method" => "notifications/list_changed"}

      # Stream A opens (no header) and receives one live event, then ends.
      #
      stream_a =
        spawn(fn ->
          conn =
            conn(:get, "/")
            |> put_req_header("accept", "text/event-stream")
            |> put_session_header(session_id)
            |> call_router()

          send(parent, {:sse_conn_a, conn})
        end)

      wait_for_stream(server, session_id, stream_a)

      :ok = Sessions.notify_all(server, notification)
      Utils.sync_server(server, session_id)

      Utils.terminate_stream(server, session_id, stream_a)
      assert_receive {:sse_conn_a, conn_a}, 5_000
      wait_for_stream_gone(server, session_id, stream_a)

      assert [event_id] = extract_event_ids(conn_a.resp_body)

      # The next event is logged while no stream is alive: it goes in the
      # ring of the stream that just ended.
      #
      :ok = Sessions.notify_all(server, notification)
      Utils.sync_server(server, session_id)

      assert {:ok, [{^event_id, _}, {missed_id, _encoded}]} =
               SessionProbe.events_after(server, session_id, "")

      # Stream B reconnects with the id of the first event: it gets the
      # missed event only and it keeps the id of the stream.
      #
      stream_b =
        spawn(fn ->
          conn =
            conn(:get, "/")
            |> put_req_header("accept", "text/event-stream")
            |> put_req_header("last-event-id", event_id)
            |> put_session_header(session_id)
            |> call_router()

          send(parent, {:sse_conn_b, conn})
        end)

      wait_for_stream(server, session_id, stream_b)

      # The next live event goes to exactly one stream (the single-delivery
      # policy, unperturbed by the replay).
      #
      :ok = Sessions.notify_all(server, notification)
      Utils.sync_server(server, session_id)

      Utils.terminate_stream(server, session_id, stream_b)

      assert_receive {:sse_conn_b, conn_b}, 5_000

      # B: the missed event replayed with the id it was logged with,
      # followed by the live one. The two ids continue the counter of the
      # stream that A opened.
      #
      assert [^missed_id, live_id] = extract_event_ids(conn_b.resp_body)
      assert [a_stream, "1"] = String.split(event_id, ":")
      assert [missed_stream, "2"] = String.split(missed_id, ":")
      assert [live_stream, "3"] = String.split(live_id, ":")
      assert a_stream == missed_stream and missed_stream == live_stream

      # A: only its own live event — the replayed and live events did not
      # go to it.
      #
      assert extract_event_ids(conn_a.resp_body) == [event_id]
    end

    @tag task_opts: %{sse_event_log_size: 3}
    test "a resume with the id of an event that the cap removed replays what stays and warns" do
      server = inst(Servers.Default)
      session_id = Utils.create_session(server, initialized: true)

      notification = %{"jsonrpc" => "2.0", "method" => "notifications/tools/list_changed"}

      conn1 = open_and_close_sse(server, session_id, nil)
      _priming_id = extract_priming_id(conn1.resp_body)

      # Five events are logged while no stream is alive: the cap of the
      # ring of the stream keeps the newest three.
      #
      logged_ids =
        Enum.map(1..5, fn _ ->
          :ok = Sessions.notify_all(server, notification)
          Utils.sync_server(server, session_id)

          assert {:ok, events} = SessionProbe.events_after(server, session_id, "")
          {event_id, _encoded} = List.last(events)
          event_id
        end)

      assert {:ok, retained} = SessionProbe.events_after(server, session_id, "")
      assert length(retained) == 3

      # Reconnect with the id of the first (pruned) event: the events it
      # missed are gone, the ones that stay are replayed.
      #
      [first_id | _] = logged_ids

      {conn, log} =
        ExUnit.CaptureLog.with_log(fn ->
          open_and_close_sse(server, session_id, first_id)
        end)

      retained_ids = Enum.map(retained, fn {id, _} -> id end)
      assert extract_message_event_ids(conn.resp_body) == retained_ids
      assert log =~ "the event log caps removed"

      # The events replay on the stream that the id named, not on a new one.
      #
      [first_stream, _n] = String.split(first_id, ":")

      for id <- retained_ids do
        assert [stream, _n] = String.split(id, ":")
        assert stream == first_stream
      end
    end

    test "unregisters the stream when the connection closes" do
      server = inst(Servers.Default)
      session_id = Utils.create_session(server, initialized: true)
      parent = self()

      requester =
        spawn(fn ->
          conn =
            conn(:get, "/")
            |> put_req_header("accept", "text/event-stream")
            |> put_session_header(session_id)
            |> call_router()

          send(parent, {:sse_conn, conn})
        end)

      # Ensure the requester has registered its stream before closing.
      #
      wait_for_stream(server, session_id, requester)

      Utils.terminate_stream(server, session_id, requester)
      assert_receive {:sse_conn, conn}, 5_000
      assert conn.status == 200

      # Unregistration happens before the requester reports back, but poll
      # anyway to avoid a flaky assertion.
      #
      wait_for_stream_gone(server, session_id, requester)

      # The stream is gone, so notifications are no longer delivered to it.
      #
      notification = %{"jsonrpc" => "2.0", "method" => "notifications/tools/list_changed"}
      :ok = Sessions.notify_all(server, notification)
      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 100
    end

    @tag :capture_log
    test "the cleanup of a stream survives a session that stops during the close" do
      server = inst(Servers.Default)
      session_id = Utils.create_session(server, initialized: true)
      parent = self()

      requester =
        spawn(fn ->
          conn =
            conn(:get, "/")
            |> put_req_header("accept", "text/event-stream")
            |> put_session_header(session_id)
            #
            # The two chunks of the start of the stream go out, then the
            # connection is closed: the next write fails.
            #
            |> Support.Helpers.AdapterClosed.wrap(2)
            |> call_router(server)

          send(parent, {:sse_conn, conn})
        end)

      wait_for_stream(server, session_id, requester)
      requester_ref = Process.monitor(requester)
      {:ok, session_pid} = OzMcp.Instance.whereis(server, {:session, session_id})
      [%{id: stream_id}] = Utils.session_streams(server, session_id)

      # The session is stopped until the cleanup call of the stream waits in
      # its mailbox: the call is in flight when the session stops. The exit
      # of the call must not stop the stream process, which still owes the
      # host server the end of the response.
      #
      :ok = :sys.suspend(session_pid)

      # The cleanup call comes from a write that fails: an event on the
      # closed connection fails and the stream calls the session while it
      # is stopped.
      #
      send(requester, {:oz_mcp_stream, stream_id, {:event, "x", "{}"}})

      wait_until(fn ->
        messages = Process.info(session_pid, :messages) |> elem(1) || []

        Enum.any?(messages, fn
          {:"$gen_call", _from, {:close_stream, ^requester}} -> true
          _other -> false
        end)
      end)

      Process.exit(session_pid, :kill)

      assert_receive {:sse_conn, conn}, 5_000
      assert conn.status == 200

      assert_receive {:DOWN, ^requester_ref, :process, ^requester, :normal}, 5_000
    end

    # The end of a session: every open stream monitors its session. The
    # stream closes with a retry hint and the client connects again with
    # its Last-Event-ID.
    #

    @tag :capture_log
    test "a GET stream closes with a retry hint when its session stops" do
      server = inst(Servers.Default)
      session_id = Utils.create_session(server, initialized: true)
      parent = self()

      requester =
        spawn(fn ->
          conn =
            conn(:get, "/")
            |> put_req_header("accept", "text/event-stream")
            |> put_session_header(session_id)
            |> call_router(server)

          {:messages, left} = Process.info(self(), :messages)
          send(parent, {:sse_conn, conn, left})
        end)

      wait_for_stream(server, session_id, requester)

      {:ok, session_pid} = OzMcp.Instance.whereis(server, {:session, session_id})
      Process.exit(session_pid, :kill)

      assert_receive {:sse_conn, sse, left}, 5_000
      assert sse.status == 200
      assert String.ends_with?(sse.resp_body, "retry: 1000\n\n")

      # No message of the stream stays in the process: Bandit can run the
      # next request of the connection in it.
      #
      refute Enum.any?(left, &match?({:DOWN, _, _, _, _}, &1))

      # The session is gone: a new GET with the same id gets 404.
      #
      conn =
        conn(:get, "/")
        |> put_req_header("accept", "text/event-stream")
        |> put_session_header(session_id)
        |> call_router(server)

      assert conn.status == 404
    end

    @tag :capture_log
    test "a resumer of a POST stream closes with a retry hint when its session stops" do
      server = inst(Servers.Outbound)
      session_id = Utils.create_session(server, initialized: true)
      parent = self()

      # A POST stream that waits for the answer of the client: the ping of
      # the callback is logged under the id of its own stream.
      #
      start_call(server, session_id, 5)
      _id = wait_for_pending(server, session_id)
      assert {ping_id, _} = wait_for_post_event(server, session_id)
      assert [stream_id, _seq] = String.split(ping_id, ":")

      # A GET resumes the stream and waits for the events.
      #
      spawn(fn ->
        conn =
          conn(:get, "/")
          |> put_req_header("accept", "text/event-stream")
          |> put_req_header("last-event-id", "#{stream_id}:0")
          |> put_session_header(session_id)
          |> call_router(server)

        {:messages, left} = Process.info(self(), :messages)
        send(parent, {:resumed, conn, left})
      end)

      wait_for_resumer(server, session_id, stream_id)

      {:ok, session_pid} = OzMcp.Instance.whereis(server, {:session, session_id})
      Process.exit(session_pid, :kill)

      assert_receive {:resumed, resume_conn, left}, 5_000
      assert resume_conn.status == 200
      assert String.ends_with?(resume_conn.resp_body, "retry: 1000\n\n")
      refute Enum.any?(left, &match?({:DOWN, _, _, _, _}, &1))

      # The session is lost: the wait of the owner of the POST stream ends
      # like at the end of a session.
      #
      wait_until(fn ->
        case SessionProbe.pending_outbound_ids(server, session_id) do
          [] -> true
          {:error, _gone} -> true
          _other -> false
        end
      end)

      # The POST request ends too. Wait for it: its callback may be stopped
      # with :shutdown and the request logs that, so the log must come
      # before the test ends (the capture_log of the tag only covers the test).
      #
      assert_receive {:call_conn, 5, _conn}, 5_000
    end

    # A close for any other reason removes the monitor of the Server with
    # its message: none of them may stay in the process of the connection.
    #

    @tag :capture_log
    test "a GET stream that closes for another reason leaves no monitor message behind" do
      server = inst(Servers.Default)
      session_id = Utils.create_session(server, initialized: true)
      parent = self()

      requester =
        spawn(fn ->
          conn =
            conn(:get, "/")
            |> put_req_header("accept", "text/event-stream")
            |> put_session_header(session_id)
            |> call_router(server)

          {:messages, left} = Process.info(self(), :messages)
          send(parent, {:sse_conn, conn, left})
        end)

      wait_for_stream(server, session_id, requester)
      Utils.terminate_stream(server, session_id, requester)

      assert_receive {:sse_conn, conn, left}, 5_000
      assert conn.status == 200
      refute Enum.any?(left, &match?({:DOWN, _, _, _, _}, &1))
    end

    # Polling mode: with sse_max_stream_ms the stream closes itself after
    # that time with a retry event and the client connects again. The
    # session stays and the events of the gap wait in the log.
    #

    @tag task_opts: %{sse_max_stream_ms: 100, sse_retry_ms: 250}
    test "the stream ends itself after sse_max_stream_ms with a retry event" do
      server = inst(Servers.Default)
      session_id = Utils.create_session(server, initialized: true)
      parent = self()

      spawn(fn ->
        conn =
          conn(:get, "/")
          |> put_req_header("accept", "text/event-stream")
          |> put_session_header(session_id)
          |> call_router()

        send(parent, {:sse_conn, conn})
      end)

      # The stream ends by itself: no :terminate message is sent. The test
      # does not wait for the stream to be registered, because it may
      # close before the test looks.
      #
      assert_receive {:sse_conn, conn}, 5_000

      # The start of the stream (retry, priming event) and the retry event
      # of the close.
      #
      assert Regex.match?(
               ~r|\Aretry: 250\n\nid: g\.[A-Za-z0-9]+:0\ndata: \n\nretry: 250\n\n\z|,
               conn.resp_body
             )
    end

    @tag task_opts: %{sse_max_stream_ms: 100, sse_retry_ms: 250}
    test "the stream is unregistered after the poll close and the session stays" do
      server = inst(Servers.Default)
      session_id = Utils.create_session(server, initialized: true)
      parent = self()

      requester =
        spawn(fn ->
          conn =
            conn(:get, "/")
            |> put_req_header("accept", "text/event-stream")
            |> put_session_header(session_id)
            |> call_router()

          send(parent, {:sse_conn, conn})
        end)

      assert_receive {:sse_conn, _conn}, 5_000

      wait_for_stream_gone(server, session_id, requester)
      assert {:ok, _} = Sessions.state(server, session_id)
    end

    @tag task_opts: %{sse_max_stream_ms: 100, sse_retry_ms: 250}
    test "an event logged during the gap replays once on a resume from the priming id" do
      server = inst(Servers.Default)
      session_id = Utils.create_session(server, initialized: true)
      parent = self()

      notification = %{"jsonrpc" => "2.0", "method" => "notifications/tools/list_changed"}

      spawn(fn ->
        conn =
          conn(:get, "/")
          |> put_req_header("accept", "text/event-stream")
          |> put_session_header(session_id)
          |> call_router()

        send(parent, {:sse_conn, conn})
      end)

      assert_receive {:sse_conn, conn_a}, 5_000
      priming_id = extract_priming_id(conn_a.resp_body)

      # The event is logged during the gap, with no stream alive.
      #
      :ok = Sessions.notify_all(server, notification)
      Utils.sync_server(server, session_id)

      conn_b = open_polling_sse(session_id, priming_id)

      # The event is replayed exactly once, with its original id.
      #
      assert [replayed_id] = extract_message_event_ids(conn_b.resp_body)
      refute replayed_id == priming_id

      assert {:ok, events} = SessionProbe.events_after(server, session_id, "")
      assert Enum.count(events, fn {id, _} -> id == replayed_id end) == 1
    end

    test "a resume from the id of the last event that the stream sent also works" do
      server = inst(Servers.Default)
      session_id = Utils.create_session(server, initialized: true)

      notification = %{"jsonrpc" => "2.0", "method" => "notifications/tools/list_changed"}

      parent = self()

      requester =
        spawn(fn ->
          conn =
            conn(:get, "/")
            |> put_req_header("accept", "text/event-stream")
            |> put_session_header(session_id)
            |> call_router()

          send(parent, {:sse_conn, conn})
        end)

      # The event flows live on the stream. The test ends the stream after
      # it (no poll timer: the stream stays open until then).
      #
      wait_for_stream(server, session_id, requester)

      :ok = Sessions.notify_all(server, notification)
      Utils.sync_server(server, session_id)

      Utils.terminate_stream(server, session_id, requester)
      assert_receive {:sse_conn, conn_a}, 5_000
      assert [event_id] = extract_event_ids(conn_a.resp_body)

      # A second event is logged during the gap.
      #
      :ok = Sessions.notify_all(server, notification)
      Utils.sync_server(server, session_id)

      conn_b = open_and_close_sse(server, session_id, event_id)

      # Only the event of the gap is replayed, never the one already seen.
      #
      assert [new_id] = extract_event_ids(conn_b.resp_body)
      refute new_id == event_id
    end

    test "the stream stays open when sse_max_stream_ms is nil" do
      server = inst(Servers.Default)
      session_id = Utils.create_session(server, initialized: true)
      parent = self()

      requester =
        spawn(fn ->
          conn =
            conn(:get, "/")
            |> put_req_header("accept", "text/event-stream")
            |> put_session_header(session_id)
            |> call_router()

          send(parent, {:sse_conn, conn})
        end)

      wait_for_stream(server, session_id, requester)

      # No poll timer runs: the DOWN of the requester does not arrive
      # well past the span of the poll time.
      #
      requester_ref = Process.monitor(requester)
      refute_receive {:DOWN, ^requester_ref, :process, ^requester, _}, 300

      Utils.terminate_stream(server, session_id, requester)

      assert_receive {:sse_conn, conn}, 5_000
      assert conn.resp_body =~ "retry: 1000"
    end

    # The poll time is long enough for the test to end the stream before it
    # on a loaded machine.
    #
    @tag task_opts: %{sse_max_stream_ms: 1_000, sse_retry_ms: 250}
    test "a termination before the poll time cancels the poll timer" do
      server = inst(Servers.Default)
      session_id = Utils.create_session(server, initialized: true)
      parent = self()

      requester =
        spawn(fn ->
          conn =
            conn(:get, "/")
            |> put_req_header("accept", "text/event-stream")
            |> put_session_header(session_id)
            |> call_router()

          send(parent, {:sse_conn, conn})

          receive do
            :report -> send(parent, {:messages, Process.info(self(), :messages)})
          end
        end)

      wait_for_stream(server, session_id, requester)
      requester_ref = Process.monitor(requester)

      Utils.terminate_stream(server, session_id, requester)

      assert_receive {:sse_conn, _conn}, 5_000

      # Past the poll time: a timer that was not cancelled would have fired
      # by now and left its message in the mailbox of the requester. The
      # wait is the check that the requester stays alive all that time.
      #
      refute_receive {:DOWN, ^requester_ref, :process, ^requester, _}, 1_200

      send(requester, :report)
      assert_receive {:messages, {:messages, messages}}, 5_000

      refute Enum.any?(messages, &match?({:sse_poll_close, _}, &1))
    end

    @tag task_opts: %{sse_max_stream_ms: 100, session_timeout_ms: 2_000}
    test "the poll close touches the session: a polling client keeps its session" do
      server = inst(Servers.Default)
      session_id = Utils.create_session(server, initialized: true)

      # Each GET stream closes itself after 100 ms. A client that polls for
      # longer than the session timeout keeps the session: the idle timer
      # starts again at each close. Each wait is the check that the DOWN
      # of the session did not arrive before the poll.
      #
      {:ok, view} = Sessions.lookup(server, session_id)
      session_ref = Process.monitor(view.pid)

      for _poll <- 1..12 do
        refute_receive {:DOWN, ^session_ref, :process, _, _}, 100

        conn =
          conn(:get, "/")
          |> put_req_header("accept", "text/event-stream")
          |> put_session_header(session_id)
          |> call_router()

        assert conn.status == 200
      end

      assert {:ok, _view} = Sessions.lookup(server, session_id)
    end

    @tag task_opts: %{sse_max_stream_ms: 100, sse_retry_ms: 250}
    test "a polling client loses no event across its connects" do
      server = inst(Servers.Default)
      session_id = Utils.create_session(server, initialized: true)
      parent = self()

      notification = %{"jsonrpc" => "2.0", "method" => "notifications/tools/list_changed"}

      open_stream = fn last_event_id, tag ->
        spawn(fn ->
          base = conn(:get, "/") |> put_req_header("accept", "text/event-stream")

          conn =
            if last_event_id do
              put_req_header(base, "last-event-id", last_event_id)
            else
              base
            end
            |> put_session_header(session_id)
            |> call_router()

          send(parent, {tag, conn})
        end)
      end

      # First connect: the stream closes itself after sse_max_stream_ms.
      #
      open_stream.(nil, :conn1)
      assert_receive {:conn1, conn1}, 5_000
      priming1 = extract_priming_id(conn1.resp_body)

      # One event is logged during the first gap.
      #
      :ok = Sessions.notify_all(server, notification)
      Utils.sync_server(server, session_id)

      # Second connect: the event of the gap is replayed.
      #
      open_stream.(priming1, :conn2)
      assert_receive {:conn2, conn2}, 5_000
      assert [replayed_id] = extract_message_event_ids(conn2.resp_body)

      # The replayed event is the position of the client: no priming event.
      #
      refute conn2.resp_body =~ "data: \n\n"

      # Third connect: nothing to replay.
      #
      open_stream.(replayed_id, :conn3)
      assert_receive {:conn3, conn3}, 5_000
      assert extract_message_event_ids(conn3.resp_body) == []

      # The event is logged once, on the ring of the stream that the
      # client resumed.
      #
      assert {:ok, events} = SessionProbe.events_after(server, session_id, "")
      assert Enum.count(events, fn {id, _} -> id == replayed_id end) == 1
    end

    test "a GET stream of the session does not receive the events of a resumed POST stream" do
      server = inst(Servers.Outbound)
      session_id = Utils.create_session(server, initialized: true)
      parent = self()

      # A GET stream of the session: open and waiting for the events.
      #
      stream =
        spawn(fn ->
          conn =
            conn(:get, "/")
            |> put_req_header("accept", "text/event-stream")
            |> put_session_header(session_id)
            |> call_router(server)

          send(parent, {:sse_conn, conn})
        end)

      wait_for_stream(server, session_id, stream)

      # A POST request that streams: the ping of the callback is logged
      # under the id of its own stream.
      #
      start_call(server, session_id, 5)
      id = wait_for_pending(server, session_id)
      assert {ping_id, _} = wait_for_post_event(server, session_id)
      assert [stream_id, _seq] = String.split(ping_id, ":")
      response_id = "#{stream_id}:2"

      # A GET resumes the POST stream: the events of that stream go to the
      # resume only, never to the GET stream of the session.
      #
      spawn(fn ->
        conn =
          conn(:get, "/")
          |> put_req_header("accept", "text/event-stream")
          |> put_req_header("last-event-id", "#{stream_id}:0")
          |> put_session_header(session_id)
          |> call_router(server)

        send(parent, {:resumed, conn})
      end)

      wait_for_resumer(server, session_id, stream_id)

      # The client answers the request: the response goes to the resume.
      #
      assert post_response(server, session_id, %{"id" => id, "result" => %{}}).status == 202

      assert_receive {:resumed, resume_conn}, 5_000

      # The resume replays the ping of the stream (its start was before the
      # ping), then it receives the response live.
      #
      assert [ping_id, ^response_id] = extract_message_event_ids(resume_conn.resp_body)
      assert [^stream_id, "1"] = String.split(ping_id, ":")

      assert [%{"method" => "ping"}, %{"id" => 5, "result" => _}] =
               sse_messages(resume_conn.resp_body)

      # The GET stream got nothing of the POST stream: a terminate gives a
      # body with the retry hint and no message event of the stream.
      #
      Utils.terminate_stream(server, session_id, stream)
      assert_receive {:sse_conn, get_conn}, 5_000
      assert extract_message_event_ids(get_conn.resp_body) == []
    end

    test "a resume with an unknown POST id gets 204 with no body" do
      server = inst(Servers.Outbound)
      session_id = Utils.create_session(server, initialized: true)
      parent = self()

      spawn(fn ->
        conn =
          conn(:get, "/")
          |> put_req_header("accept", "text/event-stream")
          |> put_req_header("last-event-id", "nostream000001:4")
          |> put_session_header(session_id)
          |> call_router(server)

        send(parent, {:resumed, conn})
      end)

      assert_receive {:resumed, conn}, 5_000

      # There is nothing to resume: the stream is not active and its ring
      # is not in the log. `204` stops the reconnect loop of the client
      # and the session stays valid.
      #
      assert conn.status == 204
      assert conn.resp_body == ""
      assert get_resp_header(conn, "content-type") == []
    end
  end

  # MCP Tasks end-to-end. Router-level integration tests:
  # task creation through task-augmented tools/call, polling / result /
  # cancel / list, notifications and capability negotiation.
  #

  @task_server_module Servers.TasksTest

  @task_server Module.concat(@task_server_module, __MODULE__)
  describe "MCP Tasks - initialize capability" do
    @describetag :tasks

    # Scenario 1
    #
    test "initialize advertises the tasks capability as objects, not booleans or nulls" do
      conn = post_json_rpc(0, "initialize", @initialize_params) |> call_router(@task_server)

      assert conn.status == 200
      assert_cors_headers(conn)

      tasks = decode_resp(conn)["result"]["capabilities"]["tasks"]

      assert tasks == %{
               "list" => %{},
               "cancel" => %{},
               "requests" => %{"tools" => %{"call" => %{}}}
             }
    end
  end

  describe "MCP Tasks - task-augmented tools/call" do
    @describetag :tasks

    # Scenario 2
    #
    test "returns a CreateTaskResult with a working task and runs the tool" do
      session_id = Utils.create_session(@task_server, initialized: true)

      conn =
        post_json_rpc(1, "tools/call", %{"name" => "task_immediate", "task" => %{"ttl" => 5_000}})
        |> put_session_header(session_id)
        |> call_router(@task_server)

      assert conn.status == 200
      assert_cors_headers(conn)

      task = decode_resp(conn)["result"]["task"]
      assert is_binary(task["taskId"]) and byte_size(task["taskId"]) > 0
      assert task["status"] == "working"
      assert task["ttl"] == 5_000
      assert String.match?(task["createdAt"], ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/)
      assert String.match?(task["lastUpdatedAt"], ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/)

      # The tool still runs in the background
      #
      assert {:ok, {:ok, _}} =
               Tasks.await(@task_server, Utils.owner(session_id), task["taskId"], 5_000)
    end

    # Scenario 18
    #
    test "returns -32602 when task.ttl is invalid" do
      session_id = Utils.create_session(@task_server, initialized: true)

      for ttl <- [-1, 0, "x"] do
        conn =
          post_json_rpc(1, "tools/call", %{"name" => "task_immediate", "task" => %{"ttl" => ttl}})
          |> put_session_header(session_id)
          |> call_router(@task_server)

        assert decode_resp(conn) == json_rpc_error(1, -32602, "invalid task metadata")
      end

      # A refused ttl never creates a task record
      #
      assert {:ok, [], nil} = Tasks.list(@task_server, Utils.owner(session_id), nil, 10)
    end

    test "accepts a ttl of 1 and a missing ttl and creates the tasks" do
      session_id = Utils.create_session(@task_server, initialized: true)

      conn =
        post_json_rpc(1, "tools/call", %{"name" => "task_immediate", "task" => %{"ttl" => 1}})
        |> put_session_header(session_id)
        |> call_router(@task_server)

      ttl_task = decode_resp(conn)["result"]["task"]
      assert is_binary(ttl_task["taskId"]) and byte_size(ttl_task["taskId"]) > 0
      assert ttl_task["ttl"] == 1

      conn =
        post_json_rpc(2, "tools/call", %{"name" => "task_immediate", "task" => %{}})
        |> put_session_header(session_id)
        |> call_router(@task_server)

      task = decode_resp(conn)["result"]["task"]
      assert is_binary(task["taskId"]) and byte_size(task["taskId"]) > 0

      # The task without ttl stays in the list of the session. The ttl-1
      # task can already be gone: its ttl elapsed.
      #
      assert {:ok, tasks, nil} = Tasks.list(@task_server, Utils.owner(session_id), nil, 10)
      assert task["taskId"] in Enum.map(tasks, & &1.taskId)
    end

    test "a ttl above the ceiling of the runtime is lowered, not refused" do
      session_id = Utils.create_session(@task_server, initialized: true)

      conn =
        post_json_rpc(1, "tools/call", %{
          "name" => "task_immediate",
          "task" => %{"ttl" => 10 ** 21}
        })
        |> put_session_header(session_id)
        |> call_router(@task_server)

      task = decode_resp(conn)["result"]["task"]
      assert is_binary(task["taskId"]) and byte_size(task["taskId"]) > 0
      assert task["ttl"] == 86_400_000

      get = rpc_tasks_get(session_id, task["taskId"])
      assert get["result"]["taskId"] == task["taskId"]
    end

    test "the pollInterval of a task comes from the execution of the tool" do
      session_id = Utils.create_session(@task_server, initialized: true)
      Support.Entities.Tools.TaskSlowTest.reset()

      conn =
        post_json_rpc(1, "tools/call", %{"name" => "task_slow", "task" => %{}})
        |> put_session_header(session_id)
        |> call_router(@task_server)

      task = decode_resp(conn)["result"]["task"]
      assert task["pollInterval"] == 2_500

      get = rpc_tasks_get(session_id, task["taskId"])
      assert get["result"]["pollInterval"] == 2_500

      Support.Entities.Tools.TaskSlowTest.finish()
    end

    test "a tool without a poll interval shows no pollInterval key" do
      session_id = Utils.create_session(@task_server, initialized: true)

      conn =
        post_json_rpc(1, "tools/call", %{"name" => "task_immediate", "task" => %{}})
        |> put_session_header(session_id)
        |> call_router(@task_server)

      task = decode_resp(conn)["result"]["task"]
      assert is_binary(task["taskId"])
      refute Map.has_key?(task, "pollInterval")

      get = rpc_tasks_get(session_id, task["taskId"])
      assert is_binary(get["result"]["taskId"])
      refute Map.has_key?(get["result"], "pollInterval")
    end

    test "tools/list never shows the poll interval of a tool" do
      session_id = Utils.create_session(@task_server, initialized: true)

      conn =
        post_json_rpc(1, "tools/list")
        |> put_session_header(session_id)
        |> call_router(@task_server)

      tools = decode_resp(conn)["result"]["tools"]

      slow = Enum.find(tools, &(&1["name"] == "task_slow"))
      assert slow["execution"] == %{"taskSupport" => "optional"}

      immediate = Enum.find(tools, &(&1["name"] == "task_immediate"))
      assert immediate["execution"] == %{"taskSupport" => "optional"}
    end

    test "arguments violating the input schema create a failed task with the tool result stored" do
      session_id =
        Utils.create_session(inst(Servers.TasksRequiredTool), initialized: true)

      conn =
        post_json_rpc(1, "tools/call", %{
          "name" => "full",
          "arguments" => %{"name" => 123},
          "task" => %{}
        })
        |> put_session_header(session_id)
        |> call_router(inst(Servers.TasksRequiredTool))

      assert conn.status == 200

      # The client still receives a CreateTaskResult, already terminal
      #
      task = decode_resp(conn)["result"]["task"]
      assert is_binary(task["taskId"]) and byte_size(task["taskId"]) > 0
      assert task["status"] == "failed"
      assert task["statusMessage"] == "The tool execution reported an error."

      # tasks/get confirms the terminal state
      #
      get = rpc_tasks_get(session_id, task["taskId"], 2, inst(Servers.TasksRequiredTool))
      assert get["result"]["status"] == "failed"

      # tasks/result replays the tool execution error the model must read
      #
      result_conn =
        rpc_tasks_result(session_id, task["taskId"], 3, inst(Servers.TasksRequiredTool))

      assert result_conn.status == 200

      result = decode_resp(result_conn)["result"]
      assert result["isError"] == true

      assert result["content"] == [
               %{"type" => "text", "text" => "'name' value is not of type string"}
             ]

      assert result["_meta"]["io.modelcontextprotocol/related-task"]["taskId"] == task["taskId"]
    end
  end

  describe "MCP Tasks - tasks/get and tasks/result" do
    @describetag :tasks

    # Scenario 3
    #
    test "polling tasks/get to completed then tasks/result returns the tool result with related-task _meta" do
      session_id = Utils.create_session(@task_server, initialized: true)
      task_id = create_task_via_router(session_id, "task_immediate")

      :ok = poll_until_status(session_id, task_id, "completed")

      conn = rpc_tasks_result(session_id, task_id)
      assert conn.status == 200

      result = decode_resp(conn)["result"]

      assert result["_meta"] == %{
               "io.modelcontextprotocol/related-task" => %{"taskId" => task_id}
             }

      assert result["content"] == [%{"type" => "text", "text" => "done"}]
    end

    # Scenario 6
    #
    test "isError tool: task fails, tasks/get carries statusMessage, tasks/result returns the tool result" do
      session_id = Utils.create_session(@task_server, initialized: true)
      task_id = create_task_via_router(session_id, "task_is_error")

      :ok = poll_until_status(session_id, task_id, "failed")

      get = rpc_tasks_get(session_id, task_id)
      assert get["result"]["status"] == "failed"
      assert get["result"]["statusMessage"] == "The tool execution reported an error."

      conn = rpc_tasks_result(session_id, task_id)
      assert conn.status == 200

      result = decode_resp(conn)["result"]
      assert result["isError"] == true
      assert result["content"] == [%{"type" => "text", "text" => "tool failure"}]
      assert result["_meta"]["io.modelcontextprotocol/related-task"]["taskId"] == task_id
    end

    # Scenario 7
    #
    @tag :capture_log
    test "crashing tool: task fails and tasks/result replays -32603" do
      session_id = Utils.create_session(@task_server, initialized: true)
      task_id = create_task_via_router(session_id, "task_crash")

      :ok = poll_until_status(session_id, task_id, "failed")

      conn = rpc_tasks_result(session_id, task_id)

      assert decode_resp(conn) ==
               json_rpc_error(3, -32603, "internal error", related_task_meta(task_id))
    end

    test "a structuredContent that violates the outputSchema fails the task and tasks/result replays -32603 with the messages" do
      session_id = Utils.create_session(@task_server, initialized: true)

      conn =
        post_json_rpc(1, "tools/call", %{
          "name" => "task_structured",
          "arguments" => %{"shape" => "wrong"},
          "task" => %{}
        })
        |> put_session_header(session_id)
        |> call_router(@task_server)

      assert conn.status == 200

      task = decode_resp(conn)["result"]["task"]
      assert is_binary(task["taskId"]) and byte_size(task["taskId"]) > 0

      :ok = poll_until_status(session_id, task["taskId"], "failed")

      get = rpc_tasks_get(session_id, task["taskId"])
      assert get["result"]["status"] == "failed"
      assert get["result"]["statusMessage"] == "tool output does not match outputSchema"

      result_conn = rpc_tasks_result(session_id, task["taskId"])
      assert result_conn.status == 200

      assert decode_resp(result_conn)["error"] == %{
               "code" => -32603,
               "message" => "tool output does not match outputSchema",
               "data" => ["'result' value is not of type string"]
             }
    end

    # Scenario 10
    #
    test "tasks/get with an unknown or foreign taskId returns -32602 Task not found" do
      session_id = Utils.create_session(@task_server, initialized: true)
      other = Utils.create_session(@task_server, initialized: true)

      conn = rpc_tasks_get(session_id, "unknown-task-id")

      assert conn ==
               json_rpc_error(2, -32602, "Failed to retrieve task: Task not found")

      task_id = create_task_via_router(session_id, "task_immediate")
      :ok = poll_until_status(session_id, task_id, "completed")

      conn = rpc_tasks_get(other, task_id)

      assert conn ==
               json_rpc_error(2, -32602, "Failed to retrieve task: Task not found")
    end

    # Scenario 19
    #
    test "expired task: tasks/get returns -32602 Task has expired" do
      session_id = Utils.create_session(@task_server, initialized: true)
      task_id = create_task_via_router(session_id, "task_immediate", %{"ttl" => 1})

      # The ttl of 1 ms is over: the tasks/get answers with the expiry.
      #
      assert Utils.eventually(fn ->
               expired? =
                 rpc_tasks_get(session_id, task_id) in [
                   json_rpc_error(2, -32602, "Failed to retrieve task: Task has expired"),
                   json_rpc_error(2, -32602, "Failed to retrieve task: Task not found")
                 ]

               expired?
             end)

      conn = rpc_tasks_get(session_id, task_id)

      assert conn in [
               json_rpc_error(2, -32602, "Failed to retrieve task: Task has expired"),
               json_rpc_error(2, -32602, "Failed to retrieve task: Task not found")
             ]
    end

    test "a refused status message keeps tasks/get and tasks/list answering" do
      session_id = Utils.create_session(@task_server, initialized: true)
      task_id = create_slow_task_via_router(session_id)
      runner = wait_for_slow_runner()

      assert {:error, :not_encodable} =
               Tasks.status_message(@task_server, task_id, <<0xFF>>)

      assert %{"result" => %{"status" => "working"}} = rpc_tasks_get(session_id, task_id)

      conn =
        post_json_rpc(4, "tasks/list", %{})
        |> put_session_header(session_id)
        |> call_router(@task_server)

      assert %{"tasks" => [listed]} = decode_resp(conn)["result"]
      assert listed["taskId"] == task_id

      send(runner, :finish)
    end

    # Scenario 11
    #
    test "tasks/result on a non-terminal task blocks until completion" do
      session_id = Utils.create_session(@task_server, initialized: true)
      task_id = create_slow_task_via_router(session_id)
      runner = wait_for_slow_runner()

      parent = self()

      spawn(fn ->
        conn = rpc_tasks_result(session_id, task_id, 9)
        send(parent, {:result_conn, conn})
      end)

      # Let the request park as a waiter of the task, then unblock.
      #
      wait_until(fn -> waiter_registered?(task_id) end)
      send(runner, :finish)

      assert_receive {:result_conn, conn}, 5_000
      assert conn.status == 200

      # The stream carries the terminal status notification before the
      # result of the request.
      #
      [_status_notification, message] = sse_messages(conn.resp_body)
      result = message["result"]
      assert result["content"] == [%{"type" => "text", "text" => "slow done"}]
      assert result["_meta"]["io.modelcontextprotocol/related-task"]["taskId"] == task_id
    end

    @tag task_opts: %{sse_heartbeat_ms: 100}
    test "a blocking tasks/result on a plain response upgrades to SSE, heartbeats keep it open" do
      session_id = Utils.create_session(@task_server, initialized: true)
      task_id = create_slow_task_via_router(session_id)
      runner = wait_for_slow_runner()

      start_tasks_result(session_id, task_id, 9)

      # The first idle heartbeat turns the plain response into a stream
      # whose comments keep the connection open: the adapter reports the
      # response as sent at that moment.
      #
      assert_receive {:plug_conn, :sent}, 5_000

      send(runner, :finish)

      assert_receive {:result_conn, 9, conn}, 5_000
      assert conn.status == 200
      assert Plug.Conn.get_resp_header(conn, "content-type") == ["text/event-stream"]

      heartbeat_count =
        conn.resp_body
        |> :binary.matches(": heartbeat")
        |> length()

      assert heartbeat_count >= 1

      # The terminal status notification and the result travel as the
      # events of the stream.
      #
      [_status_notification, message] = sse_messages(conn.resp_body)
      result = message["result"]
      assert result["content"] == [%{"type" => "text", "text" => "slow done"}]
      assert result["_meta"]["io.modelcontextprotocol/related-task"]["taskId"] == task_id
    end

    @tag task_opts: %{sse_heartbeat_ms: 100}
    test "a blocking tasks/result that is cancelled answers -32800 on the upgraded stream" do
      session_id = Utils.create_session(@task_server, initialized: true)
      task_id = create_slow_task_via_router(session_id)
      wait_for_slow_runner()
      start_tasks_result(session_id, task_id, 9)

      # The idle heartbeat upgrades the plain response to a stream.
      #
      assert_receive {:plug_conn, :sent}, 5_000
      assert post_cancelled(session_id, 9, "stop waiting").status == 202

      assert_receive {:result_conn, 9, conn}, 5_000
      assert Plug.Conn.get_resp_header(conn, "content-type") == ["text/event-stream"]

      [message] = sse_messages(conn.resp_body)
      assert message == json_rpc_error(9, -32800, "request cancelled")

      # The cancel of the request does not touch the task: only
      # tasks/cancel cancels a task.
      #
      assert {:ok, task} = Tasks.get(@task_server, Utils.owner(session_id), task_id)
      assert task.status == :working
    end

    @tag :capture_log
    test "a blocked tasks/result ends when the task process dies, the router stays up" do
      session_id = Utils.create_session(@task_server, initialized: true)
      task_id = create_slow_task_via_router(session_id)
      wait_for_slow_runner()

      parent = self()

      spawn(fn ->
        conn = rpc_tasks_result(session_id, task_id, 9)
        send(parent, {:result_conn, conn})
      end)

      # Let the request park as a waiter of the task.
      #
      wait_until(fn -> waiter_registered?(task_id) end)

      [{task_pid, _}] =
        Registry.lookup(OzMcp.Instance.names(@task_server), {:task, task_id})

      Process.exit(task_pid, :kill)

      # The answer still comes from the router process: no crash of the
      # request handling, the wait ends with the internal error.
      #
      assert_receive {:result_conn, conn}, 5_000
      assert conn.status == 200
      assert %{"error" => %{"code" => -32603}} = decode_resp(conn)

      # The reaper marks the task of the lost process failed.
      #
      :ok = poll_until_status(session_id, task_id, "failed")
    end
  end

  describe "MCP Tasks - notifications" do
    @describetag :tasks

    # Scenario 4
    #
    test "task-backed tool emits notifications/progress with the original progressToken" do
      session_id = Utils.create_session(@task_server, initialized: true, streams: [self()])

      conn =
        post_json_rpc(1, "tools/call", %{
          "name" => "task_progress",
          "task" => %{},
          "_meta" => %{"progressToken" => "tok-e2e"}
        })
        |> put_session_header(session_id)
        |> call_router(@task_server)

      assert %{"task" => %{"taskId" => task_id}} = decode_resp(conn)["result"]

      {_, notification} = Utils.receive_event(5_000)
      assert notification["method"] == "notifications/progress"

      assert notification["params"] == %{
               "progress" => 1,
               "progressToken" => "tok-e2e",
               "total" => 2,
               "message" => "step 1",
               "_meta" => %{"io.modelcontextprotocol/related-task" => %{"taskId" => task_id}}
             }

      assert {:ok, {:ok, _}} =
               Tasks.await(@task_server, Utils.owner(session_id), task_id, 5_000)
    end

    # Scenario 5
    #
    test "session stream receives notifications/tasks/status with flattened Task params" do
      session_id = Utils.create_session(@task_server, initialized: true, streams: [self()])
      task_id = create_task_via_router(session_id, "task_immediate")

      {_, notification} = Utils.receive_event(5_000)
      assert notification["method"] == "notifications/tasks/status"

      params = notification["params"]
      assert params["taskId"] == task_id
      assert params["status"] == "completed"
      assert String.match?(params["createdAt"], ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/)
      assert String.match?(params["lastUpdatedAt"], ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/)
      assert Map.has_key?(params, "ttl")

      # Flattened Task params: no task wrapper, no related-task meta (A7)
      #
      refute Map.has_key?(params, "task")
      refute Map.has_key?(params, "_meta")
    end
  end

  describe "Synchronous progress" do
    @describetag :tasks

    test "plain tool emits notifications/progress on the GET SSE stream with the request token" do
      session_id = Utils.create_session(@task_server, initialized: true, streams: [self()])

      # The test process is the GET stream of the session. The POST runs
      # in another process, as on a real server: the loop of a POST writer
      # drops the messages of another stream (here, the GET stream).
      #
      conn =
        Task.async(fn ->
          post_json_rpc(1, "tools/call", %{
            "name" => "task_progress",
            "_meta" => %{"progressToken" => "tok-sync"}
          })
          |> put_session_header(session_id)
          |> call_router(@task_server)
        end)
        |> Task.await(10_000)

      assert conn.status == 200

      assert decode_resp(conn)["result"]["content"] == [
               %{"type" => "text", "text" => "progress done"}
             ]

      {_, notification} = Utils.receive_event(5_000)
      assert notification["method"] == "notifications/progress"

      assert notification["params"] == %{
               "progress" => 1,
               "progressToken" => "tok-sync",
               "total" => 2,
               "message" => "step 1"
             }
    end

    test "plain tool without a progress token emits nothing" do
      session_id = Utils.create_session(@task_server, initialized: true, streams: [self()])

      conn =
        post_json_rpc(1, "tools/call", %{"name" => "task_progress"})
        |> put_session_header(session_id)
        |> call_router(@task_server)

      assert conn.status == 200

      assert decode_resp(conn)["result"]["content"] == [
               %{"type" => "text", "text" => "progress done"}
             ]

      # The wait is part of the check: no event of the stream arrives.
      #
      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 150
    end
  end

  describe "Requests of the server to the client" do
    @describetag :tasks

    test "the answer of the client is accepted with 202 and handed to the waiting callback" do
      session_id = Utils.create_session(@task_server, initialized: true, streams: [self()])
      waiting = start_outbound_ping(session_id)
      id = wait_for_pending_request(session_id)

      conn = post_client_response(session_id, %{"id" => id, "result" => %{}})

      assert conn.status == 202
      assert conn.resp_body == ""
      assert_cors_headers(conn)
      assert Task.await(waiting, 30_000) == {:ok, %{}}
    end

    test "an error answer of the client reaches the waiting callback" do
      session_id = Utils.create_session(@task_server, initialized: true, streams: [self()])
      waiting = start_outbound_ping(session_id)
      id = wait_for_pending_request(session_id)

      error = %{"code" => -32601, "message" => "Method not found"}
      conn = post_client_response(session_id, %{"id" => id, "error" => error})

      assert conn.status == 202
      assert Task.await(waiting, 30_000) == {:error, {:rpc_error, error}}
    end

    test "an error answer with no id is accepted with 202 and reaches no callback" do
      session_id = Utils.create_session(@task_server, initialized: true, streams: [self()])
      waiting = start_outbound_ping(session_id, timeout: 300)
      wait_for_pending_request(session_id)

      error = %{"code" => -32601, "message" => "Method not found"}

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          conn = post_client_response(session_id, %{"error" => error})

          assert conn.status == 202
          assert conn.resp_body == ""
          assert_cors_headers(conn)
        end)

      assert log =~ "client error response with no id, code -32601"
      refute log =~ "Method not found"

      # The orphan error is not the answer of the pending request.
      #
      assert Task.await(waiting, 30_000) == {:error, :timeout}

      assert wait_until(fn ->
               SessionProbe.pending_outbound_ids(@task_server, session_id) == []
             end)
    end

    test "an error answer with an id of null is accepted with 202 and reaches no callback" do
      session_id = Utils.create_session(@task_server, initialized: true, streams: [self()])
      waiting = start_outbound_ping(session_id, timeout: 300)
      wait_for_pending_request(session_id)

      error = %{"code" => -32601, "message" => "Method not found"}
      conn = post_client_response(session_id, %{"id" => nil, "error" => error})

      assert conn.status == 202
      assert conn.resp_body == ""

      # The orphan error is not the answer of the pending request.
      #
      assert Task.await(waiting, 30_000) == {:error, :timeout}

      assert wait_until(fn ->
               SessionProbe.pending_outbound_ids(@task_server, session_id) == []
             end)
    end

    test "an answer for a request that is not pending is accepted and ignored" do
      session_id = Utils.create_session(@task_server, initialized: true)

      conn = post_client_response(session_id, %{"id" => "unknown", "result" => %{}})

      assert conn.status == 202
      assert conn.resp_body == ""
    end

    test "the answer of another session does not reach the waiting callback" do
      session_id = Utils.create_session(@task_server, initialized: true, streams: [self()])
      other_session_id = Utils.create_session(@task_server, initialized: true)
      waiting = start_outbound_ping(session_id, timeout: 300)
      id = wait_for_pending_request(session_id)

      conn = post_client_response(other_session_id, %{"id" => id, "result" => %{}})

      assert conn.status == 202
      assert Task.await(waiting, 30_000) == {:error, :timeout}
    end

    test "a response is subject to the session checks" do
      session_id = Utils.create_session(@task_server, initialized: false)
      body = %{"jsonrpc" => "2.0", "id" => "x", "result" => %{}}

      # The body of a refused response carries no id: the id of a response
      # names a request of the server, not of the client.
      #
      missing =
        post_raw(:json.encode(body) |> IO.iodata_to_binary()) |> call_router(@task_server)

      assert missing.status == 400
      assert decode_resp(missing) == json_rpc_error(-32600, "missing session id")

      unknown = post_client_response("nonexistent", %{"id" => "x", "result" => %{}})
      assert unknown.status == 404
      assert decode_resp(unknown) == json_rpc_error(-32001, "invalid session")

      waiting = post_client_response(session_id, %{"id" => "x", "result" => %{}})
      assert waiting.status == 400

      assert decode_resp(waiting) ==
               json_rpc_error(-32600, "waiting session initialization")
    end

    test "a response that is not valid is an invalid request" do
      session_id = Utils.create_session(@task_server, initialized: true)

      bodies = [
        %{"jsonrpc" => "2.0", "id" => 1, "result" => %{}, "error" => %{"code" => 1}},
        %{"jsonrpc" => "2.0", "id" => 1, "result" => "text"},
        %{"jsonrpc" => "2.0", "id" => 1, "error" => %{"code" => "x", "message" => "m"}},
        %{"jsonrpc" => "2.0", "result" => %{}},
        %{"jsonrpc" => "1.0", "id" => 1, "result" => %{}}
      ]

      for body <- bodies do
        conn =
          post_raw(:json.encode(body) |> IO.iodata_to_binary())
          |> put_session_header(session_id)
          |> call_router(@task_server)

        # A refused response gets an HTTP error status and no id in the body.
        #
        assert conn.status == 400, "body: #{inspect(body)}"
        assert %{"error" => %{"code" => -32600}} = decode_resp(conn)
        refute Map.has_key?(decode_resp(conn), "id"), "body: #{inspect(body)}"
      end
    end

    test "a request that sends nothing to the client keeps the plain JSON response" do
      session_id = Utils.create_session(@task_server, initialized: true)

      conn =
        post_json_rpc(1, "tools/call", %{"name" => "task_immediate"})
        |> put_session_header(session_id)
        |> call_router(@task_server)

      assert conn.status == 200
      assert conn.state == :sent
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/json"
      assert decode_resp(conn)["result"]["content"] == [%{"type" => "text", "text" => "done"}]
    end

    test "a request sent while a POST request runs is written on the response of that POST" do
      session_id = Utils.create_session(@task_server, initialized: true, streams: [self()])
      start_slow_call(session_id, 7)
      wait_for_slow_runner()

      waiting = start_outbound_ping(session_id, request_id: 7)
      id = wait_for_pending_request(session_id)

      # The GET stream receives nothing: the request belongs to the POST.
      #
      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 50

      conn = post_client_response(session_id, %{"id" => id, "result" => %{}})
      assert conn.status == 202
      assert Task.await(waiting, 30_000) == {:ok, %{}}

      Support.Entities.Tools.TaskSlowTest.finish()
      assert_receive {:call_conn, 7, conn}, 5_000

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["text/event-stream"]
      assert get_resp_header(conn, "access-control-allow-origin") == [@cors_origin]

      assert [request, response] = sse_messages(conn.resp_body)
      assert request == %{"jsonrpc" => "2.0", "id" => id, "method" => "ping"}
      assert %{"jsonrpc" => "2.0", "id" => 7, "result" => %{"content" => [_ | _]}} = response
    end

    test "the messages arrive in order and the response is the last event" do
      session_id = Utils.create_session(@task_server, initialized: true)
      start_slow_call(session_id, 7)
      wait_for_slow_runner()

      for _ <- 1..2 do
        waiting = start_outbound_ping(session_id, request_id: 7)
        id = wait_for_pending_request(session_id)
        post_client_response(session_id, %{"id" => id, "result" => %{}})
        assert Task.await(waiting, 30_000) == {:ok, %{}}
      end

      Support.Entities.Tools.TaskSlowTest.finish()
      assert_receive {:call_conn, 7, conn}, 5_000

      assert [%{"method" => "ping"}, %{"method" => "ping"}, %{"id" => 7, "result" => _}] =
               sse_messages(conn.resp_body)
    end

    test "an error response of the request is the last event of the stream" do
      session_id = Utils.create_session(@task_server, initialized: true)
      start_slow_call(session_id, 7)
      wait_for_slow_runner()

      waiting = start_outbound_ping(session_id, request_id: 7, timeout: 5_000)
      wait_for_pending_request(session_id)

      post_cancelled(session_id, 7, "stop")
      assert_receive {:call_conn, 7, conn}, 5_000

      assert get_resp_header(conn, "content-type") == ["text/event-stream"]

      assert [%{"method" => "ping"}, %{"id" => 7, "error" => %{"code" => -32800}}] =
               sse_messages(conn.resp_body)

      Task.shutdown(waiting, :brutal_kill)
    end

    test "a request with no stream goes to the GET stream and the POST stays plain JSON" do
      session_id = Utils.create_session(@task_server, initialized: true, streams: [self()])
      start_slow_call(session_id, 7)
      wait_for_slow_runner()

      # No request id: the request belongs to no POST.
      #
      waiting = start_outbound_ping(session_id)

      assert {_event_id, %{"method" => "ping", "id" => id}} = Utils.receive_event(5_000)

      conn = post_client_response(session_id, %{"id" => id, "result" => %{}})
      assert conn.status == 202
      assert Task.await(waiting, 30_000) == {:ok, %{}}

      Support.Entities.Tools.TaskSlowTest.finish()
      assert_receive {:call_conn, 7, conn}, 5_000

      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/json"
    end

    test "ending the session ends the wait of the callback" do
      session_id = Utils.create_session(@task_server, initialized: true, streams: [self()])
      waiting = start_outbound_ping(session_id, timeout: 5_000)
      wait_for_pending_request(session_id)

      conn =
        conn(:delete, "/")
        |> put_req_header("accept", "application/json, text/event-stream")
        |> put_session_header(session_id)
        |> call_router(@task_server)

      assert conn.status == 200
      assert Task.await(waiting, 30_000) == {:error, :session_terminated}
    end
  end

  describe "MCP Tasks - tasks/cancel" do
    @describetag :tasks

    # Scenario 8
    #
    test "cancelling a working task cancels it, kills the runner and stores the cancel outcome" do
      session_id = Utils.create_session(@task_server, initialized: true)
      task_id = create_slow_task_via_router(session_id)
      runner = wait_for_slow_runner()

      conn =
        post_json_rpc(2, "tasks/cancel", %{"taskId" => task_id})
        |> put_session_header(session_id)
        |> call_router(@task_server)

      assert conn.status == 200
      task = decode_resp(conn)["result"]
      assert task["status"] == "cancelled"
      assert task["statusMessage"] == "The task was cancelled by request."

      # The cancel kills the runner: the DOWN of the runner arrives.
      #
      runner_ref = Process.monitor(runner)
      assert_receive {:DOWN, ^runner_ref, :process, ^runner, _}, 5_000

      get = rpc_tasks_get(session_id, task_id)
      assert get["result"]["status"] == "cancelled"

      conn = rpc_tasks_result(session_id, task_id, 3)

      assert decode_resp(conn) ==
               json_rpc_error(3, -32800, "task was cancelled", related_task_meta(task_id))
    end

    # Scenario 9
    #
    test "cancelling a completed task returns -32602" do
      session_id = Utils.create_session(@task_server, initialized: true)
      task_id = create_task_via_router(session_id, "task_immediate")
      :ok = poll_until_status(session_id, task_id, "completed")

      conn =
        post_json_rpc(2, "tasks/cancel", %{"taskId" => task_id})
        |> put_session_header(session_id)
        |> call_router(@task_server)

      assert decode_resp(conn) ==
               json_rpc_error(
                 2,
                 -32602,
                 "Cannot cancel task: already in terminal status 'completed'"
               )
    end
  end

  describe "MCP Tasks - tasks/list" do
    @describetag :tasks

    # Scenario 12
    #
    @tag task_opts: %{task_page_size: 2}
    test "paginates with nextCursor and closes the last page without one" do
      session_id = Utils.create_session(@task_server, initialized: true)
      t1 = create_task_via_router(session_id, "task_immediate", %{}, 1)
      t2 = create_task_via_router(session_id, "task_immediate", %{}, 2)
      t3 = create_task_via_router(session_id, "task_immediate", %{}, 3)

      conn =
        post_json_rpc(4, "tasks/list", %{})
        |> put_session_header(session_id)
        |> call_router(@task_server)

      result = decode_resp(conn)["result"]
      assert Enum.map(result["tasks"], & &1["taskId"]) == [t1, t2]
      assert is_binary(result["nextCursor"])

      conn =
        post_json_rpc(5, "tasks/list", %{"cursor" => result["nextCursor"]})
        |> put_session_header(session_id)
        |> call_router(@task_server)

      result = decode_resp(conn)["result"]
      assert Enum.map(result["tasks"], & &1["taskId"]) == [t3]
      refute Map.has_key?(result, "nextCursor")
    end

    # Scenario 13
    #
    test "returns -32602 for a garbage cursor" do
      session_id = Utils.create_session(@task_server, initialized: true)

      conn =
        post_json_rpc(1, "tasks/list", %{"cursor" => "not-a-cursor"})
        |> put_session_header(session_id)
        |> call_router(@task_server)

      assert decode_resp(conn) ==
               json_rpc_error(1, -32602, "Failed to list tasks: invalid cursor")

      conn =
        post_json_rpc(2, "tasks/list", %{"cursor" => 123})
        |> put_session_header(session_id)
        |> call_router(@task_server)

      assert decode_resp(conn) == json_rpc_error(2, -32602, "invalid cursor")
    end
  end

  describe "MCP Tasks - capability gating" do
    @describetag :tasks

    # Scenario 14
    #
    test "a server without the tasks capability answers -32601 for all tasks/* methods" do
      server = inst(@tools_only)
      session_id = Utils.create_session(server, initialized: true)

      for {method, params} <- [
            {"tasks/get", %{"taskId" => "x"}},
            {"tasks/list", %{}},
            {"tasks/cancel", %{"taskId" => "x"}},
            {"tasks/result", %{"taskId" => "x"}}
          ] do
        conn =
          post_json_rpc(1, method, params)
          |> put_session_header(session_id)
          |> call_router(server)

        assert decode_resp(conn) == json_rpc_error(1, -32601, "method not found")
      end
    end

    # Scenario 15
    #
    test "taskSupport required tool without task augmentation returns -32601" do
      server = inst(Servers.TasksRequiredTool)
      session_id = Utils.create_session(server, initialized: true)

      conn =
        post_json_rpc(1, "tools/call", %{"name" => "full", "arguments" => %{"name" => "x"}})
        |> put_session_header(session_id)
        |> call_router(server)

      assert decode_resp(conn) == json_rpc_error(1, -32601, "method not found")
    end

    test "taskSupport required tool without task augmentation returns -32601 even when the arguments violate the input schema" do
      #
      # The task support gating is decided before the argument schema: the
      # missing task marker is rejected, it never falls back to a plain
      # tool execution error result.
      #
      server = inst(Servers.TasksRequiredTool)
      session_id = Utils.create_session(server, initialized: true)

      conn =
        post_json_rpc(1, "tools/call", %{"name" => "full", "arguments" => %{"name" => 123}})
        |> put_session_header(session_id)
        |> call_router(server)

      assert decode_resp(conn) == json_rpc_error(1, -32601, "method not found")
    end

    # Scenario 16
    #
    test "taskSupport forbidden tool with task augmentation returns -32601" do
      server = inst(Servers.TasksForbiddenTool)
      session_id = Utils.create_session(server, initialized: true)

      conn =
        post_json_rpc(1, "tools/call", %{"name" => "get_date", "task" => %{}})
        |> put_session_header(session_id)
        |> call_router(server)

      assert decode_resp(conn) == json_rpc_error(1, -32601, "method not found")
    end

    # Scenario 17
    #
    test "augmented call without the tasks capability runs normally and ignores the task metadata" do
      server = inst(Servers.TasksNoCapability)
      session_id = Utils.create_session(server, initialized: true)

      conn =
        post_json_rpc(1, "tools/call", %{"name" => "task_immediate", "task" => %{"ttl" => 5_000}})
        |> put_session_header(session_id)
        |> call_router(server)

      assert conn.status == 200

      result = decode_resp(conn)["result"]
      assert result["content"] == [%{"type" => "text", "text" => "done"}]
      refute Map.has_key?(result, "task")

      # The tool ran synchronously (plain 041 ctx) and no task was created
      #
      assert Support.Entities.Tools.TaskImmediateTest.last_ctx().task_id == nil
      assert :ets.tab2list(OzMcp.Tasks.Index.index_table(server)) == []
    end
  end

  describe "MCP Tasks - plain call contract" do
    @describetag :tasks

    # Scenario 20
    #
    test "plain call on the same tool never creates a task (single-callback contract)" do
      session_id = Utils.create_session(@task_server, initialized: true)

      conn =
        post_json_rpc(1, "tools/call", %{"name" => "task_progress"})
        |> put_session_header(session_id)
        |> call_router(@task_server)

      assert conn.status == 200

      result = decode_resp(conn)["result"]
      assert result["content"] == [%{"type" => "text", "text" => "progress done"}]
      refute Map.has_key?(result, "task")

      ctx = Support.Entities.Tools.TaskProgressTest.last_ctx()
      assert ctx.task_id == nil
      assert ctx.request_id == 1
      assert :ets.tab2list(OzMcp.Tasks.Index.index_table(@task_server)) == []
    end
  end

  describe "MCP Tasks - session termination cascade" do
    @describetag :tasks

    test "HTTP DELETE kills the session's running task and deletes its records" do
      session_id = Utils.create_session(@task_server, initialized: true)
      _task_id = create_slow_task_via_router(session_id)
      runner = wait_for_slow_runner()

      conn =
        conn(:delete, "/")
        |> put_session_header(session_id)
        |> call_router(@task_server)

      assert conn.status == 200

      # The Server starts the cascade of tasks with a cast: the task
      # process handles it a moment after the reply.
      #
      wait_until(fn -> not Process.alive?(runner) end)

      assert Sessions.lookup(@task_server, session_id) == {:error, :no_session}

      wait_until(fn -> Support.Helpers.TaskScan.all(@task_server) == [] end)
      assert :ets.tab2list(OzMcp.Tasks.Index.index_table(@task_server)) == []

      get =
        post_json_rpc(2, "tasks/get", %{"taskId" => "whatever"})
        |> put_session_header(session_id)
        |> call_router(@task_server)

      assert get.status == 404
      assert decode_resp(get) == json_rpc_error(2, -32001, "invalid session")
    end

    @tag task_opts: %{session_timeout_ms: 1_000}
    test "the idle timer of the session cascades the same way" do
      session_id = Utils.create_session(@task_server, initialized: true)
      _task_id = create_slow_task_via_router(session_id)
      runner = wait_for_slow_runner()

      wait_until(
        fn -> Sessions.lookup(@task_server, session_id) == {:error, :no_session} end,
        3_000
      )

      # The Server starts the cascade of tasks with a cast: the task
      # process handles it a moment after the session is gone.
      #
      wait_until(fn -> not Process.alive?(runner) end)

      wait_until(fn -> Support.Helpers.TaskScan.all(@task_server) == [] end)
      assert :ets.tab2list(OzMcp.Tasks.Index.index_table(@task_server)) == []
    end

    test "a blocking tasks/result answers -32000 session terminated when the session is deleted" do
      session_id = Utils.create_session(@task_server, initialized: true)
      task_id = create_slow_task_via_router(session_id)
      wait_for_slow_runner()

      parent = self()

      spawn(fn ->
        conn = rpc_tasks_result(session_id, task_id, 5)
        send(parent, {:result_conn, conn})
      end)

      # The delete must come after the blocking request is waiting.
      #
      wait_until(fn ->
        case OzMcp.Instance.whereis(@task_server, {:task, task_id}) do
          {:ok, pid} ->
            {_state, data} = :sys.get_state(pid)
            data.waiters != [] or data.streams != []

          _ ->
            false
        end
      end)

      conn =
        conn(:delete, "/")
        |> put_session_header(session_id)
        |> call_router(@task_server)

      assert conn.status == 200

      assert_receive {:result_conn, result_conn}, 5_000
      assert result_conn.status == 200
      assert decode_resp(result_conn) == json_rpc_error(5, -32000, "session terminated")
    end
  end

  # User callback isolation: a raising or hanging callback must never
  # produce a non-JSON response nor keep the connection open forever.
  #

  describe "user callback isolation" do
    @describetag :tasks

    @tag :capture_log
    test "a raising tool answers a valid -32603 JSON-RPC error" do
      session_id = Utils.create_session(@task_server, initialized: true)

      conn =
        post_json_rpc(1, "tools/call", %{"name" => "task_crash"})
        |> put_session_header(session_id)
        |> call_router(@task_server)

      assert conn.status == 200
      assert_cors_headers(conn)
      assert decode_resp(conn) == json_rpc_error(1, -32603, "internal error")
    end

    @tag task_opts: %{request_timeout_ms: 300}
    test "a hanging tool is killed at the deadline and answers -32603" do
      session_id = Utils.create_session(@task_server, initialized: true)

      {duration_us, conn} =
        :timer.tc(fn ->
          post_json_rpc(1, "tools/call", %{"name" => "task_slow"})
          |> put_session_header(session_id)
          |> call_router(@task_server)
        end)

      assert conn.status == 200
      assert_cors_headers(conn)

      assert decode_resp(conn) ==
               json_rpc_error(1, -32603, "request execution timed out", %{"reason" => "timeout"})

      # The deadline is honoured: the connection is not kept open forever.
      #
      assert duration_us < 5_000_000
    end

    @tag task_opts: %{request_timeout_ms: 300}
    test "task-backed executions are not deadline-killed" do
      session_id = Utils.create_session(@task_server, initialized: true)
      task_id = create_slow_task_via_router(session_id)
      runner = wait_for_slow_runner()

      # Well past the request deadline: the background runner still works.
      # A kill at the deadline would end the runner, so the wait is the
      # check that its DOWN does not arrive.
      #
      runner_ref = Process.monitor(runner)
      refute_receive {:DOWN, ^runner_ref, :process, ^runner, _}, 500
      assert rpc_tasks_get(session_id, task_id)["result"]["status"] == "working"

      Support.Entities.Tools.TaskSlowTest.finish()
      :ok = poll_until_status(session_id, task_id, "completed")
    end
  end

  # notifications/cancelled stops the in-flight request it names. The slow
  # tool blocks until told to finish, so a sync tools/call stays in flight
  # in a separate process while the test posts the cancellation.
  #

  describe "notifications/cancelled stops in-flight requests" do
    @describetag :tasks

    test "a running tools/call ends with -32800 and its process is stopped" do
      session_id = Utils.create_session(@task_server, initialized: true)
      start_slow_call(session_id, 7)
      runner = wait_for_slow_runner()

      conn = post_cancelled(session_id, 7, "user aborted")

      assert conn.status == 202
      assert conn.resp_body == ""
      assert_cors_headers(conn)

      assert_receive {:call_conn, 7, call_conn}, 5_000
      assert call_conn.status == 200
      assert decode_resp(call_conn) == json_rpc_error(7, -32800, "request cancelled")

      wait_until(fn -> not Process.alive?(runner) end)
    end

    test "works without a reason" do
      session_id = Utils.create_session(@task_server, initialized: true)
      start_slow_call(session_id, 7)
      wait_for_slow_runner()

      conn =
        post_json_rpc(nil, "notifications/cancelled", %{"requestId" => 7})
        |> put_session_header(session_id)
        |> call_router(@task_server)

      assert conn.status == 202
      assert_receive {:call_conn, 7, call_conn}, 5_000
      assert decode_resp(call_conn)["error"]["code"] == -32800
    end

    @tag task_opts: %{request_timeout_ms: 5_000}
    test "behaves the same when request_timeout_ms is set" do
      session_id = Utils.create_session(@task_server, initialized: true)
      start_slow_call(session_id, 7)
      wait_for_slow_runner()

      assert post_cancelled(session_id, 7, "user aborted").status == 202

      assert_receive {:call_conn, 7, call_conn}, 5_000
      assert decode_resp(call_conn) == json_rpc_error(7, -32800, "request cancelled")
    end

    test "a string request id is cancelled by the same string id" do
      session_id = Utils.create_session(@task_server, initialized: true)
      start_slow_call(session_id, "req-1")
      wait_for_slow_runner()

      assert post_cancelled(session_id, "req-1", nil).status == 202

      assert_receive {:call_conn, "req-1", call_conn}, 5_000
      assert decode_resp(call_conn) == json_rpc_error("req-1", -32800, "request cancelled")
    end

    test "the id type is compared strictly: \"7\" does not cancel 7" do
      session_id = Utils.create_session(@task_server, initialized: true)
      start_slow_call(session_id, 7)
      runner = wait_for_slow_runner()

      assert post_cancelled(session_id, "7", nil).status == 202

      refute_receive {:call_conn, 7, _}, 200
      assert Process.alive?(runner)

      Support.Entities.Tools.TaskSlowTest.finish()
      assert_receive {:call_conn, 7, call_conn}, 5_000

      assert decode_resp(call_conn)["result"]["content"] == [
               %{"type" => "text", "text" => "slow done"}
             ]
    end

    test "a blocked tasks/result is stopped by notifications/cancelled, the task keeps working" do
      session_id = Utils.create_session(@task_server, initialized: true)
      task_id = create_slow_task_via_router(session_id)
      runner = wait_for_slow_runner()
      start_tasks_result(session_id, task_id, 9)

      refute_receive {:result_conn, 9, _}, 200
      assert post_cancelled(session_id, 9, "stop waiting").status == 202

      assert_receive {:result_conn, 9, conn}, 5_000
      assert decode_resp(conn) == json_rpc_error(9, -32800, "request cancelled")

      # Only tasks/cancel cancels a task.
      #
      assert rpc_tasks_get(session_id, task_id)["result"]["status"] == "working"
      assert Process.alive?(runner)

      Support.Entities.Tools.TaskSlowTest.finish()
      :ok = poll_until_status(session_id, task_id, "completed")

      result = decode_resp(rpc_tasks_result(session_id, task_id, 10))["result"]
      assert result["content"] == [%{"type" => "text", "text" => "slow done"}]
    end

    @tag task_opts: %{request_timeout_ms: 300}
    test "a blocked tasks/result is not killed by the request deadline" do
      session_id = Utils.create_session(@task_server, initialized: true)
      task_id = create_slow_task_via_router(session_id)
      wait_for_slow_runner()
      start_tasks_result(session_id, task_id, 9)

      # Well past the request deadline: the wait is still open.
      #
      refute_receive {:result_conn, 9, _}, 700

      Support.Entities.Tools.TaskSlowTest.finish()
      assert_receive {:result_conn, 9, conn}, 5_000

      # The stream carries the terminal status notification before the
      # result of the request.
      #
      message = conn.resp_body |> sse_messages() |> List.last()
      result = message["result"]
      assert result["content"] == [%{"type" => "text", "text" => "slow done"}]
    end

    @tag task_opts: %{session_timeout_ms: 1_000}
    test "a blocked tasks/result keeps the session past its idle timeout" do
      session_id = Utils.create_session(@task_server, initialized: true)
      task_id = create_slow_task_via_router(session_id)
      runner = wait_for_slow_runner()
      start_tasks_result(session_id, task_id, 9)

      # The parked request of the tasks/result stream holds the session
      # alive: well past the idle timeout the DOWN of the session does not
      # arrive and the wait is still open.
      #
      {:ok, view} = Sessions.lookup(@task_server, session_id)
      session_ref = Process.monitor(view.pid)
      refute_receive {:DOWN, ^session_ref, :process, _, _}, 1_600
      assert {:ok, _view} = Sessions.lookup(@task_server, session_id)
      refute_receive {:result_conn, 9, _}, 100

      Support.Entities.Tools.TaskSlowTest.finish()
      assert_receive {:result_conn, 9, conn}, 5_000
      assert conn.status == 200
      wait_until(fn -> not Process.alive?(runner) end)

      # The task is over and the stream is closed: the timer starts again
      # and the idle session stops.
      #
      wait_until(
        fn -> Sessions.lookup(@task_server, session_id) == {:error, :no_session} end,
        3_000
      )
    end

    test "a request of another session is not cancelled" do
      session_id = Utils.create_session(@task_server, initialized: true)
      other_session_id = Utils.create_session(@task_server, initialized: true)
      start_slow_call(session_id, 7)
      runner = wait_for_slow_runner()

      assert post_cancelled(other_session_id, 7, "not yours").status == 202

      refute_receive {:call_conn, 7, _}, 200
      assert Process.alive?(runner)

      Support.Entities.Tools.TaskSlowTest.finish()
      assert_receive {:call_conn, 7, call_conn}, 5_000

      assert decode_resp(call_conn)["result"]["content"] == [
               %{"type" => "text", "text" => "slow done"}
             ]
    end

    test "a cancel for a finished or unknown request is accepted and ignored" do
      session_id = Utils.create_session(@task_server, initialized: true)

      conn =
        post_json_rpc(1, "tools/call", %{"name" => "task_immediate"})
        |> put_session_header(session_id)
        |> call_router(@task_server)

      assert decode_resp(conn)["result"]["content"] == [%{"type" => "text", "text" => "done"}]

      assert post_cancelled(session_id, 1, "too late").status == 202
      assert post_cancelled(session_id, 999, "never existed").status == 202

      # The id of the finished request is free again.
      #
      conn =
        post_json_rpc(1, "tools/call", %{"name" => "task_immediate"})
        |> put_session_header(session_id)
        |> call_router(@task_server)

      assert decode_resp(conn)["result"]["content"] == [%{"type" => "text", "text" => "done"}]
    end

    test "a malformed cancel is accepted and cancels nothing" do
      session_id = Utils.create_session(@task_server, initialized: true)
      start_slow_call(session_id, 7)
      runner = wait_for_slow_runner()

      for params <- [
            %{},
            %{"requestId" => nil},
            %{"requestId" => true},
            %{"requestId" => 7.5},
            %{"requestId" => %{"id" => 7}},
            %{"requestId" => [7]},
            %{"reason" => "no request id"}
          ] do
        conn =
          post_json_rpc(nil, "notifications/cancelled", params)
          |> put_session_header(session_id)
          |> call_router(@task_server)

        assert conn.status == 202
      end

      refute_receive {:call_conn, 7, _}, 200
      assert Process.alive?(runner)

      Support.Entities.Tools.TaskSlowTest.finish()
      assert_receive {:call_conn, 7, _}, 5_000
    end

    test "a non-string reason is ignored but the request is still cancelled" do
      session_id = Utils.create_session(@task_server, initialized: true)
      start_slow_call(session_id, 7)
      wait_for_slow_runner()

      conn =
        post_json_rpc(nil, "notifications/cancelled", %{
          "requestId" => 7,
          "reason" => %{"not" => "a string"}
        })
        |> put_session_header(session_id)
        |> call_router(@task_server)

      assert conn.status == 202
      assert_receive {:call_conn, 7, call_conn}, 5_000
      assert decode_resp(call_conn)["error"]["code"] == -32800
    end

    test "a second request that reuses an in-flight id is refused with -32600" do
      session_id = Utils.create_session(@task_server, initialized: true)
      start_slow_call(session_id, 7)
      runner = wait_for_slow_runner()

      conn =
        post_json_rpc(7, "tools/call", %{"name" => "task_slow"})
        |> put_session_header(session_id)
        |> call_router(@task_server)

      assert conn.status == 200
      assert decode_resp(conn) == json_rpc_error(7, -32600, "request id already in use")

      # The first request is not disturbed.
      #
      assert Process.alive?(runner)
      Support.Entities.Tools.TaskSlowTest.finish()
      assert_receive {:call_conn, 7, call_conn}, 5_000

      assert decode_resp(call_conn)["result"]["content"] == [
               %{"type" => "text", "text" => "slow done"}
             ]
    end

    test "a request of another method that reuses an in-flight id is refused with -32600" do
      session_id = Utils.create_session(@task_server, initialized: true)
      start_slow_call(session_id, 7)
      runner = wait_for_slow_runner()

      conn =
        post_json_rpc(7, "tools/list", %{})
        |> put_session_header(session_id)
        |> call_router(@task_server)

      assert conn.status == 200
      assert decode_resp(conn) == json_rpc_error(7, -32600, "request id already in use")

      # The first request is not disturbed.
      #
      assert Process.alive?(runner)
      Support.Entities.Tools.TaskSlowTest.finish()
      assert_receive {:call_conn, 7, _call_conn}, 5_000
    end

    # The client owns the rule of unique ids: this test pins the current
    # behaviour.
    #
    test "an id is free again once its request has ended" do
      session_id = Utils.create_session(@task_server, initialized: true)
      start_slow_call(session_id, 7)
      wait_for_slow_runner()

      # While the request runs, the id is taken.
      #
      conn =
        post_json_rpc(7, "ping")
        |> put_session_header(session_id)
        |> call_router(@task_server)

      assert conn.status == 200
      assert decode_resp(conn) == json_rpc_error(7, -32600, "request id already in use")

      Support.Entities.Tools.TaskSlowTest.finish()
      assert_receive {:call_conn, 7, _call_conn}, 5_000

      # The answer is out: the id is free again.
      #
      conn =
        post_json_rpc(7, "ping")
        |> put_session_header(session_id)
        |> call_router(@task_server)

      assert decode_resp(conn) == %{"jsonrpc" => "2.0", "id" => 7, "result" => %{}}
    end

    test "deleting the session stops its running requests" do
      session_id = Utils.create_session(@task_server, initialized: true)
      start_slow_call(session_id, 7)
      runner = wait_for_slow_runner()

      conn =
        conn(:delete, "/")
        |> put_session_header(session_id)
        |> call_router(@task_server)

      assert conn.status == 200

      assert_receive {:call_conn, 7, call_conn}, 5_000
      assert decode_resp(call_conn) == json_rpc_error(7, -32800, "request cancelled")
      wait_until(fn -> not Process.alive?(runner) end)
    end

    test "a task runner is not cancelled by notifications/cancelled but by tasks/cancel" do
      session_id = Utils.create_session(@task_server, initialized: true)
      task_id = create_slow_task_via_router(session_id)
      runner = wait_for_slow_runner()

      # The id of the request that created the task is 1.
      #
      assert post_cancelled(session_id, 1, "user aborted").status == 202

      # The cancel of the creating request is a no-op for the runner: its
      # DOWN does not arrive.
      #
      runner_ref = Process.monitor(runner)
      refute_receive {:DOWN, ^runner_ref, :process, ^runner, _}, 100
      assert rpc_tasks_get(session_id, task_id)["result"]["status"] == "working"

      conn =
        post_json_rpc(5, "tasks/cancel", %{"taskId" => task_id})
        |> put_session_header(session_id)
        |> call_router(@task_server)

      assert decode_resp(conn)["result"]["status"] == "cancelled"
      wait_until(fn -> not Process.alive?(runner) end)
    end
  end

  describe "an instance that the runtime does not have" do
    test "answers 503 with no CORS origin, not a server error" do
      conn =
        post_json_rpc(1, "ping")
        |> call_router(inst(Servers.NoSuchServerForRouter))

      assert conn.status == 503
      refute Map.has_key?(Enum.into(conn.resp_headers, %{}), "access-control-allow-origin")

      assert decode_resp(conn) == json_rpc_error(nil, -32603, "server unavailable")
    end
  end

  describe "a session that ends during a request" do
    #
    # A session that ends between the validation and the write is a normal
    # race, not a server error: the notification stays accepted.
    #
    test "POST notifications/initialized keeps 202 when the session ended before the write" do
      server = inst(Servers.Default)
      session_id = Utils.create_session(server)
      {:ok, session_pid} = OzMcp.Instance.whereis(server, {:session, session_id})

      # The session is stopped until the request has passed the validation
      # (its write waits in the mailbox). The end of the session is in the
      # mailbox before the write: the session ends and the write finds no
      # session. `close/3` waits for the end, so it runs in a task; the
      # wait below holds until its call is the one message in the mailbox.
      #
      :ok = :sys.suspend(session_pid)

      closer =
        Task.async(fn -> OzMcp.Session.close(server, session_id) end)

      wait_until(fn ->
        match?({:message_queue_len, 1}, Process.info(session_pid, :message_queue_len))
      end)

      waiter =
        Task.async(fn ->
          post_json_rpc(nil, "notifications/initialized")
          |> put_session_header(session_id)
          |> call_router()
        end)

      wait_until(fn ->
        messages = Process.info(session_pid, :messages) |> elem(1) || []

        Enum.any?(messages, fn
          {:"$gen_call", _from, :initialized} -> true
          _other -> false
        end)
      end)

      :ok = :sys.resume(session_pid)

      conn = Task.await(waiter, 30_000)
      assert conn.status == 202
      assert conn.resp_body == ""
      assert :ok = Task.await(closer, 5_000)
    end
  end

  # A restore of a snapshot at the limit of the sessions (max_sessions: 1)
  # is refused with 429 by the restore stage of every method that carries
  # a session id: the refusal comes before any other check of the
  # session, so it tells the caller nothing about the session id.
  #
  describe "a restore at the max_sessions limit" do
    @restore_open Module.concat(Servers.Default, "RestoreLimit")
    @restore_auth Module.concat(Servers.Authorized, "RestoreLimit")
    @resource_url "https://mcp.example.com/mcp"
    @restored_id "restored-id"

    setup do
      Utils.start_instance(Servers.Default,
        name: @restore_open,
        session_snapshot: PersistentSnapshot,
        max_sessions: 1
      )

      Utils.start_instance(Servers.Authorized,
        name: @restore_auth,
        resource_url: @resource_url,
        session_snapshot: PersistentSnapshot,
        max_sessions: 1
      )

      for instance <- [@restore_open, @restore_auth] do
        Utils.create_session(instance, streams: [self()])
        PersistentSnapshot.put(instance, @restored_id, restored_snapshot())
      end

      # The restore stage checks the owner of a snapshot: the snapshot of
      # the protected server belongs to the principal of the token that
      # the DELETE of the test carries.
      #
      PersistentSnapshot.put(@restore_auth, @restored_id, %{
        restored_snapshot()
        | principal_key: {"https://issuer.test", "alice"}
      })

      :ok
    end

    test "tools/list gets 429" do
      conn =
        post_json_rpc(1, "tools/list")
        |> put_session_header(@restored_id)
        |> call_router_with([], @restore_open)

      assert conn.status == 429
      assert decode_resp(conn) == json_rpc_error(1, -32000, "too many sessions")
    end

    test "ping gets 429" do
      conn =
        post_json_rpc(2, "ping")
        |> put_session_header(@restored_id)
        |> call_router_with([], @restore_open)

      assert conn.status == 429
      assert decode_resp(conn) == json_rpc_error(2, -32000, "too many sessions")
    end

    test "notifications/initialized gets 429 with no id" do
      conn =
        post_json_rpc(nil, "notifications/initialized")
        |> put_session_header(@restored_id)
        |> call_router_with([], @restore_open)

      assert conn.status == 429
      assert conn.resp_body != ""
      assert decode_resp(conn) == json_rpc_error(-32000, "too many sessions")
    end

    test "a GET gets 429 with no id" do
      conn =
        conn(:get, "/")
        |> put_req_header("accept", "text/event-stream")
        |> put_session_header(@restored_id)
        |> call_router_with([], @restore_open)

      assert conn.status == 429
      assert decode_resp(conn) == json_rpc_error(-32000, "too many sessions")
    end

    test "DELETE of a protected server gets 429" do
      conn =
        conn(:delete, "/")
        |> put_req_header("authorization", "Bearer alice-token")
        |> put_session_header(@restored_id)
        |> call_router_with([], @restore_auth)

      assert conn.status == 429
      assert decode_resp(conn) == json_rpc_error(-32000, "too many sessions")
    end

    defp restored_snapshot do
      %{
        principal_key: nil,
        protocol_version: "2025-11-25",
        client_info: %{"name" => "restore-test", "version" => "1"},
        client_capabilities: %{},
        log_level: nil,
        subscriptions: []
      }
    end
  end

  # A restore counts in max_sessions_per_principal: a principal at its
  # limit gets 429 for the snapshot of its own id and the snapshot stays.
  # A DELETE of that id does not count: the session it starts ends at
  # once, so the caller can still remove its old session.
  #
  describe "a restore at the max_sessions_per_principal limit" do
    @limit_instance Module.concat(Servers.Default, "PrincipalLimit")
    @restored_id "restored-id"
    @alice {"https://issuer.test", "alice"}

    setup do
      Utils.start_instance(Servers.Default,
        name: @limit_instance,
        session_snapshot: PersistentSnapshot,
        max_sessions_per_principal: 1
      )

      Utils.create_session(@limit_instance, principal_key: @alice, streams: [self()])

      PersistentSnapshot.put(@limit_instance, @restored_id, %{
        restored_snapshot()
        | principal_key: @alice
      })

      :ok
    end

    test "a restore of a principal at its limit gets 429 and keeps the snapshot" do
      conn =
        post_json_rpc(1, "ping")
        |> put_session_header(@restored_id)
        |> call_router_with([], @limit_instance)

      assert conn.status == 429
      assert decode_resp(conn) == json_rpc_error(1, -32000, "too many sessions")

      conn =
        post_json_rpc(2, "ping")
        |> put_session_header(@restored_id)
        |> call_router_with([], @limit_instance)

      assert conn.status == 429
      assert PersistentSnapshot.get(@limit_instance, @restored_id) != nil
    end

    # Seen once in an earlier full run. It was not reproduced in 100 runs
    # alone and 5 runs of the file.
    #
    test "a DELETE of a principal at its limit ends the session and deletes the snapshot" do
      import Plug.Test, only: [conn: 2]

      conn =
        conn(:delete, "/")
        |> put_session_header(@restored_id)
        |> call_router_with([], @limit_instance)

      assert conn.status == 200
      assert PersistentSnapshot.get(@limit_instance, @restored_id) == nil
    end

    test "a restore of another principal starts" do
      PersistentSnapshot.put(@limit_instance, "other-id", %{
        restored_snapshot()
        | principal_key: {"https://issuer.test", "bob"}
      })

      conn =
        post_json_rpc(1, "ping")
        |> put_session_header("other-id")
        |> call_router_with([], @limit_instance)

      assert conn.status == 200

      assert {:ok, %{principal_key: {"https://issuer.test", "bob"}}} =
               Sessions.lookup(@limit_instance, "other-id")
    end
  end

  # A `Mcp-Session-Id` header that is not a valid session id is a defect
  # of the client (or a forged value): the answer is `400` for POST, GET
  # and DELETE and the bad id never reaches the snapshot store.
  #
  describe "a malformed Mcp-Session-Id header" do
    @syntax_instance Module.concat(Servers.Default, "SessionIdSyntax")

    setup do
      Utils.start_instance(Servers.Default,
        name: @syntax_instance,
        session_snapshot: PersistentSnapshot
      )

      :ok
    end

    for bad <- ["", String.duplicate("a", 129), "a b", "ab\x7F", "é"] do
      test "a session id of #{inspect(bad)} gets 400 for POST, GET and DELETE" do
        bad = unquote(bad)

        post =
          post_json_rpc(1, "ping")
          |> put_session_header(bad)
          |> call_router_with([], @syntax_instance)

        assert post.status == 400
        assert decode_resp(post) == json_rpc_error(1, -32600, "invalid session id")

        get =
          conn(:get, "/")
          |> put_req_header("accept", "text/event-stream")
          |> put_session_header(bad)
          |> call_router_with([], @syntax_instance)

        assert get.status == 400
        assert decode_resp(get) == json_rpc_error(-32600, "invalid session id")

        delete =
          conn(:delete, "/")
          |> put_session_header(bad)
          |> call_router_with([], @syntax_instance)

        assert delete.status == 400
        assert decode_resp(delete) == json_rpc_error(-32600, "invalid session id")
      end
    end

    test "two Mcp-Session-Id headers get 400" do
      conn = post_json_rpc(1, "ping")

      conn = %{
        conn
        | req_headers: [
            {"mcp-session-id", "one"},
            {"mcp-session-id", "two"} | conn.req_headers
          ]
      }

      conn = call_router_with(conn, [], @syntax_instance)

      assert conn.status == 400
      assert decode_resp(conn) == json_rpc_error(1, -32600, "invalid session id")
    end

    test "an initialize with an empty Mcp-Session-Id header gets 400" do
      conn =
        post_json_rpc(1, "initialize", %{
          "protocolVersion" => "2025-11-25",
          "clientInfo" => %{"name" => "test-client", "version" => "1.0.0"}
        })
        |> put_session_header("")
        |> call_router_with([], @syntax_instance)

      assert conn.status == 400

      assert decode_resp(conn) ==
               json_rpc_error(1, -32600, "cannot call initialize and provide a mcp session id")
    end

    test "a bad id reaches no snapshot store and the body does not echo the id" do
      bad = String.duplicate("a", 129)

      conn =
        post_json_rpc(1, "ping")
        |> put_session_header(bad)
        |> call_router_with([], @syntax_instance)

      assert conn.status == 400
      refute conn.resp_body =~ bad
      assert PersistentSnapshot.calls(@syntax_instance, :load) == 0
    end
  end

  # The DELETE of an open server runs the restore stage: a session that
  # is only in the snapshot store starts again and the DELETE ends it.
  # The end of the session deletes the snapshot.
  #
  describe "the DELETE of a session that is only in the snapshot store" do
    @snapshot_instance Module.concat(Servers.Default, "DeleteSnapshot")
    @restored_id "restored-id"

    setup do
      Utils.start_instance(Servers.Default,
        name: @snapshot_instance,
        session_snapshot: PersistentSnapshot
      )

      PersistentSnapshot.put(@snapshot_instance, @restored_id, restored_snapshot())
      :ok
    end

    test "the DELETE of an open server ends it and deletes the snapshot" do
      conn =
        conn(:delete, "/")
        |> put_session_header(@restored_id)
        |> call_router_with([], @snapshot_instance)

      assert conn.status == 200
      assert PersistentSnapshot.get(@snapshot_instance, @restored_id) == nil

      # The session is gone: a second DELETE gets 404.
      #
      conn =
        conn(:delete, "/")
        |> put_session_header(@restored_id)
        |> call_router_with([], @snapshot_instance)

      assert conn.status == 404
      assert decode_resp(conn) == json_rpc_error(-32001, "invalid session")
    end
  end

  defp call_router(conn, server \\ inst(Servers.Default)) do
    conn
    |> put_req_header("origin", @cors_origin)
    |> OzMcp.Router.call(OzMcp.Router.init(server: server, allowed_origins: [@cors_origin]))
  end

  defp call_router_with(conn, allowed_origins, server \\ inst(Servers.Default)) do
    OzMcp.Router.call(conn, OzMcp.Router.init(server: server, allowed_origins: allowed_origins))
  end

  defp error_context(conn, error_code, rpc_id \\ nil, headers \\ []) do
    conn = put_private(conn, :cors_origin, @cors_origin)

    OzMcp.Context.new(inst(Servers.Default), :http_streamable, :rpc)
    |> Map.put(:conn, conn)
    |> Map.put(:rpc_id, rpc_id)
    |> OzMcp.Context.put_error(error_code, nil, headers)
  end

  defp decode_resp(conn), do: :json.decode(conn.resp_body)

  defp post_json_rpc(id, method, params \\ %{}) do
    #
    # Wire writes a JSON null for nil: the OTP encoder would write
    # the string "nil".
    #
    body =
      %{"jsonrpc" => "2.0", "params" => params}
      |> maybe_json_rpc_id(id)
      |> maybe_json_rpc_method(method)
      |> Utils.encode_json()

    post_raw(body)
  end

  defp post_raw(body) do
    conn(:post, "/", body)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json, text/event-stream")
  end

  defp maybe_json_rpc_id(struct, id) when is_binary(id) or is_integer(id) do
    Map.put(struct, "id", id)
  end

  defp maybe_json_rpc_id(struct, _id), do: struct

  defp maybe_json_rpc_method(struct, nil), do: struct

  defp maybe_json_rpc_method(struct, method) do
    Map.put(struct, "method", method)
  end

  defp json_rpc_result(id, result) do
    %{"jsonrpc" => "2.0", "result" => result}
    |> maybe_json_rpc_id(id)
  end

  defp json_rpc_error(id, code, message) do
    %{"jsonrpc" => "2.0", "error" => %{"code" => code, "message" => message}}
    |> maybe_json_rpc_id(id)
  end

  defp json_rpc_error(id, code, message, data) do
    %{
      "jsonrpc" => "2.0",
      "error" => %{"code" => code, "message" => message, "data" => data}
    }
    |> maybe_json_rpc_id(id)
  end

  defp json_rpc_error(code, message) do
    %{"jsonrpc" => "2.0", "error" => %{"code" => code, "message" => message}}
  end

  # The data of a replayed error of `tasks/result`.
  #
  defp related_task_meta(task_id) do
    %{"_meta" => %{"io.modelcontextprotocol/related-task" => %{"taskId" => task_id}}}
  end

  defp assert_cors_headers(conn) do
    headers = Enum.into(conn.resp_headers, %{})
    assert headers["access-control-allow-origin"] == @cors_origin
    assert headers["vary"] == "Origin"

    # An answer with no body carries no content-type: there is no body to
    # describe. A HEAD answer keeps the content-type of the body the GET
    # would carry. A JSON answer carries the JSON media type.
    #
    if conn.resp_body == "" and conn.method != "HEAD" do
      refute Map.has_key?(headers, "content-type")
    else
      assert String.contains?(headers["content-type"], "application/json")
      assert String.contains?(headers["content-type"], "charset=UTF-8")
    end
  end

  defp put_session_header(conn, session_id) do
    put_req_header(conn, "mcp-session-id", session_id)
  end

  defp put_session_version(server, session_id, version) do
    :ok = OzMcp.Session.update_view(server, session_id, protocol_version: version)
    version
  end

  defp normalize_map_keys_to_string(data) do
    data
    |> :json.encode()
    |> IO.iodata_to_binary()
    |> :json.decode()
  end

  defp wait_for_stream(server, session_id, pid),
    do: Utils.wait_for_stream(server, session_id, pid)

  # The ids of the message events of a GET stream body. The priming event
  # carries no `event: message` line and no data: it is not counted.
  #
  defp extract_event_ids(resp_body) do
    Regex.scan(~r/^id: (g\.[A-Za-z0-9]+:\d+)\nevent: message$/m, resp_body,
      capture: :all_but_first
    )
    |> List.flatten()
  end

  # The ids of the message events of a stream body, whatever the shape of
  # the id (the events of a POST stream carry a colon but no dot).
  #
  defp extract_message_event_ids(resp_body) do
    Regex.scan(~r/^id: (\S+)\nevent: message$/m, resp_body, capture: :all_but_first)
    |> List.flatten()
  end

  # The id of the priming event at the start of a GET stream body.
  #
  defp extract_priming_id(resp_body) do
    case Regex.run(
           ~r/\Aretry: \d+\n\nid: (g\.[A-Za-z0-9]+:0)\ndata: \n\n/,
           resp_body,
           capture: :all_but_first
         ) do
      [id] -> id
      _ -> flunk("no priming event at the start of the stream body")
    end
  end

  # Opens a GET stream in a helper process, lets it register, ends it and
  # returns the connection (its body holds the retry and priming chunks).
  #
  defp open_and_close_sse(server, session_id, last_event_id) do
    requester = spawn_sse(session_id, last_event_id)

    wait_for_stream(server, session_id, requester)
    Utils.terminate_stream(server, session_id, requester)
    assert_receive {:sse_conn, conn}, 5_000
    conn
  end

  # The same for a server in polling mode (`sse_max_stream_ms`): the stream
  # closes itself, so the test must not wait for it to be open and must not
  # end it. It waits for the connection that the close returns.
  #
  defp open_polling_sse(session_id, last_event_id) do
    spawn_sse(session_id, last_event_id)
    assert_receive {:sse_conn, conn}, 5_000
    conn
  end

  defp spawn_sse(session_id, last_event_id) do
    parent = self()

    spawn(fn ->
      base = conn(:get, "/") |> put_req_header("accept", "text/event-stream")

      conn =
        if last_event_id do
          put_req_header(base, "last-event-id", last_event_id)
        else
          base
        end
        |> put_session_header(session_id)
        |> call_router()

      send(parent, {:sse_conn, conn})
    end)
  end

  defp wait_for_stream_gone(server, session_id, pid),
    do: Utils.wait_for_stream_gone(server, session_id, pid)

  defp wait_until(fun, retries \\ 1_500) do
    if Utils.eventually(fun, retries * 10) do
      :ok
    else
      flunk("condition was not met in time")
    end
  end

  # -----------------------------------------------------------------
  # MCP Tasks helpers
  # -----------------------------------------------------------------

  defp create_task_via_router(session_id, tool_name, task_meta \\ %{}, rpc_id \\ 1) do
    conn =
      post_json_rpc(rpc_id, "tools/call", %{"name" => tool_name, "task" => task_meta})
      |> put_session_header(session_id)
      |> call_router(@task_server)

    assert %{"task" => %{"taskId" => task_id}} = decode_resp(conn)["result"]
    task_id
  end

  # Resets the stale runner pid first: :persistent_term outlives the previous
  # test's runner, so wait_for_slow_runner/1 must wait for THIS run.
  #
  defp create_slow_task_via_router(session_id) do
    Support.Entities.Tools.TaskSlowTest.reset()
    create_task_via_router(session_id, "task_slow")
  end

  # Starts a synchronous tools/call of the slow tool in a separate process,
  # which reports the response conn back as {:call_conn, rpc_id, conn}.
  #
  defp start_slow_call(session_id, rpc_id) do
    Support.Entities.Tools.TaskSlowTest.reset()
    parent = self()

    spawn_link(fn ->
      conn =
        post_json_rpc(rpc_id, "tools/call", %{"name" => "task_slow"})
        |> put_session_header(session_id)
        |> call_router(@task_server)

      send(parent, {:call_conn, rpc_id, conn})
    end)
  end

  # Starts a blocking tasks/result in a separate process, which reports the
  # response conn back as {:result_conn, rpc_id, conn}.
  #
  defp start_tasks_result(session_id, task_id, rpc_id) do
    parent = self()

    # The conn is built here, so the test process owns it: the adapter
    # sends `{:plug_conn, :sent}` to it when the response is upgraded to a
    # stream or sent.
    #
    conn =
      post_json_rpc(rpc_id, "tasks/result", %{"taskId" => task_id})
      |> put_session_header(session_id)

    spawn_link(fn ->
      conn = call_router(conn, @task_server)
      send(parent, {:result_conn, rpc_id, conn})
    end)
  end

  # -----------------------------------------------------------------
  # Requests of the server to the client
  # -----------------------------------------------------------------

  # Posts the JSON-RPC response of the client (`fields` has the id and the
  # result or the error).
  #
  defp post_client_response(session_id, fields) do
    body = %{"jsonrpc" => "2.0"} |> Map.merge(fields) |> :json.encode() |> IO.iodata_to_binary()

    post_raw(body)
    |> put_session_header(session_id)
    |> call_router(@task_server)
  end

  # What a callback of the request `request_id` does: ping the client and
  # wait for the answer.
  #
  defp start_outbound_ping(session_id, opts \\ []) do
    {request_id, opts} = Keyword.pop(opts, :request_id)

    ctx = %{
      instance: @task_server,
      server: @task_server,
      session_id: session_id,
      request_id: request_id
    }

    Task.async(fn -> OzMcp.Outbound.ping(ctx, opts) end)
  end

  defp wait_for_pending_request(session_id) do
    wait_until(fn -> SessionProbe.pending_outbound_ids(@task_server, session_id) != [] end)
    assert [id] = SessionProbe.pending_outbound_ids(@task_server, session_id)
    id
  end

  # The JSON messages carried by the events of an SSE body.
  #
  defp sse_messages(body) do
    body
    |> String.split("\n\n", trim: true)
    |> Enum.flat_map(fn event ->
      #
      # The priming event has an id and no data: it carries no message.
      #
      case Regex.run(~r/^data: (.+)$/m, event, capture: :all_but_first) do
        [data] -> [:json.decode(data)]
        nil -> []
      end
    end)
  end

  defp post_cancelled(session_id, request_id, reason) do
    params =
      %{"requestId" => request_id}
      |> then(fn params -> if reason, do: Map.put(params, "reason", reason), else: params end)

    post_json_rpc(nil, "notifications/cancelled", params)
    |> put_session_header(session_id)
    |> call_router(@task_server)
  end

  defp rpc_tasks_get(session_id, task_id, rpc_id \\ 2, server \\ @task_server) do
    post_json_rpc(rpc_id, "tasks/get", %{"taskId" => task_id})
    |> put_session_header(session_id)
    |> call_router(server)
    |> decode_resp()
  end

  defp rpc_tasks_result(session_id, task_id, rpc_id \\ 3, server \\ @task_server) do
    post_json_rpc(rpc_id, "tasks/result", %{"taskId" => task_id})
    |> put_session_header(session_id)
    |> call_router(server)
  end

  defp poll_until_status(session_id, task_id, expected) do
    assert Utils.eventually(
             fn ->
               match?(%{"result" => %{"status" => ^expected}}, rpc_tasks_get(session_id, task_id))
             end,
             2_000
           )

    :ok
  end

  defp wait_for_slow_runner do
    assert Utils.eventually(fn ->
             Support.Entities.Tools.TaskSlowTest.last_runner_pid() != nil
           end)

    Support.Entities.Tools.TaskSlowTest.last_runner_pid()
  end

  # The request of `tasks/result` parked: the process of the task holds
  # the stream that it attached.
  #
  defp waiter_registered?(task_id) do
    case Registry.lookup(OzMcp.Instance.names(@task_server), {:task, task_id}) do
      [{pid, _}] ->
        #
        # The process of the task can end between the lookup and the read
        # of its state: the poll takes it as not parked yet.
        #
        try do
          match?({_state, %{streams: [_ | _]}}, :sys.get_state(pid))
        catch
          :exit, _ -> false
        end

      _ ->
        false
    end
  end

  # A tools/call that streams: a helper process posts the request and
  # sends the conn when the call is over.
  #
  defp start_call(server, session_id, rpc_id) do
    parent = self()

    spawn(fn ->
      conn =
        post_json_rpc(rpc_id, "tools/call", %{"name" => "outbound", "arguments" => %{}})
        |> put_session_header(session_id)
        |> call_router(server)

      send(parent, {:call_conn, rpc_id, conn})
    end)
  end

  defp wait_for_pending(server, session_id) do
    wait_until(fn -> SessionProbe.pending_outbound_ids(server, session_id) != [] end)
    assert [id] = SessionProbe.pending_outbound_ids(server, session_id)
    id
  end

  # Waits until the log of the session holds an event of a POST stream (an
  # id with a colon) and returns the first one.
  #
  defp wait_for_post_event(server, session_id) do
    wait_until(fn ->
      {:ok, events} = SessionProbe.events_after(server, session_id, "none")
      Enum.any?(events, fn {id, _} -> String.contains?(id, ":") end)
    end)

    {:ok, events} = SessionProbe.events_after(server, session_id, "none")
    Enum.find(events, fn {id, _} -> String.contains?(id, ":") end)
  end

  # Waits until the session holds a resumer for the POST stream. The attach
  # of the resumer is one step in the session: when the state shows it, the
  # takeover message has gone to the owner and the test can act on the
  # session without a race.
  #
  defp wait_for_resumer(server, session_id, stream_id) do
    wait_until(fn ->
      case Utils.session_data(server, session_id) do
        nil -> false
        data -> match?(%{resumer: pid} when is_pid(pid), data.streams[stream_id])
      end
    end)
  end

  defp post_response(server, session_id, fields) do
    body =
      %{"jsonrpc" => "2.0"}
      |> Map.merge(fields)
      |> :json.encode()
      |> IO.iodata_to_binary()

    post_raw(body)
    |> put_session_header(session_id)
    |> call_router(server)
  end

  defp listed(server, kind) do
    server
    |> OzMcp.Catalog.build!()
    |> OzMcp.Catalog.ordered(kind)
    |> Map.fetch!(:pairs)
    |> Enum.map(&elem(&1, 0))
  end
end
