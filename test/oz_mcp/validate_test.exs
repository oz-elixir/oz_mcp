defmodule OzMcp.ValidateTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias OzMcp.Auth.Principal
  alias OzMcp.Validate
  alias OzMcp.Validate.Http
  alias Support.Helpers.Utils
  alias Support.Servers

  @server_module Servers.Default
  @server Module.concat(@server_module, __MODULE__)

  setup do
    Utils.start_instance(@server_module, name: @server)
    :ok
  end

  test "the POST pipeline has the stages in this order" do
    assert Validate.http_post_stages() == [
             {OzMcp.Validate.Http, :auth},
             {OzMcp.Validate.Http, :headers},
             {OzMcp.Validate.JsonRpc, :validate},
             {OzMcp.Validate.Http, :authorize_initialize},
             {OzMcp.Validate.Http, :session_id},
             {OzMcp.Validate.Http, :protocol_version},
             {OzMcp.Validate.Http, :restore},
             {OzMcp.Validate.Http, :session},
             {OzMcp.Pipeline.Bind, :run},
             {OzMcp.Validate.Http, :required_scopes},
             {OzMcp.Validate.Http, :authorize}
           ]
  end

  test "every POST stage is a function of its module" do
    for {module, fun} <- Validate.http_post_stages() do
      assert function_exported?(Code.ensure_loaded!(module), fun, 1)
    end
  end

  test "the stdio pipeline has the stages in this order: the bind is not one of them" do
    assert Validate.stdio_stages() == [
             {OzMcp.Validate.JsonRpc, :validate},
             {OzMcp.Validate.Stdio, :session_id},
             {OzMcp.Validate.Stdio, :session}
           ]
  end

  test "every stdio stage is a function of its module" do
    for {module, fun} <- Validate.stdio_stages() do
      assert function_exported?(Code.ensure_loaded!(module), fun, 1)
    end
  end

  test "stdio_bind/1 runs the bind stage: the context of a request gets its bound" do
    rpc = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/call",
      "params" => %{"name" => "get_date"}
    }

    session_id = Utils.create_session(@server, initialized: true)

    context =
      OzMcp.Context.new(@server, :stdio, :rpc)
      |> OzMcp.Context.put_rpc(rpc)
      |> Map.put(:session_id, session_id)

    assert {:cont, context} = Validate.stdio(context)
    assert {:cont, context} = Validate.stdio_bind(context)
    assert context.bound.kind == :tool
  end

  # -------------------------------------------------------------------
  # The GET pipeline
  # -------------------------------------------------------------------

  describe "the GET pipeline" do
    test "has the stages in this order" do
      assert Validate.http_get_stages() == [
               {OzMcp.Validate.Http, :auth},
               {OzMcp.Validate.Http, :sse_header},
               {OzMcp.Validate.Http, :session_id},
               {OzMcp.Validate.Http, :protocol_version},
               {OzMcp.Validate.Http, :restore},
               {OzMcp.Validate.Http, :session}
             ]
    end

    test "every stage is a function of its module" do
      for {module, fun} <- Validate.http_get_stages() do
        assert function_exported?(Code.ensure_loaded!(module), fun, 1)
      end
    end

    test "refuses a GET with no Accept header" do
      {:halt, ctx} = run_get(get_conn([]), @server)

      assert ctx.error.code == :http_no_accept_header
    end

    test "refuses a GET whose Accept header misses text/event-stream" do
      conn = get_conn([{"accept", "application/json"}])
      {:halt, ctx} = run_get(conn, @server)

      assert ctx.error.code == :http_no_event_stream_accept_header
    end

    test "refuses a GET with an unsupported protocol version header" do
      conn =
        get_conn([
          {"accept", "text/event-stream"},
          {"mcp-session-id", Utils.generate_session_id()},
          {"mcp-protocol-version", "2025-06-18"}
        ])

      {:halt, ctx} = run_get(conn, @server)

      assert ctx.error.code == :http_unsupported_protocol_version
    end

    test "refuses a GET with no session id" do
      conn = get_conn([{"accept", "text/event-stream"}])
      {:halt, ctx} = run_get(conn, @server)

      assert ctx.error.code == :http_missing_session_id
    end

    test "the session id runs before the protocol version: a GET with no session id and an unsupported version gets the refusal of the session id" do
      conn =
        get_conn([{"accept", "text/event-stream"}, {"mcp-protocol-version", "2025-06-18"}])

      {:halt, ctx} = run_get(conn, @server)

      assert ctx.error.code == :http_missing_session_id
    end

    test "refuses a GET for a session that does not exist" do
      conn =
        get_conn([{"accept", "text/event-stream"}])
        |> put_req_header("mcp-session-id", Utils.generate_session_id())

      {:halt, ctx} = run_get(conn, @server)

      assert ctx.error.code == :http_invalid_session
    end

    test "an open server gets 503 when the session read is unavailable" do
      conn =
        get_conn([{"accept", "text/event-stream"}])
        |> put_req_header("mcp-session-id", Utils.generate_session_id())

      {:halt, ctx} = run_get(conn, :no_such_instance)

      assert ctx.error.code == :http_unavailable
    end

    test "refuses a GET for a session that waits initialization" do
      session_id = Utils.create_session(@server)

      conn =
        get_conn([{"accept", "text/event-stream"}])
        |> put_req_header("mcp-session-id", session_id)

      {:halt, ctx} = run_get(conn, @server)

      assert ctx.error.code == :http_session_waiting_initialization
    end

    test "passes a GET for an initialized session" do
      session_id = Utils.create_session(@server, initialized: true)

      conn =
        get_conn([{"accept", "text/event-stream"}])
        |> put_req_header("mcp-session-id", session_id)

      {:cont, ctx} = run_get(conn, @server)

      assert is_nil(ctx.error)
      assert ctx.session_id == session_id
    end

    test "stops at the first refusal (a bad Accept wins over the missing session id)" do
      conn = get_conn([{"accept", "application/json"}])
      {:halt, ctx} = run_get(conn, @server)

      assert ctx.error.code == :http_no_event_stream_accept_header
      assert is_nil(ctx.session_id)
    end
  end

  # -------------------------------------------------------------------
  # The DELETE pipeline
  # -------------------------------------------------------------------

  describe "the DELETE pipeline" do
    test "has the stages in this order" do
      assert Validate.http_delete_stages() == [
               {OzMcp.Validate.Http, :auth},
               {OzMcp.Validate.Http, :session_id},
               {OzMcp.Validate.Http, :protocol_version},
               {OzMcp.Validate.Http, :restore},
               {OzMcp.Validate.Http, :session_owner}
             ]
    end

    test "every stage is a function of its module" do
      for {module, fun} <- Validate.http_delete_stages() do
        assert function_exported?(Code.ensure_loaded!(module), fun, 1)
      end
    end

    test "refuses a DELETE with no session id" do
      {:halt, ctx} = run_delete(conn(:delete, "/"), @server)

      assert ctx.error.code == :http_missing_session_id
    end

    test "refuses a DELETE with an unsupported protocol version header" do
      conn =
        conn(:delete, "/")
        |> put_req_header("mcp-session-id", Utils.generate_session_id())
        |> put_req_header("mcp-protocol-version", "2025-06-18")

      {:halt, ctx} = run_delete(conn, @server)

      assert ctx.error.code == :http_unsupported_protocol_version
    end

    test "refuses a DELETE for a session that does not exist" do
      alice = Principal.new!(issuer: "https://issuer.test", subject: "alice")

      conn =
        conn(:delete, "/")
        |> put_req_header("mcp-session-id", Utils.generate_session_id())
        |> put_private(:oz_mcp_principal, alice)

      {:halt, ctx} = run_delete(conn, @server)

      assert ctx.error.code == :http_invalid_session
    end

    test "refuses a DELETE for a session of another principal" do
      bob = Principal.new!(issuer: "https://issuer.test", subject: "bob")

      session_id =
        Utils.create_session(@server, principal_key: {"https://issuer.test", "alice"})

      conn =
        conn(:delete, "/")
        |> put_req_header("mcp-session-id", session_id)
        |> put_private(:oz_mcp_principal, bob)

      {:halt, ctx} = run_delete(conn, @server)

      assert ctx.error.code == :http_invalid_session
    end

    test "passes a DELETE of the owner of the session" do
      alice = Principal.new!(issuer: "https://issuer.test", subject: "alice")

      session_id =
        Utils.create_session(@server, principal_key: {"https://issuer.test", "alice"})

      conn =
        conn(:delete, "/")
        |> put_req_header("mcp-session-id", session_id)
        |> put_private(:oz_mcp_principal, alice)

      {:cont, ctx} = run_delete(conn, @server)

      assert is_nil(ctx.error)
      assert ctx.session_id == session_id
    end
  end

  test "the three pipelines run session_id, protocol_version, restore, session in this order" do
    for stages <- [
          Validate.http_post_stages(),
          Validate.http_get_stages(),
          Validate.http_delete_stages()
        ] do
      names = Enum.map(stages, fn {_module, fun} -> fun end)

      shared =
        Enum.filter(
          names,
          &(&1 in [:session_id, :protocol_version, :restore, :session, :session_owner])
        )

      assert Enum.map(shared, &if(&1 == :session_owner, do: :session, else: &1)) ==
               [:session_id, :protocol_version, :restore, :session]
    end
  end

  # -------------------------------------------------------------------
  # The restore stage
  # -------------------------------------------------------------------

  describe "the restore stage" do
    #
    # The instances of this module have no snapshot module: the restore
    # stage reads only the config of the instance and an unknown id
    # passes. The session stage that follows reads the Registry, finds
    # nothing and refuses the request.
    #
    test "passes an unknown id when the instance has no snapshot module" do
      conn =
        get_conn([{"accept", "text/event-stream"}])
        |> put_req_header("mcp-session-id", Utils.generate_session_id())

      session_id = get_req_header(conn, "mcp-session-id") |> hd()

      stage_context =
        @server
        |> context(conn)
        |> Map.put(:session_id, session_id)
        |> Map.put(:rpc_method, "ping")

      assert {:cont, _} = Http.restore(stage_context)
    end

    test "an unknown id passes the stage and the session stage refuses it" do
      conn =
        get_conn([{"accept", "text/event-stream"}])
        |> put_req_header("mcp-session-id", Utils.generate_session_id())

      {:halt, ctx} = run_get(conn, @server)

      assert ctx.error.code == :http_invalid_session
    end

    test "a method that needs no session passes with no session id" do
      conn = conn(:post, "/", "")

      stage_context =
        @server
        |> context(conn)
        |> Map.put(:session_id, nil)
        |> Map.put(:rpc_method, "initialize")

      assert {:cont, _} = Http.restore(stage_context)
    end

    test "an instance that does not run halts the stage" do
      conn =
        get_conn([{"accept", "text/event-stream"}])
        |> put_req_header("mcp-session-id", "any-id")

      stage_context =
        :no_such_instance
        |> context(conn)
        |> Map.put(:session_id, "any-id")
        |> Map.put(:rpc_method, "ping")

      assert {:halt, ctx} = Http.restore(stage_context)

      assert ctx.error.code == :http_unavailable
    end
  end

  defp get_conn(headers) do
    Enum.reduce(headers, conn(:get, "/"), fn {name, value}, acc ->
      put_req_header(acc, name, value)
    end)
  end

  defp run_get(conn, instance) do
    instance
    |> context(conn)
    |> Validate.http_get()
    |> ctx_of()
  end

  defp run_delete(conn, instance) do
    instance
    |> context(conn)
    |> Validate.http_delete()
    |> ctx_of()
  end

  defp context(instance, conn) do
    OzMcp.Context.new(instance, :http_streamable, :http)
    |> OzMcp.Context.put_http_conn(conn)
  end

  defp ctx_of({:cont, context}), do: {:cont, context}
  defp ctx_of({:halt, context}), do: {:halt, context}
end
