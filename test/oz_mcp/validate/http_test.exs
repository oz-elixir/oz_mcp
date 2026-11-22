defmodule OzMcp.Validate.HttpTest do
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias OzMcp.Pipeline.Bound
  alias OzMcp.Sessions
  alias OzMcp.Validate
  alias OzMcp.Validate.Http
  alias Support.Helpers.Utils
  alias Support.Servers

  @broken_module Servers.AuthorizedBroken

  @localhost_module Servers.AuthorizedLocalhost

  @server_module Servers.Default
  @authorized_module Servers.Authorized
  @resource_url "https://mcp.example.com/mcp"
  @metadata_url "https://mcp.example.com/.well-known/oauth-protected-resource/mcp"

  setup do
    tag = "H#{System.unique_integer([:positive])}"

    Process.put(
      :http_instances,
      {Module.concat(@server_module, tag), Module.concat(@authorized_module, tag)}
    )

    Utils.start_instance(@server_module, name: server())

    Utils.start_instance(@authorized_module,
      name: authorized(),
      resource_url: @resource_url
    )

    :ok
  end

  # The names of the instances of the test: the setup gives each one a
  # name of its own, so the tests of the file (and of the other files) run
  # apart.
  #
  defp server, do: elem(Process.get(:http_instances), 0)
  defp authorized, do: elem(Process.get(:http_instances), 1)

  # A name of an instance that no test starts: the tests that must fail
  # closed read a server that does not run.
  #
  defp localhost, do: Module.concat(@localhost_module, "Absent")

  defp context(conn, overrides \\ []) do
    mode = Keyword.get(overrides, :mode, :rpc)

    OzMcp.Context.new(conn.private.server, :http_streamable, mode)
    |> OzMcp.Context.put_http_conn(conn)
    |> Map.put(:session_id, Keyword.get(overrides, :session_id))
    |> Map.put(:rpc_id, Keyword.get(overrides, :rpc_id))
    |> Map.put(:rpc_method, Keyword.get(overrides, :rpc_method))
    |> Map.put(:rpc_params, Keyword.get(overrides, :rpc_params))
    |> Map.put(:principal, Keyword.get(overrides, :principal))
  end

  defp build_base_conn(body \\ %{}) do
    conn(:post, "/", :json.encode(body) |> IO.iodata_to_binary())
    |> put_private(:server, server())
    |> Map.put(:body_params, body)
  end

  # The answer of a pipeline stage: the context it carries.
  #
  defp plain({:cont, context}), do: context
  defp plain({:halt, context}), do: context

  defp build_conn(body \\ %{}) do
    build_base_conn(body)
    |> put_req_header("accept", "application/json, text/event-stream")
  end

  # -------------------------------------------------------------------
  # headers/1
  # -------------------------------------------------------------------

  describe "headers/1" do
    test "put error in context when accept header is missing" do
      conn = build_base_conn()
      ctx = plain(Http.headers(context(conn)))

      refute is_nil(ctx.error)
      assert ctx.error.code == :http_no_accept_header
    end

    test "put error in context when accept http header is invalid 1" do
      conn =
        build_base_conn()
        |> put_req_header("accept", "text/event-stream")

      ctx = plain(Http.headers(context(conn)))

      refute is_nil(ctx.error)
      assert ctx.error.code == :http_bad_accept_header
    end

    test "put error in context when accept http header is invalid 2" do
      conn =
        build_base_conn()
        |> put_req_header("accept", "application/json")

      ctx = plain(Http.headers(context(conn)))

      refute is_nil(ctx.error)
      assert ctx.error.code == :http_bad_accept_header
    end

    test "pass when accept http header is valid" do
      conn = build_conn()
      ctx = plain(Http.headers(context(conn)))

      assert is_nil(ctx.error)
    end

    test "pass when accept http header is valid (case insensitive)" do
      conn =
        build_base_conn()
        |> put_req_header("accept", "Application/JSON, Text/Event-Stream")

      ctx = plain(Http.headers(context(conn)))

      assert is_nil(ctx.error)
    end

    test "pass when both media types come in two accept headers" do
      conn =
        build_base_conn()
        |> Map.put(:req_headers, [{"accept", "application/json"}, {"accept", "text/event-stream"}])

      ctx = plain(Http.headers(context(conn)))

      assert is_nil(ctx.error)
    end

    test "put error in context when the media types are in one header only and the other header has none" do
      conn =
        build_base_conn()
        |> put_req_header("accept", "garbage")
        |> put_req_header("accept", "application/json, text/event-stream")

      ctx = plain(Http.headers(context(conn)))

      assert is_nil(ctx.error)
    end

    test "pass when the full wildcard accepts everything" do
      conn =
        build_base_conn()
        |> put_req_header("accept", "*/*")

      ctx = plain(Http.headers(context(conn)))

      assert is_nil(ctx.error)
    end

    test "pass when a type wildcard covers each media type" do
      conn =
        build_base_conn()
        |> put_req_header("accept", "application/*, text/*")

      ctx = plain(Http.headers(context(conn)))

      assert is_nil(ctx.error)
    end

    test "put error in context when one media type has a q of zero" do
      conn =
        build_base_conn()
        |> put_req_header("accept", "application/json, text/event-stream;q=0")

      ctx = plain(Http.headers(context(conn)))

      refute is_nil(ctx.error)
      assert ctx.error.code == :http_bad_accept_header
    end

    test "put error in context when the q of one media type is not a number" do
      conn =
        build_base_conn()
        |> put_req_header("accept", "application/json;q=abc, text/event-stream")

      ctx = plain(Http.headers(context(conn)))

      refute is_nil(ctx.error)
      assert ctx.error.code == :http_bad_accept_header
    end

    test "pass when the q of a media type is below one" do
      conn =
        build_base_conn()
        |> put_req_header("accept", "application/json;q=0.9, text/event-stream;q=0.1")

      ctx = plain(Http.headers(context(conn)))

      assert is_nil(ctx.error)
    end

    test "put error in context when the accept header is empty" do
      conn =
        build_base_conn()
        |> put_req_header("accept", "")

      ctx = plain(Http.headers(context(conn)))

      refute is_nil(ctx.error)
      assert ctx.error.code == :http_bad_accept_header
    end

    test "put error in context when the accept header carries only garbage" do
      conn =
        build_base_conn()
        |> put_req_header("accept", "garbage, more garbage")

      ctx = plain(Http.headers(context(conn)))

      refute is_nil(ctx.error)
      assert ctx.error.code == :http_bad_accept_header
    end
  end

  # -------------------------------------------------------------------
  # sse_header/1
  # -------------------------------------------------------------------

  describe "sse_header/1" do
    test "put error in context when accept http header is missing" do
      conn =
        build_base_conn()

      ctx = plain(Http.sse_header(context(conn)))

      refute is_nil(ctx.error)
      assert ctx.error.code == :http_no_accept_header
    end

    test "put error in context when accept http header is invalid" do
      conn =
        build_base_conn()
        |> put_req_header("accept", "application/json")

      ctx = plain(Http.sse_header(context(conn)))

      refute is_nil(ctx.error)
      assert ctx.error.code == :http_no_event_stream_accept_header
    end

    test "pass when accept http header is valid 1" do
      conn =
        build_base_conn()
        |> put_req_header("accept", "text/event-stream")

      ctx = plain(Http.sse_header(context(conn)))

      assert is_nil(ctx.error)
    end

    test "pass when accept http header is valie 1" do
      conn =
        build_base_conn()
        |> put_req_header("accept", "text/event-stream, application/json")

      ctx = plain(Http.sse_header(context(conn)))

      assert is_nil(ctx.error)
    end

    test "pass when accept http header is valid 2 (case insensitive)" do
      conn =
        build_base_conn()
        |> put_req_header("accept", "Text/EVENT-STREAM")

      ctx = plain(Http.sse_header(context(conn)))

      assert is_nil(ctx.error)
    end

    test "pass when the type wildcard covers text/event-stream" do
      conn =
        build_base_conn()
        |> put_req_header("accept", "text/*")

      ctx = plain(Http.sse_header(context(conn)))

      assert is_nil(ctx.error)
    end

    test "pass when the full wildcard covers text/event-stream" do
      conn =
        build_base_conn()
        |> put_req_header("accept", "*/*")

      ctx = plain(Http.sse_header(context(conn)))

      assert is_nil(ctx.error)
    end

    test "pass when the two media types come in two accept headers" do
      conn =
        build_base_conn()
        |> Map.put(:req_headers, [{"accept", "application/json"}, {"accept", "text/event-stream"}])

      ctx = plain(Http.sse_header(context(conn)))

      assert is_nil(ctx.error)
    end

    test "put error in context when text/event-stream has a q of zero" do
      conn =
        build_base_conn()
        |> put_req_header("accept", "application/json, text/event-stream;q=0")

      ctx = plain(Http.sse_header(context(conn)))

      refute is_nil(ctx.error)
      assert ctx.error.code == :http_no_event_stream_accept_header
    end

    test "pass when the q of text/event-stream is below one" do
      conn =
        build_base_conn()
        |> put_req_header("accept", "application/json;q=1.0, text/event-stream;q=0.2")

      ctx = plain(Http.sse_header(context(conn)))

      assert is_nil(ctx.error)
    end

    test "put error in context when the accept header is empty" do
      conn =
        build_base_conn()
        |> put_req_header("accept", "")

      ctx = plain(Http.sse_header(context(conn)))

      refute is_nil(ctx.error)
      assert ctx.error.code == :http_no_event_stream_accept_header
    end
  end

  # -------------------------------------------------------------------
  # session_id/1
  # -------------------------------------------------------------------

  describe "session_id/1" do
    test "returns the context unchanged for initialize without a session id" do
      before = Utils.session_count(server())
      conn = build_conn()
      ctx = plain(Http.session_id(context(conn, rpc_method: "initialize")))

      assert is_nil(ctx.error)
      assert is_nil(ctx.session_id)
      assert get_resp_header(ctx.conn, "mcp-session-id") == []
      assert Utils.session_count(server()) == before
    end

    test "the whole POST pipeline creates no session for a valid initialize" do
      params = %{
        "protocolVersion" => "2025-11-25",
        "clientInfo" => %{"name" => "pipeline-client", "version" => "1.0.0"}
      }

      body = %{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize", "params" => params}

      conn =
        build_base_conn(body)
        |> put_req_header("accept", "application/json, text/event-stream")

      before = Utils.session_count(server())

      ctx =
        OzMcp.Context.new(server(), :http_streamable, :rpc)
        |> OzMcp.Context.put_http_conn(conn)
        |> Validate.http_post()
        |> plain()

      assert is_nil(ctx.error)
      assert is_nil(ctx.session_id)
      assert get_resp_header(ctx.conn, "mcp-session-id") == []
      assert Utils.session_count(server()) == before
    end

    test "puts :http_initialize_with_session_id error when session id is provided for initialize method" do
      conn = build_conn() |> put_req_header("mcp-session-id", "existing-session-id-value")
      ctx = plain(Http.session_id(context(conn, rpc_method: "initialize")))

      refute is_nil(ctx.error)
      assert ctx.error.code == :http_initialize_with_session_id
    end

    test "put :http_missing_session_id error in context when session header is missing for non-initialize" do
      conn = build_conn()
      ctx = plain(Http.session_id(context(conn, rpc_method: "resources/list")))

      refute is_nil(ctx.error)
      assert ctx.error.code == :http_missing_session_id
    end

    test "sets session_id from header for non-initialize" do
      sid = Utils.generate_session_id()
      conn = build_conn() |> put_req_header("mcp-session-id", sid)
      ctx = plain(Http.session_id(context(conn, rpc_method: "resources/list")))

      assert is_nil(ctx.error)
      assert ctx.session_id == sid
    end

    for bad <- ["", String.duplicate("a", 129), "a b", "ab\x7F", "é"] do
      test "a session id of #{inspect(bad)} gets :http_invalid_session_id" do
        conn = build_conn() |> put_req_header("mcp-session-id", unquote(bad))
        ctx = plain(Http.session_id(context(conn, rpc_method: "resources/list")))

        refute is_nil(ctx.error)
        assert ctx.error.code == :http_invalid_session_id
      end
    end

    test "two mcp-session-id headers get :http_invalid_session_id" do
      base = build_conn()

      conn = %{
        base
        | req_headers: [
            {"mcp-session-id", "one"},
            {"mcp-session-id", "two"} | base.req_headers
          ]
      }

      ctx = plain(Http.session_id(context(conn, rpc_method: "resources/list")))

      refute is_nil(ctx.error)
      assert ctx.error.code == :http_invalid_session_id
    end

    test "an initialize with an empty session id header gets :http_initialize_with_session_id" do
      conn = build_conn() |> put_req_header("mcp-session-id", "")
      ctx = plain(Http.session_id(context(conn, rpc_method: "initialize")))

      refute is_nil(ctx.error)
      assert ctx.error.code == :http_initialize_with_session_id
    end

    test "an initialize with an invalid session id header gets :http_initialize_with_session_id" do
      conn = build_conn() |> put_req_header("mcp-session-id", "a b")
      ctx = plain(Http.session_id(context(conn, rpc_method: "initialize")))

      refute is_nil(ctx.error)
      assert ctx.error.code == :http_initialize_with_session_id
    end
  end

  # -------------------------------------------------------------------
  # valid_session_id?/1
  # -------------------------------------------------------------------

  describe "valid_session_id?/1" do
    test "accepts the id that the library makes" do
      assert Http.valid_session_id?(Utils.generate_session_id())
    end

    test "accepts 1 to 128 bytes of visible ASCII" do
      assert Http.valid_session_id?("a")
      assert Http.valid_session_id?(String.duplicate("a", 40))
      assert Http.valid_session_id?(String.duplicate("a", 128))
    end

    test "refuses an empty value, a value over 128 bytes, a space, a control byte and a non-ASCII byte" do
      refute Http.valid_session_id?("")
      refute Http.valid_session_id?(String.duplicate("a", 129))
      refute Http.valid_session_id?("a b")
      refute Http.valid_session_id?("ab\x7F")
      refute Http.valid_session_id?("é")
    end
  end

  # -------------------------------------------------------------------
  # protocol_version/1
  # -------------------------------------------------------------------

  describe "protocol_version/1" do
    test "skips validation for initialize" do
      conn =
        build_conn()
        |> put_req_header("mcp-protocol-version", "2025-06-18")

      ctx = plain(Http.protocol_version(context(conn, rpc_method: "initialize")))

      assert is_nil(ctx.error)
    end

    test "accepts when the header is missing" do
      conn = build_conn()

      ctx = plain(Http.protocol_version(context(conn, rpc_method: "resources/list")))

      assert is_nil(ctx.error)
    end

    test "passes when the header contains a supported version" do
      conn =
        build_conn()
        |> put_req_header("mcp-protocol-version", "2025-11-25")

      ctx = plain(Http.protocol_version(context(conn, rpc_method: "resources/list")))

      assert is_nil(ctx.error)
    end

    test "puts :http_unsupported_protocol_version error when the header contains an unsupported version" do
      conn =
        build_conn()
        |> put_req_header("mcp-protocol-version", "2025-06-18")

      ctx = plain(Http.protocol_version(context(conn, rpc_method: "resources/list")))

      refute is_nil(ctx.error)
      assert ctx.error.code == :http_unsupported_protocol_version
    end

    test "validates even without an rpc method (DELETE style pipelines)" do
      conn =
        build_conn()
        |> put_req_header("mcp-protocol-version", "2025-06-18")

      ctx = plain(Http.protocol_version(context(conn)))

      refute is_nil(ctx.error)
      assert ctx.error.code == :http_unsupported_protocol_version
    end

    # The stage runs before the compare with the version of the session
    # on POST, GET and DELETE, so the compare never sees two headers.
    # The shapes of the context below are the shapes of the three routes.
    #
    @routes [
      post: [rpc_method: "resources/list"],
      get: [mode: :http],
      delete: [mode: :rpc]
    ]

    defp conn_with_headers(headers) do
      base = build_conn()
      %{base | req_headers: headers ++ base.req_headers}
    end

    for {route, overrides} <- @routes do
      test "two equal headers give :http_unsupported_protocol_version on #{route}" do
        conn =
          conn_with_headers([
            {"mcp-protocol-version", "2025-11-25"},
            {"mcp-protocol-version", "2025-11-25"}
          ])

        ctx = plain(Http.protocol_version(context(conn, unquote(Macro.escape(overrides)))))

        refute is_nil(ctx.error)
        assert ctx.error.code == :http_unsupported_protocol_version
      end

      test "two different headers give :http_unsupported_protocol_version on #{route}" do
        #
        # The first header holds a supported version: the refusal is about
        # the number of header lines, not about the values.
        #
        conn =
          conn_with_headers([
            {"mcp-protocol-version", "2025-11-25"},
            {"mcp-protocol-version", "2025-06-18"}
          ])

        ctx = plain(Http.protocol_version(context(conn, unquote(Macro.escape(overrides)))))

        refute is_nil(ctx.error)
        assert ctx.error.code == :http_unsupported_protocol_version
      end

      test "one header passes on #{route}" do
        conn = conn_with_headers([{"mcp-protocol-version", "2025-11-25"}])
        ctx = plain(Http.protocol_version(context(conn, unquote(Macro.escape(overrides)))))

        assert is_nil(ctx.error)
      end
    end
  end

  # -------------------------------------------------------------------
  # session/1
  # -------------------------------------------------------------------

  describe "session/1" do
    test "passes for a ping without a session id (a stdio ping before initialize)" do
      result = plain(Http.session(context(build_conn(), rpc_method: "ping")))
      assert is_nil(result.error)
    end

    test "returns :http_invalid_session for ping when the session does not exist" do
      session_id = Utils.generate_session_id()

      result =
        plain(Http.session(context(build_conn(), rpc_method: "ping", session_id: session_id)))

      refute is_nil(result.error)
      assert result.error.code == :http_invalid_session
    end

    test "skips validation for initialize" do
      result = plain(Http.session(context(build_conn(), rpc_method: "initialize")))
      assert is_nil(result.error)
    end

    test "returns :http_invalid_session for notifications/initialized when session id is missing" do
      result =
        plain(Http.session(context(build_conn(), rpc_method: "notifications/initialized")))

      refute is_nil(result.error)
      assert result.error.code == :http_invalid_session
    end

    test "returns :http_invalid_session for notifications/initialized when session does not exist" do
      session_id = Utils.generate_session_id()

      result =
        plain(
          Http.session(
            context(build_conn(), rpc_method: "notifications/initialized", session_id: session_id)
          )
        )

      refute is_nil(result.error)
      assert result.error.code == :http_invalid_session
    end

    test "accepts notifications/initialized when the session is already initialized" do
      session_id = Utils.create_session(server(), initialized: true)

      result =
        plain(
          Http.session(
            context(build_conn(), rpc_method: "notifications/initialized", session_id: session_id)
          )
        )

      assert is_nil(result.error)
      assert result.session_initialized == true
    end

    test "gives :http_protocol_version_mismatch for a duplicate notifications/initialized with a header that does not match the session" do
      session_id = Utils.create_session(server(), initialized: true)
      :ok = OzMcp.Session.update_view(server(), session_id, protocol_version: "2025-11-25")

      conn =
        build_conn()
        |> put_req_header("mcp-protocol-version", "2025-06-18")

      result =
        plain(
          Http.session(
            context(conn, rpc_method: "notifications/initialized", session_id: session_id)
          )
        )

      refute is_nil(result.error)
      assert result.error.code == :http_protocol_version_mismatch
    end

    test "passes for notifications/initialized when a non-initialized session is attached" do
      session_id = Utils.create_session(server())

      result =
        plain(
          Http.session(
            context(build_conn(), rpc_method: "notifications/initialized", session_id: session_id)
          )
        )

      assert is_nil(result.error)
    end

    test "puts the capabilities the client declared into the context" do
      session_id =
        Utils.create_session(server(),
          initialized: true,
          client_capabilities: %{"roots" => %{}}
        )

      result =
        plain(
          Http.session(context(build_conn(), rpc_method: "tools/call", session_id: session_id))
        )

      assert is_nil(result.error)
      assert result.client_capabilities == %{"roots" => %{}}
    end

    test "logging/setLevel requires an initialized session (spec: logging exception is server->client only)" do
      #
      # non-initialized session -> waiting initialization
      #
      session_id = Utils.create_session(server())

      result =
        plain(
          Http.session(
            context(build_conn(), rpc_method: "logging/setLevel", session_id: session_id)
          )
        )

      refute is_nil(result.error)
      assert result.error.code == :rpc_session_waiting_initialization

      # initialized session -> passes
      #
      session_id = Utils.create_session(server(), initialized: true)

      result =
        plain(
          Http.session(
            context(build_conn(), rpc_method: "logging/setLevel", session_id: session_id)
          )
        )

      assert is_nil(result.error)
    end

    test "returns with rpc error when session does not exist" do
      session_id = Utils.generate_session_id()

      result =
        plain(
          Http.session(
            context(build_conn(), rpc_id: 1, rpc_method: "resources/list", session_id: session_id)
          )
        )

      refute is_nil(result.error)
      assert result.error.code == :http_invalid_session
    end

    test "returns with rpc error when session is not initialized" do
      session_id = Utils.create_session(server())

      result =
        plain(
          Http.session(
            context(build_conn(), rpc_id: 1, rpc_method: "resources/list", session_id: session_id)
          )
        )

      refute is_nil(result.error)
      assert result.error.code == :rpc_session_waiting_initialization
    end

    test "returns with http error when session is not initialized (http mode)" do
      session_id = Utils.create_session(server())

      result =
        plain(
          Http.session(
            context(build_conn(),
              rpc_id: 1,
              rpc_method: "resources/list",
              session_id: session_id,
              mode: :http
            )
          )
        )

      refute is_nil(result.error)
      assert result.error.code == :http_session_waiting_initialization
    end

    test "passes through when session is initialized" do
      session_id = Utils.create_session(server(), initialized: true)

      result =
        plain(
          Http.session(
            context(build_conn(), rpc_method: "resources/list", session_id: session_id)
          )
        )

      assert is_nil(result.error)
    end
  end

  # -------------------------------------------------------------------
  # session/1 with a principal (authorization on)
  # -------------------------------------------------------------------

  describe "session/1 with a principal" do
    alias OzMcp.Auth.Principal

    @alice Principal.new!(issuer: "https://issuer.test", subject: "alice")
    @bob Principal.new!(issuer: "https://issuer.test", subject: "bob")

    defp create_owned_session(subject) do
      {:ok, session_id} =
        Sessions.start(server(), principal_key: {"https://issuer.test", subject})

      Sessions.set_initialized(server(), session_id)
      session_id
    end

    defp create_uninitialized_session(subject) do
      {:ok, session_id} =
        Sessions.start(server(), principal_key: {"https://issuer.test", subject})

      session_id
    end

    test "refuses a session that belongs to another principal" do
      session_id = create_owned_session("alice")

      result =
        plain(
          Http.session(
            context(build_conn(),
              rpc_method: "tools/call",
              session_id: session_id,
              principal: @bob
            )
          )
        )

      refute is_nil(result.error)
      assert result.error.code == :http_invalid_session
    end

    test "gives the answer of an unknown session for a non-initialized session of another principal" do
      session_id = create_uninitialized_session("alice")

      result =
        plain(
          Http.session(
            context(build_conn(),
              rpc_method: "tools/call",
              session_id: session_id,
              principal: @bob
            )
          )
        )

      refute is_nil(result.error)
      assert result.error.code == :http_invalid_session
    end

    test "the owner of a non-initialized session gets the waiting-initialization answer (rpc mode)" do
      session_id = create_uninitialized_session("alice")

      result =
        plain(
          Http.session(
            context(build_conn(),
              rpc_method: "tools/call",
              session_id: session_id,
              principal: @alice
            )
          )
        )

      refute is_nil(result.error)
      assert result.error.code == :rpc_session_waiting_initialization
    end

    test "the owner of a non-initialized session gets the waiting-initialization answer (http mode)" do
      session_id = create_uninitialized_session("alice")

      result =
        plain(
          Http.session(
            context(build_conn(),
              rpc_method: "tools/call",
              session_id: session_id,
              principal: @alice,
              mode: :http
            )
          )
        )

      refute is_nil(result.error)
      assert result.error.code == :http_session_waiting_initialization
    end

    test "accepts the principal that owns the session and puts the capabilities" do
      {:ok, session_id} =
        Sessions.start(server(),
          protocol_version: nil,
          client_info: nil,
          client_capabilities: %{"roots" => %{}},
          principal_key: {"https://issuer.test", "alice"}
        )

      Sessions.set_initialized(server(), session_id)

      result =
        plain(
          Http.session(
            context(build_conn(),
              rpc_method: "tools/call",
              session_id: session_id,
              principal: @alice
            )
          )
        )

      assert is_nil(result.error)
      assert result.client_capabilities == %{"roots" => %{}}
    end

    test "keeps the session of a principal with other scopes (same subject)" do
      session_id = create_owned_session("alice")

      other_scopes =
        Principal.new!(issuer: "https://issuer.test", subject: "alice", scopes: ["files:write"])

      result =
        plain(
          Http.session(
            context(build_conn(),
              rpc_method: "tools/call",
              session_id: session_id,
              principal: other_scopes
            )
          )
        )

      assert is_nil(result.error)
    end

    test "refuses a ping for a session that belongs to another principal" do
      session_id = create_owned_session("alice")

      result =
        plain(
          Http.session(
            context(build_conn(),
              rpc_method: "ping",
              session_id: session_id,
              principal: @bob
            )
          )
        )

      refute is_nil(result.error)
      assert result.error.code == :http_invalid_session
    end

    test "the owner check runs first: a ping of another principal whose header differs from the session gets the refusal of the session" do
      session_id = create_owned_session("alice")
      :ok = OzMcp.Session.update_view(server(), session_id, protocol_version: "2025-06-18")

      conn = build_conn() |> put_req_header("mcp-protocol-version", "2025-11-25")

      result =
        plain(
          Http.session(context(conn, rpc_method: "ping", session_id: session_id, principal: @bob))
        )

      refute is_nil(result.error)
      assert result.error.code == :http_invalid_session
    end

    test "the owner of a session that waits initialization can ping it" do
      session_id = create_uninitialized_session("alice")

      result =
        plain(
          Http.session(
            context(build_conn(),
              rpc_method: "ping",
              session_id: session_id,
              principal: @alice
            )
          )
        )

      assert is_nil(result.error)
    end

    test "the owner of an initialized session can ping it" do
      session_id = create_owned_session("alice")

      result =
        plain(
          Http.session(
            context(build_conn(),
              rpc_method: "ping",
              session_id: session_id,
              principal: @alice
            )
          )
        )

      assert is_nil(result.error)
    end

    test "refuses notifications/initialized of a session that belongs to another principal" do
      session_id = create_owned_session("alice")

      result =
        plain(
          Http.session(
            context(build_conn(),
              rpc_method: "notifications/initialized",
              session_id: session_id,
              principal: @bob
            )
          )
        )

      refute is_nil(result.error)
      assert result.error.code == :http_invalid_session
    end

    test "refuses a duplicate notifications/initialized of a session that belongs to another principal" do
      session_id = create_owned_session("alice")

      result =
        plain(
          Http.session(
            context(build_conn(),
              rpc_method: "notifications/initialized",
              session_id: session_id,
              principal: @bob
            )
          )
        )

      refute is_nil(result.error)
      assert result.error.code == :http_invalid_session
      refute result.session_initialized
    end

    test "accepts a duplicate notifications/initialized of the principal that owns the session" do
      session_id = create_owned_session("alice")

      result =
        plain(
          Http.session(
            context(build_conn(),
              rpc_method: "notifications/initialized",
              session_id: session_id,
              principal: @alice
            )
          )
        )

      assert is_nil(result.error)
      assert result.session_initialized == true
    end

    test "accepts notifications/initialized of the principal that owns the session" do
      {:ok, session_id} =
        Sessions.start(server(), principal_key: {"https://issuer.test", "alice"})

      result =
        plain(
          Http.session(
            context(build_conn(),
              rpc_method: "notifications/initialized",
              session_id: session_id,
              principal: @alice
            )
          )
        )

      assert is_nil(result.error)
    end

    test "fails closed when the runtime does not have the server" do
      conn = build_conn() |> put_private(:server, localhost())

      result =
        plain(
          Http.session(
            context(conn,
              rpc_method: "tools/call",
              session_id: Utils.generate_session_id(),
              principal: @alice
            )
          )
        )

      refute is_nil(result.error)
      assert result.error.code == :http_unavailable
    end

    test "fails closed without a principal when the runtime does not have the server" do
      conn = build_conn() |> put_private(:server, localhost())

      result =
        plain(
          Http.session(
            context(conn,
              rpc_method: "tools/call",
              session_id: Utils.generate_session_id()
            )
          )
        )

      refute is_nil(result.error)
      assert result.error.code == :http_unavailable
    end

    test "a ping fails closed when the runtime does not have the protected server" do
      conn = build_conn() |> put_private(:server, localhost())

      result =
        plain(
          Http.session(
            context(conn,
              rpc_method: "ping",
              session_id: Utils.generate_session_id(),
              principal: @alice
            )
          )
        )

      refute is_nil(result.error)
      assert result.error.code == :http_unavailable
    end

    test "a ping fails closed without a principal when the runtime does not have the server" do
      conn = build_conn() |> put_private(:server, localhost())

      result =
        plain(
          Http.session(
            context(conn,
              rpc_method: "ping",
              session_id: Utils.generate_session_id()
            )
          )
        )

      refute is_nil(result.error)
      assert result.error.code == :http_unavailable
    end
  end

  # -------------------------------------------------------------------
  # session_owner/1 (the DELETE route)
  # -------------------------------------------------------------------

  describe "session_owner/1" do
    test "keeps the context when authorization is off" do
      session_id = Utils.create_session(server())

      result = plain(Http.session_owner(context(build_conn(), session_id: session_id)))

      assert is_nil(result.error)
    end

    test "gives :http_protocol_version_mismatch for a header that differs from the session" do
      session_id = Utils.create_session(server(), initialized: true)
      :ok = OzMcp.Session.update_view(server(), session_id, protocol_version: "2025-06-18")

      conn = build_conn() |> put_req_header("mcp-protocol-version", "2025-11-25")

      result = plain(Http.session_owner(context(conn, session_id: session_id)))

      refute is_nil(result.error)
      assert result.error.code == :http_protocol_version_mismatch
    end

    test "accepts the principal that owns the session" do
      session_id = create_uninitialized_session("alice")

      result =
        plain(
          Http.session_owner(context(build_conn(), session_id: session_id, principal: @alice))
        )

      assert is_nil(result.error)
    end

    test "accepts a session that is not initialized yet (DELETE needs no initialization)" do
      session_id = create_uninitialized_session("alice")

      result =
        plain(
          Http.session_owner(context(build_conn(), session_id: session_id, principal: @alice))
        )

      assert is_nil(result.error)
    end

    test "refuses a principal that does not own the session" do
      session_id = create_uninitialized_session("alice")

      result =
        plain(Http.session_owner(context(build_conn(), session_id: session_id, principal: @bob)))

      refute is_nil(result.error)
      assert result.error.code == :http_invalid_session
    end

    test "refuses an unknown session" do
      result =
        plain(
          Http.session_owner(
            context(build_conn(),
              session_id: Utils.generate_session_id(),
              principal: @alice
            )
          )
        )

      refute is_nil(result.error)
      assert result.error.code == :http_invalid_session
    end
  end

  # -------------------------------------------------------------------
  # auth/1
  # -------------------------------------------------------------------

  describe "auth/1" do
    alias OzMcp.Auth.Principal

    test "copies the principal of the connection into the context" do
      principal = Principal.new!(subject: "alice", issuer: "https://issuer.test")

      conn =
        build_conn()
        |> put_private(:oz_mcp_principal, principal)

      result = plain(Http.auth(context(conn)))

      assert result.principal == principal
      assert is_nil(result.error)
    end

    test "keeps the principal nil when the connection holds none (authorization off)" do
      result = plain(Http.auth(context(build_conn())))

      assert result.principal == nil
      assert is_nil(result.error)
    end

    test "passes through a context with no connection" do
      ctx = OzMcp.Context.new(server(), :http_streamable, :rpc)

      assert plain(Http.auth(ctx)) == ctx
    end
  end

  # -------------------------------------------------------------------
  # required_scopes/1 (the scopes that the DSL requires)
  # -------------------------------------------------------------------

  describe "required_scopes/1" do
    alias OzMcp.Auth.Principal

    @alice Principal.new!(issuer: "https://issuer.test", subject: "alice", scopes: ["files:read"])

    @alice_admin Principal.new!(
                   issuer: "https://issuer.test",
                   subject: "alice",
                   scopes: ["files:read", "files:write"]
                 )

    defp scoped_context(opts) do
      conn =
        build_conn()
        |> put_private(:server, authorized())

      method = Keyword.get(opts, :rpc_method)

      context(conn, opts)
      |> Map.put(
        :bound,
        %Bound{
          kind: bound_kind(method),
          params: Keyword.get(opts, :rpc_params) || %{},
          required_scopes: Keyword.get(opts, :required_scopes, [])
        }
      )
    end

    defp bound_kind("tools/call"), do: :tool
    defp bound_kind("resources/read"), do: :resource
    defp bound_kind("resources/subscribe"), do: :resource
    defp bound_kind("prompts/get"), do: :prompt
    defp bound_kind(_method), do: :none

    test "keeps the context of an open server (no principal)" do
      ctx = scoped_context(rpc_method: "tools/call", required_scopes: ["files:write"])

      assert plain(Http.required_scopes(ctx)) == ctx
      assert is_nil(ctx.error)
    end

    test "keeps the context when the entity needs no scope" do
      ctx = scoped_context(principal: @alice, rpc_method: "tools/call")

      assert plain(Http.required_scopes(ctx)) == ctx
      assert is_nil(ctx.error)
    end

    test "keeps the context when the principal holds all the scopes" do
      ctx =
        scoped_context(
          principal: @alice_admin,
          rpc_method: "tools/call",
          required_scopes: ["files:write"]
        )

      assert plain(Http.required_scopes(ctx)) == ctx
      assert is_nil(ctx.error)
    end

    test "refuses with a 403 challenge when the principal lacks the scope" do
      result =
        plain(
          Http.required_scopes(
            scoped_context(
              principal: @alice,
              rpc_method: "tools/call",
              required_scopes: ["files:write"]
            )
          )
        )

      refute is_nil(result.error)
      assert result.error.code == :http_insufficient_scope
      assert result.error.headers == [{"www-authenticate", header(result)}]

      assert header(result) ==
               ~s(Bearer error="insufficient_scope", scope="files:read files:write", resource_metadata="#{@metadata_url}")
    end

    test "refuses when the principal holds only a part of the scopes" do
      result =
        plain(
          Http.required_scopes(
            scoped_context(
              principal: @alice_admin,
              rpc_method: "tools/call",
              required_scopes: ["files:write", "admin"]
            )
          )
        )

      refute is_nil(result.error)
      assert result.error.code == :http_insufficient_scope
      assert header(result) =~ ~s(scope="files:read files:write admin")
    end
  end

  # -------------------------------------------------------------------
  # authorize/1 (the optional authorize/3 callback of the verifier)
  # -------------------------------------------------------------------

  describe "authorize/1" do
    alias OzMcp.Auth.Principal

    @alice Principal.new!(issuer: "https://issuer.test", subject: "alice", scopes: ["files:read"])

    @alice_admin Principal.new!(
                   issuer: "https://issuer.test",
                   subject: "alice",
                   scopes: ["files:read", "files:write"]
                 )

    # The bind stage ran for every request but `initialize` in the real
    # pipeline: the context of these tests carries the bound entity the
    # callback receives. `initialize` keeps no bound: the stage
    # `authorize_initialize/1` runs before the bind stage and the
    # framework builds one of kind :none from the params.
    #
    defp protected_context(overrides) do
      conn =
        build_conn()
        |> put_private(:server, authorized())

      method = Keyword.get(overrides, :rpc_method)
      context = context(conn, overrides)

      cond do
        bound = Keyword.get(overrides, :bound) ->
          Map.put(context, :bound, bound)

        method == "initialize" ->
          context

        true ->
          Map.put(context, :bound, bound_for(method, Keyword.get(overrides, :rpc_params)))
      end
    end

    defp bound_for("tools/call", rpc_params),
      do: %Bound{
        kind: :tool,
        name: rpc_params["name"],
        params: rpc_params,
        arguments: rpc_params["arguments"] || %{}
      }

    defp bound_for("resources/read", rpc_params),
      do: %Bound{kind: :resource, name: rpc_params["uri"], params: rpc_params}

    defp bound_for("tasks/list", rpc_params),
      do: %Bound{kind: :task, params: rpc_params}

    defp bound_for(_method, rpc_params),
      do: %Bound{kind: :none, params: rpc_params || %{}}

    test "passes a request the principal is allowed to do" do
      result =
        plain(
          Http.authorize(
            protected_context(
              principal: @alice_admin,
              rpc_method: "tools/call",
              rpc_params: %{"name" => "get_date"}
            )
          )
        )

      assert is_nil(result.error)
    end

    test "authorize/3 receives the bound entity of a task-augmented call" do
      bound = %Bound{
        kind: :tool,
        name: "get_date",
        task: %{ttl: 5_000},
        params: %{"name" => "get_date"}
      }

      # The verifier records the bound under the subject of the principal:
      # the test uses a subject of its own, so the parallel tests that make
      # task-augmented calls never touch what it reads.
      #
      principal = %{@alice_admin | subject: "bound-#{System.unique_integer([:positive])}"}

      result =
        plain(
          Http.authorize(
            protected_context(
              principal: principal,
              rpc_method: "tools/call",
              rpc_params: %{"name" => "get_date", "task" => %{"ttl" => 5_000}},
              bound: bound
            )
          )
        )

      assert is_nil(result.error)
      assert Support.Auth.Default.task_bound(principal.subject) == bound
    end

    test "refuses a request out of scope with a 403 and the challenge header" do
      result =
        plain(
          Http.authorize(
            protected_context(
              principal: @alice,
              rpc_method: "tools/call",
              rpc_params: %{"name" => "get_date"}
            )
          )
        )

      refute is_nil(result.error)
      assert result.error.code == :http_insufficient_scope
      assert result.error.headers == [{"www-authenticate", header(result)}]

      challenge = header(result)

      assert challenge =~ ~s(error="insufficient_scope")
      assert challenge =~ ~s(error_description="write permission needed")
      assert challenge =~ ~s(scope="files:read files:write")
      assert challenge =~ ~s(resource_metadata="#{@metadata_url}")
    end

    test "an empty scope list gives the challenge_scopes of the server" do
      result =
        plain(
          Http.authorize(
            protected_context(
              principal: @alice,
              rpc_method: "tasks/list",
              rpc_params: %{"cursor" => "empty-scopes"}
            )
          )
        )

      assert result.error.code == :http_insufficient_scope

      assert header(result) ==
               ~s(Bearer error="insufficient_scope", scope="files:read", resource_metadata="#{@metadata_url}")
    end

    test "an empty scope list with a description keeps the description" do
      result =
        plain(
          Http.authorize(
            protected_context(
              principal: @alice,
              rpc_method: "tasks/list",
              rpc_params: %{"cursor" => "empty-scopes-description"}
            )
          )
        )

      challenge = header(result)

      assert challenge =~ ~s(error_description="need more scopes")
      assert challenge =~ ~s(scope="files:read")
    end

    test "a server with no challenge_scopes gives a header with no scope parameter" do
      Utils.stop_instance(server())

      no_scopes =
        Module.concat(@localhost_module, "NoScopes#{System.unique_integer([:positive])}")

      Utils.start_instance(
        @localhost_module,
        [name: no_scopes] ++ Map.to_list(%{resource_url: "http://127.0.0.1/mcp"})
      )

      conn = build_conn() |> put_private(:server, no_scopes)

      result =
        plain(
          Http.authorize(
            context(conn,
              principal: Principal.new!(issuer: "https://issuer.test", subject: "alice"),
              rpc_method: "tasks/list",
              rpc_params: %{"cursor" => "empty-scopes"}
            )
          )
        )

      assert result.error.code == :http_insufficient_scope

      assert header(result) ==
               ~s(Bearer error="insufficient_scope", resource_metadata="http://127.0.0.1/.well-known/oauth-protected-resource/mcp")
    end

    test "refuses a request the verifier forbids, with no challenge header" do
      result =
        plain(
          Http.authorize(
            protected_context(
              principal: @alice,
              rpc_method: "resources/read",
              rpc_params: %{"uri" => "file:///marketing.md"}
            )
          )
        )

      refute is_nil(result.error)
      assert result.error.code == :http_forbidden
      assert result.error.headers == []
    end

    test "fails closed on a wrong return value of the callback" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          result =
            plain(
              Http.authorize(
                protected_context(
                  principal: @alice,
                  rpc_method: "tasks/list",
                  rpc_params: %{"cursor" => "bad-return"}
                )
              )
            )

          refute is_nil(result.error)
          assert result.error.code == :http_internal_error
        end)

      assert log =~ "returned an invalid value"
    end

    test "fails closed when the callback raises" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          result =
            plain(
              Http.authorize(
                protected_context(
                  principal: @alice,
                  rpc_method: "tasks/list",
                  rpc_params: %{"cursor" => "crash"}
                )
              )
            )

          refute is_nil(result.error)
          assert result.error.code == :http_internal_error
        end)

      assert log =~ "authorize/3 failed"
    end

    test "a scope that breaks the syntax is a defect of the callback" do
      log =
        Utils.capture_log([level: :error], fn ->
          result =
            plain(
              Http.authorize(
                protected_context(
                  principal: @alice,
                  rpc_method: "tasks/list",
                  rpc_params: %{"cursor" => "bad-scope"}
                )
              )
            )

          refute is_nil(result.error)
          assert result.error.code == :http_internal_error
          assert result.error.headers == []
        end)

      assert log =~ "authorize/3 returned an invalid value"
      assert log =~ "RFC 6749 scope tokens"
      refute log =~ "SECRET-TOKEN"
    end

    test "keeps the context of an open server (no principal)" do
      ctx = protected_context(rpc_method: "tools/call", rpc_params: %{"name" => "get_date"})

      assert plain(Http.authorize(ctx)) == ctx
    end

    test "skips the answer of a client (no method)" do
      ctx = protected_context(principal: @alice, rpc_method: nil)

      assert plain(Http.authorize(ctx)) == ctx
    end

    test "skips initialize (the check runs before the session exists)" do
      ctx =
        protected_context(
          principal: @alice,
          rpc_method: "initialize",
          rpc_params: %{
            "protocolVersion" => "2025-11-25",
            "clientInfo" => %{"name" => "refused-client", "version" => "1.0.0"}
          }
        )

      assert plain(Http.authorize(ctx)) == ctx
    end

    test "a verifier without authorize/3 lets every request pass" do
      broken = Module.concat(@broken_module, "Broken#{System.unique_integer([:positive])}")

      Utils.start_instance(@broken_module, name: broken, resource_url: @resource_url)

      conn =
        build_conn()
        |> put_private(:server, broken)

      principal = Principal.new!(subject: "broken")

      result =
        plain(
          Http.authorize(
            context(conn,
              principal: principal,
              rpc_method: "tools/call",
              rpc_params: %{"name" => "get_date"}
            )
          )
        )

      assert is_nil(result.error)
    end

    # Each cursor embeds the marker string "SECRET-TOKEN" in the data of
    # the failure: a raise, a throw, an exit, or a returned value.
    #
    for cursor <- ["secret-match", "secret-clause", "secret-throw", "secret-exit", "secret-value"] do
      test "the log at level :error does not hold the marker string (#{cursor})" do
        log =
          Utils.capture_log([level: :error], fn ->
            result =
              plain(
                Http.authorize(
                  protected_context(
                    principal: @alice,
                    rpc_method: "tasks/list",
                    rpc_params: %{"cursor" => unquote(cursor)}
                  )
                )
              )

            refute is_nil(result.error)
            assert result.error.code == :http_internal_error
          end)

        refute log =~ "SECRET-TOKEN"
        assert log =~ "authorize/3"

        assert log |> String.split("\n") |> Enum.count(&String.contains?(&1, "[error]")) == 1
      end
    end

    test "a raise of the callback logs the exception module and a stacktrace with no arguments" do
      log =
        Utils.capture_log([level: :error], fn ->
          plain(
            Http.authorize(
              protected_context(
                principal: @alice,
                rpc_method: "tasks/list",
                rpc_params: %{"cursor" => "secret-clause"}
              )
            )
          )
        end)

      assert log =~ "FunctionClauseError"
      assert log =~ "leak_clause/2"
      refute log =~ "SECRET-TOKEN"
    end

    test "the text of the exception of the callback appears only at level :debug" do
      error_log =
        Utils.capture_log([level: :error], fn ->
          plain(
            Http.authorize(
              protected_context(
                principal: @alice,
                rpc_method: "tasks/list",
                rpc_params: %{"cursor" => "secret-match"}
              )
            )
          )
        end)

      refute error_log =~ "no match of right hand side"

      debug_log =
        Utils.capture_log([level: :debug], fn ->
          plain(
            Http.authorize(
              protected_context(
                principal: @alice,
                rpc_method: "tasks/list",
                rpc_params: %{"cursor" => "secret-match"}
              )
            )
          )
        end)

      assert debug_log =~ "no match of right hand side"
    end

    test "a callback that returns :failed is an invalid value, not a failure" do
      log =
        Utils.capture_log(fn ->
          result =
            plain(
              Http.authorize(
                protected_context(
                  principal: @alice,
                  rpc_method: "tasks/list",
                  rpc_params: %{"cursor" => "failed-marker"}
                )
              )
            )

          refute is_nil(result.error)
          assert result.error.code == :http_internal_error
        end)

      assert log =~ "returned an invalid value: :failed"
      refute log =~ "authorize/3 failed"
    end

    defp header(context), do: context.error.headers |> List.first() |> elem(1)
  end

  # -------------------------------------------------------------------
  # authorize_initialize/1 (the authorize/3 callback for initialize)
  # -------------------------------------------------------------------

  describe "authorize_initialize/1" do
    @refused_params %{
      "protocolVersion" => "2025-11-25",
      "clientInfo" => %{"name" => "refused-client", "version" => "1.0.0"}
    }

    test "refuses an initialize out of scope and creates no session" do
      before = Utils.session_count(authorized())

      result =
        plain(
          Http.authorize_initialize(
            protected_context(
              principal: @alice,
              rpc_method: "initialize",
              rpc_params: @refused_params
            )
          )
        )

      refute is_nil(result.error)
      assert result.error.code == :http_insufficient_scope
      assert Utils.session_count(authorized()) == before
    end

    test "an empty scope list of initialize gives the challenge_scopes of the server" do
      result =
        plain(
          Http.authorize_initialize(
            protected_context(
              principal: @alice,
              rpc_method: "initialize",
              rpc_params: %{
                "protocolVersion" => "2025-11-25",
                "clientInfo" => %{"name" => "empty-scope-client", "version" => "1.0.0"}
              }
            )
          )
        )

      assert result.error.code == :http_insufficient_scope
      assert header(result) =~ ~s(scope="files:read")
    end

    test "passes a request whose method is not initialize through unchanged" do
      ctx =
        protected_context(
          principal: @alice,
          rpc_method: "tools/call",
          rpc_params: %{"name" => "get_date"}
        )

      assert plain(Http.authorize_initialize(ctx)) == ctx
    end
  end
end
