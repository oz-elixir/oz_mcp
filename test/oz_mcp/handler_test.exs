#
# A tool whose list/0 always raises and a server that holds this tool
# and has no pagination. A request with a cursor must be refused before
# the list function runs: if list/0 runs, the test fails with the raise.
#
defmodule OzMcp.HandlerTest.ToolListMustNotRun do
  use OzMcp.Config.Tool, dsl?: false, warn?: false

  def list, do: raise("list/0 must not run for a refused cursor")
  def call(_ctx, _params), do: {:ok, %{"content" => []}}
end

defmodule OzMcp.HandlerTest.NoPaginateMustNotList do
  use OzMcp.Config.Server

  server_info do
    name "ts-no-paginate-must-not-list"
    version "1.0.0"
  end

  tools do
    tool OzMcp.HandlerTest.ToolListMustNotRun
  end
end

defmodule OzMcp.HandlerTest do
  use ExUnit.Case, async: true
  alias OzMcp.{Context, Handler, Session, Sessions, Tasks, Validate, Wire}
  alias OzMcp.Pipeline.Bound
  alias OzMcp.Structs.{Tool, ToolExecution}
  alias OzMcp.Utils.Paginate
  alias Support.Helpers.SessionProbe
  alias Support.Helpers.Utils
  alias Support.Servers
  require Support.Factories.Tool

  @server_module Servers.Default
  @server Module.concat(@server_module, __MODULE__)
  @tasks_server_module Servers.TasksTest
  @tasks_server Module.concat(@tasks_server_module, __MODULE__)

  # The instance that serves a server module in this file.
  #
  defp inst(nil), do: nil
  defp inst(module), do: Module.concat(module, __MODULE__)

  # The answer of a pipeline stage: the context it carries.
  #
  defp plain({:cont, context}), do: context
  defp plain({:halt, context}), do: context

  setup context do
    Support.Entities.Tools.TaskSlowTest.use_instance(@tasks_server)

    if context[:no_runtime] do
      :ok
    else
      server = context[:runtime_server] || @server_module
      opts = Map.get(context, :runtime_opts) || %{}

      Utils.start_instance(server, [name: inst(server)] ++ Map.to_list(opts))
      :ok
    end
  end

  describe "handle_request/1 - initialize" do
    test "returns session_created with the initialize result and id" do
      context =
        build_context(rpc_id: 1, rpc_method: "initialize", server: @server_module)

      assert {:session_created, session_id, response} = Handler.handle_request(context)
      assert is_binary(session_id)
      assert response["id"] == 1
      assert response["result"][:serverInfo][:name] == "ts-default-test"
    end

    test "preserves rpc id in response" do
      context =
        build_context(rpc_id: 42, rpc_method: "initialize", server: @server_module)

      assert {:session_created, _session_id, response} = Handler.handle_request(context)
      assert response["id"] == 42
    end

    test "returns correct capabilities in initialize result" do
      context =
        build_context(rpc_id: 1, rpc_method: "initialize", server: @server_module)

      assert {:session_created, _session_id, response} = Handler.handle_request(context)
      assert response["result"][:capabilities][:tools] == %{}
      #
      # subscribe is false and false values are omitted from the capabilities map
      #
      refute Map.has_key?(response["result"][:capabilities][:resources], :subscribe)
    end

    @tag runtime_server: Servers.ToolsOnly
    test "returns initialize response for tools-only server" do
      context =
        build_context(rpc_id: 1, rpc_method: "initialize", server: Servers.ToolsOnly)

      assert {:session_created, _session_id, response} = Handler.handle_request(context)
      assert response["id"] == 1
      assert response["result"][:capabilities][:tools] == %{}
      refute Map.has_key?(response["result"][:capabilities], :resources)
    end

    test "answers the negotiated protocol version" do
      context =
        build_context(
          rpc_id: 1,
          rpc_method: "initialize",
          server: @server_module,
          negotiated_protocol_version: "2025-11-25"
        )

      assert {:session_created, _session_id, response} = Handler.handle_request(context)
      assert response["result"][:protocolVersion] == "2025-11-25"
    end

    test "overrides the frozen protocol version with the negotiated one" do
      context =
        build_context(
          rpc_id: 1,
          rpc_method: "initialize",
          server: @server_module,
          negotiated_protocol_version: "2026-01-01"
        )

      assert {:session_created, _session_id, response} = Handler.handle_request(context)
      assert response["result"][:protocolVersion] == "2026-01-01"
    end

    test "falls back to the frozen protocol version when no version was negotiated" do
      context =
        build_context(rpc_id: 1, rpc_method: "initialize", server: @server_module)

      expected = @server_module.initialize_result()[:protocolVersion]

      assert {:session_created, _session_id, response} = Handler.handle_request(context)
      assert response["result"][:protocolVersion] == expected
    end

    @tag runtime_server: Servers.ResourcesSingle
    test "returns initialize response for resources-only server" do
      context =
        build_context(
          rpc_id: 1,
          rpc_method: "initialize",
          server: Servers.ResourcesSingle
        )

      assert {:session_created, _session_id, response} = Handler.handle_request(context)
      assert response["id"] == 1
      assert Map.has_key?(response["result"][:capabilities], :tools) == false
      assert response["result"][:capabilities][:resources] == %{}
    end

    test "creates the session with the negotiated version, the client info and the capabilities" do
      context =
        build_context(
          rpc_id: 1,
          rpc_method: "initialize",
          server: @server_module,
          negotiated_protocol_version: "2025-11-25",
          client_info: %{"name" => "test-client", "version" => "1.0.0"},
          client_capabilities: %{"roots" => %{"listChanged" => true}}
        )

      assert {:session_created, session_id, _response} = Handler.handle_request(context)

      assert {:ok, %{initialized: false}} = Sessions.state(@server, session_id)

      assert {:ok, view} = Sessions.lookup(@server, session_id)
      assert view.protocol_version == "2025-11-25"
      assert view.client_info == %{"name" => "test-client", "version" => "1.0.0"}
      assert view.client_capabilities == %{"roots" => %{"listChanged" => true}}
    end

    test "the session belongs to the principal of the context" do
      principal = %OzMcp.Auth.Principal{
        issuer: "https://issuer.test",
        subject: "alice",
        scopes: []
      }

      context =
        build_context(
          rpc_id: 1,
          rpc_method: "initialize",
          server: @server_module,
          principal: principal
        )

      assert {:session_created, session_id, _response} = Handler.handle_request(context)

      assert {:ok, view} = Sessions.lookup(@server, session_id)
      assert view.principal_key == {"https://issuer.test", "alice"}
    end

    # The runtime runs, but it does not have the server of the request:
    # the create of the session answers {:error, :unavailable} and the
    # handler turns it into :internal_error (never a CaseClauseError).
    #
    @tag runtime_server: Servers.ToolsOnly
    test "a runtime that does not have the server gives :internal_error" do
      context =
        build_context(rpc_id: 1, rpc_method: "initialize", server: Servers.Default)

      assert :internal_error = Handler.handle_request(context)
    end
  end

  describe "handle_request/1 - notifications/initialized" do
    test "returns :notified atom" do
      session_id = Utils.create_session(@server)

      context =
        build_context(
          rpc_method: "notifications/initialized",
          server: @server_module,
          session_id: session_id
        )

      assert :notified = Handler.handle_request(context)
    end

    test "marks session as initialized" do
      session_id = Utils.create_session(@server)

      assert SessionProbe.initialized?(@server, session_id) == false

      context =
        build_context(
          rpc_method: "notifications/initialized",
          server: @server_module,
          session_id: session_id
        )

      Handler.handle_request(context)

      assert SessionProbe.initialized?(@server, session_id) == true
    end
  end

  describe "handle_request/1 - notifications/cancelled" do
    test "returns :notified atom with requestId and reason params" do
      context =
        build_context(
          rpc_method: "notifications/cancelled",
          rpc_params: %{"requestId" => 42, "reason" => "user aborted"}
        )

      assert :notified = Handler.handle_request(context)
    end

    test "returns :notified atom without a requestId" do
      context =
        build_context(
          rpc_method: "notifications/cancelled",
          rpc_params: %{"reason" => "user aborted"}
        )

      assert :notified = Handler.handle_request(context)
    end

    test "returns :notified atom without params" do
      context =
        build_context(
          rpc_method: "notifications/cancelled",
          rpc_params: nil
        )

      assert :notified = Handler.handle_request(context)
    end

    test "returns :notified atom for a requestId that is neither a string nor an integer" do
      for request_id <- [nil, true, 1.5, %{"id" => 1}, [1]] do
        context =
          build_context(
            rpc_method: "notifications/cancelled",
            rpc_params: %{"requestId" => request_id},
            server: @server_module,
            session_id: "s1"
          )

        assert :notified = Handler.handle_request(context)
      end
    end

    @tag runtime_server: @tasks_server_module
    test "stops the in-flight request named by requestId, in the same session only" do
      session_id = tasks_session()
      other_session_id = tasks_session()

      Support.Entities.Tools.TaskSlowTest.reset()

      call =
        build_context(
          rpc_id: 11,
          rpc_method: "tools/call",
          rpc_params: %{"name" => "task_slow"},
          tool_module: Support.Entities.Tools.TaskSlowTest,
          server: @tasks_server_module,
          session_id: session_id
        )

      parent = self()

      spawn_link(fn ->
        #
        # The transport registers a request in its session before the
        # handler runs; the cancel is delivered from the registration on.
        #
        :ok = Utils.open_request(inst(@tasks_server_module), session_id, 11, self())

        send(parent, {:call_replied, Handler.handle_request(call)})
        Session.end_request(inst(@tasks_server_module), session_id, 11)
      end)

      runner = wait_for_tool_runner()

      cancel = fn session ->
        build_context(
          rpc_method: "notifications/cancelled",
          rpc_params: %{"requestId" => 11, "reason" => "user aborted"},
          server: @tasks_server_module,
          session_id: session
        )
      end

      assert :notified = Handler.handle_request(cancel.(other_session_id))
      refute_receive {:call_replied, _}, 150
      assert Process.alive?(runner)

      assert :notified = Handler.handle_request(cancel.(session_id))

      assert_receive {:call_replied, {:rpc_error, response}}, 5_000
      assert response["id"] == 11
      assert response["error"]["code"] == -32800
      assert response["error"]["message"] == "request cancelled"
    end
  end

  describe "handle_request/1 - runner of tools/call" do
    @tag runtime_server: @tasks_server_module
    test "does not hold the Plug.Conn of the request" do
      session_id = tasks_session()
      Support.Entities.Tools.TaskSlowTest.reset()

      # A large term in the conn: a runner that captured the context
      # would copy it into its heap.
      #
      blob = Enum.to_list(1..200_000)
      conn = %{Plug.Test.conn(:post, "/") | assigns: %{blob: blob}}

      call =
        build_context(
          rpc_id: 12,
          rpc_method: "tools/call",
          rpc_params: %{"name" => "task_slow"},
          tool_module: Support.Entities.Tools.TaskSlowTest,
          server: @tasks_server_module,
          session_id: session_id
        )

      call = %{call | conn: conn}
      parent = self()

      spawn_link(fn ->
        :ok = Utils.open_request(inst(@tasks_server_module), session_id, 12, self())
        send(parent, {:call_replied, Handler.handle_request(call)})
        Session.end_request(inst(@tasks_server_module), session_id, 12)
      end)

      runner = wait_for_tool_runner()

      {:total_heap_size, words} = Process.info(runner, :total_heap_size)
      assert words < 100_000

      cancel =
        build_context(
          rpc_method: "notifications/cancelled",
          rpc_params: %{"requestId" => 12},
          server: @tasks_server_module,
          session_id: session_id
        )

      assert :notified = Handler.handle_request(cancel)
      assert_receive {:call_replied, {:rpc_error, _}}, 5_000
    end
  end

  describe "handle_request/1 - notifications/tasks/status" do
    @tag runtime_opts: %{client_tasks: true}
    test "accepts a notification that carries a taskId" do
      context =
        build_context(
          rpc_id: nil,
          rpc_method: "notifications/tasks/status",
          rpc_params: %{"taskId" => "c1"},
          server: @server_module
        )

      assert :notified = Handler.handle_request(context)
    end

    @tag runtime_opts: %{client_tasks: true}
    test "ignores a notification without a valid taskId and logs a warning" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          context =
            build_context(
              rpc_id: nil,
              rpc_method: "notifications/tasks/status",
              rpc_params: %{"taskId" => 42},
              server: @server_module
            )

          assert :notified = Handler.handle_request(context)
        end)

      assert log =~ "notifications/tasks/status without a valid taskId"
    end

    test "ignores a notification with no check when client_tasks is false" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          context =
            build_context(
              rpc_id: nil,
              rpc_method: "notifications/tasks/status",
              rpc_params: %{"taskId" => 42},
              server: @server_module
            )

          assert :notified = Handler.handle_request(context)
        end)

      refute log =~ "notifications/tasks/status without a valid taskId"
    end
  end

  describe "handle_request/1 - resources/list" do
    test "returns rpc_response with resources list from single resource module" do
      context =
        build_context(
          rpc_id: 1,
          rpc_method: "resources/list",
          server: Servers.ResourcesSingle
        )

      assert {:rpc_success, response} = Handler.handle_request(context)
      response = on_wire(response)
      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 1

      resources = response["result"]["resources"]
      assert length(resources) == 1
      assert Enum.any?(resources, &(&1["uri"] == "file:///marketing.md"))
    end

    test "returns rpc_response with resources list from multiple resource modules" do
      context =
        build_context(
          rpc_id: 2,
          rpc_method: "resources/list",
          server: Servers.ResourcesMultipleSubscribed
        )

      assert {:rpc_success, response} = Handler.handle_request(context)
      response = on_wire(response)
      assert response["jsonrpc"] == "2.0"

      resources = response["result"]["resources"]
      assert length(resources) == 3
    end

    test "returns empty resources list when server has no resources configured" do
      context =
        build_context(
          rpc_id: 1,
          rpc_method: "resources/list",
          server: Servers.ToolsOnly
        )

      assert {:rpc_success, response} = Handler.handle_request(context)
      assert response["result"][:resources] == []
    end

    test "sends a fractional priority of annotations as a JSON number" do
      {server_mod, _resource_mod} = compile_priority_resource_fixtures()

      context =
        build_context(
          rpc_id: 1,
          rpc_method: "resources/list",
          server: server_mod
        )

      assert {:rpc_success, response} = Handler.handle_request(context)
      response = on_wire(response)

      resource =
        Enum.find(response["result"]["resources"], &(&1["uri"] == "file:///priority.md"))

      assert resource["annotations"]["priority"] == 0.25
      assert Utils.encode_json(resource) =~ "\"priority\":0.25"
    end
  end

  describe "handle_request/1 - resources/list pagination" do
    @describetag :no_runtime

    test "returns first page and nextCursor when no cursor is given" do
      context =
        build_context(
          rpc_id: 1,
          rpc_method: "resources/list",
          server: Servers.PaginatedResources
        )

      assert {:rpc_success, response} = Handler.handle_request(context)

      uris = Enum.map(response["result"][:resources], & &1[:uri])

      assert uris == [
               "file:///alpha/1.md",
               "file:///alpha/2.md",
               "file:///alpha/3.md",
               "file:///beta/1.md"
             ]

      assert response["result"][:nextCursor] == Paginate.encode_cursor(:resources, 2)
    end

    test "returns second page when the cursor names page 2" do
      context =
        build_context(
          rpc_id: 1,
          rpc_method: "resources/list",
          rpc_params: %{"cursor" => Paginate.encode_cursor(:resources, 2)},
          server: Servers.PaginatedResources
        )

      assert {:rpc_success, response} = Handler.handle_request(context)

      uris = Enum.map(response["result"][:resources], & &1[:uri])

      assert uris == [
               "file:///beta/2.md",
               "file:///beta/3.md",
               "file:///gamma/1.md",
               "file:///gamma/2.md"
             ]

      assert response["result"][:nextCursor] == Paginate.encode_cursor(:resources, 3)
    end

    test "returns last page without nextCursor when the cursor names the last page" do
      context =
        build_context(
          rpc_id: 1,
          rpc_method: "resources/list",
          rpc_params: %{"cursor" => Paginate.encode_cursor(:resources, 3)},
          server: Servers.PaginatedResources
        )

      assert {:rpc_success, response} = Handler.handle_request(context)

      uris = Enum.map(response["result"][:resources], & &1[:uri])
      assert uris == ["file:///gamma/3.md", "file:///gamma/4.md", "file:///gamma/5.md"]
      refute Map.has_key?(response["result"], :nextCursor)
    end

    test "returns -32602 when the cursor names a page after the last page" do
      context =
        build_context(
          rpc_id: 1,
          rpc_method: "resources/list",
          rpc_params: %{"cursor" => Paginate.encode_cursor(:resources, 4)},
          server: Servers.PaginatedResources
        )

      assert {:rpc_error, response} = Handler.handle_request(context)
      assert response["error"]["code"] == -32602
      assert response["error"]["message"] == "invalid cursor"
    end

    test "returns rpc_error with invalid params for malformed cursor" do
      context =
        build_context(
          rpc_id: 1,
          rpc_method: "resources/list",
          rpc_params: %{"cursor" => "abc"},
          server: Servers.PaginatedResources
        )

      assert {:rpc_error, response} = Handler.handle_request(context)
      assert response["error"]["code"] == -32602
      assert response["error"]["message"] == "invalid cursor"
    end

    test "refuses a cursor when pagination is disabled" do
      context =
        build_context(
          rpc_id: 1,
          rpc_method: "resources/list",
          rpc_params: %{"cursor" => Paginate.encode_cursor(:resources, 2)},
          server: Servers.ResourcesMinimal
        )

      assert {:rpc_error, response} = Handler.handle_request(context)
      assert response["error"]["code"] == -32602
      assert response["error"]["message"] == "invalid cursor"
    end

    test "gives the full list with no cursor or a nil cursor when pagination is disabled" do
      for rpc_params <- [nil, %{}, %{"cursor" => nil}] do
        context =
          build_context(
            rpc_id: 1,
            rpc_method: "resources/list",
            rpc_params: rpc_params,
            server: Servers.ResourcesMinimal
          )

        assert {:rpc_success, response} = Handler.handle_request(context)
        response = on_wire(response)

        uris = Enum.map(response["result"]["resources"], & &1["uri"])
        assert uris == ["file:///marketing.md"]
        refute Map.has_key?(response["result"], "nextCursor")
      end
    end
  end

  describe "handle_request/1 - resources/templates/list" do
    test "returns rpc_response with templates list from single template module" do
      context =
        build_context(
          rpc_id: 1,
          rpc_method: "resources/templates/list",
          server: Servers.WithTemplates
        )

      assert {:rpc_success, response} = Handler.handle_request(context)
      response = on_wire(response)
      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 1

      templates = response["result"]["resourceTemplates"]
      assert length(templates) == 1
      assert Enum.any?(templates, &(&1["uriTemplate"] == "file://docs/{path}"))
    end

    test "returns rpc_response with templates list from multiple template modules" do
      context =
        build_context(
          rpc_id: 2,
          rpc_method: "resources/templates/list",
          server: Servers.TemplatesMultiple
        )

      assert {:rpc_success, response} = Handler.handle_request(context)
      response = on_wire(response)
      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 2

      templates = response["result"]["resourceTemplates"]
      assert length(templates) == 3
    end

    test "returns empty templates list when server has no templates configured" do
      context =
        build_context(
          rpc_id: 1,
          rpc_method: "resources/templates/list",
          server: Servers.ResourcesSingle
        )

      assert {:rpc_success, response} = Handler.handle_request(context)
      assert response["result"][:resourceTemplates] == []
    end

    test "preserves rpc id in response" do
      context =
        build_context(
          rpc_id: 42,
          rpc_method: "resources/templates/list",
          server: Servers.WithTemplates
        )

      assert {:rpc_success, response} = Handler.handle_request(context)
      assert response["id"] == 42
    end
  end

  describe "handle_request/1 - resources/templates/list pagination" do
    @describetag :no_runtime

    test "returns first page and nextCursor when no cursor is given" do
      context =
        build_context(
          rpc_id: 1,
          rpc_method: "resources/templates/list",
          server: Servers.PaginatedTemplates
        )

      assert {:rpc_success, response} = Handler.handle_request(context)

      names = Enum.map(response["result"][:resourceTemplates], & &1[:name])
      assert names == ["alpha_1", "alpha_2", "alpha_3", "beta_1"]
      assert response["result"][:nextCursor] == Paginate.encode_cursor(:templates, 2)
    end

    test "returns second page when the cursor names page 2" do
      context =
        build_context(
          rpc_id: 1,
          rpc_method: "resources/templates/list",
          rpc_params: %{"cursor" => Paginate.encode_cursor(:templates, 2)},
          server: Servers.PaginatedTemplates
        )

      assert {:rpc_success, response} = Handler.handle_request(context)

      names = Enum.map(response["result"][:resourceTemplates], & &1[:name])
      assert names == ["beta_2", "beta_3", "gamma_1", "gamma_2"]
      assert response["result"][:nextCursor] == Paginate.encode_cursor(:templates, 3)
    end

    test "returns last page without nextCursor when the cursor names the last page" do
      context =
        build_context(
          rpc_id: 1,
          rpc_method: "resources/templates/list",
          rpc_params: %{"cursor" => Paginate.encode_cursor(:templates, 3)},
          server: Servers.PaginatedTemplates
        )

      assert {:rpc_success, response} = Handler.handle_request(context)

      names = Enum.map(response["result"][:resourceTemplates], & &1[:name])
      assert names == ["gamma_3", "gamma_4", "gamma_5"]
      refute Map.has_key?(response["result"], :nextCursor)
    end

    test "returns -32602 when the cursor names a page after the last page" do
      context =
        build_context(
          rpc_id: 1,
          rpc_method: "resources/templates/list",
          rpc_params: %{"cursor" => Paginate.encode_cursor(:templates, 4)},
          server: Servers.PaginatedTemplates
        )

      assert {:rpc_error, response} = Handler.handle_request(context)
      assert response["error"]["code"] == -32602
      assert response["error"]["message"] == "invalid cursor"
    end

    test "returns rpc_error with invalid params for malformed cursor" do
      context =
        build_context(
          rpc_id: 1,
          rpc_method: "resources/templates/list",
          rpc_params: %{"cursor" => "1x"},
          server: Servers.PaginatedTemplates
        )

      assert {:rpc_error, response} = Handler.handle_request(context)
      assert response["error"]["code"] == -32602
      assert response["error"]["message"] == "invalid cursor"
    end

    test "refuses a cursor when pagination is disabled" do
      context =
        build_context(
          rpc_id: 1,
          rpc_method: "resources/templates/list",
          rpc_params: %{"cursor" => Paginate.encode_cursor(:templates, 2)},
          server: Servers.WithTemplates
        )

      assert {:rpc_error, response} = Handler.handle_request(context)
      assert response["error"]["code"] == -32602
      assert response["error"]["message"] == "invalid cursor"
    end

    test "gives the full list with no cursor or a nil cursor when pagination is disabled" do
      for rpc_params <- [nil, %{}, %{"cursor" => nil}] do
        context =
          build_context(
            rpc_id: 1,
            rpc_method: "resources/templates/list",
            rpc_params: rpc_params,
            server: Servers.WithTemplates
          )

        assert {:rpc_success, response} = Handler.handle_request(context)
        response = on_wire(response)

        names = Enum.map(response["result"]["resourceTemplates"], & &1["name"])
        assert names == ["File documents"]
        refute Map.has_key?(response["result"], "nextCursor")
      end
    end
  end

  describe "handle_request/1 - resources/read" do
    test "returns rpc_response when uri matches a resource" do
      resource = %OzMcp.Structs.Resource{uri: "file:///marketing.md", name: "marketing.md"}

      context =
        build_context(
          rpc_id: 1,
          rpc_method: "resources/read",
          rpc_params: %{"uri" => "file:///marketing.md"},
          resource_type: :resource,
          resource_module: Support.Entities.Resources.FirstTest,
          resource: resource
        )

      assert {:rpc_success, response} = Handler.handle_request(context)
      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 1
      assert response["result"][:contents] != nil
    end

    test "returns rpc_error when uri matches a resource" do
      resource = %OzMcp.Structs.Resource{uri: "file:///api_call.md", name: "api_call.md"}

      context =
        build_context(
          rpc_id: 1,
          rpc_method: "resources/read",
          rpc_params: %{"uri" => "file:///api_call.md"},
          resource_type: :resource,
          resource_module: Support.Entities.Resources.SecondTest,
          resource: resource
        )

      assert {:rpc_error, response} = Handler.handle_request(context)
      assert response["jsonrpc"] == "2.0"
      assert response["error"]["code"] == -32000
      assert response["error"]["message"] == "resource temporarily unavailable"
    end

    test "returns rpc_response with template content on success when uri matches a template" do
      template = %OzMcp.Structs.ResourceTemplate{
        uriTemplate: "file://docs/{path}",
        name: "File documents"
      }

      context =
        build_context(
          rpc_id: 1,
          rpc_method: "resources/read",
          rpc_params: %{"uri" => "file://docs/intro.md"},
          resource_type: :template,
          resource_module: Support.Entities.Templates.FirstTest,
          resource: template,
          resource_uri_params: %{"path" => "intro.md"}
        )

      assert {:rpc_success, response} = Handler.handle_request(context)
      #
      # TODO: Mix key string and key atom, will need to fix that
      #
      assert response == %{
               "id" => 1,
               "jsonrpc" => "2.0",
               "result" => %{
                 contents: [
                   %{
                     text: "# Doc path: intro.md",
                     uri: "file://docs/intro.md",
                     mimeType: "text/markdown"
                   }
                 ]
               }
             }
    end

    test "returns rpc_error when template does not find the resource template" do
      template = %OzMcp.Structs.ResourceTemplate{
        uriTemplate: "file://docs/{path}",
        name: "File documents"
      }

      context =
        build_context(
          rpc_id: 1,
          rpc_method: "resources/read",
          rpc_params: %{"uri" => "file://docs/missing.md"},
          resource_type: :template,
          resource_module: Support.Entities.Templates.FirstTest,
          resource: template,
          resource_uri_params: %{"path" => "missing.md"}
        )

      assert {:rpc_error, response} = Handler.handle_request(context)
      assert response["jsonrpc"] == "2.0"
      assert response["error"]["code"] == -32000
      assert response["error"]["message"] == "resource temporarily unavailable"
    end
  end

  describe "handle_request/1 - resources/subscribe" do
    test "returns rpc_response with empty result and records the subscription" do
      session_id = Utils.create_session(@server, initialized: true)

      context =
        build_context(
          rpc_id: 1,
          rpc_method: "resources/subscribe",
          rpc_params: %{"uri" => "file:///stations.md"},
          session_id: session_id,
          server: @server_module
        )

      assert {:rpc_success, response} = Handler.handle_request(context)
      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 1
      assert response["result"] == %{}
      assert "file:///stations.md" in Utils.subscriptions(@server, session_id)
    end

    test "does not duplicate an already existing subscription" do
      session_id = Utils.create_session(@server, initialized: true)

      context =
        build_context(
          rpc_id: 1,
          rpc_method: "resources/subscribe",
          rpc_params: %{"uri" => "file:///stations.md"},
          session_id: session_id,
          server: @server_module
        )

      assert {:rpc_success, _} = Handler.handle_request(context)
      assert {:rpc_success, _} = Handler.handle_request(context)

      assert Utils.subscriptions(@server, session_id) == ["file:///stations.md"]
    end

    test "returns rpc_error when the server is not running" do
      context =
        build_context(
          rpc_id: 1,
          rpc_method: "resources/subscribe",
          rpc_params: %{"uri" => "file:///marketing.md"},
          session_id: "whatever",
          server: Servers.ResourcesMultipleSubscribed
        )

      assert {:rpc_error, response} = Handler.handle_request(context)
      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 1
      assert response["error"]["code"] == -32603
      assert response["error"]["message"] == "internal server error"
    end

    @tag runtime_server: Servers.ResourcesMultipleSubscribed,
         runtime_opts: %{max_subscriptions_per_session: 1}
    test "answers too many subscriptions when the limit of the session is reached" do
      server = Servers.ResourcesMultipleSubscribed
      session_id = Utils.create_session(inst(server), initialized: true)
      :ok = Sessions.subscribe(inst(server), session_id, "file:///marketing.md")

      context =
        build_context(
          rpc_id: 1,
          rpc_method: "resources/subscribe",
          rpc_params: %{"uri" => "file:///definitions.md"},
          session_id: session_id,
          server: server
        )

      assert {:rpc_error, response} = Handler.handle_request(context)
      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 1
      assert response["error"]["code"] == -32000
      assert response["error"]["message"] == "too many subscriptions"
      assert response["error"]["data"] == %{"limit" => "max_subscriptions_per_session"}

      assert Utils.subscriptions(inst(server), session_id) == ["file:///marketing.md"]
    end
  end

  describe "handle_request/1 - resources/unsubscribe" do
    test "returns rpc_response with empty result and removes the subscription" do
      session_id = Utils.create_session(@server, initialized: true)
      :ok = Sessions.subscribe(@server, session_id, "file:///stations.md")

      context =
        build_context(
          rpc_id: 1,
          rpc_method: "resources/unsubscribe",
          rpc_params: %{"uri" => "file:///stations.md"},
          session_id: session_id,
          server: @server_module
        )

      assert {:rpc_success, response} = Handler.handle_request(context)
      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 1
      assert response["result"] == %{}
      refute "file:///stations.md" in Utils.subscriptions(@server, session_id)
    end

    test "returns rpc_response with empty result for a non subscribed uri" do
      session_id = Utils.create_session(@server, initialized: true)

      context =
        build_context(
          rpc_id: 1,
          rpc_method: "resources/unsubscribe",
          rpc_params: %{"uri" => "file:///stations.md"},
          session_id: session_id,
          server: @server_module
        )

      assert {:rpc_success, response} = Handler.handle_request(context)
      assert response["result"] == %{}
    end

    test "returns rpc_error when the server is not running" do
      context =
        build_context(
          rpc_id: 1,
          rpc_method: "resources/unsubscribe",
          rpc_params: %{"uri" => "file:///marketing.md"},
          session_id: "whatever",
          server: Servers.ResourcesMultipleSubscribed
        )

      assert {:rpc_error, response} = Handler.handle_request(context)
      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 1
      assert response["error"]["code"] == -32603
      assert response["error"]["message"] == "internal server error"
    end
  end

  describe "handle_request/1 - tools/list" do
    test "returns rpc_response with tools list from single tool module" do
      context =
        build_context(
          rpc_id: 1,
          rpc_method: "tools/list",
          server: Servers.ToolsOnly
        )

      assert {:rpc_success, response} = Handler.handle_request(context)
      response = on_wire(response)
      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 1

      tools = response["result"]["tools"]
      assert length(tools) == 2
      tool_names = Enum.map(tools, & &1["name"])
      assert "get_date" in tool_names
      assert "get_time" in tool_names
    end

    test "returns rpc_response with tools list from multiple tool modules" do
      context =
        build_context(
          rpc_id: 1,
          rpc_method: "tools/list",
          server: Servers.ToolsMultiple
        )

      assert {:rpc_success, response} = Handler.handle_request(context)
      response = on_wire(response)
      assert response["jsonrpc"] == "2.0"

      tools = response["result"]["tools"]
      assert length(tools) == 3
      tool_names = Enum.map(tools, & &1["name"])
      assert "get_date" in tool_names
      assert "get_time" in tool_names
      assert "get_temperature" in tool_names
    end

    test "returns empty tools list when server has no tools configured" do
      context =
        build_context(
          rpc_id: 1,
          rpc_method: "tools/list",
          server: Servers.ResourcesSingle
        )

      assert {:rpc_success, response} = Handler.handle_request(context)
      assert response["result"][:tools] == []
    end
  end

  describe "handle_request/1 - tools/list pagination" do
    @describetag :no_runtime

    test "returns first page and nextCursor when no cursor is given" do
      context =
        build_context(
          rpc_id: 1,
          rpc_method: "tools/list",
          server: Servers.PaginatedTools
        )

      assert {:rpc_success, response} = Handler.handle_request(context)

      names = Enum.map(response["result"][:tools], & &1[:name])
      assert names == ["alpha_1", "alpha_2", "alpha_3", "beta_1"]
      assert response["result"][:nextCursor] == Paginate.encode_cursor(:tools, 2)
    end

    test "returns the first page when the cursor is nil" do
      context =
        build_context(
          rpc_id: 1,
          rpc_method: "tools/list",
          rpc_params: %{"cursor" => nil},
          server: Servers.PaginatedTools
        )

      assert {:rpc_success, response} = Handler.handle_request(context)

      names = Enum.map(response["result"][:tools], & &1[:name])
      assert names == ["alpha_1", "alpha_2", "alpha_3", "beta_1"]
      assert response["result"][:nextCursor] == Paginate.encode_cursor(:tools, 2)
    end

    test "returns second page when the cursor names page 2" do
      context =
        build_context(
          rpc_id: 1,
          rpc_method: "tools/list",
          rpc_params: %{"cursor" => Paginate.encode_cursor(:tools, 2)},
          server: Servers.PaginatedTools
        )

      assert {:rpc_success, response} = Handler.handle_request(context)

      names = Enum.map(response["result"][:tools], & &1[:name])
      assert names == ["beta_2", "beta_3", "gamma_1", "gamma_2"]
      assert response["result"][:nextCursor] == Paginate.encode_cursor(:tools, 3)
    end

    test "returns last page without nextCursor when the cursor names the last page" do
      context =
        build_context(
          rpc_id: 1,
          rpc_method: "tools/list",
          rpc_params: %{"cursor" => Paginate.encode_cursor(:tools, 3)},
          server: Servers.PaginatedTools
        )

      assert {:rpc_success, response} = Handler.handle_request(context)

      names = Enum.map(response["result"][:tools], & &1[:name])
      assert names == ["gamma_3", "gamma_4", "gamma_5"]
      refute Map.has_key?(response["result"], :nextCursor)
    end

    test "returns -32602 when the cursor names a page after the last page" do
      context =
        build_context(
          rpc_id: 1,
          rpc_method: "tools/list",
          rpc_params: %{"cursor" => Paginate.encode_cursor(:tools, 4)},
          server: Servers.PaginatedTools
        )

      assert {:rpc_error, response} = Handler.handle_request(context)
      assert response["error"]["code"] == -32602
      assert response["error"]["message"] == "invalid cursor"
    end

    test "returns rpc_error with invalid params for malformed cursor" do
      context =
        build_context(
          rpc_id: 1,
          rpc_method: "tools/list",
          rpc_params: %{"cursor" => "abc"},
          server: Servers.PaginatedTools
        )

      assert {:rpc_error, response} = Handler.handle_request(context)
      assert response["error"]["code"] == -32602
      assert response["error"]["message"] == "invalid cursor"
    end

    test "refuses a cursor when pagination is disabled" do
      context =
        build_context(
          rpc_id: 1,
          rpc_method: "tools/list",
          rpc_params: %{"cursor" => Paginate.encode_cursor(:tools, 2)},
          server: Servers.ToolsOnly
        )

      assert {:rpc_error, response} = Handler.handle_request(context)
      assert response["error"]["code"] == -32602
      assert response["error"]["message"] == "invalid cursor"
    end

    test "gives the full list with no cursor or a nil cursor when pagination is disabled" do
      for rpc_params <- [nil, %{}, %{"cursor" => nil}] do
        context =
          build_context(
            rpc_id: 1,
            rpc_method: "tools/list",
            rpc_params: rpc_params,
            server: Servers.ToolsOnly
          )

        assert {:rpc_success, response} = Handler.handle_request(context)
        response = on_wire(response)

        names = Enum.map(response["result"]["tools"], & &1["name"])
        assert names == ["get_date", "get_time"]
        refute Map.has_key?(response["result"], "nextCursor")
      end
    end

    for cursor <- [
          "zzz",
          "",
          5,
          false,
          %{},
          ["a"],
          Paginate.encode_cursor(:tools, 1),
          Paginate.encode_cursor(:prompts, 1)
        ] do
      test "refuses the cursor #{inspect(cursor)} when pagination is disabled" do
        context =
          build_context(
            rpc_id: 1,
            rpc_method: "tools/list",
            rpc_params: %{"cursor" => unquote(Macro.escape(cursor))},
            server: Servers.ToolsOnly
          )

        assert {:rpc_error, response} = Handler.handle_request(context)
        assert response["error"]["code"] == -32602
        assert response["error"]["message"] == "invalid cursor"
      end
    end

    test "refuses a cursor before the list function runs" do
      context =
        build_context(
          rpc_id: 1,
          rpc_method: "tools/list",
          rpc_params: %{"cursor" => "zzz"},
          server: OzMcp.HandlerTest.NoPaginateMustNotList
        )

      assert {:rpc_error, response} = Handler.handle_request(context)
      assert response["error"]["code"] == -32602
      assert response["error"]["message"] == "invalid cursor"
    end
  end

  describe "handle_request/1 - tools/call" do
    test "returns rpc_response with tool result on success" do
      context =
        build_context(
          rpc_id: 1,
          rpc_method: "tools/call",
          rpc_params: %{"name" => "get_date"},
          tool_module: Support.Entities.Tools.SecondTest
        )

      assert {:rpc_success, response} = Handler.handle_request(context)
      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 1
      assert response["result"][:content] != nil
    end

    test "returns rpc_response with tool result with arguments" do
      context =
        build_context(
          rpc_id: 2,
          rpc_method: "tools/call",
          rpc_params: %{
            "name" => "get_temperature",
            "arguments" => %{"location" => "Paris"}
          },
          tool_module: Support.Entities.Tools.FirstTest
        )

      assert {:rpc_success, response} = Handler.handle_request(context)
      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 2
      assert response["result"][:content] != nil
    end

    test "answers input errors with an isError result and never runs the tool" do
      import Support.Factories.Tool

      code =
        quote do
          def call(_ctx, _params), do: raise("the tool must not run on input errors")
        end

      tool_mod =
        module("NeverRuns", _code_: code) do
          tool("get_date", title: "T", description: "D")
        end
        |> compile()

      context =
        build_context(
          rpc_id: 3,
          rpc_method: "tools/call",
          rpc_params: %{"name" => "get_date", "arguments" => %{"extra" => 1}},
          tool_module: tool_mod,
          tool_input_errors: [
            "'location' value is not of type string",
            "property 'location' is required"
          ]
        )

      assert {:rpc_success, response} = Handler.handle_request(context)
      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 3

      assert response["result"] == %{
               content: [
                 %{
                   type: "text",
                   text: "'location' value is not of type string\nproperty 'location' is required"
                 }
               ],
               isError: true
             }
    end

    test "input errors answer an isError result when the call is not task-augmented" do
      context =
        build_context(
          rpc_id: 4,
          rpc_method: "tools/call",
          rpc_params: %{"name" => "task_immediate", "task" => %{}},
          tool_module: Support.Entities.Tools.TaskImmediateTest,
          task_metadata: nil,
          tool_input_errors: ["property 'location' is required"],
          server: Servers.TasksTest
        )

      assert {:rpc_success, response} = Handler.handle_request(context)
      assert response["result"][:isError] == true
      refute Map.has_key?(response["result"], :task)
    end

    test "accepts a structuredContent matching the compiled outputSchema" do
      {tool_mod, tool_config} = structured_tool(%{"result" => "ok"})

      context =
        build_context(
          rpc_id: 5,
          rpc_method: "tools/call",
          rpc_params: %{"name" => "structured_tool"},
          tool_module: tool_mod,
          tool_config: tool_config,
          server: @server_module
        )

      assert {:rpc_success, response} = Handler.handle_request(context)
      assert response["result"][:structuredContent] == %{"result" => "ok"}
    end

    test "answers -32603 when structuredContent violates the compiled outputSchema" do
      {tool_mod, tool_config} = structured_tool(%{"result" => 42})

      context =
        build_context(
          rpc_id: 6,
          rpc_method: "tools/call",
          rpc_params: %{"name" => "structured_tool"},
          tool_module: tool_mod,
          tool_config: tool_config,
          server: @server_module
        )

      assert {:rpc_error, response} = Handler.handle_request(context)
      assert response["error"]["code"] == -32603
      assert response["error"]["message"] == "tool output does not match outputSchema"
      assert response["error"]["data"] == ["'result' value is not of type string"]
    end

    test "an invalid outputSchema answers -32603 internal error, never an output mismatch" do
      {tool_mod, tool_config} = broken_output_schema_tool()

      context =
        build_context(
          rpc_id: 8,
          rpc_method: "tools/call",
          rpc_params: %{"name" => "broken_output_tool", "arguments" => %{}},
          tool_module: tool_mod,
          tool_config: tool_config,
          server: @server_module
        )

      assert {:rpc_error, response} = Handler.handle_request(context)

      assert response["error"] == %{"code" => -32603, "message" => "internal error"}
    end

    test "answers -32603 when structuredContent is missing and an outputSchema is declared" do
      {tool_mod, tool_config} = structured_tool(nil)

      context =
        build_context(
          rpc_id: 7,
          rpc_method: "tools/call",
          rpc_params: %{"name" => "structured_tool"},
          tool_module: tool_mod,
          tool_config: tool_config,
          server: @server_module
        )

      assert {:rpc_error, response} = Handler.handle_request(context)
      assert response["error"]["code"] == -32603
      assert response["error"]["message"] == "tool output does not match outputSchema"

      assert response["error"]["data"] == [
               "'structuredContent' is missing, the tool declares an outputSchema"
             ]
    end

    test "accepts an isError result without structuredContent when an outputSchema is declared" do
      {tool_mod, tool_config} = error_tool()

      context =
        build_context(
          rpc_id: 10,
          rpc_method: "tools/call",
          rpc_params: %{"name" => "error_tool"},
          tool_module: tool_mod,
          tool_config: tool_config,
          server: @server_module
        )

      assert {:rpc_success, response} = Handler.handle_request(context)
      assert response["result"][:isError] == true
      refute Map.has_key?(response["result"], :structuredContent)
    end

    test "accepts a structuredContent with atom keys and keeps them on the wire" do
      {tool_mod, tool_config} = structured_tool(%{result: "ok"})

      context =
        build_context(
          rpc_id: 11,
          rpc_method: "tools/call",
          rpc_params: %{"name" => "structured_tool"},
          tool_module: tool_mod,
          tool_config: tool_config,
          server: @server_module
        )

      assert {:rpc_success, response} = Handler.handle_request(context)
      assert response["result"][:structuredContent] == %{result: "ok"}
    end

    test "answers -32603 for a plain map result whose structuredContent is not an object" do
      {tool_mod, tool_config} = plain_map_tool()

      context =
        build_context(
          rpc_id: 12,
          rpc_method: "tools/call",
          rpc_params: %{"name" => "plain_map_tool"},
          tool_module: tool_mod,
          tool_config: tool_config,
          server: @server_module
        )

      assert {:rpc_error, response} = Handler.handle_request(context)
      assert response["error"]["code"] == -32603
      assert response["error"]["message"] == "internal error"
    end

    test "accepts a tool result without structuredContent when no outputSchema is declared" do
      import Support.Factories.Tool

      code =
        quote do
          def call(_ctx, _params) do
            result =
              %OzMcp.Structs.CallToolResult{}
              |> OzMcp.Structs.CallToolResult.content([])
              |> OzMcp.Structs.CallToolResult.build()

            {:ok, result}
          end
        end

      tool_mod =
        module("NoOutputSchema", _code_: code) do
          tool("plain_tool", title: "T", description: "D")
        end
        |> compile()

      tool_config = Enum.find(tool_mod.list(), &(&1.name == "plain_tool"))

      context =
        build_context(
          rpc_id: 13,
          rpc_method: "tools/call",
          rpc_params: %{"name" => "plain_tool"},
          tool_module: tool_mod,
          tool_config: tool_config
        )

      assert {:rpc_success, response} = Handler.handle_request(context)
      refute Map.has_key?(response["result"], :structuredContent)
    end

    @tag :capture_log
    test "answers -32603 with the right id for a result with a string that is not valid UTF-8" do
      import Support.Factories.Tool

      code =
        quote do
          def call(_ctx, _params) do
            {:ok, %{"content" => [%{"type" => "text", "text" => <<0xFF>>}]}}
          end
        end

      tool_mod =
        module("BadUtf8Result", _code_: code) do
          tool("bad_utf8_tool", title: "T", description: "D")
        end
        |> compile()

      tool_config = Enum.find(tool_mod.list(), &(&1.name == "bad_utf8_tool"))

      context =
        build_context(
          rpc_id: 41,
          rpc_method: "tools/call",
          rpc_params: %{"name" => "bad_utf8_tool"},
          tool_module: tool_mod,
          tool_config: tool_config
        )

      assert {:rpc_error, response} = Handler.handle_request(context)
      assert response["id"] == 41
      assert response["error"] == %{"code" => -32603, "message" => "internal error"}
    end

    @tag :capture_log
    test "answers -32603 for an error whose message is not valid UTF-8" do
      import Support.Factories.Tool

      code =
        quote do
          def call(_ctx, _params) do
            {:error, %{code: 1, message: <<0xFF>>}}
          end
        end

      tool_mod =
        module("BadUtf8Error", _code_: code) do
          tool("bad_utf8_error_tool", title: "T", description: "D")
        end
        |> compile()

      tool_config = Enum.find(tool_mod.list(), &(&1.name == "bad_utf8_error_tool"))

      context =
        build_context(
          rpc_id: 42,
          rpc_method: "tools/call",
          rpc_params: %{"name" => "bad_utf8_error_tool"},
          tool_module: tool_mod,
          tool_config: tool_config
        )

      assert {:rpc_error, response} = Handler.handle_request(context)
      assert response["id"] == 42
      assert response["error"] == %{"code" => -32603, "message" => "internal error"}
    end
  end

  describe "handle_request/1 - tools/call ctx" do
    test "passes the execution ctx to the tool" do
      import Support.Factories.Tool

      code =
        quote do
          def call(ctx, _params) do
            :persistent_term.put({:oz_mcp_test, :tool_ctx}, ctx)

            {:ok,
             %OzMcp.Structs.CallToolResult{}
             |> OzMcp.Structs.CallToolResult.content([
               %OzMcp.Structs.TextContent{} |> OzMcp.Structs.TextContent.text("ok")
             ])
             |> OzMcp.Structs.CallToolResult.build()}
          end
        end

      tool_mod =
        module("CtxCapture", _code_: code) do
          tool("get_date", title: "T", description: "D")
        end
        |> compile()

      session_id = Utils.generate_session_id()

      context =
        build_context(
          rpc_id: 7,
          rpc_method: "tools/call",
          rpc_params: %{"name" => "get_date"},
          tool_module: tool_mod,
          server: @server_module,
          session_id: session_id,
          progress_token: "tok-9"
        )

      assert {:rpc_success, _} = Handler.handle_request(context)

      assert :persistent_term.get({:oz_mcp_test, :tool_ctx}, nil) == %{
               instance: @server,
               server: @server_module,
               session_id: session_id,
               request_id: 7,
               progress_token: "tok-9",
               task_id: nil,
               client_capabilities: %{},
               principal: nil
             }
    after
      :persistent_term.erase({:oz_mcp_test, :tool_ctx})
    end

    test "passes nil progress_token and nil request_id when absent" do
      import Support.Factories.Tool

      code =
        quote do
          def call(ctx, _params) do
            :persistent_term.put({:oz_mcp_test, :tool_ctx}, ctx)

            {:ok,
             %OzMcp.Structs.CallToolResult{}
             |> OzMcp.Structs.CallToolResult.content([
               %OzMcp.Structs.TextContent{} |> OzMcp.Structs.TextContent.text("ok")
             ])
             |> OzMcp.Structs.CallToolResult.build()}
          end
        end

      tool_mod =
        module("CtxCaptureNil", _code_: code) do
          tool("get_date", title: "T", description: "D")
        end
        |> compile()

      session_id = Utils.generate_session_id()

      context =
        build_context(
          rpc_id: nil,
          rpc_method: "tools/call",
          rpc_params: %{"name" => "get_date"},
          tool_module: tool_mod,
          server: @server_module,
          session_id: session_id
        )

      assert {:rpc_success, _} = Handler.handle_request(context)

      assert :persistent_term.get({:oz_mcp_test, :tool_ctx}, nil) == %{
               instance: @server,
               server: @server_module,
               session_id: session_id,
               request_id: nil,
               progress_token: nil,
               task_id: nil,
               client_capabilities: %{},
               principal: nil
             }
    after
      :persistent_term.erase({:oz_mcp_test, :tool_ctx})
    end
  end

  describe "handle_request/1 - prompts/list" do
    test "returns rpc_response with prompts list from single prompt module" do
      context =
        build_context(
          rpc_id: 1,
          rpc_method: "prompts/list",
          server: Servers.PromptsOnly
        )

      assert {:rpc_success, response} = Handler.handle_request(context)
      response = on_wire(response)
      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 1

      prompts = response["result"]["prompts"]
      assert Enum.map(prompts, & &1["name"]) == ["code_review"]
    end

    test "returns rpc_response with prompts list from multiple prompt modules" do
      context =
        build_context(
          rpc_id: 1,
          rpc_method: "prompts/list",
          server: Servers.PromptsMultiple
        )

      assert {:rpc_success, response} = Handler.handle_request(context)
      response = on_wire(response)
      assert response["jsonrpc"] == "2.0"

      prompts = response["result"]["prompts"]
      assert Enum.map(prompts, & &1["name"]) == ["code_review", "greeting", "farewell"]
    end

    test "serializes declared prompt arguments" do
      context =
        build_context(
          rpc_id: 1,
          rpc_method: "prompts/list",
          server: Servers.PromptsOnly
        )

      assert {:rpc_success, response} = Handler.handle_request(context)
      response = on_wire(response)

      [prompt] = response["result"]["prompts"]

      assert prompt["arguments"] == [
               %{
                 "name" => "language",
                 "description" => "Programming language",
                 "required" => true
               }
             ]
    end

    test "returns empty prompts list when server has no prompts configured" do
      context =
        build_context(
          rpc_id: 1,
          rpc_method: "prompts/list",
          server: Servers.ToolsOnly
        )

      assert {:rpc_success, response} = Handler.handle_request(context)
      assert response["result"][:prompts] == []
    end
  end

  describe "handle_request/1 - prompts/list pagination" do
    @describetag :no_runtime

    test "returns first page and nextCursor when no cursor is given" do
      context =
        build_context(
          rpc_id: 1,
          rpc_method: "prompts/list",
          server: Servers.PaginatedPrompts
        )

      assert {:rpc_success, response} = Handler.handle_request(context)

      names = Enum.map(response["result"][:prompts], & &1[:name])
      assert names == ["alpha_1", "alpha_2", "alpha_3", "beta_1"]
      assert response["result"][:nextCursor] == Paginate.encode_cursor(:prompts, 2)
    end

    test "returns second page when the cursor names page 2" do
      context =
        build_context(
          rpc_id: 1,
          rpc_method: "prompts/list",
          rpc_params: %{"cursor" => Paginate.encode_cursor(:prompts, 2)},
          server: Servers.PaginatedPrompts
        )

      assert {:rpc_success, response} = Handler.handle_request(context)

      names = Enum.map(response["result"][:prompts], & &1[:name])
      assert names == ["beta_2", "beta_3", "gamma_1", "gamma_2"]
      assert response["result"][:nextCursor] == Paginate.encode_cursor(:prompts, 3)
    end

    test "returns last page without nextCursor when the cursor names the last page" do
      context =
        build_context(
          rpc_id: 1,
          rpc_method: "prompts/list",
          rpc_params: %{"cursor" => Paginate.encode_cursor(:prompts, 3)},
          server: Servers.PaginatedPrompts
        )

      assert {:rpc_success, response} = Handler.handle_request(context)

      names = Enum.map(response["result"][:prompts], & &1[:name])
      assert names == ["gamma_3", "gamma_4", "gamma_5"]
      refute Map.has_key?(response["result"], :nextCursor)
    end

    test "returns -32602 when the cursor names a page after the last page" do
      context =
        build_context(
          rpc_id: 1,
          rpc_method: "prompts/list",
          rpc_params: %{"cursor" => Paginate.encode_cursor(:prompts, 4)},
          server: Servers.PaginatedPrompts
        )

      assert {:rpc_error, response} = Handler.handle_request(context)
      assert response["error"]["code"] == -32602
      assert response["error"]["message"] == "invalid cursor"
    end

    test "returns rpc_error with invalid params for malformed cursor" do
      context =
        build_context(
          rpc_id: 1,
          rpc_method: "prompts/list",
          rpc_params: %{"cursor" => "abc"},
          server: Servers.PaginatedPrompts
        )

      assert {:rpc_error, response} = Handler.handle_request(context)
      assert response["error"]["code"] == -32602
      assert response["error"]["message"] == "invalid cursor"
    end

    test "refuses a cursor when pagination is disabled" do
      context =
        build_context(
          rpc_id: 1,
          rpc_method: "prompts/list",
          rpc_params: %{"cursor" => Paginate.encode_cursor(:prompts, 2)},
          server: Servers.PromptsOnly
        )

      assert {:rpc_error, response} = Handler.handle_request(context)
      assert response["error"]["code"] == -32602
      assert response["error"]["message"] == "invalid cursor"
    end

    test "gives the full list with no cursor or a nil cursor when pagination is disabled" do
      for rpc_params <- [nil, %{}, %{"cursor" => nil}] do
        context =
          build_context(
            rpc_id: 1,
            rpc_method: "prompts/list",
            rpc_params: rpc_params,
            server: Servers.PromptsOnly
          )

        assert {:rpc_success, response} = Handler.handle_request(context)
        response = on_wire(response)

        names = Enum.map(response["result"]["prompts"], & &1["name"])
        assert names == ["code_review"]
        refute Map.has_key?(response["result"], "nextCursor")
      end
    end
  end

  describe "handle_request/1 - prompts/list result meta/extras" do
    @describetag :no_runtime

    test "includes _meta when list_result meta is declared" do
      context =
        build_context(
          rpc_id: 1,
          rpc_method: "prompts/list",
          server: Servers.OnlyMeta
        )

      assert {:rpc_success, response} = Handler.handle_request(context)

      assert response["result"][:_meta] == %{
               "prm_meta1" => "prm_meta1_value",
               "prm_meta2" => "prm_meta2_value"
             }
    end

    test "includes extras when list_result extras are declared" do
      context =
        build_context(
          rpc_id: 1,
          rpc_method: "prompts/list",
          server: Servers.OnlyExtra
        )

      assert {:rpc_success, response} = Handler.handle_request(context)

      assert response["result"]["prm_extra1"] == "prm_extra1_value"
      assert response["result"]["prm_extra2"] == "prm_extra2_value"
      refute Map.has_key?(response["result"], :_meta)
    end

    test "includes both meta and extras when both are declared" do
      context =
        build_context(
          rpc_id: 1,
          rpc_method: "prompts/list",
          server: Servers.MetaAndExtra
        )

      assert {:rpc_success, response} = Handler.handle_request(context)

      assert response["result"][:_meta] == %{
               "prm_meta1" => "prm_meta1_value",
               "prm_meta2" => "prm_meta2_value"
             }

      assert response["result"]["prm_extra1"] == "prm_extra1_value"
    end
  end

  describe "handle_request/1 - prompts/get" do
    @describetag :no_runtime

    test "returns rpc_response with the built GetPromptResult on success" do
      context =
        build_context(
          rpc_id: 1,
          rpc_method: "prompts/get",
          rpc_params: %{"name" => "code_review", "arguments" => %{"language" => "elixir"}},
          prompt_module: Support.Entities.Prompts.FirstTest,
          server: Servers.PromptsOnly,
          session_id: "session-1"
        )

      assert {:rpc_success, response} = Handler.handle_request(context)
      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 1
      assert response["result"][:description] == "Code review prompt"

      assert response["result"][:messages] == [
               %{"role" => "user", "content" => %{type: "text", text: "Review this code."}}
             ]
    end

    test "builds a plain-map result into its result struct" do
      import Support.Factories.Prompt

      code =
        quote do
          def get(_ctx, _params), do: {:ok, %{"messages" => []}}
        end

      prompt_mod =
        module("PlainMapGet", _code_: code) do
          prompt("plain", title: "T", description: "D")
        end
        |> compile()

      context =
        build_context(
          rpc_id: 1,
          rpc_method: "prompts/get",
          rpc_params: %{"name" => "plain"},
          prompt_module: prompt_mod,
          server: @server_module
        )

      assert {:rpc_success, response} = Handler.handle_request(context)
      assert response["result"] == %{messages: []}
    end

    test "propagates the author {:error, %Error{}} verbatim" do
      import Support.Factories.Prompt

      code =
        quote do
          def get(_ctx, _params) do
            {:error, OzMcp.Utils.Error.new(-32001, "custom prompt error", %{"info" => 1})}
          end
        end

      prompt_mod =
        module("ErrorGet", _code_: code) do
          prompt("failing", title: "T", description: "D")
        end
        |> compile()

      context =
        build_context(
          rpc_id: 3,
          rpc_method: "prompts/get",
          rpc_params: %{"name" => "failing"},
          prompt_module: prompt_mod,
          server: @server_module
        )

      assert {:rpc_error, response} = Handler.handle_request(context)
      assert response["error"]["code"] == -32001
      assert response["error"]["message"] == "custom prompt error"
      assert response["error"]["data"] == %{"info" => 1}
    end

    test "get/2 receives the raw wire params, including _meta" do
      {prompt_mod, server_mod} = compile_raw_params_fixtures()

      body = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "prompts/get",
        "params" => %{
          "name" => "greeting",
          "_meta" => %{"progressToken" => "tok-1"}
        }
      }

      conn =
        Plug.Test.conn(:post, "/", :json.encode(body) |> IO.iodata_to_binary())
        |> Plug.Conn.put_private(:server, server_mod)
        |> Plug.Conn.put_req_header("accept", "application/json, text/event-stream")
        |> Map.put(:body_params, body)

      context =
        server_mod
        |> Context.new(:http_streamable, :rpc)
        |> Context.put_http_conn(conn)
        |> Validate.JsonRpc.validate()
        |> then(fn
          {:cont, context} -> OzMcp.Pipeline.Bind.run(context)
          {:halt, context} -> context
        end)
        |> plain()

      assert is_nil(context.error), "validate failed: #{inspect(context.error)}"
      assert context.bound.module == prompt_mod

      assert context.rpc_params ==
               %{"name" => "greeting", "_meta" => %{"progressToken" => "tok-1"}}

      assert {:rpc_success, _} = Handler.handle_request(context)

      assert :persistent_term.get({:oz_mcp_test, :prompt_params}, nil) ==
               %{"name" => "greeting", "_meta" => %{"progressToken" => "tok-1"}}
    after
      :persistent_term.erase({:oz_mcp_test, :prompt_params})
    end
  end

  describe "handle_request/1 - prompts/get ctx" do
    @describetag :no_runtime

    test "passes the execution ctx to the prompt" do
      import Support.Factories.Prompt

      code =
        quote do
          def get(ctx, _params) do
            :persistent_term.put({:oz_mcp_test, :prompt_ctx}, ctx)

            {:ok,
             %OzMcp.Structs.GetPromptResult{}
             |> OzMcp.Structs.GetPromptResult.messages([])}
          end
        end

      prompt_mod =
        module("CtxCapture", _code_: code) do
          prompt("code_review", title: "T", description: "D")
        end
        |> compile()

      session_id = Utils.generate_session_id()

      context =
        build_context(
          rpc_id: 7,
          rpc_method: "prompts/get",
          rpc_params: %{"name" => "code_review"},
          prompt_module: prompt_mod,
          server: @server_module,
          session_id: session_id,
          progress_token: "tok-9"
        )

      assert {:rpc_success, _} = Handler.handle_request(context)

      assert :persistent_term.get({:oz_mcp_test, :prompt_ctx}, nil) == %{
               instance: @server,
               server: @server_module,
               session_id: session_id,
               request_id: 7,
               progress_token: "tok-9",
               task_id: nil,
               client_capabilities: %{},
               principal: nil
             }
    after
      :persistent_term.erase({:oz_mcp_test, :prompt_ctx})
    end

    test "passes nil progress_token and nil request_id when absent" do
      import Support.Factories.Prompt

      code =
        quote do
          def get(ctx, _params) do
            :persistent_term.put({:oz_mcp_test, :prompt_ctx}, ctx)

            {:ok,
             %OzMcp.Structs.GetPromptResult{}
             |> OzMcp.Structs.GetPromptResult.messages([])}
          end
        end

      prompt_mod =
        module("CtxCaptureNil", _code_: code) do
          prompt("code_review", title: "T", description: "D")
        end
        |> compile()

      session_id = Utils.generate_session_id()

      context =
        build_context(
          rpc_id: nil,
          rpc_method: "prompts/get",
          rpc_params: %{"name" => "code_review"},
          prompt_module: prompt_mod,
          server: @server_module,
          session_id: session_id
        )

      assert {:rpc_success, _} = Handler.handle_request(context)

      assert :persistent_term.get({:oz_mcp_test, :prompt_ctx}, nil) == %{
               instance: @server,
               server: @server_module,
               session_id: session_id,
               request_id: nil,
               progress_token: nil,
               task_id: nil,
               client_capabilities: %{},
               principal: nil
             }
    after
      :persistent_term.erase({:oz_mcp_test, :prompt_ctx})
    end
  end

  describe "handle_request/1 - tools/call task-augmented" do
    @describetag runtime_server: Servers.TasksTest

    setup do
      %{session_id: tasks_session()}
    end

    test "returns a CreateTaskResult and never the tool result", %{session_id: session_id} do
      context =
        build_context(
          rpc_id: 1,
          rpc_method: "tools/call",
          rpc_params: %{"name" => "task_immediate", "arguments" => %{}},
          tool_module: Support.Entities.Tools.TaskImmediateTest,
          task_metadata: %{ttl: nil},
          server: @tasks_server_module,
          session_id: session_id
        )

      assert {:rpc_success, response} = Handler.handle_request(context)
      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 1

      task = response["result"][:task]
      assert is_binary(task[:taskId])
      assert task[:status] == "working"
      assert task[:ttl] == 86_400_000
      assert String.match?(task[:createdAt], ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/)
      assert String.match?(task[:lastUpdatedAt], ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/)

      # The tool result is never part of the creation response
      #
      refute Map.has_key?(response["result"], :content)

      # The tool still runs in the background
      #
      assert {:ok, {:ok, _}} =
               Tasks.await(@tasks_server, Utils.owner(session_id), task[:taskId], 5_000)
    end

    test "forwards the requested ttl and the progress token to the task", %{
      session_id: session_id
    } do
      context =
        build_context(
          rpc_id: 2,
          rpc_method: "tools/call",
          rpc_params: %{"name" => "task_immediate", "arguments" => %{}},
          tool_module: Support.Entities.Tools.TaskImmediateTest,
          task_metadata: %{ttl: 5_000},
          progress_token: "tok-7",
          server: @tasks_server_module,
          session_id: session_id
        )

      assert {:rpc_success, response} = Handler.handle_request(context)
      task = response["result"][:task]
      assert task[:ttl] == 5_000

      assert {:ok, {:ok, _}} =
               Tasks.await(@tasks_server, Utils.owner(session_id), task[:taskId], 5_000)

      # The background runner received the 041 ctx with the task_id set and
      # the request's progress token (A17, A18)
      #
      ctx = Support.Entities.Tools.TaskImmediateTest.last_ctx()
      assert ctx.task_id == task[:taskId]
      assert ctx.progress_token == "tok-7"
      assert ctx.request_id == nil
      assert ctx.server == @tasks_server_module
      assert ctx.session_id == session_id
    end

    test "plain tools/call on the same tool returns the tool result and creates no task", %{
      session_id: session_id
    } do
      context =
        build_context(
          rpc_id: 3,
          rpc_method: "tools/call",
          rpc_params: %{"name" => "task_immediate", "arguments" => %{}},
          tool_module: Support.Entities.Tools.TaskImmediateTest,
          server: @tasks_server_module,
          session_id: session_id
        )

      assert {:rpc_success, response} = Handler.handle_request(context)
      assert response["result"][:content] != nil

      list_context =
        build_context(
          rpc_id: 4,
          rpc_method: "tasks/list",
          server: @tasks_server_module,
          session_id: session_id
        )

      assert {:rpc_success, list_response} = Handler.handle_request(list_context)
      assert list_response["result"][:tasks] == []
      refute Map.has_key?(list_response["result"], :nextCursor)
    end

    test "input errors create a failed task carrying the tool result and never run the tool", %{
      session_id: session_id
    } do
      import Support.Factories.Tool

      tool_mod =
        module("InputErrorTasked") do
          tool("get_date", title: "T", description: "D")
        end
        |> compile()

      context =
        build_context(
          rpc_id: 5,
          rpc_method: "tools/call",
          rpc_params: %{"name" => "get_date", "arguments" => %{"extra" => 1}},
          tool_module: tool_mod,
          task_metadata: %{ttl: 5_000},
          tool_input_errors: [
            "'location' value is not of type string",
            "property 'location' is required"
          ],
          progress_token: "tok-8",
          server: @tasks_server_module,
          session_id: session_id
        )

      assert {:rpc_success, response} = Handler.handle_request(context)
      assert response["id"] == 5

      # The client still receives a CreateTaskResult, already terminal
      #
      task = response["result"][:task]
      assert is_binary(task[:taskId])
      assert task[:status] == "failed"
      assert task[:statusMessage] == "The tool execution reported an error."
      assert task[:ttl] == 5_000

      # The tool result a plain call would have returned is stored for
      # tasks/result (SEP-1303: the model can read the messages)
      #
      assert {:ok, {:ok, result}} =
               Tasks.await(@tasks_server, Utils.owner(session_id), task[:taskId], 5_000)

      assert result[:isError] == true

      assert result[:content] == [
               %{
                 type: "text",
                 text: "'location' value is not of type string\nproperty 'location' is required"
               }
             ]

      # No runner was spawned: the tool callback never executes
      #
      assert {:ok, record} = OzMcp.Tasks.EtsStore.get(@tasks_server, task[:taskId])
      assert record.runner_pid == nil

      # The CreateTaskResult already shows the status: no notification
      #
      refute_receive {:oz_mcp_stream, _, {:event, _, %{method: "notifications/tasks/status"}}},
                     100
    end

    test "a broken outputSchema answers -32603 internal error and creates no task", %{
      session_id: session_id
    } do
      {tool_mod, tool_config} = broken_output_schema_tool()

      context =
        build_context(
          rpc_id: 6,
          rpc_method: "tools/call",
          rpc_params: %{"name" => "broken_output_tool", "arguments" => %{}},
          tool_module: tool_mod,
          tool_config: tool_config,
          task_metadata: %{ttl: 5_000},
          server: @tasks_server_module,
          session_id: session_id
        )

      assert {:rpc_error, response} = Handler.handle_request(context)
      assert response["error"] == %{"code" => -32603, "message" => "internal error"}

      assert {:ok, [], nil} = Tasks.list(@tasks_server, Utils.owner(session_id), nil, 10)
    end

    test "an incorrect structuredContent fails the task and tasks/result replays -32603", %{
      session_id: session_id
    } do
      tool_config =
        Enum.find(
          Support.Entities.Tools.TaskStructuredTest.list(),
          &(&1.name == "task_structured")
        )

      context =
        build_context(
          rpc_id: 7,
          rpc_method: "tools/call",
          rpc_params: %{
            "name" => "task_structured",
            "arguments" => %{"shape" => "wrong"},
            "task" => %{}
          },
          tool_module: Support.Entities.Tools.TaskStructuredTest,
          tool_config: tool_config,
          task_metadata: %{ttl: nil},
          server: @tasks_server_module,
          session_id: session_id
        )

      assert {:rpc_success, response} = Handler.handle_request(context)

      task = response["result"][:task]
      assert is_binary(task[:taskId])

      assert {:ok, {:error, err}} =
               Tasks.await(@tasks_server, Utils.owner(session_id), task[:taskId], 5_000)

      assert err == %{
               code: -32603,
               message: "tool output does not match outputSchema",
               data: ["'result' value is not of type string"]
             }

      assert {:ok, stored} = Tasks.get(@tasks_server, Utils.owner(session_id), task[:taskId])
      assert stored.status == :failed
      assert stored.statusMessage == "tool output does not match outputSchema"
    end

    @tag runtime_opts: %{task_store: Support.TasksStores.Failing}
    @tag :capture_log
    test "input errors answer -32603 cannot create task when the store cannot write the task",
         %{session_id: session_id} do
      import Support.Factories.Tool

      on_exit(fn -> Support.TasksStores.Failing.clear_instance(@tasks_server) end)

      tool_mod =
        module("InputErrorTaskedNoStore") do
          tool("get_date", title: "T", description: "D")
        end
        |> compile()

      context =
        build_context(
          rpc_id: 5,
          rpc_method: "tools/call",
          rpc_params: %{"name" => "get_date", "arguments" => %{"extra" => 1}},
          tool_module: tool_mod,
          task_metadata: %{ttl: 5_000},
          tool_input_errors: ["property 'location' is required"],
          server: @tasks_server_module,
          session_id: session_id
        )

      for mode <- [:error, :raise, :exit] do
        Support.TasksStores.Failing.arm(@tasks_server, :put, mode)

        # The text of the exception of the store stays out of the log.
        #
        log =
          ExUnit.CaptureLog.capture_log(fn ->
            assert {:rpc_error, response} = Handler.handle_request(context)
            assert response["error"] == %{"code" => -32603, "message" => "cannot create task"}
          end)

        refute log =~ "secret-client-payload"

        # No CreateTaskResult went out and no task exists to poll.
        #
        assert {:ok, [], nil} = Tasks.list(@tasks_server, Utils.owner(session_id), nil, 10)
      end

      # The store writes again: the same call creates the failed task.
      #
      Support.TasksStores.Failing.clear(@tasks_server, :put)

      assert {:rpc_success, response} = Handler.handle_request(context)
      assert response["result"][:task][:status] == "failed"
    end

    @tag runtime_opts: %{task_store: Support.TasksStores.Failing}
    @tag :capture_log
    test "input errors answer -32603 cannot create task when the store fails in the limit check",
         %{session_id: session_id} do
      import Support.Factories.Tool

      on_exit(fn -> Support.TasksStores.Failing.clear_instance(@tasks_server) end)

      tool_mod =
        module("InputErrorTaskedLimitCheck") do
          tool("get_date", title: "T", description: "D")
        end
        |> compile()

      context =
        build_context(
          rpc_id: 5,
          rpc_method: "tools/call",
          rpc_params: %{"name" => "get_date", "arguments" => %{"extra" => 1}},
          tool_module: tool_mod,
          task_metadata: %{ttl: 5_000},
          tool_input_errors: ["property 'location' is required"],
          server: @tasks_server_module,
          session_id: session_id
        )

      for mode <- [:error, :raise, :exit] do
        Support.TasksStores.Failing.arm(@tasks_server, :owner_usage, mode)

        # The text of the exception of the store stays out of the log.
        #
        log =
          ExUnit.CaptureLog.capture_log(fn ->
            assert {:rpc_error, response} = Handler.handle_request(context)
            assert response["error"] == %{"code" => -32603, "message" => "cannot create task"}
          end)

        refute log =~ "secret-client-payload"

        # No CreateTaskResult went out and no task exists to poll.
        #
        assert {:ok, [], nil} = Tasks.list(@tasks_server, Utils.owner(session_id), nil, 10)
      end

      # The store answers again: the same call creates the failed task.
      #
      Support.TasksStores.Failing.clear(@tasks_server, :owner_usage)

      assert {:rpc_success, response} = Handler.handle_request(context)
      assert response["result"][:task][:status] == "failed"
    end

    @tag runtime_opts: %{max_tasks_per_session: 2}
    test "refuses a task above the limit with -32000 too many tasks", %{session_id: session_id} do
      #
      # Two slow tasks keep the session at the limit while their tools run
      #
      assert {:rpc_success, first} =
               tasked_call(session_id, 1, Support.Entities.Tools.TaskSlowTest)

      assert {:rpc_success, second} =
               tasked_call(session_id, 2, Support.Entities.Tools.TaskSlowTest)

      task1 = first["result"][:task]
      task2 = second["result"][:task]

      assert {:rpc_error, refused} =
               tasked_call(session_id, 3, Support.Entities.Tools.TaskImmediateTest)

      assert refused["error"] == %{
               "code" => -32000,
               "message" => "too many tasks",
               "data" => %{"limit" => "max_tasks_per_session"}
             }

      # A task that reaches a terminal status frees its slot: a new task
      # gets its CreateTaskResult again
      #
      finish_slow_runners([task1[:taskId], task2[:taskId]])

      assert {:ok, {:ok, _}} =
               Tasks.await(@tasks_server, Utils.owner(session_id), task1[:taskId], 5_000)

      assert {:ok, {:ok, _}} =
               Tasks.await(@tasks_server, Utils.owner(session_id), task2[:taskId], 5_000)

      assert {:rpc_success, response} =
               tasked_call(session_id, 4, Support.Entities.Tools.TaskImmediateTest)

      assert is_binary(response["result"][:task][:taskId])
    end

    @tag runtime_opts: %{max_task_bytes_per_owner: 1}
    test "refuses a task above the byte budget of the owner with the limit in data", %{
      session_id: session_id
    } do
      assert {:rpc_success, first} =
               tasked_call(session_id, 1, Support.Entities.Tools.TaskImmediateTest)

      assert {:ok, {:ok, _}} =
               Tasks.await(
                 @tasks_server,
                 Utils.owner(session_id),
                 first["result"][:task][:taskId],
                 5_000
               )

      assert {:rpc_error, refused} =
               tasked_call(session_id, 2, Support.Entities.Tools.TaskImmediateTest)

      assert refused["error"] == %{
               "code" => -32000,
               "message" => "too many tasks",
               "data" => %{"limit" => "max_task_bytes_per_owner"}
             }
    end

    test "puts the immediate response of the tool in the CreateTaskResult _meta", %{
      session_id: session_id
    } do
      tool_config = immediate_response_config("Export started. It can take a few minutes.")

      context =
        build_context(
          rpc_id: 10,
          rpc_method: "tools/call",
          rpc_params: %{"name" => "task_immediate", "arguments" => %{}},
          tool_module: Support.Entities.Tools.TaskImmediateTest,
          tool_config: tool_config,
          task_metadata: %{ttl: nil},
          server: @tasks_server_module,
          session_id: session_id
        )

      assert {:rpc_success, response} = Handler.handle_request(context)

      assert response["result"][:_meta] == %{
               "io.modelcontextprotocol/model-immediate-response" =>
                 "Export started. It can take a few minutes."
             }

      task = response["result"][:task]

      assert {:ok, {:ok, _}} =
               Tasks.await(@tasks_server, Utils.owner(session_id), task[:taskId], 5_000)
    end

    test "puts the immediate response in the CreateTaskResult _meta of an input error", %{
      session_id: session_id
    } do
      tool_config = immediate_response_config("Export started. It can take a few minutes.")

      context =
        build_context(
          rpc_id: 11,
          rpc_method: "tools/call",
          rpc_params: %{"name" => "task_immediate", "arguments" => %{}},
          tool_module: Support.Entities.Tools.TaskImmediateTest,
          tool_config: tool_config,
          task_metadata: %{ttl: nil},
          tool_input_errors: ["property 'location' is required"],
          server: @tasks_server_module,
          session_id: session_id
        )

      assert {:rpc_success, response} = Handler.handle_request(context)

      assert response["result"][:_meta] == %{
               "io.modelcontextprotocol/model-immediate-response" =>
                 "Export started. It can take a few minutes."
             }

      task = response["result"][:task]

      assert {:ok, {:ok, _}} =
               Tasks.await(@tasks_server, Utils.owner(session_id), task[:taskId], 5_000)
    end

    test "a tool without the option returns no _meta in the CreateTaskResult", %{
      session_id: session_id
    } do
      tool_config = %Tool{
        name: "task_immediate",
        inputSchema: %{},
        execution: %ToolExecution{taskSupport: :optional}
      }

      context =
        build_context(
          rpc_id: 12,
          rpc_method: "tools/call",
          rpc_params: %{"name" => "task_immediate", "arguments" => %{}},
          tool_module: Support.Entities.Tools.TaskImmediateTest,
          tool_config: tool_config,
          task_metadata: %{ttl: nil},
          server: @tasks_server_module,
          session_id: session_id
        )

      assert {:rpc_success, response} = Handler.handle_request(context)
      refute Map.has_key?(response["result"], :_meta)

      task = response["result"][:task]

      assert {:ok, {:ok, _}} =
               Tasks.await(@tasks_server, Utils.owner(session_id), task[:taskId], 5_000)
    end

    @tag runtime_opts: %{task_poll_interval_ms: 750}
    test "a plain map tool config with a string execution key keeps the instance default", %{
      session_id: session_id
    } do
      {tool_mod, tool_config} = plain_execution_tool()

      context =
        build_context(
          rpc_id: 9,
          rpc_method: "tools/call",
          rpc_params: %{"name" => "plain_tasked", "arguments" => %{}},
          tool_module: tool_mod,
          tool_config: tool_config,
          task_metadata: %{ttl: nil},
          server: @tasks_server_module,
          session_id: session_id
        )

      assert {:rpc_success, response} = Handler.handle_request(context)

      task = response["result"][:task]
      assert is_binary(task[:taskId])
      assert task[:pollInterval] == 750

      assert {:ok, {:ok, _}} =
               Tasks.await(@tasks_server, Utils.owner(session_id), task[:taskId], 5_000)
    end
  end

  describe "handle_request/1 - tools/call task-augmented without tasks runtime" do
    @tag :capture_log
    test "returns -32603 cannot create task when the manager is not running" do
      context =
        build_context(
          rpc_id: 1,
          rpc_method: "tools/call",
          rpc_params: %{"name" => "task_immediate", "arguments" => %{}},
          tool_module: Support.Entities.Tools.TaskImmediateTest,
          task_metadata: %{ttl: nil},
          server: Servers.TasksTest,
          session_id: "whatever"
        )

      assert {:rpc_error, response} = Handler.handle_request(context)
      assert response["error"]["code"] == -32603
      assert response["error"]["message"] == "cannot create task"
    end
  end

  describe "handle_request/1 - tasks/get" do
    @describetag runtime_server: Servers.TasksTest

    setup do
      %{session_id: tasks_session()}
    end

    test "returns the flattened task at the result top level", %{session_id: session_id} do
      task = create_task(session_id)

      context =
        build_context(
          rpc_id: 1,
          rpc_method: "tasks/get",
          rpc_params: %{"taskId" => task.taskId},
          task_id: task.taskId,
          server: @tasks_server_module,
          session_id: session_id
        )

      assert {:rpc_success, response} = Handler.handle_request(context)
      result = response["result"]

      # Flattened (Result & Task): no "task" wrapper
      #
      refute Map.has_key?(result, :task)
      assert result[:taskId] == task.taskId
      assert result[:status] in ["working", "completed"]
      assert Map.has_key?(result, :createdAt)
      assert Map.has_key?(result, :lastUpdatedAt)
      assert Map.has_key?(result, :ttl)
    end

    test "returns -32602 Task not found for an unknown id", %{session_id: session_id} do
      context =
        build_context(
          rpc_id: 1,
          rpc_method: "tasks/get",
          rpc_params: %{"taskId" => "does-not-exist"},
          task_id: "does-not-exist",
          server: @tasks_server_module,
          session_id: session_id
        )

      assert {:rpc_error, response} = Handler.handle_request(context)
      assert response["error"]["code"] == -32602
      assert response["error"]["message"] == "Failed to retrieve task: Task not found"
    end

    test "hides other sessions' tasks (D2)", %{session_id: session_id} do
      task = create_task(session_id)
      other = Utils.create_session(@tasks_server, initialized: true)

      context =
        build_context(
          rpc_id: 1,
          rpc_method: "tasks/get",
          rpc_params: %{"taskId" => task.taskId},
          task_id: task.taskId,
          server: @tasks_server_module,
          session_id: other
        )

      assert {:rpc_error, response} = Handler.handle_request(context)
      assert response["error"]["code"] == -32602
      assert response["error"]["message"] == "Failed to retrieve task: Task not found"
    end

    test "returns -32602 Task has expired for an expired task", %{session_id: session_id} do
      task = create_task(session_id, ttl: 1)

      # The wait is part of the check: the ttl of 1 ms is over.
      #
      Process.sleep(60)

      context =
        build_context(
          rpc_id: 1,
          rpc_method: "tasks/get",
          rpc_params: %{"taskId" => task.taskId},
          task_id: task.taskId,
          server: @tasks_server_module,
          session_id: session_id
        )

      assert {:rpc_error, response} = Handler.handle_request(context)
      assert response["error"]["code"] == -32602

      assert response["error"]["message"] in [
               "Failed to retrieve task: Task has expired",
               "Failed to retrieve task: Task not found"
             ]

      assert OzMcp.Tasks.EtsStore.get(@tasks_server, task.taskId) == :not_found
    end

    test "returns -32603 internal server error when the instance does not run" do
      context =
        build_context(
          rpc_id: 1,
          rpc_method: "tasks/get",
          rpc_params: %{"taskId" => "t1"},
          task_id: "t1",
          server: Servers.TasksRequestsOnly,
          session_id: "whatever"
        )

      assert {:rpc_error, response} = Handler.handle_request(context)
      assert response["error"]["code"] == -32603
      assert response["error"]["message"] == "internal server error"
    end
  end

  describe "handle_request/1 - tasks/list" do
    @describetag runtime_server: Servers.TasksTest

    setup do
      %{session_id: tasks_session()}
    end

    test "returns an empty list when the session has no tasks", %{session_id: session_id} do
      context =
        build_context(
          rpc_id: 1,
          rpc_method: "tasks/list",
          server: @tasks_server_module,
          session_id: session_id
        )

      assert {:rpc_success, response} = Handler.handle_request(context)
      assert response["result"][:tasks] == []
      refute Map.has_key?(response["result"], :nextCursor)
    end

    @tag runtime_opts: %{task_page_size: 2}
    test "paginates with an opaque nextCursor", %{session_id: session_id} do
      t1 = create_task(session_id)
      t2 = create_task(session_id)
      t3 = create_task(session_id)

      first =
        build_context(
          rpc_id: 1,
          rpc_method: "tasks/list",
          server: @tasks_server_module,
          session_id: session_id
        )

      assert {:rpc_success, response} = Handler.handle_request(first)

      assert Enum.map(response["result"][:tasks], & &1[:taskId]) == [t1.taskId, t2.taskId]
      cursor = response["result"][:nextCursor]
      assert is_binary(cursor)

      second =
        build_context(
          rpc_id: 2,
          rpc_method: "tasks/list",
          rpc_params: %{"cursor" => cursor},
          tasks_cursor: cursor,
          server: @tasks_server_module,
          session_id: session_id
        )

      assert {:rpc_success, response} = Handler.handle_request(second)
      assert Enum.map(response["result"][:tasks], & &1[:taskId]) == [t3.taskId]
      refute Map.has_key?(response["result"], :nextCursor)
    end

    test "returns -32602 for a garbage cursor", %{session_id: session_id} do
      context =
        build_context(
          rpc_id: 1,
          rpc_method: "tasks/list",
          rpc_params: %{"cursor" => "abc"},
          tasks_cursor: "abc",
          server: @tasks_server_module,
          session_id: session_id
        )

      assert {:rpc_error, response} = Handler.handle_request(context)
      assert response["error"]["code"] == -32602
      assert response["error"]["message"] == "Failed to list tasks: invalid cursor"
    end

    test "returns -32603 internal server error when the instance does not run" do
      context =
        build_context(
          rpc_id: 1,
          rpc_method: "tasks/list",
          server: Servers.TasksRequestsOnly,
          session_id: "whatever"
        )

      assert {:rpc_error, response} = Handler.handle_request(context)
      assert response["error"]["code"] == -32603
      assert response["error"]["message"] == "internal server error"
    end
  end

  describe "handle_request/1 - tasks/cancel" do
    @describetag runtime_server: Servers.TasksTest

    setup do
      %{session_id: tasks_session()}
    end

    test "cancels a working task and returns the flattened CancelTaskResult", %{
      session_id: session_id
    } do
      {task_id, runner} = create_slow_task(session_id)

      context =
        build_context(
          rpc_id: 1,
          rpc_method: "tasks/cancel",
          rpc_params: %{"taskId" => task_id},
          task_id: task_id,
          server: @tasks_server_module,
          session_id: session_id
        )

      assert {:rpc_success, response} = Handler.handle_request(context)

      # Flattened (Result & Task): no "task" wrapper
      #
      refute Map.has_key?(response["result"], :task)
      assert response["result"][:taskId] == task_id
      assert response["result"][:status] == "cancelled"
      assert response["result"][:statusMessage] == "The task was cancelled by request."

      # The transition happened BEFORE the reply: the notification is
      # already delivered when the handler returns
      #
      {_, notification} = Utils.receive_event(5_000)
      assert notification["method"] == "notifications/tasks/status"
      assert notification["params"]["status"] == "cancelled"
      assert notification["params"]["taskId"] == task_id

      wait_until(fn -> not Process.alive?(runner) end)
    end

    test "returns -32602 when the task is already terminal", %{session_id: session_id} do
      task = create_task(session_id)

      assert {:ok, {:ok, _}} =
               Tasks.await(@tasks_server, Utils.owner(session_id), task.taskId, 5_000)

      context =
        build_context(
          rpc_id: 1,
          rpc_method: "tasks/cancel",
          rpc_params: %{"taskId" => task.taskId},
          task_id: task.taskId,
          server: @tasks_server_module,
          session_id: session_id
        )

      assert {:rpc_error, response} = Handler.handle_request(context)
      assert response["error"]["code"] == -32602

      assert response["error"]["message"] ==
               "Cannot cancel task: already in terminal status 'completed'"
    end

    test "returns -32602 Task not found for an unknown id", %{session_id: session_id} do
      context =
        build_context(
          rpc_id: 1,
          rpc_method: "tasks/cancel",
          rpc_params: %{"taskId" => "does-not-exist"},
          task_id: "does-not-exist",
          server: @tasks_server_module,
          session_id: session_id
        )

      assert {:rpc_error, response} = Handler.handle_request(context)
      assert response["error"]["code"] == -32602
      assert response["error"]["message"] == "Failed to cancel task: Task not found"
    end

    test "returns -32603 internal server error when the instance does not run" do
      context =
        build_context(
          rpc_id: 1,
          rpc_method: "tasks/cancel",
          rpc_params: %{"taskId" => "t1"},
          task_id: "t1",
          server: Servers.TasksRequestsOnly,
          session_id: "whatever"
        )

      assert {:rpc_error, response} = Handler.handle_request(context)
      assert response["error"]["code"] == -32603
      assert response["error"]["message"] == "internal server error"
    end
  end

  describe "handle_request/1 - tasks/result" do
    @describetag runtime_server: Servers.TasksTest

    setup do
      %{session_id: tasks_session()}
    end

    test "replays the stored outcome with the related-task _meta injected", %{
      session_id: session_id
    } do
      task = create_task(session_id)

      assert {:ok, {:ok, _}} =
               Tasks.await(@tasks_server, Utils.owner(session_id), task.taskId, 5_000)

      context =
        build_context(
          rpc_id: 1,
          rpc_method: "tasks/result",
          rpc_params: %{"taskId" => task.taskId},
          task_id: task.taskId,
          server: @tasks_server_module,
          session_id: session_id
        )

      assert {:rpc_success, response} = Handler.handle_request(context)
      assert response["result"][:content] != nil

      related = response["result"][:_meta]["io.modelcontextprotocol/related-task"]
      assert related["taskId"] == task.taskId
    end

    test "blocks until the task reaches a terminal status", %{session_id: session_id} do
      {task_id, _runner} = create_slow_task(session_id)

      context =
        build_context(
          rpc_id: 2,
          rpc_method: "tasks/result",
          rpc_params: %{"taskId" => task_id},
          task_id: task_id,
          server: @tasks_server_module,
          session_id: session_id
        )

      parent = self()

      spawn(fn ->
        send(parent, {:result_replied, Handler.handle_request(context)})
      end)

      # Finish only after the blocking request is waiting.
      #
      wait_until(fn ->
        case OzMcp.Instance.whereis(@tasks_server, {:task, task_id}) do
          {:ok, pid} ->
            {_state, data} = :sys.get_state(pid)
            data.waiters != [] or data.streams != []

          _ ->
            false
        end
      end)

      Support.Entities.Tools.TaskSlowTest.finish()

      assert_receive {:result_replied, {:rpc_success, response}}, 5_000
      assert response["result"][:content] != nil

      related = response["result"][:_meta]["io.modelcontextprotocol/related-task"]
      assert related["taskId"] == task_id
    end

    test "replays a stored protocol error with code/message/data", %{session_id: session_id} do
      task =
        create_task(session_id, tool: {Support.Entities.Tools.TaskErrorTest, "task_error"})

      assert {:ok, {:error, _}} =
               Tasks.await(@tasks_server, Utils.owner(session_id), task.taskId, 5_000)

      context =
        build_context(
          rpc_id: 1,
          rpc_method: "tasks/result",
          rpc_params: %{"taskId" => task.taskId},
          task_id: task.taskId,
          server: @tasks_server_module,
          session_id: session_id
        )

      assert {:rpc_error, response} = Handler.handle_request(context)
      assert response["error"]["code"] == -32000
      assert response["error"]["message"] == "boom"
    end

    test "replays the cancel outcome for a cancelled task (A4)", %{session_id: session_id} do
      {task_id, _runner} = create_slow_task(session_id)

      assert {:ok, _} = Tasks.cancel(@tasks_server, Utils.owner(session_id), task_id)

      context =
        build_context(
          rpc_id: 1,
          rpc_method: "tasks/result",
          rpc_params: %{"taskId" => task_id},
          task_id: task_id,
          server: @tasks_server_module,
          session_id: session_id
        )

      assert {:rpc_error, response} = Handler.handle_request(context)
      assert response["error"]["code"] == -32800
      assert response["error"]["message"] == "task was cancelled"
    end

    test "answers -32000 session terminated when the session is terminated while blocking", %{
      session_id: session_id
    } do
      {task_id, _runner} = create_slow_task(session_id)

      context =
        build_context(
          rpc_id: 1,
          rpc_method: "tasks/result",
          rpc_params: %{"taskId" => task_id},
          task_id: task_id,
          server: @tasks_server_module,
          session_id: session_id
        )

      parent = self()

      spawn(fn ->
        send(parent, {:result_replied, Handler.handle_request(context)})
      end)

      # The termination must come after the blocking request is waiting.
      #
      wait_until(fn ->
        case OzMcp.Instance.whereis(@tasks_server, {:task, task_id}) do
          {:ok, pid} ->
            {_state, data} = :sys.get_state(pid)
            data.waiters != [] or data.streams != []

          _ ->
            false
        end
      end)

      assert :ok = SessionProbe.terminate_tasks(@tasks_server, session_id)

      assert_receive {:result_replied, {:rpc_error, response}}, 5_000
      assert response["error"]["code"] == -32000
      assert response["error"]["message"] == "session terminated"
    end

    test "answers -32603 internal server error for an outcome of an unknown shape", %{
      session_id: session_id
    } do
      {task_id, _runner} = create_slow_task(session_id)

      context =
        build_context(
          rpc_id: 1,
          rpc_method: "tasks/result",
          rpc_params: %{"taskId" => task_id},
          task_id: task_id,
          server: @tasks_server_module,
          session_id: session_id
        )

      parent = self()

      caller =
        spawn(fn ->
          send(parent, {:result_replied, Handler.handle_request(context)})
        end)

      # The message must arrive when the wait runs: the request waits
      # when the task holds it.
      #
      wait_until(fn ->
        case OzMcp.Instance.whereis(@tasks_server, {:task, task_id}) do
          {:ok, task_pid} ->
            {_state, data} = :sys.get_state(task_pid)
            data.waiters != [] or data.streams != []

          _ ->
            false
        end
      end)

      # A message with an answer the wait cannot read stands for an
      # outcome of an unknown shape.
      #
      send(caller, {:oz_mcp_task_result, task_id, :unexpected})

      assert_receive {:result_replied, {:rpc_error, response}}, 5_000
      assert response["error"]["code"] == -32603
      assert response["error"]["message"] == "internal server error"

      # The runner of the task is still blocked: release it.
      #
      Support.Entities.Tools.TaskSlowTest.finish()

      wait_until(fn ->
        not Process.alive?(Support.Entities.Tools.TaskSlowTest.last_runner_pid())
      end)
    end

    test "returns -32602 Task not found for an unknown id", %{session_id: session_id} do
      context =
        build_context(
          rpc_id: 1,
          rpc_method: "tasks/result",
          rpc_params: %{"taskId" => "does-not-exist"},
          task_id: "does-not-exist",
          server: @tasks_server_module,
          session_id: session_id
        )

      assert {:rpc_error, response} = Handler.handle_request(context)
      assert response["error"]["code"] == -32602
      assert response["error"]["message"] == "Failed to retrieve task: Task not found"
    end

    test "returns -32602 Task has expired for an expired task", %{session_id: session_id} do
      {task_id, runner} = create_slow_task(session_id, %{ttl: 1_000})
      wait_until(fn -> not Process.alive?(runner) end)

      context =
        build_context(
          rpc_id: 1,
          rpc_method: "tasks/result",
          rpc_params: %{"taskId" => task_id},
          task_id: task_id,
          server: @tasks_server_module,
          session_id: session_id
        )

      assert {:rpc_error, response} = Handler.handle_request(context)
      assert response["error"]["code"] == -32602

      assert response["error"]["message"] in [
               "Failed to retrieve task: Task has expired",
               "Failed to retrieve task: Task not found"
             ]

      Support.Entities.Tools.TaskSlowTest.finish()
      wait_until(fn -> not Process.alive?(runner) end)
    end
  end

  describe "handle_request/1 - logging/setLevel" do
    @levels [:debug, :info, :notice, :warning, :error, :critical, :alert, :emergency]

    test "returns rpc_response with empty result and stores the level, for each level" do
      Enum.each(@levels, fn level ->
        session_id = Utils.create_session(@server)

        context =
          build_context(
            rpc_id: 1,
            rpc_method: "logging/setLevel",
            log_level: level,
            session_id: session_id,
            server: @server_module
          )

        assert {:rpc_success, response} = Handler.handle_request(context)
        assert response["jsonrpc"] == "2.0"
        assert response["id"] == 1
        assert response["result"] == %{}

        assert {:ok, %{log_level: ^level}} = Sessions.lookup(@server, session_id)
      end)
    end

    test "preserves rpc id in response" do
      session_id = Utils.create_session(@server)

      context =
        build_context(
          rpc_id: 42,
          rpc_method: "logging/setLevel",
          log_level: :warning,
          session_id: session_id,
          server: @server_module
        )

      assert {:rpc_success, response} = Handler.handle_request(context)
      assert response["id"] == 42
    end

    test "overwrites a previously set level" do
      session_id = Utils.create_session(@server)

      first =
        build_context(
          rpc_id: 1,
          rpc_method: "logging/setLevel",
          log_level: :debug,
          session_id: session_id,
          server: @server_module
        )

      second =
        build_context(
          rpc_id: 2,
          rpc_method: "logging/setLevel",
          log_level: :emergency,
          session_id: session_id,
          server: @server_module
        )

      assert {:rpc_success, _} = Handler.handle_request(first)
      assert {:rpc_success, _} = Handler.handle_request(second)

      assert {:ok, %{log_level: :emergency}} = Sessions.lookup(@server, session_id)
    end
  end

  describe "handle_request/1 - a session that ended" do
    test "notifications/initialized stays accepted when the session ended before the write" do
      session_id = Utils.create_session(@server)
      :ok = Sessions.terminate(@server, session_id)

      context =
        build_context(
          rpc_method: "notifications/initialized",
          server: @server_module,
          session_id: session_id
        )

      assert :notified = Handler.handle_request(context)
    end

    test "a duplicate notifications/initialized returns :notified and writes nothing" do
      session_id = Utils.create_session(@server, initialized: true)

      context =
        build_context(
          rpc_method: "notifications/initialized",
          server: @server_module,
          session_id: session_id,
          session_initialized: true
        )

      assert :notified = Handler.handle_request(context)
      assert SessionProbe.initialized?(@server, session_id) == true
    end

    test "logging/setLevel stays a success when the session ended before the write" do
      session_id = Utils.create_session(@server)
      :ok = Sessions.terminate(@server, session_id)

      context =
        build_context(
          rpc_id: 1,
          rpc_method: "logging/setLevel",
          log_level: :debug,
          server: @server_module,
          session_id: session_id
        )

      assert {:rpc_success, %{"result" => %{}}} = Handler.handle_request(context)
      assert {:error, :no_session} = Sessions.lookup(@server, session_id)
    end
  end

  describe "handle_request/1 - ping" do
    test "returns rpc_response with empty result" do
      context =
        build_context(
          rpc_id: 1,
          rpc_method: "ping"
        )

      assert {:rpc_success, response} = Handler.handle_request(context)
      assert response == %{"jsonrpc" => "2.0", "id" => 1, "result" => %{}}
    end

    test "preserves rpc id" do
      context =
        build_context(
          rpc_id: 99,
          rpc_method: "ping"
        )

      assert {:rpc_success, response} = Handler.handle_request(context)
      assert response["id"] == 99
    end

    test "handles string rpc id" do
      context =
        build_context(
          rpc_id: "abc-123",
          rpc_method: "ping"
        )

      assert {:rpc_success, response} = Handler.handle_request(context)
      assert response["id"] == "abc-123"
    end
  end

  describe "handle_request/1 - completion/complete" do
    test "returns completion values for a prompt reference" do
      context =
        build_context(
          rpc_id: 1,
          rpc_method: "completion/complete",
          completion_module: Support.Entities.Prompts.FirstTest,
          completion_ref: "code_review",
          completion_argument: %{"name" => "language", "value" => "el"}
        )

      assert {:rpc_success, response} = Handler.handle_request(context)
      assert response["id"] == 1

      assert response["result"] == %{
               completion: %{values: ["elixir", "python"], total: 2, hasMore: false}
             }
    end

    test "passes the completion context arguments to the callback" do
      context =
        build_context(
          rpc_id: 2,
          rpc_method: "completion/complete",
          completion_module: Support.Entities.Prompts.FirstTest,
          completion_ref: "code_review",
          completion_argument: %{"name" => "language", "value" => ""},
          completion_context: %{"focus" => "security"}
        )

      assert {:rpc_success, response} = Handler.handle_request(context)
      assert response["result"][:completion][:values] == ["elixir", "erlang"]
    end

    test "returns completion values for a resource template reference" do
      context =
        build_context(
          rpc_id: 3,
          rpc_method: "completion/complete",
          completion_module: Support.Entities.Templates.FirstTest,
          completion_ref: "file://docs/{path}",
          completion_argument: %{"name" => "path", "value" => "in"}
        )

      assert {:rpc_success, response} = Handler.handle_request(context)
      assert response["result"][:completion][:values] == ["intro.md", "index.md"]
    end

    test "returns empty values when the callback has no suggestions" do
      context =
        build_context(
          rpc_id: 4,
          rpc_method: "completion/complete",
          completion_module: Support.Entities.Prompts.FirstTest,
          completion_ref: "code_review",
          completion_argument: %{"name" => "unknown", "value" => ""}
        )

      assert {:rpc_success, response} = Handler.handle_request(context)
      assert response["result"][:completion][:values] == []
    end
  end

  describe "handle_request/1 - unknown method" do
    test "returns rpc_error with method not found" do
      context =
        build_context(
          rpc_id: 1,
          rpc_method: "unknown/method"
        )

      assert {:rpc_error, response} = Handler.handle_request(context)
      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 1
      assert response["error"]["code"] == -32601
      assert response["error"]["message"] == "method not found"
    end

    test "an unknown method is logged at debug, not above" do
      context = build_context(rpc_id: 1, rpc_method: "unknown/method")

      log =
        Utils.capture_log([level: :info], fn ->
          assert {:rpc_error, response} = Handler.handle_request(context)
          assert response["error"]["code"] == -32601
        end)

      assert log == ""

      log = Utils.capture_log([level: :debug], fn -> Handler.handle_request(context) end)
      assert log =~ "[debug] Unsupported method:"
    end

    test "an unknown notification is logged at debug, not above" do
      context = build_context(rpc_id: nil, rpc_method: "notifications/unknown")

      log =
        Utils.capture_log([level: :info], fn ->
          assert :notified = Handler.handle_request(context)
        end)

      assert log == ""

      log = Utils.capture_log([level: :debug], fn -> Handler.handle_request(context) end)
      assert log =~ "[debug] Unhandled notification:"
    end

    test "returns rpc_error for completely unknown method" do
      context =
        build_context(
          rpc_id: 5,
          rpc_method: "nonexistent"
        )

      assert {:rpc_error, response} = Handler.handle_request(context)
      assert response["error"]["code"] == -32601
    end

    test "returns rpc_error without an id member when rpc id is nil" do
      context =
        build_context(
          rpc_id: nil,
          rpc_method: "something/else"
        )

      assert {:rpc_error, response} = Handler.handle_request(context)
      refute Map.has_key?(response, "id")
    end
  end

  describe "handle_request/1 - unknown notification" do
    test "returns :notified (no JSON-RPC body) for an unknown notifications/* method" do
      context =
        build_context(
          rpc_id: nil,
          rpc_method: "notifications/roots/list_changed"
        )

      assert :notified = Handler.handle_request(context)
    end

    test "returns :notified for inbound notifications/progress from a client" do
      context =
        build_context(
          rpc_id: nil,
          rpc_method: "notifications/progress",
          rpc_params: %{"progressToken" => "tok-42", "progress" => 1}
        )

      assert :notified = Handler.handle_request(context)
    end
  end

  describe "handle_request/1 - an error response of the client with no id" do
    test "the log holds a code in range" do
      context =
        build_context(
          rpc_response: {:orphan_error, %{"code" => -32601, "message" => "Method not found"}}
        )

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :notified = Handler.handle_request(context)
        end)

      assert log =~ "client error response with no id, code -32601"
      refute log =~ "Method not found"
    end

    test "the log bounds the code: a number of 100 digits stays out" do
      digits = String.duplicate("9", 100)
      code = String.to_integer(digits)

      context =
        build_context(rpc_response: {:orphan_error, %{"code" => code, "message" => "boom"}})

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :notified = Handler.handle_request(context)
        end)

      assert log =~ "client error response with no id, code out of range"
      refute log =~ digits
      refute log =~ "boom"
    end

    test "the log bounds a code that is above the bound but short" do
      code = 2_147_483_648

      context =
        build_context(rpc_response: {:orphan_error, %{"code" => code, "message" => "boom"}})

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :notified = Handler.handle_request(context)
        end)

      assert log =~ "client error response with no id, code out of range"
      refute log =~ "2147483648"
    end
  end

  # Compiles a tool module whose call/2 returns the given structuredContent
  # and declares a matching-typed outputSchema. Returns {module, tool_config}.
  #
  defp structured_tool(structured_content) do
    import Support.Factories.Tool

    code =
      quote do
        def call(_ctx, _params) do
          result =
            %OzMcp.Structs.CallToolResult{}
            |> OzMcp.Structs.CallToolResult.content([])
            |> OzMcp.Structs.CallToolResult.structured_content(
              unquote(Macro.escape(structured_content))
            )
            |> OzMcp.Structs.CallToolResult.build()

          {:ok, result}
        end
      end

    tool_mod =
      module("StructuredTool", _code_: code) do
        tool("structured_tool", title: "T", description: "D") do
          output_schema(%{type: "object", properties: %{result: %{type: "string"}}})
        end
      end
      |> compile()

    tool_config = Enum.find(tool_mod.list(), &(&1.name == "structured_tool"))

    {tool_mod, tool_config}
  end

  # Compiles a tool module whose call/2 returns an isError result with no
  # structuredContent and declares a matching-typed outputSchema.
  # Returns {module, tool_config}.
  #
  defp error_tool do
    import Support.Factories.Tool

    code =
      quote do
        def call(_ctx, _params) do
          result =
            %OzMcp.Structs.CallToolResult{}
            |> OzMcp.Structs.CallToolResult.content([
              %OzMcp.Structs.TextContent{} |> OzMcp.Structs.TextContent.text("failed")
            ])
            |> OzMcp.Structs.CallToolResult.is_error(true)
            |> OzMcp.Structs.CallToolResult.build()

          {:ok, result}
        end
      end

    tool_mod =
      module("ErrorTool", _code_: code) do
        tool("error_tool", title: "T", description: "D") do
          output_schema(%{type: "object", properties: %{result: %{type: "string"}}})
        end
      end
      |> compile()

    tool_config = Enum.find(tool_mod.list(), &(&1.name == "error_tool"))

    {tool_mod, tool_config}
  end

  # Compiles a dsl?: false tool module whose call/2 returns a plain map
  # with a structuredContent that is not an object. Returns {module, tool_config}.
  #
  defp plain_map_tool do
    import Support.Factories.Tool

    code =
      quote do
        @schema %{type: "object", properties: %{result: %{type: "string"}}}

        def list do
          [
            %OzMcp.Structs.Tool{}
            |> OzMcp.Structs.Tool.name("plain_map_tool")
            |> OzMcp.Structs.Tool.description("Returns a plain map result")
            |> OzMcp.Structs.Tool.output_schema(@schema)
          ]
        end

        def call(_ctx, _params) do
          {:ok, %{content: [], structuredContent: [1]}}
        end
      end

    tool_mod =
      module("PlainMapTool", _dsl_: false, _code_: code)
      |> compile()

    tool_config = Enum.find(tool_mod.list(), &(&1.name == "plain_map_tool"))

    {tool_mod, tool_config}
  end

  # Compiles a dsl?: false tool module whose list/0 returns a plain map
  # with a string 'execution' key. The map is normalized like the
  # catalog does before the handler reads it. Returns {module, tool_config}.
  #
  defp plain_execution_tool do
    import Support.Factories.Tool

    code =
      quote do
        def list do
          [
            %{
              "name" => "plain_tasked",
              "description" => "A plain map with a string execution key",
              "inputSchema" => %{"type" => "object"},
              "execution" => %{"taskSupport" => "optional"}
            }
          ]
        end

        def call(_ctx, _params), do: {:ok, %{"content" => []}}
      end

    tool_mod =
      module("PlainExecutionTool", _dsl_: false, _code_: code)
      |> compile()

    raw = Enum.find(tool_mod.list(), &(&1["name"] == "plain_tasked"))
    {:ok, tool_config} = OzMcp.Catalog.Normalize.entity(:tools, raw)

    {tool_mod, tool_config}
  end

  # Compiles a dsl?: false tool module whose outputSchema does not compile
  # (a DSL tool would reject the same schema at compile time).
  # Returns {module, tool_config}.
  #
  defp broken_output_schema_tool do
    import Support.Factories.Tool

    code =
      quote do
        @invalid_schema %{"type" => "object", "properties" => %{"price" => %{"type" => "float"}}}

        def list do
          [
            %OzMcp.Structs.Tool{}
            |> OzMcp.Structs.Tool.name("broken_output_tool")
            |> OzMcp.Structs.Tool.description("Declares an invalid outputSchema")
            |> OzMcp.Structs.Tool.output_schema(@invalid_schema)
          ]
        end

        def call(_ctx, _params) do
          {:ok,
           %OzMcp.Structs.CallToolResult{}
           |> OzMcp.Structs.CallToolResult.content([
             %OzMcp.Structs.TextContent{} |> OzMcp.Structs.TextContent.text("should not run")
           ])
           |> OzMcp.Structs.CallToolResult.build()}
        end
      end

    tool_mod =
      module("BrokenOutputSchema", _dsl_: false, _code_: code)
      |> compile()

    tool_config = Enum.find(tool_mod.list(), &(&1.name == "broken_output_tool"))

    {tool_mod, tool_config}
  end

  defp immediate_response_config(text) do
    %Tool{
      name: "task_immediate",
      inputSchema: %{},
      execution: %ToolExecution{
        taskSupport: :optional,
        immediate_response: text
      }
    }
  end

  defp build_context(opts) do
    context = %Context{
      instance: Keyword.get(opts, :instance, inst(Keyword.get(opts, :server))),
      server: Keyword.get(opts, :server),
      session_id: Keyword.get(opts, :session_id),
      rpc_id: Keyword.get(opts, :rpc_id),
      rpc_method: Keyword.get(opts, :rpc_method),
      rpc_params: Keyword.get(opts, :rpc_params),
      rpc_response: Keyword.get(opts, :rpc_response),
      negotiated_protocol_version: Keyword.get(opts, :negotiated_protocol_version),
      client_info: Keyword.get(opts, :client_info),
      client_capabilities: Keyword.get(opts, :client_capabilities),
      session_initialized: Keyword.get(opts, :session_initialized),
      log_level: Keyword.get(opts, :log_level),
      completion_ref: Keyword.get(opts, :completion_ref),
      completion_argument: Keyword.get(opts, :completion_argument),
      completion_context: Keyword.get(opts, :completion_context),
      progress_token: Keyword.get(opts, :progress_token),
      task_id: Keyword.get(opts, :task_id),
      tasks_cursor: Keyword.get(opts, :tasks_cursor),
      principal: Keyword.get(opts, :principal)
    }

    Map.put(context, :bound, bound_from_opts(opts))
  end

  # The items of a static list are the bytes of the boot until the
  # transports encode the answer, so a test reads them as the wire
  # writes them: encoded, then decoded, with the keys of the wire.
  #
  defp on_wire(response), do: response |> Wire.encode_answer() |> JSON.decode!()

  # The bind stage puts the entity the request names in `bound`. The
  # fixture options name the pieces of the bound entity directly: the
  # module, the entity, the input errors, the uri params and the task
  # metadata.
  #
  defp bound_from_opts(opts) do
    params = Keyword.get(opts, :rpc_params) || %{}

    cond do
      module = Keyword.get(opts, :tool_module) ->
        %Bound{
          kind: :tool,
          name: params["name"],
          module: module,
          entity: Keyword.get(opts, :tool_config),
          params: params,
          input_errors: Keyword.get(opts, :tool_input_errors),
          task: Keyword.get(opts, :task_metadata)
        }

      module = Keyword.get(opts, :prompt_module) ->
        %Bound{kind: :prompt, name: params["name"], module: module, params: params}

      module = Keyword.get(opts, :resource_module) ->
        if Keyword.get(opts, :resource_type) == :template do
          %Bound{
            kind: :template,
            name: params["uri"],
            module: module,
            entity: Keyword.get(opts, :resource),
            params: params,
            uri_params: Keyword.get(opts, :resource_uri_params)
          }
        else
          %Bound{
            kind: :resource,
            name: params["uri"],
            module: module,
            entity: Keyword.get(opts, :resource),
            params: params
          }
        end

      module = Keyword.get(opts, :completion_module) ->
        %Bound{kind: :completion, module: module, params: params}

      true ->
        nil
    end
  end

  # Compiles a prompt module that records the params it receives in get/2
  # plus a server module registering it. Must NOT run with Support.Factories.Prompt
  # imported in the caller scope: its prompt/2 macro (default-arg prompt/1
  # clause) hijacks the Server DSL prompt/1 inside Code.compile_quoted.
  #
  defp compile_raw_params_fixtures do
    prompt_name =
      Module.concat(["HandlerTest", "RawParamsPrompt_#{System.unique_integer([:positive])}"])

    server_name =
      Module.concat(["HandlerTest", "RawParamsServer_#{System.unique_integer([:positive])}"])

    fixtures =
      quote do
        defmodule unquote(prompt_name) do
          use OzMcp.Config.Prompt

          prompt "greeting" do
            title "T"
            description "D"
          end

          def get(_ctx, params) do
            :persistent_term.put({:oz_mcp_test, :prompt_params}, params)

            {:ok,
             %OzMcp.Structs.GetPromptResult{}
             |> OzMcp.Structs.GetPromptResult.messages([])}
          end
        end

        defmodule unquote(server_name) do
          use OzMcp.Config.Server

          server_info do
            name "raw-params-server"
            version "1.0.0"
          end

          prompts do
            prompt(unquote(prompt_name))
          end
        end
      end

    Code.compile_quoted(fixtures)

    {prompt_name, server_name}
  end

  # Compiles a resource module that declares a fractional priority plus a
  # server module listing it. Must NOT run with Support.Factories.Resource imported in
  # the caller scope: its resource/2 macro hijacks the Server DSL resource/1
  # inside Code.compile_quoted.
  #
  defp compile_priority_resource_fixtures do
    resource_name =
      Module.concat(["HandlerTest", "PriorityResource_#{System.unique_integer([:positive])}"])

    server_name =
      Module.concat(["HandlerTest", "PriorityServer_#{System.unique_integer([:positive])}"])

    fixtures =
      quote do
        defmodule unquote(resource_name) do
          use OzMcp.Config.Resource

          resource "priority.md" do
            uri "file:///priority.md"
            title "P"
            description "P"

            annotations do
              priority 0.25
            end
          end

          def read(_ctx, _rpc_params), do: {:ok, %{}}
        end

        defmodule unquote(server_name) do
          use OzMcp.Config.Server

          server_info do
            name "priority-server"
            version "1.0.0"
          end

          resources do
            resource(unquote(resource_name))
          end
        end
      end

    Code.compile_quoted(fixtures)

    {server_name, resource_name}
  end

  # ------------------------------------------------------------------
  # Task helpers
  # ------------------------------------------------------------------

  defp create_task(session_id, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          session_id: session_id,
          tool: {Support.Entities.Tools.TaskImmediateTest, "task_immediate"},
          request: %{"name" => "task_immediate", "arguments" => %{}},
          ttl: nil,
          progress_token: nil
        },
        Map.new(attrs)
      )

    assert {:ok, task} = Tasks.create(@tasks_server, attrs)
    task
  end

  defp wait_until(fun, retries \\ 1_500) do
    if Utils.eventually(fun, retries * 10) do
      :ok
    else
      flunk("condition was not met in time")
    end
  end

  defp wait_for_tool_runner do
    assert Utils.eventually(fn ->
             Support.Entities.Tools.TaskSlowTest.last_runner_pid() != nil
           end)

    Support.Entities.Tools.TaskSlowTest.last_runner_pid()
  end

  # Resets the stale runner pid first: :persistent_term outlives previous
  # runs, so the wait must observe THIS run's runner.
  #
  defp create_slow_task(session_id, extra_attrs \\ %{}) do
    Support.Entities.Tools.TaskSlowTest.reset()

    task =
      create_task(
        session_id,
        Map.merge(
          %{tool: {Support.Entities.Tools.TaskSlowTest, "task_slow"}},
          Map.new(extra_attrs)
        )
      )

    runner = wait_for_tool_runner()

    {task.taskId, runner}
  end

  # A task-augmented tools/call through the handler, for the tool of the
  # task test servers.
  #
  defp tasked_call(session_id, rpc_id, tool_module) do
    name =
      if tool_module == Support.Entities.Tools.TaskImmediateTest,
        do: "task_immediate",
        else: "task_slow"

    context =
      build_context(
        rpc_id: rpc_id,
        rpc_method: "tools/call",
        rpc_params: %{"name" => name, "arguments" => %{}},
        tool_module: tool_module,
        task_metadata: %{ttl: nil},
        server: @tasks_server_module,
        session_id: session_id
      )

    Handler.handle_request(context)
  end

  # The runners of the tasks blocked in the slow tool: a :finish ends
  # each runner and its task reaches its terminal status.
  #
  defp finish_slow_runners(task_ids) do
    for task_id <- task_ids do
      assert {:ok, record} = OzMcp.Tasks.EtsStore.get(@tasks_server, task_id)
      send(record.runner_pid, :finish)
    end
  end

  defp tasks_session do
    Utils.create_session(@tasks_server, initialized: true, streams: [self()])
  end
end
