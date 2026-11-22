# Tests for the runtime options `check_results` and
# `check_output_schemas`: the two options of the instance that turn the
# checks of a result off. A tool whose result shape the argument selects
# (Support.Entities.Tools.TaskBadShapeTest, Support.Entities.Tools.TaskStructuredTest) serves the bad results;
# a prompt and a resource module of this file serve the reads.
#

defmodule OzMcp.CheckOptionsTest.BadRolePrompt do
  use OzMcp.Config.Prompt, dsl?: false, warn?: false

  @prompts [%{"name" => "bad_role", "description" => "Gives a message with a bad role"}]

  def list, do: @prompts

  def get(_ctx, _params) do
    {:ok,
     %{
       "messages" => [
         %{"role" => "robot", "content" => %{"type" => "text", "text" => "hello"}}
       ]
     }}
  end
end

defmodule OzMcp.CheckOptionsTest.RelativeUriResource do
  use OzMcp.Config.Resource, dsl?: false, warn?: false

  def list do
    [%{"uri" => "file:///bad.txt", "name" => "bad.txt", "mimeType" => "text/plain"}]
  end

  def read(_ctx, _params) do
    {:ok, %{"contents" => [%{"uri" => "not-absolute", "text" => "hi"}]}}
  end
end

defmodule OzMcp.CheckOptionsTest.Server do
  use OzMcp.Config.Server

  server_info do
    name "check-options-server"
    version "1.0.0"
  end

  tools do
    tool Support.Entities.Tools.TaskBadShapeTest
    tool Support.Entities.Tools.TaskStructuredTest
    tool Support.Entities.Tools.TaskErrorTest
    tool Support.Entities.Tools.TaskCrashTest
  end

  prompts do
    prompt OzMcp.CheckOptionsTest.BadRolePrompt
  end

  resources do
    resource OzMcp.CheckOptionsTest.RelativeUriResource
  end

  capabilities do
    tasks do
      list %{}
      cancel %{}
      requests %{tools: %{call: %{}}}
    end
  end
end

