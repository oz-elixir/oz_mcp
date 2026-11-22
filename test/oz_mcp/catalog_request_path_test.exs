# Tests for the request path of the catalog: a static tool never builds its
# schema at a request.
# See: lib/oz_mcp/catalog.ex, lib/oz_mcp/utils/json_schema_validator.ex
#

#
# An empty execution block is valid at compile time and the build of the
# wire map fails when the catalog normalizes the entity at boot.
#
defmodule CatalogRequestPathTest.EmptyExecutionTool do
  use OzMcp.Config.Tool, warn?: false

  tool "empty_execution" do
    title "Empty execution"
    description "A tool whose execution block builds no wire map"

    execution do
    end
  end

  def call(_ctx, _params), do: {:ok, %{"content" => []}}
end

defmodule CatalogRequestPathTest.EmptyExecutionServer do
  use OzMcp.Config.Server

  server_info do
    name "catalog-empty-execution"
    version "1.0.0"
  end

  tools do
    tool CatalogRequestPathTest.EmptyExecutionTool
  end
end

defmodule OzMcp.CatalogRequestPathTest do
  use ExUnit.Case, async: false

  alias CatalogRequestPathTest.EmptyExecutionServer
  alias Support.Helpers.Utils
  alias Support.Servers

  test "a request for each static tool of the big server builds no schema" do
    name =
      Module.concat(Bench.BigServer, "CatalogRequestPath#{System.unique_integer([:positive])}")

    Utils.start_instance(Bench.BigServer, name: name)
    session_id = Utils.create_session(name, initialized: true)

    builds =
      count_builds(fn ->
        for index <- 1..10, n <- 1..20 do
          conn = call_tool(name, session_id, "tool_#{index}_#{n}")

          assert conn.status == 200
          assert %{"result" => %{"content" => _}} = :json.decode(conn.resp_body)
        end
      end)

    assert builds == 0
  end

  @tag :capture_log
  test "an empty execution block stops the boot" do
    assert_raise ArgumentError, ~r/All fields are 'nil', remove 'execution' declaration/, fn ->
      Utils.start_instance(EmptyExecutionServer)
    end
  end

  test "an unsubscribe of a resource that is gone answers and it keeps the other subscriptions" do
    uri = "file:///definitions.md"
    gone = "file:///gone/1"

    name = Module.concat(Servers.ResourcesMultipleSubscribed, "Gone")

    Utils.start_instance(Servers.ResourcesMultipleSubscribed, name: name)
    session_id = Utils.create_session(name, initialized: true, streams: [self()])

    assert %{"result" => %{}} = rpc(name, session_id, "resources/subscribe", %{"uri" => uri})

    assert %{"error" => %{"code" => -32002}} =
             rpc(name, session_id, "resources/subscribe", %{"uri" => gone})

    conn =
      Bench.Runner.post(name, session_id, rpc_body("resources/unsubscribe", %{"uri" => gone}))

    assert conn.status == 200
    assert :json.decode(conn.resp_body) == %{"jsonrpc" => "2.0", "id" => 1, "result" => %{}}

    assert :ok = OzMcp.Notify.resource_updated(name, uri)
    assert_receive {:oz_mcp_stream, _, {:event, _, _}}, 1_000
  end

  defp rpc_body(method, params),
    do: %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params}

  defp rpc(name, session_id, method, params) do
    conn = Bench.Runner.post(name, session_id, rpc_body(method, params))

    assert conn.status == 200
    :json.decode(conn.resp_body)
  end

  defp call_tool(instance, session_id, tool_name) do
    body = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/call",
      "params" => %{"name" => tool_name, "arguments" => %{"text" => "x"}}
    }

    Bench.Runner.post(instance, session_id, body)
  end

  # The call-count trace is global: the module is async: false.
  #
  defp count_builds(fun) do
    #
    # A trace armed on a module that is not loaded is lost at the load.
    #
    Code.ensure_loaded!(JSV)

    mfa = {JSV, :build, 2}

    :erlang.trace_pattern(mfa, true, [:call_count])
    :erlang.trace_pattern(mfa, :restart, [:call_count])

    try do
      fun.()

      case :erlang.trace_info(mfa, :call_count) do
        {:call_count, count} when is_integer(count) -> count
        _other -> 0
      end
    after
      :erlang.trace_pattern(mfa, false, [:call_count])
    end
  end
end
