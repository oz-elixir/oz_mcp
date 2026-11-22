defmodule OzMcp.ConfigReadsTest do
  #
  # Sync: the trace counters of the VM are global. The `async: false` files
  # run after the async ones, so no other test arms the same trace.
  #
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test
  alias Support.Helpers.Utils
  alias Support.Servers

  @server Servers.Default
  @authorized Servers.Authorized
  @scoped Servers.Scoped
  @resource_url "https://mcp.example.com/mcp"
  @config_mfa {OzMcp.Instance, :config, 1}
  @protocol_version "2025-11-25"

  setup do
    suffix = System.unique_integer([:positive])

    instance = Module.concat(@server, "CR#{suffix}")
    auth_instance = Module.concat(@authorized, "CR#{suffix}")
    scoped_instance = Module.concat(@scoped, "CR#{suffix}")

    Utils.start_instance(@server, name: instance, allowed_origins: [], sse_max_stream_ms: 50)

    Utils.start_instance(@authorized,
      name: auth_instance,
      allowed_origins: [],
      resource_url: @resource_url
    )

    Utils.start_instance(@scoped,
      name: scoped_instance,
      allowed_origins: [],
      resource_url: @resource_url
    )

    %{instance: instance, auth_instance: auth_instance, scoped_instance: scoped_instance}
  end

  describe "one read of the config for each request" do
    test "a ping reads the config one time", %{instance: instance} do
      session_id = Utils.create_session(instance, initialized: true)

      assert 1 ==
               count_config_reads(fn ->
                 assert 200 == post(instance, session_id, 1, "ping").status
               end)
    end

    test "tools/list reads the config one time", %{instance: instance} do
      session_id = Utils.create_session(instance, initialized: true)

      assert 1 ==
               count_config_reads(fn ->
                 assert 200 == post(instance, session_id, 1, "tools/list").status
               end)
    end

    test "tools/call reads the config one time", %{instance: instance} do
      session_id = Utils.create_session(instance, initialized: true)

      assert 1 ==
               count_config_reads(fn ->
                 assert 200 ==
                          post(instance, session_id, 1, "tools/call", %{
                            "name" => "get_date",
                            "arguments" => %{}
                          }).status
               end)
    end

    test "a GET stream reads the config one time", %{instance: instance} do
      session_id = Utils.create_session(instance, initialized: true)

      assert 1 ==
               count_config_reads(fn ->
                 conn =
                   conn(:get, "/")
                   |> put_req_header("accept", "text/event-stream")
                   |> put_req_header("mcp-protocol-version", @protocol_version)
                   |> put_req_header("mcp-session-id", session_id)
                   |> OzMcp.Router.call(OzMcp.Router.init(instance: instance))

                 assert conn.status == 200
               end)
    end

    test "a request with a token reads the config one time", %{auth_instance: instance} do
      session_id =
        Utils.create_session(instance,
          initialized: true,
          principal_key: {"https://issuer.test", "alice"}
        )

      assert 1 ==
               count_config_reads(fn ->
                 assert 200 == post_with_token(instance, session_id, "ping").status
               end)
    end

    # A protected server filters a list by scope when the request has a
    # principal. The list methods read the authorization block of the
    # config and the router already read it for the request.
    #
    for method <- ~w(tools/list prompts/list resources/list resources/templates/list) do
      test "#{method} with a token reads the config one time", %{scoped_instance: instance} do
        session_id =
          Utils.create_session(instance,
            initialized: true,
            principal_key: {"https://issuer.test", "alice"}
          )

        assert 1 ==
                 count_config_reads(fn ->
                   assert 200 ==
                            post_with_token(instance, session_id, unquote(method)).status
                 end)
      end
    end

    test "initialize reads the config two times", %{instance: instance} do
      assert 2 ==
               count_config_reads(fn ->
                 conn =
                   conn(:post, "/", JSON.encode!(initialize_body()))
                   |> put_req_header("content-type", "application/json")
                   |> put_req_header("accept", "application/json, text/event-stream")
                   |> put_req_header("mcp-protocol-version", @protocol_version)
                   |> OzMcp.Router.call(OzMcp.Router.init(instance: instance))

                 assert conn.status == 200
                 assert [_session_id] = get_resp_header(conn, "mcp-session-id")
               end)
    end
  end

  defp count_config_reads(fun) do
    :erlang.trace_pattern(@config_mfa, true, [:call_count])
    :erlang.trace_pattern(@config_mfa, :restart, [:call_count])

    try do
      fun.()

      {:call_count, count} = :erlang.trace_info(@config_mfa, :call_count)
      count
    after
      :erlang.trace_pattern(@config_mfa, false, [])
    end
  end

  defp post(instance, session_id, id, method, params \\ %{}) do
    conn(:post, "/", JSON.encode!(request_body(id, method, params)))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json, text/event-stream")
    |> put_req_header("mcp-session-id", session_id)
    |> put_req_header("mcp-protocol-version", @protocol_version)
    |> OzMcp.Router.call(OzMcp.Router.init(instance: instance))
  end

  defp post_with_token(instance, session_id, method) do
    conn(:post, "/", JSON.encode!(request_body(1, method, %{})))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json, text/event-stream")
    |> put_req_header("mcp-session-id", session_id)
    |> put_req_header("mcp-protocol-version", @protocol_version)
    |> put_req_header("authorization", "Bearer alice-token")
    |> OzMcp.Router.call(OzMcp.Router.init(instance: instance))
  end

  defp request_body(id, method, params) do
    %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}
  end

  defp initialize_body do
    %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => @protocol_version,
        "capabilities" => %{},
        "clientInfo" => %{"name" => "config-reads", "version" => "1.0.0"}
      }
    }
  end
end
