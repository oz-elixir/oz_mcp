#
# Router level tests of the authentication step: a server with an
# authorization block refuses a request with no valid token before its
# body is read and the challenge travels in the WWW-Authenticate header.
#
defmodule OzMcp.RouterAuthTest do
  #
  # Sync: the tests set flags in :persistent_term and change the state of the Support.Auth.Default verifier.
  #
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias OzMcp.Session
  alias OzMcp.Sessions
  alias OzMcp.Tasks
  alias OzMcp.Utils.Paginate
  alias Support.Helpers.PersistentSnapshot
  alias Support.Helpers.Utils
  alias Support.Servers

  require Support.Factories.Tool

  # The instance that serves a server module in this file.
  #
  defp inst(module), do: Module.concat(module, __MODULE__)

  @resource_url "https://mcp.example.com/mcp"
  @metadata_url "https://mcp.example.com/.well-known/oauth-protected-resource/mcp"

  @initialize_params %{
    "protocolVersion" => "2025-11-25",
    "clientInfo" => %{"name" => "test-client", "version" => "1.0.0"}
  }

  setup context do
    Support.Auth.Default.reset()

    # Per-test server opts hook (`@tag task_opts:`), used e.g. to run the
    # stream tests with a short poll time.
    #
    task_opts = Map.get(context, :task_opts, %{})

    Utils.start_instances(
      [
        {Servers.Authorized, Map.merge(%{resource_url: @resource_url}, task_opts)},
        {Servers.AuthorizedBroken, Map.merge(%{resource_url: @resource_url}, task_opts)},
        {Servers.AuthorizedIsolation, Map.merge(%{resource_url: @resource_url}, task_opts)},
        {Servers.Scoped, Map.merge(%{resource_url: @resource_url}, task_opts)},
        {Servers.ScopedPaginated, Map.merge(%{resource_url: @resource_url}, task_opts)},
        {Servers.Counting, Map.merge(%{resource_url: @resource_url}, task_opts)},
        {Servers.StructScoped, Map.merge(%{resource_url: @resource_url}, task_opts)}
      ],
      __MODULE__,
      allowed_origins: []
    )

    :ok
  end

  describe "requests with no usable credential" do
    test "no authorization header: 401 with the challenge and the default scopes" do
      conn =
        post_json_rpc(1, "initialize", @initialize_params)
        |> call_router()

      assert conn.status == 401

      assert header(conn, "www-authenticate") ==
               ~s(Bearer scope="files:read", resource_metadata="#{@metadata_url}")

      assert decode_resp(conn) == json_rpc_error(-32010, "unauthorized")
    end

    test "a Basic header is no credential: 401 like no header" do
      conn =
        post_json_rpc(1, "initialize", @initialize_params)
        |> put_req_header("authorization", "Basic dXNlcjpwYXNz")
        |> call_router()

      assert conn.status == 401

      assert header(conn, "www-authenticate") ==
               ~s(Bearer scope="files:read", resource_metadata="#{@metadata_url}")
    end

    test "a token in the query string only is never read: 401" do
      conn =
        post_json_rpc(1, "initialize", @initialize_params)
        |> put_query_token("alice-token")
        |> call_router()

      assert conn.status == 401
    end

    test "a big unparseable body with no token: 401, the parser never runs" do
      #
      # If the body was parsed, Plug.Parsers would raise and the client
      # would receive the parse error with a 400. The 401 proves the
      # authentication step answered first.
      #
      conn =
        conn(:post, "/", String.duplicate("{", 100_000))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "application/json, text/event-stream")
        |> call_router()

      assert conn.status == 401
      assert decode_resp(conn) == json_rpc_error(-32010, "unauthorized")
    end

    test "a POST with no Content-Type and no token: 401, before the media check" do
      conn =
        conn(:post, "/", "{}")
        |> put_req_header("accept", "application/json, text/event-stream")
        |> call_router()

      assert conn.status == 401
      assert decode_resp(conn) == json_rpc_error(-32010, "unauthorized")
    end
  end

  describe "requests with a bad credential" do
    test "an unknown token: 401 with error=invalid_token" do
      conn =
        post_json_rpc(1, "initialize", @initialize_params)
        |> put_bearer("no-such-token")
        |> call_router()

      assert conn.status == 401

      challenge = header(conn, "www-authenticate")
      assert challenge =~ ~s(error="invalid_token")
      assert challenge =~ ~s(error_description="unknown token")
      assert challenge =~ ~s(scope="files:read")
      assert challenge =~ ~s(resource_metadata="#{@metadata_url}")

      assert decode_resp(conn) == json_rpc_error(-32010, "unauthorized")
    end

    test "a malformed token: 400 with error=invalid_request" do
      conn =
        post_json_rpc(1, "initialize", @initialize_params)
        |> put_bearer("abc def")
        |> call_router()

      assert conn.status == 400

      challenge = header(conn, "www-authenticate")
      assert challenge =~ ~s(error="invalid_request")
      assert challenge =~ ~s(resource_metadata="#{@metadata_url}")

      assert decode_resp(conn) == json_rpc_error(-32600, "malformed authorization")
    end

    test "an expired principal gets 401 on POST, GET and DELETE" do
      Support.Auth.Default.expire_at("alice-token", System.system_time(:second) - 10)
      on_exit(fn -> Support.Auth.Default.reset() end)

      for request <- [
            post_json_rpc(1, "initialize", @initialize_params),
            get_stream(),
            delete_session()
          ] do
        conn = request |> put_bearer("alice-token") |> call_router()

        assert conn.status == 401

        challenge = header(conn, "www-authenticate")
        assert challenge =~ ~s(error="invalid_token")
        assert challenge =~ ~s(error_description="token expired")

        assert decode_resp(conn) == json_rpc_error(-32010, "unauthorized")
      end
    end

    test "a token for another audience gets 401 on POST, GET and DELETE" do
      for request <- [
            post_json_rpc(1, "initialize", @initialize_params),
            get_stream(),
            delete_session()
          ] do
        conn = request |> put_bearer("other-audience") |> call_router()

        assert conn.status == 401

        challenge = header(conn, "www-authenticate")
        assert challenge =~ ~s(error="invalid_token")
        assert challenge =~ ~s(error_description="token audience mismatch")
        assert challenge =~ ~s(scope="files:read")
        assert challenge =~ ~s(resource_metadata="#{@metadata_url}")

        assert decode_resp(conn) == json_rpc_error(-32010, "unauthorized")
      end
    end

    test "a principal without audiences gets 401 and the warning is written once" do
      flag = {OzMcp.Auth.Gate, inst(Servers.Authorized), :missing_audiences}
      :persistent_term.erase(flag)
      on_exit(fn -> :persistent_term.erase(flag) end)

      log =
        Utils.capture_log([level: :warning], fn ->
          for _ <- 1..2 do
            conn =
              post_json_rpc(1, "initialize", @initialize_params)
              |> put_bearer("no-audience")
              |> call_router()

            assert conn.status == 401

            assert header(conn, "www-authenticate") =~
                     ~s(error_description="token audience mismatch")
          end
        end)

      assert log =~ "returned a principal without audiences"
      assert log |> String.split("\n") |> Enum.count(&String.contains?(&1, "[warning]")) == 1
    end

    test "a token with the audience in upper case gets 200" do
      conn =
        post_json_rpc(1, "initialize", @initialize_params)
        |> put_bearer("upper-audience")
        |> call_router()

      assert conn.status == 200
      assert decode_resp(conn)["error"] == nil
    end

    test "a server with audience_check false accepts a token for another audience" do
      Utils.stop_instances()

      Utils.start_instances(
        [{Servers.AuthorizedLocalhost, %{resource_url: @resource_url}}],
        __MODULE__,
        allowed_origins: []
      )

      for token <- ["other-audience", "no-audience"] do
        conn =
          post_json_rpc(1, "initialize", @initialize_params)
          |> put_bearer(token)
          |> call_router(inst(Servers.AuthorizedLocalhost))

        assert conn.status == 200
        assert decode_resp(conn)["error"] == nil
      end
    end
  end

  describe "requests with a valid token" do
    test "initialize creates the session and the response holds no token" do
      conn =
        post_json_rpc(1, "initialize", @initialize_params)
        |> put_bearer("alice-token")
        |> call_router()

      assert conn.status == 200
      assert [session_id] = get_resp_header(conn, "mcp-session-id")
      assert byte_size(session_id) > 0

      refute conn.resp_body =~ "alice-token"
      assert decode_resp(conn)["error"] == nil
    end

    test "a token with a huge expiry gets 200 on POST" do
      Support.Auth.Default.expire_at("alice-token", 1.0e308)
      on_exit(fn -> Support.Auth.Default.reset() end)

      conn =
        post_json_rpc(1, "initialize", @initialize_params)
        |> put_bearer("alice-token")
        |> call_router()

      assert conn.status == 200
      assert decode_resp(conn)["error"] == nil
    end

    test "GET without a session passes the gate and gets the session error" do
      conn =
        conn(:get, "/")
        |> put_req_header("accept", "text/event-stream")
        |> put_bearer("alice-token")
        |> call_router()

      assert conn.status == 400
      assert decode_resp(conn) == json_rpc_error(-32600, "missing session id")
    end

    test "DELETE without a session passes the gate and gets the session error" do
      conn =
        conn(:delete, "/")
        |> put_bearer("alice-token")
        |> call_router()

      assert conn.status == 400
      assert decode_resp(conn) == json_rpc_error(-32600, "missing session id")
    end

    test "a POST with no Content-Type and a valid token: 415" do
      conn =
        conn(:post, "/", "{}")
        |> put_bearer("alice-token")
        |> put_req_header("accept", "application/json, text/event-stream")
        |> call_router()

      assert conn.status == 415
      assert decode_resp(conn) == json_rpc_error(-32600, "content type must be application/json")
    end
  end

  describe "the size limit of the bearer token" do
    test "a token over the default limit gives 400 invalid_request" do
      conn =
        post_json_rpc(1, "initialize", @initialize_params)
        |> put_bearer(String.duplicate("a", 9000))
        |> call_router()

      assert conn.status == 400
      assert header(conn, "www-authenticate") =~ ~s(error="invalid_request")
    end

    test "a header with no token after the scheme is no credential: 401 without an error parameter" do
      conn =
        post_json_rpc(1, "initialize", @initialize_params)
        |> put_req_header("authorization", "Bearer ")
        |> call_router()

      assert conn.status == 401

      challenge = header(conn, "www-authenticate")
      assert challenge =~ ~s(resource_metadata="#{@metadata_url}")
      refute challenge =~ "error="
    end

    test "a token over the limit of the server gives 400 invalid_request" do
      restart_runtime(max_token_bytes: 100)

      conn =
        post_json_rpc(1, "initialize", @initialize_params)
        |> put_bearer(String.duplicate("a", 101))
        |> call_router()

      assert conn.status == 400

      challenge = header(conn, "www-authenticate")
      assert challenge =~ ~s(error="invalid_request")
      assert challenge =~ ~s(error_description="token too long")
    end

    test "a token at the limit of the server reaches the verifier" do
      restart_runtime(max_token_bytes: 100)

      conn =
        post_json_rpc(1, "initialize", @initialize_params)
        |> put_bearer(String.duplicate("a", 100))
        |> call_router()

      assert conn.status == 401
      assert header(conn, "www-authenticate") =~ ~s(error="invalid_token")
    end

    test "a raised limit lets a long token reach the verifier" do
      restart_runtime(max_token_bytes: 16_384)

      conn =
        post_json_rpc(1, "initialize", @initialize_params)
        |> put_bearer(String.duplicate("a", 9000))
        |> call_router()

      assert conn.status == 401
      assert header(conn, "www-authenticate") =~ ~s(error="invalid_token")
    end
  end

  describe "a refused initialize" do
    @refused_params %{
      "protocolVersion" => "2025-11-25",
      "clientInfo" => %{"name" => "refused-client", "version" => "1.0.0"}
    }

    @crash_params %{
      "protocolVersion" => "2025-11-25",
      "clientInfo" => %{"name" => "crash-client", "version" => "1.0.0"}
    }

    test "answers 403 with the scope challenge, no session header, no new session" do
      before = Utils.session_count(inst(Servers.Authorized))

      conn =
        post_json_rpc(1, "initialize", @refused_params)
        |> put_bearer("alice-token")
        |> call_router()

      assert conn.status == 403
      assert get_resp_header(conn, "mcp-session-id") == []

      challenge = header(conn, "www-authenticate")
      assert challenge =~ ~s(error="insufficient_scope")
      assert challenge =~ ~s(scope="files:read files:admin")

      assert Utils.session_count(inst(Servers.Authorized)) ==
               before
    end

    test "a crash of authorize/3 answers 500, no session header, no new session" do
      before = Utils.session_count(inst(Servers.Authorized))

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          conn =
            post_json_rpc(1, "initialize", @crash_params)
            |> put_bearer("alice-token")
            |> call_router()

          assert conn.status == 500
          assert get_resp_header(conn, "mcp-session-id") == []
          assert decode_resp(conn)["id"] == 1
          assert decode_resp(conn)["error"] == internal_error()
        end)

      assert log =~ "authorize/3 failed"

      assert Utils.session_count(inst(Servers.Authorized)) ==
               before
    end

    test "a refused initialize with a session header is still refused: 403" do
      before = Utils.session_count(inst(Servers.Authorized))

      conn =
        post_json_rpc(1, "initialize", @refused_params)
        |> put_bearer("alice-token")
        |> put_session_id("abc")
        |> call_router()

      assert conn.status == 403

      challenge = header(conn, "www-authenticate")
      assert challenge =~ ~s(error="insufficient_scope")

      assert get_resp_header(conn, "mcp-session-id") == []

      assert Utils.session_count(inst(Servers.Authorized)) ==
               before
    end

    test "an allowed initialize with a session header keeps the 400 of the session check" do
      before = Utils.session_count(inst(Servers.Authorized))

      conn =
        post_json_rpc(1, "initialize", @initialize_params)
        |> put_bearer("alice-token")
        |> put_session_id("abc")
        |> call_router()

      assert conn.status == 400

      error = decode_resp(conn)["error"]
      assert error["code"] == -32600
      assert error["message"] == "cannot call initialize and provide a mcp session id"

      assert Utils.session_count(inst(Servers.Authorized)) ==
               before
    end

    test "an allowed initialize is unchanged: 200, one session header, one new session" do
      before = Utils.session_count(inst(Servers.Authorized))

      conn =
        post_json_rpc(1, "initialize", @initialize_params)
        |> put_bearer("alice-token")
        |> call_router()

      assert conn.status == 200
      assert [_session_id] = get_resp_header(conn, "mcp-session-id")

      assert Utils.session_count(inst(Servers.Authorized)) ==
               before + 1
    end

    test "no error answer of initialize carries a session header" do
      requests = %{
        "no token" => fn -> post_json_rpc(1, "initialize", @refused_params) end,
        "bad accept" => fn ->
          post_json_rpc(1, "initialize", @initialize_params)
          |> put_bearer("alice-token")
          |> put_req_header("accept", "application/json")
        end,
        "invalid params" => fn ->
          post_json_rpc(1, "initialize", %{"protocolVersion" => "2025-11-25"})
          |> put_bearer("alice-token")
        end,
        "refused scope" => fn ->
          post_json_rpc(1, "initialize", @refused_params) |> put_bearer("alice-token")
        end,
        "crash" => fn ->
          post_json_rpc(1, "initialize", @crash_params) |> put_bearer("alice-token")
        end
      }

      statuses = %{
        "no token" => 401,
        "bad accept" => 406,
        "invalid params" => 200,
        "refused scope" => 403,
        "crash" => 500
      }

      for {name, request} <- requests do
        ExUnit.CaptureLog.capture_log(fn ->
          conn = request.() |> call_router()

          assert conn.status == Map.fetch!(statuses, name), "case #{name}"
          assert get_resp_header(conn, "mcp-session-id") == [], "case #{name}"
        end)
      end
    end
  end

  describe "requests that never reach the gate" do
    test "OPTIONS with no token: 204, no challenge" do
      conn = conn(:options, "/") |> call_router()

      assert conn.status == 204
      assert header(conn, "www-authenticate") == nil
    end

    test "a bad origin with a valid token: 403" do
      conn =
        post_json_rpc(1, "initialize", @initialize_params)
        |> put_bearer("alice-token")
        |> put_req_header("origin", "https://evil.example")
        |> call_router()

      assert conn.status == 403
      assert conn.resp_body == ""
      assert header(conn, "www-authenticate") == nil
    end
  end

  describe "unsupported methods and the fail-closed order" do
    test "PUT / with no token: 401 with the challenge, the gate runs first" do
      conn = conn(:put, "/") |> call_router()

      assert conn.status == 401

      challenge = header(conn, "www-authenticate")
      assert challenge =~ ~s(scope="files:read")
      assert challenge =~ ~s(resource_metadata="#{@metadata_url}")

      assert decode_resp(conn) == json_rpc_error(-32010, "unauthorized")
    end

    test "PUT / with a valid token: 405 with the allow header" do
      conn = conn(:put, "/") |> put_bearer("alice-token") |> call_router()

      assert conn.status == 405
      assert get_resp_header(conn, "allow") == ["GET, POST, DELETE, OPTIONS"]
      assert decode_resp(conn) == json_rpc_error(-32600, "method not allowed")
    end

    test "a bad origin with PUT /: 403" do
      conn =
        conn(:put, "/")
        |> put_bearer("alice-token")
        |> put_req_header("origin", "https://evil.example")
        |> call_router()

      assert conn.status == 403
      assert conn.resp_body == ""
    end
  end

  describe "a defective verifier" do
    #
    # The log at level :error holds the type of the failure, never the
    # data of the application: the text of an exception is logged at
    # level :debug only, the value of a throw is never logged and an
    # exit reason is reduced to its tag.
    #
    @defeats %{
      "raise-token" => "authenticate/2 failed: raised RuntimeError",
      "throw-token" => "authenticate/2 failed: throw (the value is not logged)",
      "exit-token" => "authenticate/2 failed: exit :verifier_failure",
      "bad-value-token" => "returned an invalid value",
      "unknown-atom-token" =>
        "returned an invalid value: authenticate/2 returned the shortcut atom :not_a_challenge",
      "bogus-challenge-token" =>
        "returned an invalid value: authenticate/2 returned a challenge with an unknown error: :bogus"
    }

    test "a raise, a throw, an exit, or a bad value: 500 and the type of the failure is logged" do
      for {token, line} <- @defeats do
        log =
          Utils.capture_log([level: :error], fn ->
            conn =
              post_json_rpc(1, "initialize", @initialize_params)
              |> put_bearer(token)
              |> call_router(inst(Servers.AuthorizedBroken))

            assert conn.status == 500
            assert decode_resp(conn) == json_rpc_error(-32603, "internal server error")
          end)

        assert log =~ line
        refute log =~ "verifier failure"
      end
    end

    test "the caller is never authenticated and the response holds no token" do
      log =
        Utils.capture_log(fn ->
          conn =
            post_json_rpc(1, "initialize", @initialize_params)
            |> put_bearer("raise-token")
            |> call_router(inst(Servers.AuthorizedBroken))

          assert conn.status == 500
          refute conn.resp_body =~ "raise-token"
        end)

      refute log =~ "raise-token"
    end

    test "a challenge with an unknown error: 500, no challenge header, no session" do
      before =
        Utils.session_count(inst(Servers.AuthorizedBroken))

      log =
        ExUnit.CaptureLog.capture_log([level: :error], fn ->
          conn =
            post_json_rpc(1, "initialize", @initialize_params)
            |> put_bearer("bogus-challenge-token")
            |> call_router(inst(Servers.AuthorizedBroken))

          assert conn.status == 500
          assert header(conn, "www-authenticate") == nil
          assert get_resp_header(conn, "mcp-session-id") == []
          assert decode_resp(conn) == json_rpc_error(-32603, "internal server error")
        end)

      assert log =~ "unknown error: :bogus"

      assert Utils.session_count(inst(Servers.AuthorizedBroken)) ==
               before
    end

    test "a challenge with a description that is not a string: 500, no challenge header" do
      log =
        ExUnit.CaptureLog.capture_log([level: :error], fn ->
          conn =
            post_json_rpc(1, "initialize", @initialize_params)
            |> put_bearer("bad-description-token")
            |> call_router(inst(Servers.AuthorizedBroken))

          assert conn.status == 500
          assert header(conn, "www-authenticate") == nil
          assert get_resp_header(conn, "mcp-session-id") == []
          assert decode_resp(conn) == json_rpc_error(-32603, "internal server error")
        end)

      assert log =~ "a description that is not a string or nil"
    end

    test "a challenge with scopes that are not a list: 500, no challenge header" do
      log =
        ExUnit.CaptureLog.capture_log([level: :error], fn ->
          conn =
            post_json_rpc(1, "initialize", @initialize_params)
            |> put_bearer("bad-scopes-token")
            |> call_router(inst(Servers.AuthorizedBroken))

          assert conn.status == 500
          assert header(conn, "www-authenticate") == nil
          assert decode_resp(conn) == json_rpc_error(-32603, "internal server error")
        end)

      assert log =~ "with scopes that are not a list"
    end
  end

  describe "fail closed" do
    test "a server with the block that the runtime does not have: 503" do
      conn =
        post_json_rpc(1, "initialize", @initialize_params)
        |> put_bearer("alice-token")
        |> call_router(inst(Servers.AuthorizedLocalhost))

      assert conn.status == 503
      assert decode_resp(conn) == json_rpc_error(-32603, "server unavailable")
    end
  end

  @isolation_module Servers.AuthorizedIsolation

  @isolation Module.concat(@isolation_module, __MODULE__)
  @scoped_module Servers.Scoped
  @scoped Module.concat(@scoped_module, __MODULE__)
  @invalid_error %{"code" => -32001, "message" => "invalid session"}

  describe "the session belongs to its owner" do
    #
    # A snapshot of alice: bob must get the refusal of an unknown session
    # and no session process may start from the snapshot of another
    # principal.
    #
    @tag task_opts: %{session_snapshot: PersistentSnapshot}
    test "a snapshot of another principal gives 404 and starts no session" do
      import Plug.Test, only: [conn: 2]
      import Plug.Conn, only: [put_req_header: 3]

      assert @invalid_error["code"] == -32001
      sessions_before = Utils.session_count(@isolation)

      PersistentSnapshot.put(@isolation, "stored-id", %{
        principal_key: {"https://issuer.test", "alice"},
        protocol_version: "2025-11-25",
        client_info: %{"name" => "restore-test", "version" => "1"},
        client_capabilities: %{},
        log_level: nil,
        subscriptions: []
      })

      for request <- [
            post_json_rpc(2, "ping", %{}),
            conn(:get, "/") |> put_req_header("accept", "text/event-stream"),
            conn(:delete, "/")
          ] do
        log =
          ExUnit.CaptureLog.capture_log(fn ->
            conn =
              request
              |> put_bearer("bob-token")
              |> put_session_id("stored-id")
              |> call_router(@isolation)

            assert conn.status == 404, "method #{conn.method}"
            assert decode_resp(conn)["error"] == @invalid_error, "method #{conn.method}"
          end)

        assert log =~ "session owner mismatch"
        assert Utils.session_count(@isolation) == sessions_before
      end

      assert PersistentSnapshot.calls(@isolation, :load) == 3
    end

    # The subject is a name or an email: it is personal data. The log of
    # an owner mismatch keeps no subject and no session id.
    #
    test "the owner mismatch log holds no subject and no session id" do
      session_id = alice_session()
      token = Support.Auth.Default.register_token(subject: "alice@example.test")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          conn =
            post_json_rpc(2, "ping", %{})
            |> put_bearer(token)
            |> put_session_id(session_id)
            |> call_router(@isolation)

          assert conn.status == 404
          assert decode_resp(conn)["error"] == @invalid_error
        end)

      assert log =~ "session owner mismatch"
      refute log =~ "alice"
      refute log =~ session_id
    end

    @tag task_opts: %{max_sessions_per_principal: 1}
    test "a second initialize of one principal gets 429, another principal passes" do
      alice_session = alice_session()
      assert {:ok, _} = Session.open_stream(@isolation, alice_session, :get, self(), nil)

      conn =
        post_json_rpc(1, "initialize", @initialize_params)
        |> put_bearer("alice-token")
        |> call_router(@isolation)

      assert conn.status == 429
      assert get_resp_header(conn, "mcp-session-id") == []
      assert decode_resp(conn)["error"]["message"] == "too many sessions"

      conn =
        post_json_rpc(1, "initialize", @initialize_params)
        |> put_bearer("bob-token")
        |> call_router(@isolation)

      assert conn.status == 200
    end

    test "another principal cannot use the tools of the session" do
      session_id = alice_session()

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          conn =
            post_json_rpc(2, "tools/call", %{"name" => "get_time"})
            |> put_bearer("bob-token")
            |> put_session_id(session_id)
            |> call_router(@isolation)

          assert conn.status == 404
          assert decode_resp(conn)["error"] == @invalid_error
        end)

      assert log =~ "session owner mismatch"
    end

    test "another principal cannot ping the session and the session does not change" do
      session_id = alice_session()
      {:ok, view} = OzMcp.Sessions.lookup(@isolation, session_id)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          conn =
            post_json_rpc(2, "ping", %{})
            |> put_bearer("bob-token")
            |> put_session_id(session_id)
            |> call_router(@isolation)

          assert conn.status == 404
          assert decode_resp(conn)["error"] == @invalid_error
        end)

      assert log =~ "session owner mismatch"

      assert {:ok, ^view} = OzMcp.Sessions.lookup(@isolation, session_id)
    end

    test "the owner can ping the session" do
      session_id = alice_session()

      conn =
        post_json_rpc(2, "ping", %{})
        |> put_bearer("alice-token")
        |> put_session_id(session_id)
        |> call_router(@isolation)

      assert conn.status == 200
      assert decode_resp(conn) == %{"jsonrpc" => "2.0", "id" => 2, "result" => %{}}
    end

    test "the owner can ping a session that waits for notifications/initialized" do
      session_id = alice_session(initialized: false)

      conn =
        post_json_rpc(2, "ping", %{})
        |> put_bearer("alice-token")
        |> put_session_id(session_id)
        |> call_router(@isolation)

      assert conn.status == 200
      assert decode_resp(conn) == %{"jsonrpc" => "2.0", "id" => 2, "result" => %{}}
    end

    test "another principal cannot stream the session" do
      session_id = alice_session()

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          conn =
            conn(:get, "/")
            |> put_req_header("accept", "text/event-stream")
            |> put_bearer("bob-token")
            |> put_session_id(session_id)
            |> call_router(@isolation)

          assert conn.status == 404
          assert decode_resp(conn)["error"] == @invalid_error
        end)

      assert log =~ "session owner mismatch"
    end

    test "another principal cannot end the session" do
      session_id = alice_session()

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          conn =
            conn(:delete, "/")
            |> put_bearer("bob-token")
            |> put_session_id(session_id)
            |> call_router(@isolation)

          assert conn.status == 404
          assert decode_resp(conn)["error"] == @invalid_error
        end)

      assert log =~ "session owner mismatch"

      # The session is still there: Alice can end it herself.
      #
      conn =
        conn(:delete, "/")
        |> put_bearer("alice-token")
        |> put_session_id(session_id)
        |> call_router(@isolation)

      assert conn.status == 200
    end

    test "another principal cannot start the session" do
      session_id = alice_session(initialized: false)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          conn =
            post_notification("notifications/initialized")
            |> put_bearer("bob-token")
            |> put_session_id(session_id)
            |> call_router(@isolation)

          assert conn.status == 404
          assert decode_resp(conn)["error"] == @invalid_error
        end)

      assert log =~ "session owner mismatch"
    end

    test "the owner can send notifications/initialized twice" do
      session_id = alice_session(initialized: false)

      conn =
        post_notification("notifications/initialized")
        |> put_bearer("alice-token")
        |> put_session_id(session_id)
        |> call_router(@isolation)

      assert conn.status == 202

      conn =
        post_notification("notifications/initialized")
        |> put_bearer("alice-token")
        |> put_session_id(session_id)
        |> call_router(@isolation)

      assert conn.status == 202
      assert conn.resp_body == ""
    end

    test "another principal cannot send a duplicate notifications/initialized" do
      session_id = alice_session(initialized: false)

      conn =
        post_notification("notifications/initialized")
        |> put_bearer("alice-token")
        |> put_session_id(session_id)
        |> call_router(@isolation)

      assert conn.status == 202

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          conn =
            post_notification("notifications/initialized")
            |> put_bearer("bob-token")
            |> put_session_id(session_id)
            |> call_router(@isolation)

          assert conn.status == 404
          assert decode_resp(conn)["error"] == @invalid_error
        end)

      assert log =~ "session owner mismatch"
    end

    test "a foreign non-initialized session gets the answer of an unknown session" do
      session_id = alice_session(initialized: false)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          foreign =
            post_json_rpc(2, "tools/call", %{"name" => "get_time"})
            |> put_bearer("bob-token")
            |> put_session_id(session_id)
            |> call_router(@isolation)

          unknown =
            post_json_rpc(2, "tools/call", %{"name" => "get_time"})
            |> put_bearer("bob-token")
            |> put_session_id("no-such-session")
            |> call_router(@isolation)

          assert foreign.status == 404
          assert foreign.status == unknown.status
          assert foreign.resp_body == unknown.resp_body
        end)

      assert log =~ "session owner mismatch"
    end

    # The owner check runs before the compare of the protocol version:
    # a foreign principal gets the refusal of an unknown session, even
    # with a header that would not match the version of the session.
    #
    test "a foreign principal with a mismatching header gets the answer of an unknown session" do
      session_id = alice_session()
      put_session_version(@isolation, session_id, "2025-06-18")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          foreign =
            post_json_rpc(2, "tools/call", %{"name" => "get_time"})
            |> put_bearer("bob-token")
            |> put_session_id(session_id)
            |> put_req_header("mcp-protocol-version", "2025-11-25")
            |> call_router(@isolation)

          unknown =
            post_json_rpc(2, "tools/call", %{"name" => "get_time"})
            |> put_bearer("bob-token")
            |> put_session_id("no-such-session")
            |> put_req_header("mcp-protocol-version", "2025-11-25")
            |> call_router(@isolation)

          assert foreign.status == 404
          assert foreign.resp_body == unknown.resp_body
          assert decode_resp(foreign)["error"] == @invalid_error
        end)

      assert log =~ "session owner mismatch"
    end

    test "the owner still gets the answer waiting initialization" do
      session_id = alice_session(initialized: false)

      conn =
        post_json_rpc(2, "tools/call", %{"name" => "get_time"})
        |> put_bearer("alice-token")
        |> put_session_id(session_id)
        |> call_router(@isolation)

      assert conn.status == 200

      assert decode_resp(conn)["error"] == %{
               "code" => -32600,
               "message" => "waiting session initialization"
             }
    end

    test "GET of a foreign non-initialized session gets 404" do
      session_id = alice_session(initialized: false)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          conn =
            conn(:get, "/")
            |> put_req_header("accept", "text/event-stream")
            |> put_bearer("bob-token")
            |> put_session_id(session_id)
            |> call_router(@isolation)

          assert conn.status == 404
          assert decode_resp(conn)["error"] == @invalid_error
        end)

      assert log =~ "session owner mismatch"
    end

    test "another principal cannot subscribe a resource of the session" do
      session_id = alice_session()

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          conn =
            post_json_rpc(2, "resources/subscribe", %{"uri" => "file:///marketing.md"})
            |> put_bearer("bob-token")
            |> put_session_id(session_id)
            |> call_router(@isolation)

          assert conn.status == 404
          assert decode_resp(conn)["error"] == @invalid_error
        end)

      assert log =~ "session owner mismatch"
    end

    test "another principal cannot read the tasks of the session" do
      session_id = alice_session()

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          conn =
            post_json_rpc(2, "tasks/get", %{"taskId" => "task-of-alice"})
            |> put_bearer("bob-token")
            |> put_session_id(session_id)
            |> call_router(@isolation)

          assert conn.status == 404
          assert decode_resp(conn)["error"] == @invalid_error
        end)

      assert log =~ "session owner mismatch"
    end

    test "the session of alice is unchanged after the attempts of bob" do
      session_id = alice_session()

      ExUnit.CaptureLog.capture_log(fn ->
        for request <- [
              fn ->
                post_json_rpc(2, "tools/call", %{"name" => "get_time"})
                |> put_bearer("bob-token")
                |> put_session_id(session_id)
                |> call_router(@isolation)
              end,
              fn ->
                conn(:delete, "/")
                |> put_bearer("bob-token")
                |> put_session_id(session_id)
                |> call_router(@isolation)
              end
            ] do
          conn = request.()
          assert conn.status == 404
        end
      end)

      conn =
        post_json_rpc(3, "tools/call", %{"name" => "get_time"})
        |> put_bearer("alice-token")
        |> put_session_id(session_id)
        |> call_router(@isolation)

      assert conn.status == 200
      assert decode_resp(conn)["error"] == nil
    end

    test "a token with other scopes for the same subject keeps the session" do
      session_id = alice_session()

      conn =
        post_json_rpc(2, "tools/call", %{"name" => "get_time"})
        |> put_bearer("alice-admin")
        |> put_session_id(session_id)
        |> call_router(@isolation)

      assert conn.status == 200
      assert decode_resp(conn)["error"] == nil
    end
  end

  # The lookup of the entity runs after the session owner check: the
  # answer to a foreign principal must not depend on the entity that the
  # request names.
  #
  describe "the lookup of the entity runs after the session owner check" do
    test "a tools/call of a foreign session gets 404 for a known tool and for an unknown tool" do
      session_id = alice_session()

      ExUnit.CaptureLog.capture_log(fn ->
        known =
          post_json_rpc(2, "tools/call", %{"name" => "get_date"})
          |> put_bearer("bob-token")
          |> put_session_id(session_id)
          |> call_router(@isolation)

        unknown =
          post_json_rpc(2, "tools/call", %{"name" => "nope"})
          |> put_bearer("bob-token")
          |> put_session_id(session_id)
          |> call_router(@isolation)

        assert known.status == 404
        assert unknown.status == 404
        assert decode_resp(known) == decode_resp(unknown)
      end)
    end

    test "a resources/read of a foreign session gets 404 for a known uri and for an unknown uri" do
      session_id = alice_session()

      ExUnit.CaptureLog.capture_log(fn ->
        known =
          post_json_rpc(2, "resources/read", %{"uri" => "file:///marketing.md"})
          |> put_bearer("bob-token")
          |> put_session_id(session_id)
          |> call_router(@isolation)

        unknown =
          post_json_rpc(2, "resources/read", %{"uri" => "file:///nope.md"})
          |> put_bearer("bob-token")
          |> put_session_id(session_id)
          |> call_router(@isolation)

        assert known.status == 404
        assert unknown.status == 404
        assert decode_resp(known) == decode_resp(unknown)
      end)
    end

    test "a prompts/get of a foreign session gets 404 for a known prompt and for an unknown prompt" do
      session_id = scoped_session("alice-token")

      ExUnit.CaptureLog.capture_log(fn ->
        known =
          post_json_rpc(2, "prompts/get", %{"name" => "audit"})
          |> put_bearer("bob-token")
          |> put_session_id(session_id)
          |> call_router(@scoped)

        unknown =
          post_json_rpc(2, "prompts/get", %{"name" => "nope"})
          |> put_bearer("bob-token")
          |> put_session_id(session_id)
          |> call_router(@scoped)

        assert known.status == 404
        assert unknown.status == 404
        assert decode_resp(known) == decode_resp(unknown)
      end)
    end

    test "a completion/complete of a foreign session gets 404 for a known ref and for an unknown ref" do
      session_id = scoped_session("alice-token")

      params = fn name ->
        %{
          "ref" => %{"type" => "ref/prompt", "name" => name},
          "argument" => %{"name" => "query", "value" => "a"}
        }
      end

      ExUnit.CaptureLog.capture_log(fn ->
        known =
          post_json_rpc(2, "completion/complete", params.("audit"))
          |> put_bearer("bob-token")
          |> put_session_id(session_id)
          |> call_router(@scoped)

        unknown =
          post_json_rpc(2, "completion/complete", params.("nope"))
          |> put_bearer("bob-token")
          |> put_session_id(session_id)
          |> call_router(@scoped)

        assert known.status == 404
        assert unknown.status == 404
        assert decode_resp(known) == decode_resp(unknown)
      end)
    end
  end

  describe "a session limit per principal" do
    test "the second initialize of a principal gets 429, another principal passes" do
      Utils.stop_instances()

      Utils.start_instances(
        [
          {Servers.Authorized, %{resource_url: @resource_url, max_sessions_per_principal: 1}}
        ],
        __MODULE__,
        allowed_origins: []
      )

      conn =
        post_json_rpc(1, "initialize", @initialize_params)
        |> put_bearer("alice-token")
        |> call_router()

      assert conn.status == 200
      assert [session_id] = get_resp_header(conn, "mcp-session-id")

      assert {:ok, _} =
               Session.open_stream(
                 inst(Servers.Authorized),
                 session_id,
                 :get,
                 self(),
                 nil
               )

      conn =
        post_json_rpc(2, "initialize", @initialize_params)
        |> put_bearer("alice-token")
        |> call_router()

      assert conn.status == 429
      assert get_resp_header(conn, "mcp-session-id") == []
      assert decode_resp(conn) == json_rpc_error(2, -32000, "too many sessions")

      conn =
        post_json_rpc(3, "initialize", @initialize_params)
        |> put_bearer("bob-token")
        |> call_router()

      assert conn.status == 200
      assert [_session_id] = get_resp_header(conn, "mcp-session-id")
    end
  end

  describe "revocation by principal" do
    @alice_key {"https://issuer.test", "alice"}

    test "after terminate_sessions/2 the old session id gets 404, a new session works" do
      session_id = alice_session()

      assert {:ok, [^session_id]} =
               Sessions.terminate_principal(@isolation, @alice_key)

      conn =
        post_json_rpc(2, "tools/list", %{})
        |> put_bearer("alice-token")
        |> put_session_id(session_id)
        |> call_router(@isolation)

      assert conn.status == 404

      # The token is still valid: the application did not refuse it (step 1).
      #
      conn =
        post_json_rpc(3, "initialize", @initialize_params)
        |> put_bearer("alice-token")
        |> call_router(@isolation)

      assert conn.status == 200
    end

    test "refusing the token first and then ending the sessions: no new session" do
      session_id = alice_session()

      Support.Auth.Default.revoke("alice-token")
      on_exit(fn -> Support.Auth.Default.reset() end)

      assert {:ok, [^session_id]} =
               Sessions.terminate_principal(@isolation, @alice_key)

      conn =
        post_json_rpc(3, "initialize", @initialize_params)
        |> put_bearer("alice-token")
        |> call_router(@isolation)

      assert conn.status == 401
    end
  end

  describe "a GET stream and the expiry of the principal" do
    @alice_key {"https://issuer.test", "alice"}

    test "the stream ends with a retry event when the principal expires" do
      session_id = alice_session()
      Support.Auth.Default.expire_at("alice-token", System.system_time(:millisecond) / 1000 + 0.5)
      on_exit(fn -> Support.Auth.Default.reset() end)

      task = Task.async(fn -> open_stream("alice-token", session_id) end)

      # The stream ends by itself: no :terminate message is sent.
      #
      conn = Task.await(task, 30_000)

      assert conn.status == 200
      assert String.ends_with?(conn.resp_body, "retry: 1000\n\n")
    end

    test "the stream is no longer registered in the session after the expiry" do
      session_id = alice_session()
      Support.Auth.Default.expire_at("alice-token", System.system_time(:millisecond) / 1000 + 0.5)
      on_exit(fn -> Support.Auth.Default.reset() end)

      Task.async(fn -> open_stream("alice-token", session_id) end) |> Task.await(30_000)

      assert {:ok, %{stream?: false}} = Sessions.delivery(@isolation, session_id)
    end

    test "the session stays: a new stream with a fresh token is accepted" do
      session_id = alice_session()
      Support.Auth.Default.expire_at("alice-token", System.system_time(:millisecond) / 1000 + 0.5)
      on_exit(fn -> Support.Auth.Default.reset() end)

      Task.async(fn -> open_stream("alice-token", session_id) end) |> Task.await(30_000)

      # alice-admin is the same principal key with a fresh token.
      #
      task = Task.async(fn -> open_stream("alice-admin", session_id) end)
      refute Task.yield(task, 300)
      wait_for_stream(session_id)

      assert [stream_pid] = stream_pids(session_id)
      Utils.terminate_stream(@isolation, session_id, stream_pid)
      assert %Plug.Conn{status: 200} = Task.await(task, 30_000)
    end

    test "a principal with no expiry gets no timer: only the heartbeat runs" do
      session_id = alice_session()
      task = Task.async(fn -> open_stream("alice-token", session_id) end)

      refute Task.yield(task, 600)
      wait_for_stream(session_id)

      [stream_pid] = stream_pids(session_id)
      Utils.terminate_stream(@isolation, session_id, stream_pid)
      Task.await(task, 30_000)
    end

    test "an expiry far in the future does not raise and does not end the stream" do
      session_id = alice_session()
      Support.Auth.Default.expire_at("alice-token", System.system_time(:second) + 365 * 24 * 3600)
      on_exit(fn -> Support.Auth.Default.reset() end)

      task = Task.async(fn -> open_stream("alice-token", session_id) end)
      refute Task.yield(task, 300)
      wait_for_stream(session_id)

      [stream_pid] = stream_pids(session_id)
      Utils.terminate_stream(@isolation, session_id, stream_pid)
      Task.await(task, 30_000)
    end

    test "terminate_sessions/2 ends the open stream of the principal" do
      session_id = alice_session()
      task = Task.async(fn -> open_stream("alice-token", session_id) end)
      refute Task.yield(task, 200)
      wait_for_stream(session_id)

      assert {:ok, [^session_id]} = Sessions.terminate_principal(@isolation, @alice_key)

      conn = Task.await(task, 30_000)
      assert String.ends_with?(conn.resp_body, "retry: 1000\n\n")
    end

    # The stream runs in the Task process: the mailbox read happens there,
    # after a wait that is past the expiry time. An expiry message that
    # arrives after the stream ended is a timer that was not cancelled.
    #
    test "a stream that ends with :terminate leaves no expiry message" do
      session_id = alice_session()
      Support.Auth.Default.expire_at("alice-token", System.system_time(:millisecond) / 1000 + 1.0)
      on_exit(fn -> Support.Auth.Default.reset() end)

      task =
        Task.async(fn ->
          conn = open_stream("alice-token", session_id)

          receive do
            :report -> {conn, Process.info(self(), :messages)}
          end
        end)

      wait_for_stream(session_id)
      [stream_pid] = stream_pids(session_id)
      Utils.terminate_stream(@isolation, session_id, stream_pid)

      # Past the expiry time: an expiry timer that was not cancelled would
      # have fired by now. The wait is the check that the DOWN of the task
      # does not arrive while it holds the stream.
      #
      task_ref = Process.monitor(task.pid)
      refute_receive {:DOWN, ^task_ref, :process, _, _}, 1_300

      send(task.pid, :report)
      assert {%Plug.Conn{status: 200}, {:messages, messages}} = Task.await(task, 30_000)
      refute Enum.any?(messages, &match?({:principal_expired, _}, &1))
    end

    test "a stream that ends with a failed write leaves no expiry message" do
      session_id = alice_session()
      Support.Auth.Default.expire_at("alice-token", System.system_time(:millisecond) / 1000 + 1.0)
      on_exit(fn -> Support.Auth.Default.reset() end)

      task =
        Task.async(fn ->
          conn =
            conn(:get, "/")
            |> put_req_header("accept", "text/event-stream")
            |> put_bearer("alice-token")
            |> put_session_id(session_id)
            #
            # The two chunks of the start of the stream go out, then the
            # connection is closed: the next write fails.
            #
            |> Support.Helpers.AdapterClosed.wrap(2)
            |> call_router(@isolation)

          receive do
            :report -> {conn, Process.info(self(), :messages)}
          end
        end)

      wait_for_stream(session_id)
      [stream_pid] = stream_pids(session_id)

      # The stream ends with a write that fails: an event cannot reach the
      # closed connection.
      #
      [%{id: stream_id}] = Utils.session_streams(@isolation, session_id)
      send(stream_pid, {:oz_mcp_stream, stream_id, {:event, "x", "{}"}})

      # Past the expiry time: an expiry timer that was not cancelled would
      # have fired by now. The wait is the check that the DOWN of the task
      # does not arrive while it holds the stream.
      #
      task_ref = Process.monitor(task.pid)
      refute_receive {:DOWN, ^task_ref, :process, _, _}, 1_300

      send(task.pid, :report)
      assert {%Plug.Conn{status: 200}, {:messages, messages}} = Task.await(task, 30_000)
      refute Enum.any?(messages, &match?({:principal_expired, _}, &1))
    end

    test "a fresh stream whose first write fails leaves no expiry timer" do
      session_id = alice_session()
      Support.Auth.Default.expire_at("alice-token", System.system_time(:millisecond) / 1000 + 0.1)
      on_exit(fn -> Support.Auth.Default.reset() end)

      conn =
        conn(:get, "/")
        |> put_req_header("accept", "text/event-stream")
        |> put_bearer("alice-token")
        |> put_session_id(session_id)
        |> Support.Helpers.AdapterClosed.wrap(0)
        |> call_router(@isolation)

      assert conn.status == 200

      # Past the expiry time: a timer that was armed before the failed
      # write would have fired and left its message by now.
      #
      refute_receive {:principal_expired, _}, 300
    end

    test "a stray expiry message does not end a stream whose principal is not expired" do
      session_id = alice_session()
      Support.Auth.Default.expire_at("alice-token", System.system_time(:second) + 3600)
      on_exit(fn -> Support.Auth.Default.reset() end)

      task = Task.async(fn -> open_stream("alice-token", session_id) end)
      wait_for_stream(session_id)
      [stream_pid] = stream_pids(session_id)

      send(stream_pid, {:principal_expired, make_ref()})
      refute Task.yield(task, 200)
      assert [^stream_pid] = stream_pids(session_id)

      Utils.terminate_stream(@isolation, session_id, stream_pid)
      Task.await(task, 30_000)
    end

    @tag task_opts: %{sse_max_stream_ms: 60_000}
    test "a stray poll close message does not end a stream" do
      session_id = alice_session()
      Support.Auth.Default.expire_at("alice-token", System.system_time(:second) + 3600)
      on_exit(fn -> Support.Auth.Default.reset() end)

      task = Task.async(fn -> open_stream("alice-token", session_id) end)
      wait_for_stream(session_id)
      [stream_pid] = stream_pids(session_id)

      send(stream_pid, {:sse_poll_close, make_ref()})
      refute Task.yield(task, 200)
      assert [^stream_pid] = stream_pids(session_id)

      Utils.terminate_stream(@isolation, session_id, stream_pid)
      Task.await(task, 30_000)
    end

    # The stream runs in the Task process: the mailbox read happens there,
    # after a wait that is past both the expiry time and the poll time.
    # Whatever timer was left running would have fired by then and left a
    # stray message behind.
    #
    @tag task_opts: %{sse_max_stream_ms: 200, sse_retry_ms: 250}
    test "a principal that expires before the poll close ends the stream at the expiry" do
      session_id = alice_session()

      Support.Auth.Default.expire_at(
        "alice-token",
        System.system_time(:millisecond) / 1000 + 0.08
      )

      on_exit(fn -> Support.Auth.Default.reset() end)

      task =
        Task.async(fn ->
          conn = open_stream("alice-token", session_id)

          receive do
            :report -> {conn, Process.info(self(), :messages)}
          end
        end)

      # Past both the expiry time and the poll time: whatever timer was
      # left running would have fired by now and left a stray message in
      # the mailbox of the task. The wait is the check that the DOWN of
      # the task does not arrive.
      #
      task_ref = Process.monitor(task.pid)
      refute_receive {:DOWN, ^task_ref, :process, _, _}, 500

      send(task.pid, :report)
      {conn, {:messages, messages}} = Task.await(task, 30_000)

      # The stream ended by itself, at the expiry of the principal, with
      # the configured retry hint.
      #
      assert String.ends_with?(conn.resp_body, "retry: 250\n\n")

      # Only one of the two timers fired: no stray message is left behind.
      #
      refute Enum.any?(messages, &match?({:principal_expired, _}, &1))
      refute Enum.any?(messages, &match?({:sse_poll_close, _}, &1))
    end
  end

  describe "the resume of a POST stream and the principal" do
    test "a foreign principal that resumes a forged stream gets 404, not 204" do
      session_id = alice_session()

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          conn =
            conn(:get, "/")
            |> put_req_header("accept", "text/event-stream")
            |> put_req_header("last-event-id", "forged-stream:3")
            |> put_bearer("bob-token")
            |> put_session_id(session_id)
            |> call_router(@isolation)

          assert conn.status == 404
          assert decode_resp(conn)["error"] == @invalid_error
        end)

      assert log =~ "session owner mismatch"
    end
  end

  describe "the version of the session and the principal" do
    test "a foreign principal whose ping carries a version that differs gets 404, not 400" do
      session_id = alice_session()
      put_session_version(@isolation, session_id, "2025-06-18")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          conn =
            post_json_rpc(2, "ping", %{})
            |> put_bearer("bob-token")
            |> put_session_id(session_id)
            |> put_req_header("mcp-protocol-version", "2025-11-25")
            |> call_router(@isolation)

          assert conn.status == 404
          assert decode_resp(conn)["error"] == @invalid_error
        end)

      assert log =~ "session owner mismatch"
    end

    test "a ping of the owner with a version that differs gets 400" do
      session_id = alice_session()
      put_session_version(@isolation, session_id, "2025-06-18")

      conn =
        post_json_rpc(2, "ping", %{})
        |> put_bearer("alice-token")
        |> put_session_id(session_id)
        |> put_req_header("mcp-protocol-version", "2025-11-25")
        |> call_router(@isolation)

      assert conn.status == 400

      assert decode_resp(conn) ==
               json_rpc_error(2, -32600, "MCP protocol version does not match the session")
    end
  end

  describe "the answer of a client to a request of the server" do
    test "the answer of another principal for the session is ignored" do
      session_id = alice_session()
      out_id = spawn_waiter(session_id)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          conn =
            post_answer(out_id)
            |> put_bearer("bob-token")
            |> put_session_id(session_id)
            |> call_router(@isolation)

          assert conn.status == 404
          assert decode_resp(conn)["error"] == @invalid_error
        end)

      assert log =~ "session owner mismatch"

      refute_receive {:client_answer, _}, 200

      # The owner answers the same request: it is delivered.
      #
      conn =
        post_answer(out_id)
        |> put_bearer("alice-token")
        |> put_session_id(session_id)
        |> call_router(@isolation)

      assert conn.status == 202
      assert_receive {:client_answer, {:ok, %{}}}
    end
  end

  describe "the cost of the owner check" do
    test "the owner check adds no session read to a request that reads the session" do
      session_id = alice_session()

      count =
        count_session_state_calls(fn ->
          conn =
            post_json_rpc(2, "tools/call", %{"name" => "get_time"})
            |> put_bearer("alice-token")
            |> put_session_id(session_id)
            |> call_router(@isolation)

          assert conn.status == 200
        end)

      assert count == 1
    end
  end

  describe "the principal in the ctx of the callbacks" do
    test "a tool receives the principal of the caller in ctx" do
      session_id = alice_session()

      conn =
        post_json_rpc(2, "tools/call", %{"name" => "task_immediate", "arguments" => %{}})
        |> put_bearer("alice-token")
        |> put_session_id(session_id)
        |> call_router(@isolation)

      assert conn.status == 200
      assert decode_resp(conn)["error"] == nil

      ctx = Support.Entities.Tools.TaskImmediateTest.last_ctx()
      assert %OzMcp.Auth.Principal{} = ctx.principal
      assert ctx.principal.subject == "alice"
      assert ctx.principal.issuer == "https://issuer.test"
      assert ctx.principal.scopes == ["files:read"]
    end

    test "the runner of a task-augmented call receives the principal of the request" do
      session_id = alice_session()

      conn =
        post_json_rpc(2, "tools/call", %{
          "name" => "task_immediate",
          "arguments" => %{},
          "task" => %{}
        })
        |> put_bearer("alice-token")
        |> put_session_id(session_id)
        |> call_router(@isolation)

      assert conn.status == 200
      assert %{"task" => %{"taskId" => task_id}} = decode_resp(conn)["result"]

      wait_until(fn ->
        ctx = Support.Entities.Tools.TaskImmediateTest.last_ctx()
        ctx != nil and ctx.task_id == task_id
      end)

      assert Support.Entities.Tools.TaskImmediateTest.last_ctx().principal.subject == "alice"
    end

    test "the runner keeps the snapshot of the caller after the token is gone" do
      Support.Entities.Tools.TaskSlowTest.reset()
      session_id = alice_session()

      conn =
        post_json_rpc(2, "tools/call", %{"name" => "task_slow", "arguments" => %{}, "task" => %{}})
        |> put_bearer("alice-token")
        |> put_session_id(session_id)
        |> call_router(@isolation)

      assert conn.status == 200
      assert %{"task" => %{"taskId" => task_id}} = decode_resp(conn)["result"]

      # The ctx is stored after the runner pid, so this wait also proves
      # the runner started.
      #
      wait_until(fn ->
        ctx = Support.Entities.Tools.TaskSlowTest.last_ctx()
        ctx != nil and ctx.task_id == task_id
      end)

      assert Support.Entities.Tools.TaskSlowTest.last_ctx().principal.subject == "alice"

      # The authorization server expires the token of alice: a new request
      # with it is refused...
      #
      Support.Auth.Default.revoke("alice-token")
      on_exit(fn -> Support.Auth.Default.reset() end)

      conn =
        post_json_rpc(3, "tools/call", %{"name" => "get_time"})
        |> put_bearer("alice-token")
        |> put_session_id(session_id)
        |> call_router(@isolation)

      assert conn.status == 401

      # ...but the task record keeps the principal of the request that made
      # the task. The runner context reads this snapshot: it never needs the
      # token again.
      #
      assert {:ok, record} = OzMcp.Tasks.EtsStore.get(@isolation, task_id)
      assert record.principal.subject == "alice"
      assert record.principal.issuer == "https://issuer.test"

      Support.Entities.Tools.TaskSlowTest.finish()
    end

    test "tasks/get of another principal for a task of alice is not found" do
      session_id = alice_session()

      conn =
        post_json_rpc(2, "tools/call", %{
          "name" => "task_immediate",
          "arguments" => %{},
          "task" => %{}
        })
        |> put_bearer("alice-token")
        |> put_session_id(session_id)
        |> call_router(@isolation)

      assert conn.status == 200
      assert %{"task" => %{"taskId" => task_id}} = decode_resp(conn)["result"]

      # Bob works in his own session: the task of alice is invisible for
      # him, exactly like the task of an unknown session.
      #
      conn =
        post_json_rpc(1, "initialize", @initialize_params)
        |> put_bearer("bob-token")
        |> call_router(@isolation)

      assert conn.status == 200
      assert [bob_session_id] = get_resp_header(conn, "mcp-session-id")

      conn =
        post_notification("notifications/initialized")
        |> put_bearer("bob-token")
        |> put_session_id(bob_session_id)
        |> call_router(@isolation)

      assert conn.status == 202

      conn =
        post_json_rpc(2, "tasks/get", %{"taskId" => task_id})
        |> put_bearer("bob-token")
        |> put_session_id(bob_session_id)
        |> call_router(@isolation)

      assert conn.status == 200

      assert decode_resp(conn)["error"] == %{
               "code" => -32602,
               "message" => "Failed to retrieve task: Task not found"
             }
    end

    test "ctx.principal is nil when authorization is off" do
      Utils.stop_instances()

      Utils.start_instances([Servers.TasksTest], __MODULE__, allowed_origins: [])

      conn =
        post_json_rpc(1, "initialize", @initialize_params)
        |> call_router(inst(Servers.TasksTest))

      assert conn.status == 200
      assert [session_id] = get_resp_header(conn, "mcp-session-id")

      conn =
        post_notification("notifications/initialized")
        |> put_session_id(session_id)
        |> call_router(inst(Servers.TasksTest))

      assert conn.status == 202

      conn =
        post_json_rpc(2, "tools/call", %{"name" => "task_immediate", "arguments" => %{}})
        |> put_session_id(session_id)
        |> call_router(inst(Servers.TasksTest))

      assert conn.status == 200
      assert decode_resp(conn)["error"] == nil

      assert Support.Entities.Tools.TaskImmediateTest.last_ctx().principal == nil
    end
  end

  describe "the authorize step of the verifier" do
    test "a call out of scope gets a 403 whose body holds the id of the request" do
      session_id = alice_session()

      conn =
        post_json_rpc(2, "tools/call", %{"name" => "get_date"})
        |> put_bearer("alice-token")
        |> put_session_id(session_id)
        |> call_router(@isolation)

      assert conn.status == 403

      challenge = header(conn, "www-authenticate")
      assert challenge =~ ~s(error="insufficient_scope")
      assert challenge =~ ~s(error_description="write permission needed")
      assert challenge =~ ~s(scope="files:read files:write")
      assert challenge =~ ~s(resource_metadata="#{@metadata_url}")

      assert decode_resp(conn) == %{
               "jsonrpc" => "2.0",
               "id" => 2,
               "error" => %{"code" => -32011, "message" => "insufficient scope"}
             }
    end

    test "an empty scope list in the answer of authorize/3 names the challenge_scopes" do
      session_id = alice_session()

      conn =
        post_json_rpc(2, "tasks/list", %{"cursor" => "empty-scopes"})
        |> put_bearer("alice-token")
        |> put_session_id(session_id)
        |> call_router(@isolation)

      assert conn.status == 403

      challenge = header(conn, "www-authenticate")
      assert challenge =~ ~s(error="insufficient_scope")
      assert challenge =~ ~s(scope="files:read")
      assert challenge =~ ~s(resource_metadata="#{@metadata_url}")
      assert decode_resp(conn)["id"] == 2
    end

    test "an empty scope list in the answer of authorize/3 keeps the granted scopes" do
      session_id = alice_session()

      conn =
        post_json_rpc(2, "tasks/list", %{"cursor" => "empty-scopes"})
        |> put_bearer("alice-admin")
        |> put_session_id(session_id)
        |> call_router(@isolation)

      assert conn.status == 403
      assert header(conn, "www-authenticate") =~ ~s(scope="files:read files:write")
    end

    test "a call in scope passes" do
      session_id = alice_session()

      conn =
        post_json_rpc(2, "tools/call", %{"name" => "get_date"})
        |> put_bearer("alice-admin")
        |> put_session_id(session_id)
        |> call_router(@isolation)

      assert conn.status == 200
      assert decode_resp(conn)["error"] == nil
    end

    test "a plain refusal gets a 403 with no challenge header" do
      session_id = alice_session()

      conn =
        post_json_rpc(2, "resources/read", %{"uri" => "file:///marketing.md"})
        |> put_bearer("alice-token")
        |> put_session_id(session_id)
        |> call_router(@isolation)

      assert conn.status == 403
      assert header(conn, "www-authenticate") == nil

      assert decode_resp(conn)["error"] == %{"code" => -32011, "message" => "forbidden"}
    end

    test "a session the caller does not own is refused before the authorize step" do
      session_id = alice_session()

      conn =
        post_json_rpc(2, "tools/call", %{"name" => "get_date"})
        |> put_bearer("bob-token")
        |> put_session_id(session_id)
        |> call_router(@isolation)

      assert conn.status == 404
      assert header(conn, "www-authenticate") == nil
      assert decode_resp(conn)["error"] == @invalid_error
    end

    test "a verifier that declares no authorize/3 lets every request pass" do
      conn =
        post_json_rpc(1, "initialize", @initialize_params)
        |> put_bearer("some-token")
        |> call_router(inst(Servers.AuthorizedBroken))

      assert conn.status == 200
      assert [session_id] = get_resp_header(conn, "mcp-session-id")

      conn =
        post_notification("notifications/initialized")
        |> put_bearer("some-token")
        |> put_session_id(session_id)
        |> call_router(inst(Servers.AuthorizedBroken))

      assert conn.status == 202

      conn =
        post_json_rpc(2, "tools/call", %{"name" => "get_date"})
        |> put_bearer("some-token")
        |> put_session_id(session_id)
        |> call_router(inst(Servers.AuthorizedBroken))

      assert conn.status == 200
      assert decode_resp(conn)["error"] == nil
    end

    test "a raise of the callback is a server error and the cause is logged" do
      session_id = alice_session()

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          conn =
            post_json_rpc(2, "tasks/list", %{"cursor" => "crash"})
            |> put_bearer("alice-token")
            |> put_session_id(session_id)
            |> call_router(@isolation)

          assert conn.status == 500
          assert decode_resp(conn)["id"] == 2
          assert decode_resp(conn)["error"] == internal_error()
        end)

      assert log =~ "authorize/3 failed"
      assert log =~ "authorize failure"
    end

    test "a wrong return value of the callback is a server error" do
      session_id = alice_session()

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          conn =
            post_json_rpc(2, "tasks/list", %{"cursor" => "bad-return"})
            |> put_bearer("alice-token")
            |> put_session_id(session_id)
            |> call_router(@isolation)

          assert conn.status == 500
          assert decode_resp(conn)["id"] == 2
          assert decode_resp(conn)["error"] == internal_error()
        end)

      assert log =~ "returned an invalid value"
    end

    test "the second element of a returned tuple is named by its type, never its content" do
      session_id = alice_session()

      log =
        Utils.capture_log([level: :error], fn ->
          conn =
            post_json_rpc(2, "tasks/list", %{"cursor" => "secret-error-binary"})
            |> put_bearer("alice-token")
            |> put_session_id(session_id)
            |> call_router(@isolation)

          assert conn.status == 500
          assert decode_resp(conn)["error"] == internal_error()
        end)

      assert log =~ "authorize/3 returned an invalid value"
      assert log =~ "second element: binary"
      refute log =~ "SECRET-TOKEN"
    end

    test "a scope that breaks the syntax in the answer is a server error, not a crash" do
      session_id = alice_session()

      log =
        Utils.capture_log(fn ->
          conn =
            post_json_rpc(2, "tasks/list", %{"cursor" => "bad-scope"})
            |> put_bearer("alice-token")
            |> put_session_id(session_id)
            |> call_router(@isolation)

          assert conn.status == 500
          assert decode_resp(conn)["id"] == 2
          assert decode_resp(conn)["error"] == internal_error()
        end)

      assert log =~ "authorize/3 returned an invalid value"
      assert log =~ "RFC 6749 scope tokens"
      refute log =~ "Unexpected failure"
    end

    test "a description that is not a string in the answer of authorize/3 is a server error" do
      session_id = alice_session()

      log =
        Utils.capture_log(fn ->
          conn =
            post_json_rpc(3, "tasks/list", %{"cursor" => "bad-description"})
            |> put_bearer("alice-token")
            |> put_session_id(session_id)
            |> call_router(@isolation)

          assert conn.status == 500
          assert header(conn, "www-authenticate") == nil
          assert decode_resp(conn)["id"] == 3
          assert decode_resp(conn)["error"] == internal_error()
        end)

      assert log =~ "authorize/3 returned an invalid value"
      assert log =~ "a string or nil as description"
      refute log =~ "SECRET-TOKEN"
    end

    test "a request with a method reaches the authorize callback once" do
      session_id = alice_session()

      count =
        count_authorize_calls(fn ->
          conn =
            post_json_rpc(2, "tools/call", %{"name" => "get_date"})
            |> put_bearer("alice-token")
            |> put_session_id(session_id)
            |> call_router(@isolation)

          assert conn.status == 403
        end)

      assert count == 1
    end

    test "the answer of a client never reaches the authorize callback" do
      session_id = alice_session()
      out_id = spawn_waiter(session_id)

      count =
        count_authorize_calls(fn ->
          conn =
            post_answer(out_id)
            |> put_bearer("alice-token")
            |> put_session_id(session_id)
            |> call_router(@isolation)

          assert conn.status == 202
        end)

      assert count == 0
      assert_receive {:client_answer, {:ok, %{}}}
    end
  end

  # ---------------------------------------------------------------------------

  describe "required_scopes of the DSL" do
    #
    # A session of the caller on the scoped server. The token selects the
    # scopes of the principal: alice-token holds files:read, alice-admin
    # holds files:read and files:write. No token of the verifier holds
    # admin, so admin_tool tests a partial match.
    #
    defp scoped_session(token) do
      conn =
        post_json_rpc(1, "initialize", @initialize_params)
        |> put_bearer(token)
        |> call_router(@scoped)

      assert conn.status == 200
      assert [session_id] = get_resp_header(conn, "mcp-session-id")

      conn =
        post_notification("notifications/initialized")
        |> put_bearer(token)
        |> put_session_id(session_id)
        |> call_router(@scoped)

      assert conn.status == 202
      session_id
    end

    test "tools/call without the scope: 403, the challenge names the scopes, the callback does not run" do
      Support.Entities.Tools.ScopedTest.reset()
      session = scoped_session("alice-token")

      conn =
        post_json_rpc(2, "tools/call", %{"name" => "write_file", "arguments" => %{"path" => "a"}})
        |> put_bearer("alice-token")
        |> put_session_id(session)
        |> call_router(@scoped)

      assert conn.status == 403

      assert header(conn, "www-authenticate") ==
               ~s(Bearer error="insufficient_scope", scope="files:read files:write", resource_metadata="#{@metadata_url}")

      assert decode_resp(conn) == %{
               "jsonrpc" => "2.0",
               "id" => 2,
               "error" => %{"code" => -32011, "message" => "insufficient scope"}
             }

      assert Support.Entities.Tools.ScopedTest.last_ran() == nil
    end

    test "a principal that holds only a part of the scopes is refused" do
      Support.Entities.Tools.ScopedTest.reset()
      session = scoped_session("alice-admin")

      conn =
        post_json_rpc(2, "tools/call", %{"name" => "admin_tool", "arguments" => %{}})
        |> put_bearer("alice-admin")
        |> put_session_id(session)
        |> call_router(@scoped)

      assert conn.status == 403

      challenge = header(conn, "www-authenticate")
      assert challenge =~ ~s(error="insufficient_scope")
      assert challenge =~ ~s(scope="files:read files:write admin")

      assert Support.Entities.Tools.ScopedTest.last_ran() == nil
    end

    test "tools/call with the scopes reaches the callback" do
      Support.Entities.Tools.ScopedTest.reset()
      session = scoped_session("alice-admin")

      conn =
        post_json_rpc(2, "tools/call", %{"name" => "write_file", "arguments" => %{"path" => "a"}})
        |> put_bearer("alice-admin")
        |> put_session_id(session)
        |> call_router(@scoped)

      assert conn.status == 200
      assert decode_resp(conn)["error"] == nil
      assert Support.Entities.Tools.ScopedTest.last_ran() == "write_file"
    end

    test "an entity with no scope is open to every principal" do
      Support.Entities.Tools.ScopedTest.reset()
      session = scoped_session("alice-token")

      conn =
        post_json_rpc(2, "tools/call", %{"name" => "read_file", "arguments" => %{"path" => "a"}})
        |> put_bearer("alice-token")
        |> put_session_id(session)
        |> call_router(@scoped)

      assert conn.status == 200
      assert decode_resp(conn)["error"] == nil
      assert Support.Entities.Tools.ScopedTest.last_ran() == "read_file"
    end

    test "a map tool with required_scopes: 403 without the scope and the key never reaches the client" do
      server = authorized_map_scoped_server(["files:write"])
      instance = Module.concat(server, __MODULE__)
      Utils.start_instance(server, name: instance, resource_url: @resource_url)

      session = session_on(instance, "alice-token")

      conn =
        post_json_rpc(2, "tools/call", %{"name" => "scoped_map"})
        |> put_bearer("alice-token")
        |> put_session_id(session)
        |> call_router(instance)

      assert conn.status == 403
      assert header(conn, "www-authenticate") =~ ~s(scope="files:read files:write")

      session = session_on(instance, "alice-admin")

      conn =
        post_json_rpc(2, "tools/call", %{"name" => "scoped_map"})
        |> put_bearer("alice-admin")
        |> put_session_id(session)
        |> call_router(instance)

      assert conn.status == 200

      answer = decode_resp(conn) |> :json.encode() |> IO.iodata_to_binary()
      refute answer =~ "required_scopes"
      refute answer =~ "requiredScopes"
      assert decode_resp(conn)["error"] == nil
    end

    test "a map tool with required_scopes is hidden from the filtered list without the scope" do
      server = authorized_map_scoped_server(["files:write"])
      instance = Module.concat(server, __MODULE__)
      Utils.start_instance(server, name: instance, resource_url: @resource_url)

      session = session_on(instance, "alice-token")

      conn =
        post_json_rpc(2, "tools/list", %{})
        |> put_bearer("alice-token")
        |> put_session_id(session)
        |> call_router(instance)

      assert names_of(conn, "tools") == []

      session = session_on(instance, "alice-admin")

      conn =
        post_json_rpc(2, "tools/list", %{})
        |> put_bearer("alice-admin")
        |> put_session_id(session)
        |> call_router(instance)

      assert names_of(conn, "tools") == ["scoped_map"]

      answer = decode_resp(conn) |> :json.encode() |> IO.iodata_to_binary()
      refute answer =~ "required_scopes"
      refute answer =~ "requiredScopes"
    end

    test "resources/read of the secret resource: 403 and the callback does not run" do
      Support.Entities.Resources.ScopedTest.reset()
      session = scoped_session("alice-token")

      conn =
        post_json_rpc(2, "resources/read", %{"uri" => "file:///secret.md"})
        |> put_bearer("alice-token")
        |> put_session_id(session)
        |> call_router(@scoped)

      assert conn.status == 403
      assert header(conn, "www-authenticate") =~ ~s(scope="files:read files:write")

      assert Support.Entities.Resources.ScopedTest.last_read() == nil
    end

    test "resources/read of a uri that matches the template: 403" do
      session = scoped_session("alice-token")

      conn =
        post_json_rpc(2, "resources/read", %{"uri" => "file:///docs/report.md"})
        |> put_bearer("alice-token")
        |> put_session_id(session)
        |> call_router(@scoped)

      assert conn.status == 403
      assert header(conn, "www-authenticate") =~ ~s(scope="files:read files:write")
    end

    test "resources/subscribe of the secret resource: 403 and no subscription" do
      session = scoped_session("alice-token")

      conn =
        post_json_rpc(2, "resources/subscribe", %{"uri" => "file:///secret.md"})
        |> put_bearer("alice-token")
        |> put_session_id(session)
        |> call_router(@scoped)

      assert conn.status == 403
      assert header(conn, "www-authenticate") =~ ~s(scope="files:read files:write")
      assert Utils.subscriptions(@scoped, session) == []
    end

    test "resources/unsubscribe of the secret resource passes the scope step" do
      session = scoped_session("alice-token")

      conn =
        post_json_rpc(2, "resources/unsubscribe", %{"uri" => "file:///secret.md"})
        |> put_bearer("alice-token")
        |> put_session_id(session)
        |> call_router(@scoped)

      assert conn.status == 200
      assert decode_resp(conn)["error"] == nil
    end

    test "prompts/get of the audit prompt: 403" do
      session = scoped_session("alice-token")

      conn =
        post_json_rpc(2, "prompts/get", %{"name" => "audit"})
        |> put_bearer("alice-token")
        |> put_session_id(session)
        |> call_router(@scoped)

      assert conn.status == 403
      assert header(conn, "www-authenticate") =~ ~s(scope="files:read files:write")
    end

    test "completion/complete for a prompt reference of the audit prompt: 403" do
      session = scoped_session("alice-token")

      conn =
        post_json_rpc(2, "completion/complete", %{
          "ref" => %{"type" => "ref/prompt", "name" => "audit"},
          "argument" => %{"name" => "query", "value" => "a"}
        })
        |> put_bearer("alice-token")
        |> put_session_id(session)
        |> call_router(@scoped)

      assert conn.status == 403
      assert header(conn, "www-authenticate") =~ ~s(scope="files:read files:write")
    end

    test "completion/complete for a resource reference of the secret resource: 403" do
      session = scoped_session("alice-token")

      conn =
        post_json_rpc(2, "completion/complete", %{
          "ref" => %{"type" => "ref/resource", "uri" => "file:///secret.md"},
          "argument" => %{"name" => "query", "value" => "a"}
        })
        |> put_bearer("alice-token")
        |> put_session_id(session)
        |> call_router(@scoped)

      assert conn.status == 403
      assert header(conn, "www-authenticate") =~ ~s(scope="files:read files:write")
    end

    test "completion/complete for a template reference: 403, for the template text and for a uri" do
      session = scoped_session("alice-token")

      for uri <- ["file:///docs/{name}", "file:///docs/abc"] do
        conn =
          post_json_rpc(2, "completion/complete", %{
            "ref" => %{"type" => "ref/resource", "uri" => uri},
            "argument" => %{"name" => "name", "value" => "a"}
          })
          |> put_bearer("alice-token")
          |> put_session_id(session)
          |> call_router(@scoped)

        assert conn.status == 403
        assert header(conn, "www-authenticate") =~ ~s(scope="files:read files:write")
      end
    end

    test "completion/complete for a template reference with the scope reaches the callback" do
      session = scoped_session("alice-admin")

      conn =
        post_json_rpc(2, "completion/complete", %{
          "ref" => %{"type" => "ref/resource", "uri" => "file:///docs/abc"},
          "argument" => %{"name" => "name", "value" => "a"}
        })
        |> put_bearer("alice-admin")
        |> put_session_id(session)
        |> call_router(@scoped)

      assert conn.status == 200
      assert decode_resp(conn)["result"]["completion"] == %{"values" => []}
    end

    test "a bad request of a caller without the scope gets its -32602 error before the 403" do
      session = scoped_session("alice-token")

      conn =
        post_json_rpc(2, "tools/call", %{"name" => "write_file", "arguments" => "bad"})
        |> put_bearer("alice-token")
        |> put_session_id(session)
        |> call_router(@scoped)

      assert conn.status == 200
      assert decode_resp(conn)["error"]["code"] == -32602
      assert get_resp_header(conn, "www-authenticate") == []

      conn =
        post_json_rpc(3, "tools/call", %{"name" => "nope", "arguments" => %{}})
        |> put_bearer("alice-token")
        |> put_session_id(session)
        |> call_router(@scoped)

      assert conn.status == 200
      assert decode_resp(conn)["error"]["code"] == -32602
    end

    test "a task-augmented call without the scope: 403 and no task" do
      Support.Entities.Tools.ScopedTest.reset()
      session = scoped_session("alice-token")

      conn =
        post_json_rpc(2, "tools/call", %{
          "name" => "write_file",
          "arguments" => %{"path" => "a"},
          "task" => %{}
        })
        |> put_bearer("alice-token")
        |> put_session_id(session)
        |> call_router(@scoped)

      assert conn.status == 403
      assert header(conn, "www-authenticate") =~ ~s(scope="files:read files:write")

      assert {:ok, [], nil} = Tasks.list(@scoped, Utils.owner(session), nil, 10)
      assert Support.Entities.Tools.ScopedTest.last_ran() == nil
    end

    test "the authorize step still runs after the scope step and can refuse" do
      session = scoped_session("alice-token")

      conn =
        post_json_rpc(2, "tools/call", %{"name" => "get_date"})
        |> put_bearer("alice-token")
        |> put_session_id(session)
        |> call_router(@scoped)

      assert conn.status == 403

      challenge = header(conn, "www-authenticate")
      assert challenge =~ ~s(error="insufficient_scope")
      assert challenge =~ ~s(error_description="write permission needed")
      assert challenge =~ ~s(scope="files:read files:write")
    end

    test "a refusal of the scope step comes before a raise of authorize/3" do
      Support.Entities.Tools.ScopedTest.reset()
      session = scoped_session("alice-token")

      log =
        Utils.capture_log(fn ->
          count =
            count_authorize_calls(fn ->
              conn =
                post_json_rpc(2, "tools/call", %{
                  "name" => "write_file",
                  "arguments" => %{"path" => "crash"}
                })
                |> put_bearer("alice-token")
                |> put_session_id(session)
                |> call_router(@scoped)

              assert conn.status == 403
            end)

          assert count == 0
        end)

      refute log =~ "authorize/3 failed"
      assert Support.Entities.Tools.ScopedTest.last_ran() == nil
    end

    test "an open server with a plain module is unchanged" do
      Utils.stop_instances()

      Utils.start_instances([Servers.Default], __MODULE__, allowed_origins: [])

      conn =
        post_json_rpc(1, "initialize", @initialize_params)
        |> call_router(inst(Servers.Default))

      assert conn.status == 200
      assert [session_id] = get_resp_header(conn, "mcp-session-id")

      conn =
        post_notification("notifications/initialized")
        |> put_session_id(session_id)
        |> call_router(inst(Servers.Default))

      assert conn.status == 202

      conn =
        post_json_rpc(2, "tools/call", %{"name" => "get_time"})
        |> put_session_id(session_id)
        |> call_router(inst(Servers.Default))

      assert conn.status == 200
      assert decode_resp(conn)["error"] == nil
    end
  end

  describe "the lists filtered by scope" do
    #
    # A protected server whose lists are filtered (the default): only the
    # entities that the principal can use appear, each page is full and
    # the cursor counts the filtered items. The token selects the scopes:
    # alice-token holds files:read (no scope of the five tools), alice-admin
    # holds files:write and alice-root holds every scope of the server.
    # The scoped server itself declares filter_by_scope false, so it pins
    # the old code path.
    #
    @paginated_module Servers.ScopedPaginated
    @paginated Module.concat(@paginated_module, __MODULE__)
    defp filtered_session(token) do
      conn =
        post_json_rpc(1, "initialize", @initialize_params)
        |> put_bearer(token)
        |> call_router(@paginated)

      assert conn.status == 200
      assert [session_id] = get_resp_header(conn, "mcp-session-id")

      conn =
        post_notification("notifications/initialized")
        |> put_bearer(token)
        |> put_session_id(session_id)
        |> call_router(@paginated)

      assert conn.status == 202
      session_id
    end

    defp filtered_list(session_id, token, method, params) do
      conn =
        post_json_rpc(2, method, params)
        |> put_bearer(token)
        |> put_session_id(session_id)
        |> call_router(@paginated)

      assert conn.status == 200
      assert decode_resp(conn)["error"] == nil
      conn
    end

    defp result_of(conn, key), do: decode_resp(conn)["result"][key]

    defp names_of(conn, key),
      do: Enum.map(result_of(conn, key), & &1["name"])

    test "a principal with no scope of the tools sees only the tools without a scope" do
      session = filtered_session("alice-token")

      conn = filtered_list(session, "alice-token", "tools/list", %{})

      assert names_of(conn, "tools") == ["t1", "t3"]
      assert result_of(conn, "nextCursor") == nil
    end

    test "a principal with every scope sees all the tools in the order of the module" do
      session = filtered_session("alice-root")

      conn = filtered_list(session, "alice-root", "tools/list", %{})

      assert names_of(conn, "tools") == ["t1", "t2"]
      assert result_of(conn, "nextCursor") == Paginate.encode_cursor(:tools, 2)

      conn =
        filtered_list(session, "alice-root", "tools/list", %{
          "cursor" => Paginate.encode_cursor(:tools, 2)
        })

      assert names_of(conn, "tools") == ["t3", "t4"]
      assert result_of(conn, "nextCursor") == Paginate.encode_cursor(:tools, 3)

      conn =
        filtered_list(session, "alice-root", "tools/list", %{
          "cursor" => Paginate.encode_cursor(:tools, 3)
        })

      assert names_of(conn, "tools") == ["t5"]
      assert result_of(conn, "nextCursor") == nil
    end

    test "a page holds only the visible items and the cursor counts them" do
      session = filtered_session("alice-admin")

      conn = filtered_list(session, "alice-admin", "tools/list", %{})

      assert names_of(conn, "tools") == ["t1", "t2"]
      assert result_of(conn, "nextCursor") == Paginate.encode_cursor(:tools, 2)

      conn =
        filtered_list(session, "alice-admin", "tools/list", %{
          "cursor" => Paginate.encode_cursor(:tools, 2)
        })

      assert names_of(conn, "tools") == ["t3", "t5"]
      assert result_of(conn, "nextCursor") == nil
    end

    test "a principal that sees less gets its own last page" do
      session = filtered_session("alice-token")

      conn = filtered_list(session, "alice-token", "tools/list", %{})

      assert names_of(conn, "tools") == ["t1", "t3"]
      assert result_of(conn, "nextCursor") == nil
    end

    test "a cursor that names a page after the last page is refused with -32602" do
      session = filtered_session("alice-admin")

      conn =
        post_json_rpc(2, "tools/list", %{"cursor" => Paginate.encode_cursor(:tools, 9)})
        |> put_bearer("alice-admin")
        |> put_session_id(session)
        |> call_router(@paginated)

      assert conn.status == 200

      assert decode_resp(conn)["error"] == %{
               "code" => -32602,
               "message" => "invalid cursor"
             }
    end

    test "an invalid cursor is refused with -32602" do
      session = filtered_session("alice-admin")

      conn =
        post_json_rpc(2, "tools/list", %{"cursor" => "page-two"})
        |> put_bearer("alice-admin")
        |> put_session_id(session)
        |> call_router(@paginated)

      assert conn.status == 200

      assert decode_resp(conn)["error"] == %{
               "code" => -32602,
               "message" => "invalid cursor"
             }
    end

    test "a cursor on a list without a page size is refused" do
      session = filtered_session("alice-admin")

      conn =
        post_json_rpc(2, "resources/list", %{"cursor" => "page-two"})
        |> put_bearer("alice-admin")
        |> put_session_id(session)
        |> call_router(@paginated)

      assert %{"code" => -32602, "message" => "invalid cursor"} = decode_resp(conn)["error"]
    end

    test "resources/list shows the resources the principal can read and every plain map" do
      session = filtered_session("alice-token")

      conn = filtered_list(session, "alice-token", "resources/list", %{})

      assert Enum.map(result_of(conn, "resources"), & &1["uri"]) == [
               "file:///public.md",
               "file:///plain-one.md",
               "file:///plain-two.md"
             ]

      session = filtered_session("alice-root")
      conn = filtered_list(session, "alice-root", "resources/list", %{})

      assert Enum.map(result_of(conn, "resources"), & &1["uri"]) == [
               "file:///public.md",
               "file:///secret.md",
               "file:///plain-one.md",
               "file:///plain-two.md"
             ]
    end

    test "resources/templates/list shows only the templates the principal can use" do
      session = filtered_session("alice-token")
      conn = filtered_list(session, "alice-token", "resources/templates/list", %{})

      assert result_of(conn, "resourceTemplates") == []

      session = filtered_session("alice-admin")
      conn = filtered_list(session, "alice-admin", "resources/templates/list", %{})

      assert Enum.map(result_of(conn, "resourceTemplates"), & &1["uriTemplate"]) == [
               "file:///docs/{name}"
             ]
    end

    test "prompts/list shows only the prompts the principal can use" do
      session = filtered_session("alice-token")
      conn = filtered_list(session, "alice-token", "prompts/list", %{})

      assert names_of(conn, "prompts") == ["summarize"]

      session = filtered_session("alice-admin")
      conn = filtered_list(session, "alice-admin", "prompts/list", %{})

      assert names_of(conn, "prompts") == ["summarize", "audit"]
    end

    defp session_on(server, token) do
      conn =
        post_json_rpc(1, "initialize", @initialize_params)
        |> put_bearer(token)
        |> call_router(server)

      assert [session_id] = get_resp_header(conn, "mcp-session-id")

      conn =
        post_notification("notifications/initialized")
        |> put_bearer(token)
        |> put_session_id(session_id)
        |> call_router(server)

      assert conn.status == 202
      session_id
    end

    test "a protected server with no scoped entity serves the page from the catalog" do
      Process.register(self(), :tool_counting_probe)
      session = session_on(inst(Servers.Counting), "alice-token")
      flush_probe()

      conn =
        post_json_rpc(2, "tools/list", %{"cursor" => Paginate.encode_cursor(:tools, 2)})
        |> put_bearer("alice-token")
        |> put_session_id(session)
        |> call_router(inst(Servers.Counting))

      assert conn.status == 200
      assert names_of(conn, "tools") == ["plain3", "plain4"]
      assert result_of(conn, "nextCursor") == Paginate.encode_cursor(:tools, 3)

      # The static list was read at boot: the request does not call list/0.
      #
      assert Enum.filter(flush_probe(), &(&1 in [:list, :template_list])) == []
    end

    test "a module with dsl?: false whose structs carry required_scopes is filtered" do
      session = session_on(inst(Servers.StructScoped), "alice-token")

      conn =
        post_json_rpc(2, "tools/list", %{})
        |> put_bearer("alice-token")
        |> put_session_id(session)
        |> call_router(inst(Servers.StructScoped))

      assert names_of(conn, "tools") == ["open_struct"]

      session = session_on(inst(Servers.StructScoped), "alice-admin")

      conn =
        post_json_rpc(2, "tools/list", %{})
        |> put_bearer("alice-admin")
        |> put_session_id(session)
        |> call_router(inst(Servers.StructScoped))

      assert names_of(conn, "tools") == ["open_struct", "closed_struct"]
    end

    test "a filtered list with no pagination refuses a cursor" do
      session = session_on(inst(Servers.StructScoped), "alice-token")

      for cursor <- ["zzz", Paginate.encode_cursor(:tools, 1)] do
        conn =
          post_json_rpc(2, "tools/list", %{"cursor" => cursor})
          |> put_bearer("alice-token")
          |> put_session_id(session)
          |> call_router(inst(Servers.StructScoped))

        assert %{"code" => -32602, "message" => "invalid cursor"} = decode_resp(conn)["error"]
      end

      for params <- [%{}, %{"cursor" => nil}] do
        conn =
          post_json_rpc(3, "tools/list", params)
          |> put_bearer("alice-token")
          |> put_session_id(session)
          |> call_router(inst(Servers.StructScoped))

        assert names_of(conn, "tools") == ["open_struct"]
        assert result_of(conn, "nextCursor") == nil
      end
    end

    defp flush_probe(acc \\ []) do
      receive do
        message -> flush_probe([message | acc])
      after
        0 -> Enum.reverse(acc)
      end
    end

    test "filter_by_scope false shows every entity and keeps the old code path" do
      conn =
        post_json_rpc(1, "initialize", @initialize_params)
        |> put_bearer("alice-token")
        |> call_router(@scoped)

      assert conn.status == 200
      assert [session_id] = get_resp_header(conn, "mcp-session-id")

      conn =
        post_notification("notifications/initialized")
        |> put_bearer("alice-token")
        |> put_session_id(session_id)
        |> call_router(@scoped)

      assert conn.status == 202

      conn =
        post_json_rpc(2, "tools/list", %{})
        |> put_bearer("alice-token")
        |> put_session_id(session_id)
        |> call_router(@scoped)

      assert conn.status == 200

      assert names_of(conn, "tools") ==
               ["read_file", "write_file", "admin_tool", "get_date", "get_time"]

      conn =
        post_json_rpc(3, "resources/list", %{})
        |> put_bearer("alice-token")
        |> put_session_id(session_id)
        |> call_router(@scoped)

      assert conn.status == 200

      assert Enum.map(result_of(conn, "resources"), & &1["uri"]) == [
               "file:///public.md",
               "file:///secret.md"
             ]
    end

    test "an open server lists every entity (no principal)" do
      Utils.stop_instances()

      Utils.start_instances([Servers.Default], __MODULE__, allowed_origins: [])

      conn =
        post_json_rpc(1, "initialize", @initialize_params)
        |> call_router(inst(Servers.Default))

      assert conn.status == 200
      assert [session_id] = get_resp_header(conn, "mcp-session-id")

      conn =
        post_notification("notifications/initialized")
        |> put_session_id(session_id)
        |> call_router(inst(Servers.Default))

      assert conn.status == 202

      conn =
        post_json_rpc(2, "tools/list", %{})
        |> put_session_id(session_id)
        |> call_router(inst(Servers.Default))

      assert conn.status == 200
      assert names_of(conn, "tools") == ["get_date", "get_time"]
    end
  end

  # Restarts the runtime with the given server opts on the authorized
  # test server: the tests of a runtime option need their own boot.
  #
  defp restart_runtime(opts) do
    Utils.stop_instances()

    Utils.start_instances(
      [
        {Servers.Authorized, Map.put(Map.new(opts), :resource_url, @resource_url)}
      ],
      __MODULE__,
      allowed_origins: []
    )
  end

  # A session of alice on the isolation server. The session is bound to
  # the principal key of alice ({issuer, subject}), whatever token of
  # alice the requests carry.
  #
  defp alice_session(opts \\ []) do
    conn =
      post_json_rpc(1, "initialize", @initialize_params)
      |> put_bearer("alice-token")
      |> call_router(@isolation)

    assert conn.status == 200
    assert [session_id] = get_resp_header(conn, "mcp-session-id")

    if Keyword.get(opts, :initialized, true) do
      conn =
        post_notification("notifications/initialized")
        |> put_bearer("alice-token")
        |> put_session_id(session_id)
        |> call_router(@isolation)

      assert conn.status == 202
      session_id
    else
      session_id
    end
  end

  # A process that makes the session of alice ask the client and waits for
  # the answer. It reports the id of the request; its outcome comes as
  # `{:client_answer, outcome}`.
  #
  defp spawn_waiter(session_id) do
    parent = self()

    spawn(fn ->
      {:ok, out_id, _session_pid} =
        OzMcp.Sessions.request_client(@isolation, session_id, {:request, nil}, {"ping", nil})

      send(parent, {:pending, out_id})

      receive do
        {:oz_mcp_client_answer, ^out_id, outcome} -> send(parent, {:client_answer, outcome})
      after
        5_000 -> send(parent, {:client_answer, :timeout})
      end
    end)

    assert_receive {:pending, out_id}, 5_000
    out_id
  end

  # Opens the GET stream of a session in the calling process: the request
  # does not answer until the stream ends (an expiry, a termination, or a
  # closed connection).
  #
  defp open_stream(token, session_id) do
    conn(:get, "/")
    |> put_req_header("accept", "text/event-stream")
    |> put_bearer(token)
    |> put_session_id(session_id)
    |> call_router(@isolation)
  end

  defp stream_pids(session_id), do: Utils.stream_pids(@isolation, session_id)

  defp wait_for_stream(session_id) do
    wait_until(fn -> stream_pids(session_id) != [] end)
  end

  # The owner check reuses the session_state call of the session step: it
  # adds none. A process cannot be its own tracer: a helper process
  # collects the trace. The pattern watches the full arity of the call:
  # the two-arguments shape delegates to it (count/1 counts each logical
  # call once).
  #
  defp count_session_state_calls(fun) do
    parent = self()
    tracer = spawn_link(fn -> collect_session_state_calls(parent, 0) end)

    :erlang.trace_pattern({OzMcp.Sessions, :state, 2}, true, [:local])
    :erlang.trace(self(), true, [:call, {:tracer, tracer}])

    try do
      fun.()
    after
      :erlang.trace(self(), false, [:call])
      :erlang.trace_pattern({OzMcp.Sessions, :state, 2}, false, [:local])
    end

    ref = :erlang.trace_delivered(self())

    receive do
      {:trace_delivered, _pid, ^ref} -> :ok
    end

    send(tracer, :report)

    receive do
      {:calls, count} -> count
    end
  end

  defp put_session_version(server, session_id, version) do
    :ok = OzMcp.Session.update_view(server, session_id, protocol_version: version)
    version
  end

  defp collect_session_state_calls(parent, count) do
    receive do
      {:trace, _pid, :call, {OzMcp.Sessions, :state, [_instance, _session_id]}} ->
        collect_session_state_calls(parent, count + 1)

      {:trace, _pid, :call, _other} ->
        collect_session_state_calls(parent, count)

      :report ->
        send(parent, {:calls, count})
    end
  end

  # Counts the calls of the authorize/3 callback of the test verifier
  # during a request: the step must be skipped exactly where the
  # contract says so. Same shape as count_session_state_calls/1.
  #
  defp count_authorize_calls(fun) do
    parent = self()
    tracer = spawn_link(fn -> collect_authorize_calls(parent, 0) end)

    :erlang.trace_pattern({Support.Auth.Default, :authorize, 3}, true, [:local])
    :erlang.trace(self(), true, [:call, {:tracer, tracer}])

    try do
      fun.()
    after
      :erlang.trace(self(), false, [:call])
      :erlang.trace_pattern({Support.Auth.Default, :authorize, 3}, false, [:local])
    end

    ref = :erlang.trace_delivered(self())

    receive do
      {:trace_delivered, _pid, ^ref} -> :ok
    end

    send(tracer, :report)

    receive do
      {:calls, count} -> count
    end
  end

  defp collect_authorize_calls(parent, count) do
    receive do
      {:trace, _pid, :call, {Support.Auth.Default, :authorize, _args}} ->
        collect_authorize_calls(parent, count + 1)

      {:trace, _pid, :call, _other} ->
        collect_authorize_calls(parent, count)

      :report ->
        send(parent, {:calls, count})
    end
  end

  defp wait_until(fun, retries \\ 1_500) do
    if Utils.eventually(fun, retries * 10) do
      :ok
    else
      flunk("condition was not met in time")
    end
  end

  # A protected server whose tool module has `dsl?: false` and returns
  # a map with the given scopes. The module defines no constant.
  #
  defp authorized_map_scoped_server(scopes) do
    code =
      quote do
        def list do
          [
            %{
              "name" => "scoped_map",
              "description" => "A map tool with scopes",
              "inputSchema" => %{"type" => "object"},
              "required_scopes" => unquote(scopes)
            }
          ]
        end

        def call(_ctx, _params),
          do: {:ok, %{"content" => [%{"type" => "text", "text" => "ran"}]}}
      end

    tool_mod =
      Support.Factories.Tool.module("AuthMapScopedTool", _dsl_: false, _code_: code)
      |> Support.Factories.Tool.compile()

    exprs = [
      Support.Factories.Server.__tools__([], [Support.Factories.Server.tool(tool_mod)]),
      Support.Factories.Server.__authorization__([], [
        Support.Factories.Server.verifier(Support.Auth.Default),
        Support.Factories.Server.authorization_servers(["https://auth.example.com"])
      ])
    ]

    "AuthMapScopes"
    |> Support.Factories.Server.__module__([_tools_: :_none_], exprs)
    |> Support.Factories.Server.compile()
  end

  defp call_router(conn, server \\ inst(Servers.Authorized)) do
    OzMcp.Router.call(conn, OzMcp.Router.init(server: server, allowed_origins: []))
  end

  defp post_json_rpc(id, method, params) do
    #
    # Wire writes a JSON null for nil: the OTP encoder would write
    # the string "nil".
    #
    body =
      %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}
      |> Utils.encode_json()

    conn(:post, "/", body)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json, text/event-stream")
  end

  defp put_bearer(conn, token),
    do: put_req_header(conn, "authorization", "Bearer #{token}")

  defp put_session_id(conn, session_id),
    do: put_req_header(conn, "mcp-session-id", session_id)

  defp post_notification(method, params \\ %{}) do
    %{"jsonrpc" => "2.0", "method" => method, "params" => params}
    |> :json.encode()
    |> IO.iodata_to_binary()
    |> post_raw()
  end

  defp post_answer(request_id) do
    %{"jsonrpc" => "2.0", "id" => request_id, "result" => %{}}
    |> :json.encode()
    |> IO.iodata_to_binary()
    |> post_raw()
  end

  defp post_raw(body) do
    conn(:post, "/", body)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json, text/event-stream")
  end

  defp put_query_token(conn, token),
    do: Map.put(conn, :query_string, "access_token=#{token}")

  defp get_stream,
    do: conn(:get, "/") |> put_req_header("accept", "text/event-stream")

  defp delete_session, do: conn(:delete, "/")

  defp header(conn, name) do
    case get_resp_header(conn, name) do
      [value] -> value
      [] -> nil
    end
  end

  defp decode_resp(conn), do: :json.decode(conn.resp_body)

  defp json_rpc_error(code, message) do
    %{"jsonrpc" => "2.0", "error" => %{"code" => code, "message" => message}}
  end

  defp json_rpc_error(id, code, message) do
    %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}
  end

  defp internal_error, do: %{"code" => -32603, "message" => "internal server error"}
end