defmodule OzMcp.CheckOptionsTest do
  use ExUnit.Case, async: true
  import Plug.Conn
  import Plug.Test

  alias OzMcp.Handler.Invoke
  alias OzMcp.Utils.Error
  alias Support.Helpers.Utils

  @server OzMcp.CheckOptionsTest.Server
  @instance Module.concat(@server, __MODULE__)
  @protocol_version "2025-11-25"

  setup context do
    opts = Map.get(context, :opts) || %{}

    Utils.start_instance(@server, [name: @instance] ++ Map.to_list(opts))
    %{instance: @instance, session: initialize(@instance)}
  end

  # -----
  # check_results: false, check_output_schemas: true
  # -----

  @tag opts: %{check_results: false}
  test "a map result with a bad annotations value reaches the client as it is", %{
    instance: instance,
    session: session
  } do
    assert %{"content" => [%{"type" => "text", "text" => "x", "annotations" => bad}]} =
             call_result(instance, session, 10, "task_bad_shape", %{"shape" => "bad_annotations"})

    assert bad == %{"priority" => "high"}
  end

  @tag opts: %{check_results: false}
  test "a content that is not a list and a block with no type reach the client as they are", %{
    instance: instance,
    session: session
  } do
    assert %{"content" => "not a list"} =
             call_result(instance, session, 11, "task_bad_shape", %{"shape" => "bad_content"})

    assert %{"content" => [%{"text" => "no type"}]} =
             call_result(instance, session, 12, "task_bad_shape", %{"shape" => "no_type"})
  end

  @tag opts: %{check_results: false}
  test "a result that is not a map reaches the client as it is", %{
    instance: instance,
    session: session
  } do
    assert call_result(instance, session, 13, "task_bad_shape", %{"shape" => "text"}) == "text"
  end

  @tag opts: %{check_results: false}
  test "a relative uri in a read item reaches the client as it is", %{
    instance: instance,
    session: session
  } do
    assert %{"contents" => [%{"uri" => "not-absolute", "text" => "hi"}]} =
             request_result(instance, session, 14, "resources/read", %{
               "uri" => "file:///bad.txt"
             })
  end

  @tag opts: %{check_results: false}
  test "a bad role in a prompt message reaches the client as it is", %{
    instance: instance,
    session: session
  } do
    assert %{"messages" => [%{"role" => "robot"}]} =
             request_result(instance, session, 15, "prompts/get", %{"name" => "bad_role"})
  end

  @tag opts: %{check_results: false}
  test "a tool with an outputSchema and a bad structuredContent gives the schema error", %{
    instance: instance,
    session: session
  } do
    assert %{"code" => -32603, "message" => "tool output does not match outputSchema"} =
             call_error(instance, session, 16, "task_structured", %{"shape" => "wrong"})
  end

  @tag opts: %{check_results: false}
  test "a struct result gives the same wire map as with the checks on", ctx do
    off = call_result(ctx.instance, ctx.session, 17, "task_bad_shape", %{})

    on_instance = Module.concat(@server, "ChecksOn")
    Utils.start_instance(@server, name: on_instance)
    on_session = initialize(on_instance)
    on = call_result(on_instance, on_session, 17, "task_bad_shape", %{})

    assert off == on
    assert off == %{"content" => [%{"type" => "text", "text" => "ok"}]}
  end

  @tag opts: %{check_results: false}
  @tag :capture_log
  test "a result that is not JSON gives -32603 on HTTP and the session stays alive", %{
    instance: instance,
    session: session
  } do
    conn =
      request(instance, session, 18, "tools/call", %{
        "name" => "task_bad_shape",
        "arguments" => %{"shape" => "not_json"}
      })

    assert %{"error" => %{"code" => -32603}, "id" => 18} = JSON.decode!(conn.resp_body)

    ping_ok(instance, session, 19)
  end

  @tag opts: %{check_results: false}
  @tag :capture_log
  test "a duplicate key in a result gives -32603 on HTTP", %{
    instance: instance,
    session: session
  } do
    conn =
      request(instance, session, 28, "tools/call", %{
        "name" => "task_bad_shape",
        "arguments" => %{"shape" => "duplicate_key"}
      })

    assert %{"error" => %{"code" => -32603}, "id" => 28} = JSON.decode!(conn.resp_body)
  end

  @tag opts: %{check_results: false}
  @tag :capture_log
  test "a task whose result is not a map makes a failed task and -32603", %{
    instance: instance,
    session: session
  } do
    task_id = task_call(instance, session, 26, "task_bad_shape", %{"shape" => "text"})

    assert %{"code" => -32603, "message" => "internal error"} =
             call_task_error(instance, session, 27, task_id)
  end

  @tag opts: %{check_results: false}
  @tag :capture_log
  test "a result that is not JSON gives -32603 through tasks/result and the session stays alive",
       %{instance: instance, session: session} do
    task_id =
      task_call(instance, session, 20, "task_bad_shape", %{"shape" => "not_json"})

    conn =
      request(instance, session, 21, "tasks/result", %{"taskId" => task_id})

    assert %{"error" => %{"code" => -32603}, "id" => 21} = JSON.decode!(conn.resp_body)

    ping_ok(instance, session, 22)
  end

  @tag opts: %{check_results: false}
  test "a callback error, a raise and a bad return value give the answers of the checks on", %{
    instance: instance,
    session: session
  } do
    assert %{"code" => -32000, "message" => "boom"} =
             call_error(instance, session, 23, "task_error", %{})

    assert %{"code" => -32603, "message" => "internal error"} =
             call_error(instance, session, 24, "task_crash", %{})

    assert %{"code" => -32603, "message" => "internal error"} =
             call_error(instance, session, 25, "task_bad_shape", %{"shape" => "reserved_error"})

    assert {:error, %{code: -32603, message: "internal error"}} =
             Invoke.run(%{instance: instance, server: @server}, fn -> :ok end)

    assert {:error, %{code: -32000, message: "boom"}} =
             Invoke.run(%{instance: instance, server: @server}, fn ->
               {:error, Error.new(-32000, "boom")}
             end)

    assert {:error, %{code: -32603, message: "internal error"}} =
             Invoke.run(%{instance: instance, server: @server}, fn ->
               {:error, Error.new(-32800, "reserved")}
             end)
  end

  @tag opts: %{check_results: false}
  @tag :capture_log
  test "a struct result with an empty text still gives -32603", %{
    instance: instance,
    session: session
  } do
    assert %{"code" => -32603, "message" => "internal error"} =
             call_error(instance, session, 28, "task_bad_shape", %{"shape" => "empty_text"})
  end

  # -----
  # check_output_schemas: false, check_results: true
  # -----

  @tag opts: %{check_output_schemas: false}
  test "a tool with an outputSchema and a bad structuredContent gives a success answer", %{
    instance: instance,
    session: session
  } do
    assert %{"structuredContent" => %{"result" => 42}} =
             call_result(instance, session, 30, "task_structured", %{"shape" => "wrong"})
  end

  @tag opts: %{check_output_schemas: false}
  @tag :capture_log
  test "a map result with a bad annotations value still gives -32603", %{
    instance: instance,
    session: session
  } do
    assert %{"code" => -32603, "message" => "internal error"} =
             call_error(instance, session, 31, "task_bad_shape", %{"shape" => "bad_annotations"})
  end

  # -----
  # both options false
  # -----

  @tag opts: %{check_results: false, check_output_schemas: false}
  test "a bad structuredContent in a map result with a bad block reaches the client as it is", %{
    instance: instance,
    session: session
  } do
    assert %{"content" => [%{"text" => "no type"}], "structuredContent" => %{"result" => 42}} =
             call_result(instance, session, 40, "task_structured", %{"shape" => "map_bad_both"})
  end

  # -----
  # stdio transport
  # -----

  @tag :stdio
  test "the stdio transport gives -32603 for a result that is not JSON" do
    Utils.start_runtime(%{transport: :stdio, servers: [{@server, %{check_results: false}}]})
    on_exit(fn -> Utils.stop_runtime() end)

    pipe = start_supervised!({Support.Helpers.StdioPipe, nil})

    start_supervised!(
      Supervisor.child_spec(
        {OzMcp.Transport.Stdio,
         [
           server: @server,
           read: Support.Helpers.StdioPipe.reader(pipe),
           write: Support.Helpers.StdioPipe.writer(pipe)
         ]},
        restart: :temporary
      )
    )

    Support.Helpers.StdioPipe.send_line(pipe, initialize_request(1))
    _init = Support.Helpers.StdioPipe.recv(pipe)

    Support.Helpers.StdioPipe.send_line(pipe, %{
      "jsonrpc" => "2.0",
      "method" => "notifications/initialized"
    })

    Support.Helpers.StdioPipe.send_line(pipe, %{
      "jsonrpc" => "2.0",
      "id" => 2,
      "method" => "tools/call",
      "params" => %{
        "name" => "task_bad_shape",
        "arguments" => %{"shape" => "not_json"}
      }
    })

    assert %{"id" => 2, "error" => %{"code" => -32603}} = Support.Helpers.StdioPipe.recv(pipe)

    Support.Helpers.StdioPipe.send_line(pipe, %{"jsonrpc" => "2.0", "id" => 3, "method" => "ping"})

    assert %{"id" => 3, "result" => %{}} = Support.Helpers.StdioPipe.recv(pipe)
  end

  defp post(instance, session_id, body) do
    conn(:post, "/", JSON.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json, text/event-stream")
    |> session_header(session_id)
    |> put_req_header("mcp-protocol-version", @protocol_version)
    |> OzMcp.Router.call(OzMcp.Router.init(instance: instance))
  end

  defp session_header(conn, nil), do: conn
  defp session_header(conn, session_id), do: put_req_header(conn, "mcp-session-id", session_id)

  defp initialize(instance) do
    conn =
      post(instance, nil, %{
        "jsonrpc" => "2.0",
        "id" => 0,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => @protocol_version,
          "capabilities" => %{},
          "clientInfo" => %{"name" => "check-options", "version" => "1.0.0"}
        }
      })

    assert [session] = Plug.Conn.get_resp_header(conn, "mcp-session-id")

    post(instance, session, %{"jsonrpc" => "2.0", "method" => "notifications/initialized"})

    session
  end

  defp request(instance, session, id, method, params \\ %{}) do
    post(instance, session, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method,
      "params" => params
    })
  end

  defp decode(conn), do: JSON.decode!(conn.resp_body)

  defp call_result(instance, session, id, tool, args) do
    %{"result" => result} =
      decode(request(instance, session, id, "tools/call", %{"name" => tool, "arguments" => args}))

    result
  end

  defp call_error(instance, session, id, tool, args) do
    %{"error" => error} =
      decode(request(instance, session, id, "tools/call", %{"name" => tool, "arguments" => args}))

    error
  end

  defp request_result(instance, session, id, method, params) do
    %{"result" => result} = decode(request(instance, session, id, method, params))
    result
  end

  defp ping_ok(instance, session, id) do
    %{"result" => %{}} = decode(request(instance, session, id, "ping"))
    :ok
  end

  defp call_task_error(instance, session, id, task_id) do
    %{"error" => error} =
      decode(request(instance, session, id, "tasks/result", %{"taskId" => task_id}))

    error
  end

  defp task_call(instance, session, id, tool, args) do
    %{"result" => %{"task" => %{"taskId" => task_id}}} =
      decode(
        request(instance, session, id, "tools/call", %{
          "name" => tool,
          "arguments" => args,
          "task" => %{}
        })
      )

    task_id
  end

  defp initialize_request(id) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => @protocol_version,
        "capabilities" => %{},
        "clientInfo" => %{"name" => "check-options", "version" => "1.0.0"}
      }
    }
  end
end

defmodule OzMcp.CheckOptionsTest.RemovedOptions do
  use ExUnit.Case, async: true
  alias Support.Servers

  test "a lookup_timeout_ms option stops the boot" do
    assert_raise ArgumentError,
                 ~r/unknown option\(s\) for .*: \[:lookup_timeout_ms\]/,
                 fn ->
                   OzMcp.Instance.Config.parse!(%{
                     server: Servers.Default,
                     allowed_origins: [],
                     lookup_timeout_ms: 100
                   })
                 end
  end
end
