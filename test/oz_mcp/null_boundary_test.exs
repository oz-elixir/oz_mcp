#
# End-to-end cases for a JSON null at the boundary of the wire: a null
# argument reaches the callback of a tool as `nil` when the input schema
# allows it and a null inside the answer of a client reaches the
# application as `nil`. Each case runs over HTTP and over stdio.
#
defmodule OzMcp.NullBoundaryTest do
  use ExUnit.Case

  import Plug.Conn
  import Plug.Test

  alias Support.Helpers.SessionProbe
  alias Support.Helpers.Utils
  alias Support.Servers

  @version "2025-11-25"
  @client_info %{"name" => "null-boundary-test", "version" => "1.0.0"}

  @tools ["nullable_string", "null_only", "enum_null"]

  # -------------------------------------------------------------------
  # HTTP
  # -------------------------------------------------------------------

  describe "a null argument over HTTP" do
    @server Module.concat(Servers.NullArgs, __MODULE__)

    setup do
      Utils.start_instance(Servers.NullArgs, name: @server)
      session_id = Utils.create_session(@server, initialized: true)
      %{session_id: session_id}
    end

    for tool <- @tools do
      test "#{tool}: the callback receives a nil for a null argument", %{session_id: session_id} do
        conn = call_tool(session_id, unquote(tool), %{"a" => nil})

        assert conn.status == 200
        assert %{"result" => result} = :json.decode(conn.resp_body)
        assert is_nil(result["isError"])
        assert [%{"type" => "text", "text" => "%{\"a\" => nil}"}] = result["content"]
      end

      test "#{tool}: a number for the argument is still a tool execution error", %{
        session_id: session_id
      } do
        conn = call_tool(session_id, unquote(tool), %{"a" => 1})

        assert conn.status == 200
        assert %{"result" => result} = :json.decode(conn.resp_body)
        assert result["isError"] == true
      end
    end
  end

  describe "a null arguments member of prompts/get over HTTP" do
    @server Module.concat(Servers.NullArgs, __MODULE__)

    setup do
      Utils.start_instance(Servers.NullArgs, name: @server)
      session_id = Utils.create_session(@server, initialized: true)
      %{session_id: session_id}
    end

    test "the prompt callback receives an empty map for a null arguments", %{
      session_id: session_id
    } do
      conn =
        post_json(1, "prompts/get", %{"name" => "echo_arguments", "arguments" => nil})
        |> put_req_header("mcp-session-id", session_id)
        |> call_router(@server, Servers.NullArgs)

      assert conn.status == 200

      assert %{
               "result" => %{
                 "messages" => [%{"content" => %{"text" => "%{}", "type" => "text"}}]
               }
             } = :json.decode(conn.resp_body)
    end
  end

  describe "an answer of a client that holds a null over HTTP" do
    @outbound Module.concat(Servers.Outbound, __MODULE__)

    test "the content of an accepted elicitation reaches the callback as nil" do
      Utils.start_instance(Servers.Outbound, name: @outbound)

      session_id =
        Utils.create_session(@outbound,
          initialized: true,
          client_capabilities: %{"elicitation" => %{}}
        )

      start_call(session_id, 5)

      id = wait_for_pending(session_id)

      assert post_response(session_id, %{
               "id" => id,
               "result" => %{"action" => "accept", "content" => %{"name" => "Ana", "note" => nil}}
             }).status == 202

      assert_receive {:call_conn, 5, conn}, 5_000

      assert conn.status == 200

      assert [_request, %{"id" => 5, "result" => %{"content" => [content]}}] =
               sse_messages(conn.resp_body)

      assert content["text"] =~ "action: :accept"
      assert content["text"] =~ "\"note\" => nil"
      assert SessionProbe.pending_outbound_ids(@outbound, session_id) == []
    end

    defp start_call(session_id, rpc_id) do
      parent = self()

      spawn_link(fn ->
        conn =
          post_json(rpc_id, "tools/call", %{
            "name" => "outbound",
            "arguments" => %{"feature" => "elicit_form"}
          })
          |> put_req_header("mcp-session-id", session_id)
          |> call_router(@outbound, Servers.Outbound)

        send(parent, {:call_conn, rpc_id, conn})
      end)
    end

    defp wait_for_pending(session_id, retries \\ 1_500) do
      assert Utils.eventually(
               fn -> SessionProbe.pending_outbound_ids(@outbound, session_id) != [] end,
               retries * 10
             )

      hd(SessionProbe.pending_outbound_ids(@outbound, session_id))
    end
  end

  defp call_tool(session_id, name, arguments) do
    post_json(1, "tools/call", %{"name" => name, "arguments" => arguments})
    |> put_req_header("mcp-session-id", session_id)
    |> call_router(@server, Servers.NullArgs)
  end

  defp post_json(id, method, params) do
    %{"jsonrpc" => "2.0", "method" => method, "params" => params}
    |> then(fn rpc -> if id, do: Map.put(rpc, "id", id), else: rpc end)
    |> Utils.encode_json()
    |> IO.iodata_to_binary()
    |> post_raw()
  end

  defp post_response(session_id, fields) do
    body =
      %{"jsonrpc" => "2.0"}
      |> Map.merge(fields)
      |> Utils.encode_json()
      |> IO.iodata_to_binary()

    post_raw(body)
    |> put_req_header("mcp-session-id", session_id)
    |> call_router(@outbound, Servers.Outbound)
  end

  defp post_raw(body) do
    conn(:post, "/", body)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json, text/event-stream")
    |> put_req_header("mcp-protocol-version", @version)
  end

  defp call_router(conn, instance, server) do
    OzMcp.Router.call(
      conn,
      OzMcp.Router.init(instance: instance, server: server, allowed_origins: [])
    )
  end

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

  # -------------------------------------------------------------------
  # stdio
  # -------------------------------------------------------------------

  describe "a null argument over stdio" do
    test "the callback of each tool receives a nil for a null argument" do
      start_runtime([Servers.NullArgs])
      %{pipe: pipe} = start_transport(Servers.NullArgs)
      handshake(pipe)

      for {tool, id} <- Enum.with_index(@tools, 2) do
        send_request(pipe, id, "tools/call", %{"name" => tool, "arguments" => %{"a" => nil}})

        result = assert_result(pipe, id)
        assert is_nil(result["isError"])
        assert [%{"type" => "text", "text" => "%{\"a\" => nil}"}] = result["content"]
      end
    end

    test "a number for the argument is still a tool execution error" do
      start_runtime([Servers.NullArgs])
      %{pipe: pipe} = start_transport(Servers.NullArgs)
      handshake(pipe)

      send_request(pipe, 2, "tools/call", %{
        "name" => "nullable_string",
        "arguments" => %{"a" => 1}
      })

      result = assert_result(pipe, 2)
      assert result["isError"] == true
    end

    test "the prompt callback receives an empty map for a null arguments" do
      start_runtime([Servers.NullArgs])
      %{pipe: pipe} = start_transport(Servers.NullArgs)
      handshake(pipe)

      send_request(pipe, 2, "prompts/get", %{"name" => "echo_arguments", "arguments" => nil})

      assert %{"messages" => [%{"content" => %{"text" => "%{}", "type" => "text"}}]} =
               assert_result(pipe, 2)
    end
  end

  describe "an answer of a client that holds a null over stdio" do
    test "the content of an accepted elicitation reaches the callback as nil" do
      start_runtime([Servers.Outbound])
      %{pipe: pipe} = start_transport(Servers.Outbound)
      handshake(pipe, %{"elicitation" => %{}})

      send_request(pipe, 2, "tools/call", %{
        "name" => "outbound",
        "arguments" => %{"feature" => "elicit_form"}
      })

      elicit = recv_matching(pipe, &match?(%{"method" => "elicitation/create"}, &1))

      Support.Helpers.StdioPipe.send_line(pipe, %{
        "jsonrpc" => "2.0",
        "id" => elicit["id"],
        "result" => %{"action" => "accept", "content" => %{"name" => "Ana", "note" => nil}}
      })

      assert %{"content" => [%{"text" => text}]} = assert_result(pipe, 2)
      assert text =~ "action: :accept"
      assert text =~ "\"note\" => nil"
    end
  end

  defp start_runtime(servers) do
    start_supervised!(Utils.runtime_spec(%{transport: :stdio, servers: servers}))
  end

  defp start_transport(server) do
    pipe = start_supervised!({Support.Helpers.StdioPipe, nil})

    transport =
      start_supervised!(
        Supervisor.child_spec(
          {OzMcp.Transport.Stdio,
           [
             server: server,
             read: Support.Helpers.StdioPipe.reader(pipe),
             write: Support.Helpers.StdioPipe.writer(pipe)
           ]},
          restart: :temporary
        )
      )

    %{pipe: pipe, transport: transport}
  end

  defp initialize_request(id, capabilities) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => @version,
        "clientInfo" => @client_info,
        "capabilities" => capabilities
      }
    }
  end

  defp handshake(pipe, capabilities \\ %{}) do
    Support.Helpers.StdioPipe.send_line(pipe, initialize_request(1, capabilities))
    _init = Support.Helpers.StdioPipe.recv(pipe)

    Support.Helpers.StdioPipe.send_line(pipe, %{
      "jsonrpc" => "2.0",
      "method" => "notifications/initialized"
    })

    :ok
  end

  defp send_request(pipe, id, method, params) do
    Support.Helpers.StdioPipe.send_line(pipe, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method,
      "params" => params
    })
  end

  defp assert_result(pipe, id) do
    assert %{"id" => ^id, "result" => result} = Support.Helpers.StdioPipe.recv(pipe)
    result
  end

  defp recv_matching(pipe, fun, timeout \\ 10_000) do
    case Support.Helpers.StdioPipe.recv(pipe, timeout) do
      :timeout ->
        flunk(
          "no matching line before the deadline, got: #{inspect(Support.Helpers.StdioPipe.lines(pipe))}"
        )

      message ->
        if fun.(message), do: message, else: recv_matching(pipe, fun, timeout)
    end
  end
end
