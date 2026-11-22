#
# The features of the server over the wire: the four lists with their
# pagination, the tool calls (a plain JSON answer, an event stream with
# progress, an input schema error), the resources and their templates,
# the subscriptions, the prompts, the completions and the log messages.
#
defmodule OzMcp.E2E.FeaturesTest do
  use OzMcp.E2ECase, async: true

  test "each list walks its pages", %{base_url: url} do
    client = url |> Client.new() |> Client.ready!()

    {client, tool_pages} = walk(client, "tools/list", "tools")
    assert [%{"name" => "get_temperature"}, %{"name" => "task_slow"}] = hd(tool_pages)

    names = tool_pages |> List.flatten() |> Enum.map(& &1["name"])

    assert names == [
             "get_temperature",
             "task_slow",
             "progress",
             "log",
             "gamma_1",
             "gamma_2",
             "gamma_3",
             "gamma_4",
             "gamma_5",
             "gate"
           ]

    {client, resource_pages} = walk(client, "resources/list", "resources")
    assert length(resource_pages) == 3

    uris = resource_pages |> List.flatten() |> Enum.map(& &1["uri"])

    assert uris == [
             "file:///marketing.md",
             "file:///gamma/1.md",
             "file:///gamma/2.md",
             "file:///gamma/3.md",
             "file:///gamma/4.md",
             "file:///gamma/5.md"
           ]

    {client, template_pages} = walk(client, "resources/templates/list", "resourceTemplates")
    assert length(template_pages) == 3

    template_uris =
      template_pages |> List.flatten() |> Enum.map(& &1["uriTemplate"])

    assert template_uris == [
             "file://docs/{path}",
             "file:///gamma/{g1}",
             "file:///gamma/{g2}",
             "file:///gamma/{g3}",
             "file:///gamma/{g4}",
             "file:///gamma/{g5}"
           ]

    {client, prompt_pages} = walk(client, "prompts/list", "prompts")
    assert length(prompt_pages) == 3

    prompt_names = prompt_pages |> List.flatten() |> Enum.map(& &1["name"])

    assert prompt_names == [
             "code_review",
             "gamma_1",
             "gamma_2",
             "gamma_3",
             "gamma_4",
             "gamma_5"
           ]

    # A cursor that no page gave is refused.
    #
    {_client, {200, _h, %{"error" => %{"code" => -32602, "message" => "invalid cursor"}}}} =
      Client.request(client, "tools/list", %{"cursor" => "nope"})

    # A cursor is bound to its list: the cursor of one list is refused on
    # another list.
    #
    tools_cursor = OzMcp.Utils.Paginate.encode_cursor(:tools, 2)

    {_client, {200, _h, %{"error" => %{"code" => -32602, "message" => "invalid cursor"}}}} =
      Client.request(client, "prompts/list", %{"cursor" => tools_cursor})
  end

  @tag server: OzMcp.E2E.ConformanceServer
  test "a list with no pagination refuses a cursor", %{base_url: url} do
    client = url |> Client.new() |> Client.ready!()

    for {method, key} <- [
          {"tools/list", "tools"},
          {"prompts/list", "prompts"},
          {"resources/list", "resources"},
          {"resources/templates/list", "resourceTemplates"}
        ] do
      #
      # No cursor: the full list, with no nextCursor.
      #
      {_client, {200, _h, %{"result" => result}}} = Client.request(client, method, %{})
      assert [_ | _] = result[key]
      refute Map.has_key?(result, "nextCursor")

      # A null cursor: the same.
      #
      {_client, {200, _h, %{"result" => ^result}}} =
        Client.request(client, method, %{"cursor" => nil})

      # A cursor: the server gave none, so it is invalid.
      #
      {_client, {200, _h, %{"error" => %{"code" => -32602, "message" => "invalid cursor"}}}} =
        Client.request(client, method, %{"cursor" => "zzz"})
    end
  end

  test "tools/call answers JSON when the callback sends nothing", %{base_url: url} do
    client = url |> Client.new() |> Client.ready!()

    {_client, {200, headers, %{"result" => %{"content" => [%{"type" => "text"}]}}}} =
      Client.request(client, "tools/call", %{
        "name" => "get_temperature",
        "arguments" => %{"location" => "Oslo"}
      })

    assert ["application/json;charset=UTF-8"] = for({"content-type", [v]} <- headers, do: v)
  end

  test "tools/call answers an event stream when the callback reports progress", %{base_url: url} do
    client = url |> Client.new() |> Client.ready!()

    {_client, {200, headers, events}} =
      Client.request(client, "tools/call", %{
        "name" => "progress",
        "arguments" => %{},
        "_meta" => %{"progressToken" => "p1"}
      })

    assert ["text/event-stream" <> _] = for({"content-type", [v]} <- headers, do: v)

    assert [
             %{
               "method" => "notifications/progress",
               "params" => %{
                 "progressToken" => "p1",
                 "progress" => 1,
                 "total" => 2,
                 "message" => "step 1"
               }
             },
             %{
               "method" => "notifications/progress",
               "params" => %{"progressToken" => "p1", "progress" => 2, "total" => 2}
             },
             %{"id" => _, "result" => %{"content" => [%{"text" => "progress done"}]}}
           ] = for(event <- events, event.data != "", do: JSON.decode!(event.data))
  end

  test "tools/call receives only the progress values that increase", %{base_url: url} do
    client = url |> Client.new() |> Client.ready!()

    {_client, {200, headers, events}} =
      Client.request(client, "tools/call", %{
        "name" => "progress",
        "arguments" => %{"repeat" => true},
        "_meta" => %{"progressToken" => "p1"}
      })

    assert ["text/event-stream" <> _] = for({"content-type", [v]} <- headers, do: v)

    progress =
      for event <- events,
          event.data != "",
          %{"method" => "notifications/progress"} = message <-
            [JSON.decode!(event.data)],
          do: message["params"]["progress"]

    assert progress == [1, 2]
  end

  test "arguments that violate the input schema are a tool error, not a protocol error", %{
    base_url: url
  } do
    client = url |> Client.new() |> Client.ready!()

    {_client, {200, _h, %{"result" => %{"isError" => true, "content" => [_ | _]}}}} =
      Client.request(client, "tools/call", %{
        "name" => "get_temperature",
        "arguments" => %{}
      })
  end

  test "resources/read reads a resource and a template", %{base_url: url} do
    client = url |> Client.new() |> Client.ready!()

    {_client, {200, _h, %{"result" => %{"contents" => contents}}}} =
      Client.request(client, "resources/read", %{"uri" => "file:///marketing.md"})

    assert [%{"uri" => "file:///marketing.md", "text" => "# Marketing rules"}] = contents

    {_client, {200, _h, %{"result" => %{"contents" => contents}}}} =
      Client.request(client, "resources/read", %{"uri" => "file://docs/intro.md"})

    assert [%{"uri" => "file://docs/intro.md", "text" => "# Doc path: intro.md"}] = contents
  end

  test "resources/subscribe and resources/unsubscribe accept the uri of a resource", %{
    base_url: url
  } do
    client = url |> Client.new() |> Client.ready!()

    {client, {200, _h, %{"result" => %{}}}} =
      Client.request(client, "resources/subscribe", %{"uri" => "file:///marketing.md"})

    {_client, {200, _h, %{"result" => %{}}}} =
      Client.request(client, "resources/unsubscribe", %{"uri" => "file:///marketing.md"})
  end

  test "prompts/get returns the messages of the prompt", %{base_url: url} do
    client = url |> Client.new() |> Client.ready!()

    {_client, {200, _h, %{"result" => %{"messages" => messages}}}} =
      Client.request(client, "prompts/get", %{
        "name" => "code_review",
        "arguments" => %{"language" => "elixir"}
      })

    assert [
             %{"role" => "user", "content" => %{"type" => "text", "text" => "Review this code."}}
           ] = messages
  end

  test "completion/complete completes the argument of a prompt", %{base_url: url} do
    client = url |> Client.new() |> Client.ready!()

    {_client, {200, _h, %{"result" => %{"completion" => completion}}}} =
      Client.request(client, "completion/complete", %{
        "ref" => %{"type" => "ref/prompt", "name" => "code_review"},
        "argument" => %{"name" => "language", "value" => "el"}
      })

    assert %{"values" => ["elixir", "python"], "total" => 2, "hasMore" => false} = completion

    {_client, {200, _h, %{"error" => %{"code" => -32602}}}} =
      Client.request(client, "completion/complete", %{
        "ref" => %{"type" => "ref/prompt", "name" => "code_review"},
        "argument" => %{"name" => "language", "value" => "el"},
        "context" => %{"arguments" => %{"focus" => 1}}
      })
  end

  test "the log messages obey the level of the session", %{base_url: url} do
    client = url |> Client.new() |> Client.ready!()

    # Before logging/setLevel no message is sent: the answer stays JSON.
    #
    {client, {200, headers, %{"result" => %{"content" => [%{"text" => "log done"}]}}}} =
      Client.request(client, "tools/call", %{"name" => "log"})

    assert ["application/json;charset=UTF-8"] = for({"content-type", [v]} <- headers, do: v)

    {client, {200, _h, %{"result" => %{}}}} =
      Client.request(client, "logging/setLevel", %{"level" => "warning"})

    # The message below the level of the session is filtered, the warning goes out.
    #
    {_client, {200, headers, events}} = Client.request(client, "tools/call", %{"name" => "log"})

    assert ["text/event-stream" <> _] = for({"content-type", [v]} <- headers, do: v)

    assert [
             %{
               "method" => "notifications/message",
               "params" => %{
                 "level" => "warning",
                 "data" => %{"disk" => "92%"},
                 "logger" => "tool"
               }
             },
             %{"id" => _, "result" => %{"content" => [%{"text" => "log done"}]}}
           ] = for(event <- events, event.data != "", do: JSON.decode!(event.data))
  end

  test "a flood of log messages is rate limited and the response is the last event", %{
    base_url: url
  } do
    client = url |> Client.new() |> Client.ready!()

    {client, {200, _h, %{"result" => %{}}}} =
      Client.request(client, "logging/setLevel", %{"level" => "info"})

    # The tool sends 500 logs: the session of the stream accepts only the
    # messages under `max_log_rate` (the default, 100 for each second).
    #
    {_client, {200, _headers, events}} =
      Client.request(client, "tools/call", %{
        "name" => "log",
        "arguments" => %{"count" => 500}
      })

    messages = for(event <- events, event.data != "", do: JSON.decode!(event.data))
    logs = Enum.count(messages, &(&1["method"] == "notifications/message"))

    assert logs > 0
    assert logs < 500

    # The response of the request is the last event of the stream.
    #
    assert [%{"id" => _, "result" => %{"content" => [%{"text" => "log done"}]}}] =
             Enum.take(messages, -1)
  end

  # The pages of one list, in order, until the cursor ends.
  #
  defp walk(client, method, key, params \\ %{}, pages \\ [])

  defp walk(client, method, key, params, pages) do
    {client, {200, _h, %{"result" => result}}} = Client.request(client, method, params)

    case result["nextCursor"] do
      nil -> {client, Enum.reverse([result[key] | pages])}
      cursor -> walk(client, method, key, %{"cursor" => cursor}, [result[key] | pages])
    end
  end
end
