#
# Checks that every message of a whole session conforms to the official
# schema and checks the validator itself on hand-made messages.
#
defmodule OzMcp.E2E.ConformanceTest do
  use OzMcp.E2ECase, async: true

  alias OzMcp.E2E.Conformance

  # ---- The validator itself

  test "a result conforms when it matches the result type of the method" do
    assert :ok = Conformance.check_result("ping", %{})
    assert :ok = Conformance.check_result("tools/list", %{"tools" => []})
    assert :ok = Conformance.check_result("tools/call", %{"content" => []})

    task = %{
      "taskId" => "t",
      "status" => "working",
      "createdAt" => "2026-01-01T00:00:00Z",
      "lastUpdatedAt" => "2026-01-01T00:00:00Z",
      "ttl" => nil
    }

    assert :ok = Conformance.check_result("tools/call", %{"task" => task})
  end

  test "a result that matches one candidate of a union conforms" do
    #
    # CreateTaskResult requires the task field, but the union passes
    # because the value matches CallToolResult.
    #
    assert :ok = Conformance.check_result("tools/call", %{"content" => []})
  end

  test "a result that does not match gives one error per candidate definition" do
    errors = Conformance.check_result("ping", "a string instead of an object")
    assert [%{definition: "EmptyResult", errors: [_ | _]}] = errors

    errors = Conformance.check_result("tools/call", %{"nope" => true})

    assert [
             %{definition: "CallToolResult", errors: [_ | _]},
             %{definition: "CreateTaskResult", errors: [_ | _]}
           ] =
             errors
  end

  test "the payload of tasks/result matches the result type of the original request" do
    #
    # A CallToolResult payload with the related-task _meta passes both
    # checks: the schema type of the method and the payload type.
    #
    result = %{
      "content" => [%{"type" => "text", "text" => "22"}],
      "_meta" => %{"io.modelcontextprotocol/related-task" => %{"taskId" => "t1"}}
    }

    assert :ok = Conformance.check_result("tasks/result", result)

    # A payload that is not an object fails the schema type of the method.
    #
    errors = Conformance.check_result("tasks/result", ["not", "an", "object"])

    assert [%{definition: "GetTaskPayloadResult", errors: [_ | _]}] = errors

    # An object of the shape of the result of tasks/get passes the schema
    # type of the method and fails the check of the payload type.
    #
    task = %{
      "taskId" => "t1",
      "status" => "completed",
      "createdAt" => "2026-01-01T00:00:00Z",
      "lastUpdatedAt" => "2026-01-01T00:00:00Z",
      "ttl" => nil
    }

    errors = Conformance.check_result("tasks/result", %{"task" => task})

    assert [%{definition: "CallToolResult", errors: [_ | _]}] = errors
  end

  test "an unknown method gives no check" do
    assert :ok = Conformance.check_result("some/unknown", %{"anything" => true})
  end

  test "a notification conforms when it matches a notification of the schema" do
    message = %{
      "jsonrpc" => "2.0",
      "method" => "notifications/progress",
      "params" => %{"progressToken" => "tok", "progress" => 1, "total" => 2}
    }

    assert :ok = Conformance.check_notification(message)
  end

  test "a notification that matches no type of the union gives one error" do
    message = %{"jsonrpc" => "2.0", "method" => "notifications/unknown", "params" => %{}}

    assert [%{definition: "ServerNotification", errors: [_ | _]}] =
             Conformance.check_notification(message)
  end

  test "a server request conforms when it matches a request of the schema" do
    message = %{"jsonrpc" => "2.0", "id" => 7, "method" => "ping"}
    assert :ok = Conformance.check_server_request(message)
  end

  test "a server request that matches no type of the union gives one error" do
    message = %{"jsonrpc" => "2.0", "id" => 7, "method" => "some/unknown"}

    assert [%{definition: "ServerRequest", errors: [_ | _]}] =
             Conformance.check_server_request(message)
  end

  test "an error response conforms when the error has a code and a message" do
    message = %{
      "jsonrpc" => "2.0",
      "id" => 3,
      "error" => %{"code" => -32601, "message" => "no such method"}
    }

    assert :ok = Conformance.check_error_response(message)
  end

  test "an error response without a code does not conform" do
    message = %{"jsonrpc" => "2.0", "id" => 3, "error" => %{"message" => "no code"}}

    assert [%{definition: "JSONRPCErrorResponse", errors: [_ | _]}] =
             Conformance.check_error_response(message)
  end

  test "the assert helpers raise with the definition and the errors" do
    assert_raise ExUnit.AssertionError, ~r/EmptyResult/, fn ->
      Conformance.assert_result!("ping", "a string instead of an object")
    end

    assert_raise ExUnit.AssertionError, ~r/ServerNotification/, fn ->
      Conformance.assert_notification!(%{"jsonrpc" => "2.0", "method" => "notifications/unknown"})
    end

    assert_raise ExUnit.AssertionError, ~r/ServerRequest/, fn ->
      Conformance.assert_server_request!(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "some/unknown"
      })
    end

    assert_raise ExUnit.AssertionError, ~r/JSONRPCErrorResponse/, fn ->
      Conformance.assert_error_response!(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "error" => %{"message" => "x"}
      })
    end
  end

  test "the compiled roots are cached in the persistent terms" do
    assert Conformance.root("EmptyResult") == Conformance.root("EmptyResult")
    assert :persistent_term.get({Conformance, "EmptyResult"}, nil) != nil
  end

  # ---- The client validates each message of a whole session

  test "each answer, notification and error of a session conforms", %{base_url: url} do
    client = Client.new(url)

    {client, {200, _h, %{"result" => %{"protocolVersion" => "2025-11-25"}}}} =
      Client.initialize(client)

    {client, {202, _h, nil}} = Client.notify(client, "notifications/initialized")

    {client, {200, _h, %{"result" => %{"tools" => [_ | _]}}}} =
      Client.request(client, "tools/list")

    {client, {200, _h, %{"result" => %{"content" => [%{"type" => "text"}]}}}} =
      Client.request(client, "tools/call", %{
        "name" => "get_temperature",
        "arguments" => %{"location" => "Oslo"}
      })

    # An input schema error is a result with isError true, not an error answer.
    #
    {client, {200, _h, %{"result" => %{"isError" => true}}}} =
      Client.request(client, "tools/call", %{
        "name" => "get_temperature",
        "arguments" => %{}
      })

    {client, {200, _h, %{"result" => %{"resources" => [_ | _]}}}} =
      Client.request(client, "resources/list")

    {client, {200, _h, %{"result" => %{"resourceTemplates" => [_ | _]}}}} =
      Client.request(client, "resources/templates/list")

    {client, {200, _h, %{"result" => %{"contents" => [_ | _]}}}} =
      Client.request(client, "resources/read", %{"uri" => "file:///marketing.md"})

    {client, {200, _h, %{"result" => %{"contents" => [_ | _]}}}} =
      Client.request(client, "resources/read", %{"uri" => "file://docs/intro.md"})

    # A template read error is an error answer.
    #
    {client, {200, _h, %{"error" => %{"code" => -32000}}}} =
      Client.request(client, "resources/read", %{"uri" => "file://docs/missing.md"})

    {client, {200, _h, %{"result" => %{"prompts" => [_ | _]}}}} =
      Client.request(client, "prompts/list")

    {client, {200, _h, %{"result" => %{"messages" => [_ | _]}}}} =
      Client.request(client, "prompts/get", %{
        "name" => "code_review",
        "arguments" => %{"language" => "elixir"}
      })

    {client, {200, _h, %{"result" => %{"completion" => %{"values" => _}}}}} =
      Client.request(client, "completion/complete", %{
        "ref" => %{"type" => "ref/prompt", "name" => "code_review"},
        "argument" => %{"name" => "language", "value" => "el"}
      })

    {client, {200, _h, %{"result" => %{}}}} = Client.request(client, "ping")

    assert {_client, {200, _h, nil}} = Client.delete(client)
  end

  @tag server: OzMcp.E2E.BadShapeServer
  @tag :capture_log
  test "the -32603 answer of a result that cannot be encoded conforms", %{base_url: url} do
    client = url |> Client.new() |> Client.ready!()

    {_client, {200, _headers, body}} =
      Client.request(client, "tools/call", %{
        "name" => "task_bad_shape",
        "arguments" => %{"shape" => "bad_utf8"}
      })

    assert %{"jsonrpc" => "2.0", "error" => %{"code" => -32603}} = body
    assert :ok = Conformance.check_error_response(body)
  end

  @tag server: OzMcp.E2E.BadShapeServer
  @tag :capture_log
  test "the -32603 answer of a map result with a bad shape conforms", %{base_url: url} do
    for shape <- ["bad_content", "bad_is_error", "bad_structured"] do
      client = url |> Client.new() |> Client.ready!()

      {_client, {200, _headers, body}} =
        Client.request(client, "tools/call", %{
          "name" => "task_bad_shape",
          "arguments" => %{"shape" => shape}
        })

      assert %{"jsonrpc" => "2.0", "error" => %{"code" => -32603}} = body
      assert body["error"]["message"] == "internal error"
      assert :ok = Conformance.check_error_response(body)
    end
  end
end
