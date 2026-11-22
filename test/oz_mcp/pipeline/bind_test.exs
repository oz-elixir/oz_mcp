defmodule OzMcp.Pipeline.BindTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias OzMcp.Context
  alias OzMcp.Pipeline.Bind
  alias OzMcp.Pipeline.Bound
  alias OzMcp.Validate.JsonRpc
  alias Support.Helpers.Utils
  alias Support.Servers

  @tools_module Servers.ToolsOnly
  @schema_module Servers.ToolsAllArguments
  @templates_module Servers.WithTemplates
  @prompts_module Servers.PromptsOnly
  @completion_module Servers.Completions
  @tasks_module Servers.TasksTest

  setup do
    for module <- [
          @tools_module,
          @schema_module,
          @templates_module,
          @prompts_module,
          @completion_module,
          @tasks_module
        ] do
      Utils.start_instance(module, name: inst(module))
    end

    :ok
  end

  defp inst(module), do: Module.concat(module, __MODULE__)

  # The stage runs after the JSON-RPC stage, as the pipelines do: the
  # shape of the params is already checked when the bind runs.
  #
  defp run_bind(server_module, body) do
    context = context(server_module, body)

    case JsonRpc.validate(context) do
      {:cont, context} -> Bind.run(context)
      {:halt, context} -> {:halt, context}
    end
  end

  defp context(server_module, body) do
    body = Map.put(body, "jsonrpc", "2.0")

    conn =
      conn(:post, "/", :json.encode(body) |> IO.iodata_to_binary())
      |> Map.put(:body_params, body)
      |> put_req_header("accept", "application/json, text/event-stream")

    Context.put_http_conn(Context.new(inst(server_module), :http_streamable, :rpc), conn)
  end

  describe "tools/call" do
    test "binds the tool of the request" do
      {:cont, ctx} =
        run_bind(@tools_module, %{
          "id" => 1,
          "method" => "tools/call",
          "params" => %{"name" => "get_date", "arguments" => %{}}
        })

      assert %Bound{} = ctx.bound
      assert ctx.bound.kind == :tool
      assert ctx.bound.name == "get_date"
      assert ctx.bound.module == Support.Entities.Tools.SecondTest
      assert %OzMcp.Structs.Tool{} = ctx.bound.entity
      assert ctx.bound.params == %{"name" => "get_date", "arguments" => %{}}
      assert ctx.bound.arguments == %{}
      assert ctx.bound.input_errors == nil
      assert ctx.bound.required_scopes == []
      assert ctx.bound.task == nil
      assert is_nil(ctx.error)
    end

    test "the defaults of the input schema are applied to the arguments" do
      {:cont, ctx} =
        run_bind(@schema_module, %{
          "id" => 1,
          "method" => "tools/call",
          "params" => %{
            "name" => "input_schema_tool",
            "arguments" => %{"string_1" => "a", "integer_1" => 1}
          }
        })

      assert ctx.bound.arguments["string_2"] == "default_2"
      assert ctx.bound.params["arguments"]["string_2"] == "default_2"
      assert is_nil(ctx.bound.input_errors)
    end

    test "a schema violation travels in the bound entity, not as an error" do
      {:cont, ctx} =
        run_bind(@schema_module, %{
          "id" => 1,
          "method" => "tools/call",
          "params" => %{"name" => "input_schema_tool", "arguments" => %{"integer_1" => 1}}
        })

      assert is_nil(ctx.error)
      assert is_list(ctx.bound.input_errors)
      assert "property 'string_1' is required" in ctx.bound.input_errors
    end

    test "an unknown tool halts with the tool error" do
      {:halt, ctx} =
        run_bind(@tools_module, %{
          "id" => 1,
          "method" => "tools/call",
          "params" => %{"name" => "no_such_tool", "arguments" => %{}}
        })

      assert ctx.error.code == :rpc_tool_not_found
      assert ctx.error.data == %{"name" => "no_such_tool"}
      assert is_nil(ctx.bound)
    end

    test "a task-augmented call binds the task metadata and strips the marker" do
      {:cont, ctx} =
        run_bind(@tasks_module, %{
          "id" => 1,
          "method" => "tools/call",
          "params" => %{
            "name" => "task_immediate",
            "arguments" => %{},
            "task" => %{"ttl" => 5_000}
          }
        })

      assert ctx.bound.kind == :tool
      assert ctx.bound.name == "task_immediate"
      assert ctx.bound.module == Support.Entities.Tools.TaskImmediateTest
      assert ctx.bound.task == %{ttl: 5_000}
      refute Map.has_key?(ctx.bound.params, "task")
      assert is_nil(ctx.error)
    end

    test "the task marker of a server without the tasks capability is stripped" do
      {:cont, ctx} =
        run_bind(@tools_module, %{
          "id" => 1,
          "method" => "tools/call",
          "params" => %{"name" => "get_date", "arguments" => %{}, "task" => %{}}
        })

      assert ctx.bound.task == nil
      refute Map.has_key?(ctx.bound.params, "task")
      assert is_nil(ctx.error)
    end
  end

  describe "resources/read and resources/subscribe" do
    test "a resource binds its kind, its module and its entity" do
      for method <- ["resources/read", "resources/subscribe"] do
        {:cont, ctx} =
          run_bind(@templates_module, %{
            "id" => 1,
            "method" => method,
            "params" => %{"uri" => "file:///definitions.md"}
          })

        assert ctx.bound.kind == :resource
        assert ctx.bound.name == "file:///definitions.md"
        assert ctx.bound.module == Support.Entities.Resources.WithTemplateTest
        assert %OzMcp.Structs.Resource{} = ctx.bound.entity
        assert ctx.bound.uri_params == nil
        assert is_nil(ctx.error)
      end
    end

    test "resources/unsubscribe binds no entity, for a known and an unknown uri" do
      for uri <- ["file:///definitions.md", "file:///gone.md"] do
        {:cont, ctx} =
          run_bind(@templates_module, %{
            "id" => 1,
            "method" => "resources/unsubscribe",
            "params" => %{"uri" => uri}
          })

        assert ctx.bound.kind == :none
        assert ctx.bound.params == %{"uri" => uri}
        assert is_nil(ctx.error)
      end
    end

    test "a template binds its uri params" do
      {:cont, ctx} =
        run_bind(@templates_module, %{
          "id" => 1,
          "method" => "resources/read",
          "params" => %{"uri" => "file://docs/intro.md"}
        })

      assert ctx.bound.kind == :template
      assert ctx.bound.name == "file://docs/intro.md"
      assert ctx.bound.module == Support.Entities.Templates.FirstTest
      assert %OzMcp.Structs.ResourceTemplate{} = ctx.bound.entity
      assert ctx.bound.uri_params == %{"path" => "intro.md"}
      assert is_nil(ctx.error)
    end

    test "an unknown uri halts with the resource error" do
      {:halt, ctx} =
        run_bind(@templates_module, %{
          "id" => 1,
          "method" => "resources/read",
          "params" => %{"uri" => "file:///gone.md"}
        })

      assert ctx.error.code == :rpc_resource_not_found
      assert ctx.error.data == %{"uri" => "file:///gone.md"}
      assert is_nil(ctx.bound)
    end
  end

  describe "prompts/get" do
    test "binds the prompt of the request" do
      {:cont, ctx} =
        run_bind(@prompts_module, %{
          "id" => 1,
          "method" => "prompts/get",
          "params" => %{"name" => "code_review", "arguments" => %{"language" => "elixir"}}
        })

      assert ctx.bound.kind == :prompt
      assert ctx.bound.name == "code_review"
      assert ctx.bound.module == Support.Entities.Prompts.FirstTest
      assert %OzMcp.Structs.Prompt{} = ctx.bound.entity
      assert ctx.bound.arguments == %{"language" => "elixir"}
      assert ctx.bound.required_scopes == []
      assert is_nil(ctx.error)
    end

    test "an unknown prompt halts with the prompt error" do
      {:halt, ctx} =
        run_bind(@prompts_module, %{
          "id" => 1,
          "method" => "prompts/get",
          "params" => %{"name" => "gone"}
        })

      assert ctx.error.code == :rpc_prompt_not_found
      assert is_nil(ctx.bound)
    end
  end

  describe "completion/complete" do
    test "binds the module of the completion and its reference" do
      {:cont, ctx} =
        run_bind(@completion_module, %{
          "id" => 1,
          "method" => "completion/complete",
          "params" => %{
            "ref" => %{"type" => "ref/prompt", "name" => "code_review"},
            "argument" => %{"name" => "language", "value" => "e"}
          }
        })

      assert ctx.bound.kind == :completion
      assert ctx.bound.module == Support.Entities.Prompts.FirstTest
      assert ctx.bound.completion.ref == {:prompt, "code_review"}
      assert ctx.bound.completion.argument == %{"name" => "language", "value" => "e"}
      assert is_nil(ctx.error)
    end
  end

  describe "the task methods" do
    test "tasks/get binds the task id" do
      {:cont, ctx} =
        run_bind(@tasks_module, %{
          "id" => 1,
          "method" => "tasks/get",
          "params" => %{"taskId" => "t-1"}
        })

      assert ctx.bound.kind == :task
      assert ctx.bound.name == "t-1"
      assert ctx.bound.params == %{"taskId" => "t-1"}
      assert is_nil(ctx.error)
    end

    test "tasks/get takes no scopes from an expired record and removes nothing" do
      now = DateTime.utc_now()

      record = %OzMcp.Tasks.EtsStore{
        task_id: "expired-task",
        session_id: "s",
        owner_key: {:session, nil},
        seq: System.unique_integer([:positive]),
        status: :completed,
        created_at: DateTime.add(now, -10, :second),
        last_updated_at: now,
        ttl: 1,
        required_scopes: ["files:write"]
      }

      :ok = OzMcp.Tasks.Records.put(OzMcp.Tasks.EtsStore, inst(@tasks_module), record)

      {:cont, ctx} =
        run_bind(@tasks_module, %{
          "id" => 1,
          "method" => "tasks/get",
          "params" => %{"taskId" => "expired-task"}
        })

      assert ctx.bound.required_scopes == []

      assert {:ok, _record} =
               OzMcp.Tasks.EtsStore.get(inst(@tasks_module), "expired-task")
    end

    test "tasks/list binds no task id" do
      {:cont, ctx} =
        run_bind(@tasks_module, %{"id" => 1, "method" => "tasks/list", "params" => %{}})

      assert ctx.bound.kind == :task
      assert ctx.bound.name == nil
      assert is_nil(ctx.error)
    end

    # The list method ignores a `taskId` param: it binds the value in
    # the field `name`, but no task exists, so no scope lookup runs.
    #
    test "tasks/list keeps a taskId param without a scope lookup" do
      {:cont, ctx} =
        run_bind(@tasks_module, %{
          "id" => 1,
          "method" => "tasks/list",
          "params" => %{"taskId" => "no-such-task"}
        })

      assert ctx.bound.kind == :task
      assert ctx.bound.name == "no-such-task"
      assert ctx.bound.params == %{"taskId" => "no-such-task"}
      assert ctx.bound.required_scopes == []
      assert is_nil(ctx.error)
    end
  end

  describe "the methods without an entity" do
    test "ping binds kind :none with the params" do
      {:cont, ctx} =
        run_bind(@tools_module, %{"id" => 1, "method" => "ping", "params" => %{"key" => "val"}})

      assert ctx.bound == %Bound{kind: :none, params: %{"key" => "val"}}
    end

    test "initialize binds kind :none with the params" do
      params = %{
        "protocolVersion" => "2025-11-25",
        "clientInfo" => %{"name" => "bind-client", "version" => "1.0.0"}
      }

      {:cont, ctx} =
        run_bind(@tools_module, %{"id" => 1, "method" => "initialize", "params" => params})

      assert ctx.bound == %Bound{kind: :none, params: params}
    end

    test "a notification binds kind :none" do
      {:cont, ctx} =
        run_bind(@tools_module, %{"method" => "notifications/initialized"})

      assert ctx.bound == %Bound{kind: :none, params: %{}}
    end

    test "a message without params binds empty params" do
      {:cont, ctx} = run_bind(@tools_module, %{"id" => 1, "method" => "ping"})

      assert ctx.bound == %Bound{kind: :none, params: %{}}
    end
  end
end
