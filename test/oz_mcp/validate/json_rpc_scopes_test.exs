defmodule OzMcp.Validate.JsonRpcScopesTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias OzMcp.Context
  alias OzMcp.Pipeline.Bind
  alias OzMcp.Validate.JsonRpc
  alias Support.Servers

  # The bind stage resolves the entity and copies its required scopes
  # into the bound entity (OzMcp.Pipeline.Bind, the step after the
  # session checks). These tests pin the copy for each entity kind; the
  # refusal itself is covered by the router tests.
  #
  @server Servers.Scoped

  # The answer of a pipeline stage: the context it carries.
  #
  defp plain({:cont, context}), do: context
  defp plain({:halt, context}), do: context

  defp validate(method, params) do
    body = %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params}

    conn =
      conn(:post, "/", :json.encode(body) |> IO.iodata_to_binary())
      |> put_private(:server, @server)
      |> Map.put(:body_params, body)
      |> put_req_header("accept", "application/json, text/event-stream")

    context = Context.put_http_conn(Context.new(@server, :http_streamable, :rpc), conn)

    case JsonRpc.validate(context) do
      {:cont, context} -> plain(Bind.run(context))
      {:halt, context} -> context
    end
  end

  test "tools/call copies the scopes of the tool" do
    ctx = validate("tools/call", %{"name" => "write_file", "arguments" => %{"path" => "a"}})
    assert is_nil(ctx.error)
    assert ctx.bound.required_scopes == ["files:write"]

    ctx = validate("tools/call", %{"name" => "admin_tool", "arguments" => %{}})
    assert ctx.bound.required_scopes == ["files:write", "admin"]

    ctx = validate("tools/call", %{"name" => "read_file", "arguments" => %{"path" => "a"}})
    assert ctx.bound.required_scopes == []
  end

  test "tools/call with a wrong type of arguments answers the argument error" do
    ctx = validate("tools/call", %{"name" => "write_file", "arguments" => "not a map"})

    assert ctx.error.code == :rpc_bad_arguments
    assert is_nil(ctx.bound)
  end

  test "resources/read copies the scopes of the resource and of the template" do
    ctx = validate("resources/read", %{"uri" => "file:///secret.md"})
    assert ctx.bound.required_scopes == ["files:write"]

    ctx = validate("resources/read", %{"uri" => "file:///public.md"})
    assert ctx.bound.required_scopes == []

    ctx = validate("resources/read", %{"uri" => "file:///docs/report.md"})
    assert ctx.bound.required_scopes == ["files:write"]
  end

  test "resources/subscribe resolves the entity like resources/read, resources/unsubscribe has no scopes" do
    ctx = validate("resources/subscribe", %{"uri" => "file:///secret.md"})
    assert ctx.bound.required_scopes == ["files:write"]

    ctx = validate("resources/unsubscribe", %{"uri" => "file:///secret.md"})
    assert ctx.bound.required_scopes == []
  end

  test "prompts/get copies the scopes of the prompt" do
    ctx = validate("prompts/get", %{"name" => "audit"})
    assert is_nil(ctx.error)
    assert ctx.bound.required_scopes == ["files:write"]

    ctx = validate("prompts/get", %{"name" => "summarize"})
    assert ctx.bound.required_scopes == []
  end

  test "prompts/get with an unknown argument answers the argument error and copies no scope" do
    ctx = validate("prompts/get", %{"name" => "audit", "arguments" => %{"topic" => "x"}})

    assert ctx.error.code == :rpc_bad_arguments
    assert is_nil(ctx.bound)
  end

  test "completion/complete copies the scopes of the named entity" do
    ctx =
      validate("completion/complete", %{
        "ref" => %{"type" => "ref/prompt", "name" => "audit"},
        "argument" => %{"name" => "query", "value" => "a"}
      })

    assert is_nil(ctx.error)
    assert ctx.bound.required_scopes == ["files:write"]

    ctx =
      validate("completion/complete", %{
        "ref" => %{"type" => "ref/resource", "uri" => "file:///secret.md"},
        "argument" => %{"name" => "query", "value" => "a"}
      })

    assert is_nil(ctx.error)
    assert ctx.bound.required_scopes == ["files:write"]

    ctx =
      validate("completion/complete", %{
        "ref" => %{"type" => "ref/resource", "uri" => "file:///docs/{name}"},
        "argument" => %{"name" => "query", "value" => "a"}
      })

    assert is_nil(ctx.error)
    assert ctx.bound.required_scopes == ["files:write"]

    ctx =
      validate("completion/complete", %{
        "ref" => %{"type" => "ref/prompt", "name" => "summarize"},
        "argument" => %{"name" => "query", "value" => "a"}
      })

    assert ctx.bound.required_scopes == []
  end
end
