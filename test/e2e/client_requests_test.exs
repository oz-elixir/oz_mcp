#
# The requests of the server to the client over the wire: a callback that
# runs for a POST asks the client (elicitation, sampling, roots), the
# request travels on the event stream of that POST and the answer of the
# client is a POST that carries the JSON-RPC response for its id.
#
defmodule OzMcp.E2E.ClientRequestsTest do
  use OzMcp.E2ECase, async: true

  alias Support.Servers

  @moduletag server: Servers.Outbound

  # The capabilities the client declares: the form and the url modes of the
  # elicitation, the sampling with tools and the roots.
  #
  @capabilities %{
    "elicitation" => %{"form" => %{}, "url" => %{}},
    "sampling" => %{"tools" => %{}},
    "roots" => %{}
  }

  @answer_timeout 10_000

  test "elicitation/create in form mode travels on the stream of the POST", %{base_url: url} do
    client = url |> Client.new() |> Client.ready!(capabilities: @capabilities)
    {client, resp, sse} = call_outbound(client, "elicit_form")

    {:ok, event, sse} = Client.next_event(resp, sse)
    request = JSON.decode!(event.data)

    assert %{
             "id" => request_id,
             "method" => "elicitation/create",
             "params" => %{
               "message" => "Who are you?",
               "requestedSchema" => %{"type" => "object", "required" => ["name"]}
             }
           } = request

    assert is_binary(request_id) and request_id != ""
    assert Map.has_key?(request["params"]["requestedSchema"]["properties"], "name")
    assert Map.has_key?(request["params"]["requestedSchema"]["properties"], "age")

    {_client, {202, _headers, nil}} =
      Client.answer(client, request, %{
        "action" => "accept",
        "content" => %{"name" => "Ada", "age" => 36}
      })

    {:ok, answer_event, sse} = Client.next_event(resp, sse)

    assert %{"id" => 2, "result" => %{"content" => [%{"text" => text}]}} =
             JSON.decode!(answer_event.data)

    assert text =~ "action: :accept"
    assert text =~ "\"Ada\""
    assert text =~ "36"

    # The answer of the request is the last event of the stream.
    #
    {:ended, _sse} = Client.next_frame(resp, sse)
  end

  test "elicitation/create in url mode travels on the stream of the POST", %{base_url: url} do
    client = url |> Client.new() |> Client.ready!(capabilities: @capabilities)
    {client, resp, sse} = call_outbound(client, "elicit_url")

    {:ok, event, sse} = Client.next_event(resp, sse)
    request = JSON.decode!(event.data)

    assert %{
             "method" => "elicitation/create",
             "params" => %{
               "mode" => "url",
               "message" => "Authorize the access",
               "url" => "https://example.com/authorize",
               "elicitationId" => "elicit-1"
             }
           } = request

    {_client, {202, _headers, nil}} =
      Client.answer(client, request, %{"action" => "accept"})

    {:ok, answer_event, _sse} = Client.next_event(resp, sse)

    assert %{"id" => 2, "result" => %{"content" => [%{"text" => text}]}} =
             JSON.decode!(answer_event.data)

    assert text =~ "action: :accept"
    assert text =~ "elicit-1"

    {:ended, _sse} = Client.next_frame(resp, sse)
  end

  test "sampling/createMessage travels on the stream of the POST", %{base_url: url} do
    client = url |> Client.new() |> Client.ready!(capabilities: @capabilities)
    {_client, resp, sse} = call_outbound(client, "sample")

    {:ok, event, sse} = Client.next_event(resp, sse)
    request = JSON.decode!(event.data)

    assert %{
             "method" => "sampling/createMessage",
             "params" => %{"messages" => messages, "maxTokens" => 50}
           } = request

    assert [%{"role" => "user"}] = messages

    {_client, {202, _headers, nil}} =
      Client.answer(client, request, %{
        "role" => "assistant",
        "content" => [%{"type" => "text", "text" => "Hi"}],
        "model" => "test-model"
      })

    {:ok, answer_event, _sse} = Client.next_event(resp, sse)

    assert %{"id" => 2, "result" => %{"content" => [%{"text" => text}]}} =
             JSON.decode!(answer_event.data)

    assert text =~ "model: \"test-model\""

    {:ended, _sse} = Client.next_frame(resp, sse)
  end

  test "sampling/createMessage with tools travels on the stream of the POST", %{base_url: url} do
    client = url |> Client.new() |> Client.ready!(capabilities: @capabilities)
    {client, resp, sse} = call_outbound(client, "sample_tools")

    {:ok, event, sse} = Client.next_event(resp, sse)
    request = JSON.decode!(event.data)

    assert %{
             "method" => "sampling/createMessage",
             "params" => %{
               "tools" => [%{"name" => "weather"}],
               "toolChoice" => %{"mode" => "auto"}
             }
           } = request

    {_client, {202, _headers, nil}} =
      Client.answer(client, request, %{
        "role" => "assistant",
        "content" => [%{"type" => "text", "text" => "Sunny"}],
        "model" => "test-model",
        "stopReason" => "endTurn"
      })

    {:ok, answer_event, _sse} = Client.next_event(resp, sse)

    assert %{"id" => 2, "result" => %{"content" => [%{"text" => text}]}} =
             JSON.decode!(answer_event.data)

    assert text =~ "stop_reason: \"endTurn\""

    {:ended, _sse} = Client.next_frame(resp, sse)
  end

  test "roots/list travels on the stream of the POST", %{base_url: url} do
    client = url |> Client.new() |> Client.ready!(capabilities: @capabilities)
    {client, resp, sse} = call_outbound(client, "roots")

    {:ok, event, sse} = Client.next_event(resp, sse)
    request = JSON.decode!(event.data)
    assert %{"method" => "roots/list"} = request

    {_client, {202, _headers, nil}} =
      Client.answer(client, request, %{
        "roots" => [%{"uri" => "file:///project", "name" => "project"}]
      })

    {:ok, answer_event, _sse} = Client.next_event(resp, sse)

    assert %{"id" => 2, "result" => %{"content" => [%{"text" => text}]}} =
             JSON.decode!(answer_event.data)

    assert text =~ "file:///project"

    {:ended, _sse} = Client.next_frame(resp, sse)
  end

  defp call_outbound(client, feature) do
    Client.stream_request(client, "tools/call", %{
      "name" => "outbound",
      "arguments" => %{"feature" => feature, "timeout" => @answer_timeout}
    })
  end
end
