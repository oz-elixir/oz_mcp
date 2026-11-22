defmodule OzMcp.TestingTest do
  use ExUnit.Case, async: true

  alias OzMcp.Testing
  alias Support.Helpers.Utils

  @scoped_url "https://mcp.example.com/mcp"

  test "starts a server and its client" do
    assert {:ok, client} = Testing.start(Support.Servers.Outbound)

    instance = Testing.instance(client)
    assert {:ok, config} = OzMcp.Instance.config(instance)
    assert config.name == instance
  end

  test "gives the initialize result" do
    assert {:ok, client} = Testing.start(Support.Servers.Outbound)

    assert %{
             "serverInfo" => %{"name" => "ts-outbound-test", "version" => "1.0.0"},
             "protocolVersion" => protocol_version,
             "capabilities" => %{"tasks" => _tasks}
           } = result = Testing.initialize_result(client)

    assert protocol_version == OzMcp.Protocol.latest()
    assert result == Testing.initialize_result(client)
  end

  test "keeps the initialize result after a call" do
    assert {:ok, client} = Testing.start(Support.Servers.Outbound)
    result = Testing.initialize_result(client)

    assert {:ok, %{"content" => _content}} = Testing.call_tool(client, "progress", %{})

    assert Testing.initialize_result(client) == result
  end

  test "calls a tool and gives its JSON answer" do
    assert {:ok, client} = Testing.start(Support.Servers.ToolsMultiple)

    assert {:ok, %{"content" => [%{"text" => "22/11/2025"}]}} =
             Testing.call_tool(client, "get_date")
  end

  test "gives the error of an unknown tool" do
    assert {:ok, client} = Testing.start(Support.Servers.Outbound)

    assert {:error, %{"code" => -32602}} = Testing.call_tool(client, "nope", %{})
  end

  test "gives an isError result for an input error" do
    assert {:ok, client} = Testing.start(Support.Servers.ToolsMultiple)

    assert {:ok, %{"isError" => true, "content" => [%{"text" => text}]}} =
             Testing.call_tool(client, "get_temperature", %{})

    assert text =~ "location"
  end

  test "the progress notifications reach the test before the answer" do
    assert {:ok, client} = Testing.start(Support.Servers.Outbound)

    assert {:ok, %{"content" => _content}} =
             Testing.call_tool(client, "progress", %{}, meta: %{"progressToken" => 1})

    assert_received {:oz_mcp_notification, "notifications/progress", %{"progress" => 1}}
    assert_received {:oz_mcp_notification, "notifications/progress", %{"progress" => 2}}
  end

  test "the log notifications reach the test" do
    assert {:ok, client} =
             Testing.start(Support.Servers.AuthorizedOutbound,
               token: "alice-token",
               resource_url: @scoped_url
             )

    assert {:ok, _result} = Testing.request(client, "logging/setLevel", %{"level" => "debug"})
    assert {:ok, %{"content" => _content}} = Testing.call_tool(client, "log", %{})

    assert_received {:oz_mcp_notification, "notifications/message", %{"level" => "debug"}}
    assert_received {:oz_mcp_notification, "notifications/message", %{"level" => "warning"}}
  end

  test "lists the tools of the server" do
    assert {:ok, client} = Testing.start(Support.Servers.Outbound)

    assert {:ok, %{"tools" => tools}} = Testing.list(client, :tools)
    assert Enum.map(tools, & &1["name"]) |> Enum.sort() == ["log", "outbound", "progress"]
  end

  test "gets a prompt" do
    assert {:ok, client} = Testing.start(Support.Servers.Completions)

    assert {:ok, %{"description" => "Code review prompt"}} =
             Testing.get_prompt(client, "code_review", %{"language" => "elixir"})
  end

  test "completes a prompt argument" do
    assert {:ok, client} = Testing.start(Support.Servers.Completions)

    ref = %{"type" => "ref/prompt", "name" => "code_review"}
    argument = %{"name" => "language", "value" => "e"}

    assert {:ok, %{"completion" => %{"values" => ["elixir", "python"]}}} =
             Testing.complete(client, ref, argument)
  end

  test "reads a resource" do
    assert {:ok, client} = Testing.start(Support.Servers.ResourcesMinimal)

    assert {:ok, %{"contents" => [%{"text" => "# Marketing rules"}]}} =
             Testing.read_resource(client, "file:///marketing.md")
  end

  test "gives resource not found for an unknown uri" do
    assert {:ok, client} = Testing.start(Support.Servers.ResourcesMinimal)

    assert {:error, %{"code" => -32002}} =
             Testing.read_resource(client, "file:///unknown.md")
  end

  test "a missing scope is the error of the answer" do
    assert {:ok, client} =
             Testing.start(Support.Servers.Scoped,
               token: "alice-token",
               resource_url: @scoped_url
             )

    assert {:error, %{"code" => -32011}} =
             Testing.call_tool(client, "write_file", %{"path" => "a"})
  end

  test "a token with the scope reaches the callback" do
    assert {:ok, client} =
             Testing.start(Support.Servers.Scoped,
               token: "alice-admin",
               resource_url: @scoped_url
             )

    assert {:ok, %{"content" => [%{"text" => "write_file ran"}]}} =
             Testing.call_tool(client, "write_file", %{"path" => "a"})
  end

  test "an unknown token is the error of the refused initialize" do
    assert {:error, %{"code" => -32010}} =
             Testing.start(Support.Servers.Scoped,
               token: "nope",
               resource_url: @scoped_url
             )
  end

  test "refuses sse_max_stream_ms" do
    assert_raise ArgumentError, ~r/sse_max_stream_ms/, fn ->
      Testing.start(Support.Servers.Outbound, sse_max_stream_ms: 100)
    end
  end

  test "sets the default resource_url of a protected server" do
    token = Support.Auth.Default.register_token(audiences: "http://localhost/mcp")

    assert {:ok, client} = Testing.start(Support.Servers.Scoped, token: token)

    assert {:ok, %{"content" => _content}} =
             Testing.call_tool(client, "read_file", %{"path" => "a"})
  end

  test "two calls at the same time get their own answer" do
    assert {:ok, client} = Testing.start(Support.Servers.ToolsMultiple)

    date = Task.async(fn -> Testing.call_tool(client, "get_date") end)
    time = Task.async(fn -> Testing.call_tool(client, "get_time") end)

    assert {:ok, %{"content" => [%{"text" => "22/11/2025"}]}} = Task.await(date)
    assert {:ok, %{"content" => [%{"text" => "14:45:20"}]}} = Task.await(time)
  end

  test "answers an elicitation with the handle" do
    handle = fn "elicitation/create", _params ->
      {:ok, %{"action" => "accept", "content" => %{"name" => "Ada"}}}
    end

    assert {:ok, client} =
             Testing.start(Support.Servers.Outbound,
               capabilities: %{"elicitation" => %{"form" => %{}}},
               handle: handle
             )

    text = outbound_text(client, "elicitation/create")
    assert text =~ ~s("action" => "accept")
    assert text =~ ~s("name" => "Ada")
  end

  test "answers sampling with the handle" do
    handle = fn "sampling/createMessage", _params ->
      {:ok,
       %{
         "role" => "assistant",
         "content" => %{"type" => "text", "text" => "Sunny"},
         "model" => "test-model"
       }}
    end

    assert {:ok, client} =
             Testing.start(Support.Servers.Outbound,
               capabilities: %{"sampling" => %{}},
               handle: handle
             )

    text = outbound_text(client, "sampling/createMessage")
    assert text =~ ~s("text" => "Sunny")
  end

  test "answers roots with the handle" do
    handle = fn "roots/list", _params ->
      {:ok, %{"roots" => [%{"uri" => "file:///first.md", "name" => "first"}]}}
    end

    assert {:ok, client} =
             Testing.start(Support.Servers.Outbound,
               capabilities: %{"roots" => %{}},
               handle: handle
             )

    assert outbound_text(client, "roots/list") =~ "file:///first.md"
  end

  test "gives capability_not_supported with no capability and does not call the handle" do
    test_pid = self()

    handle = fn method, _params ->
      send(test_pid, {:handle_called, method})
      {:ok, %{}}
    end

    assert {:ok, client} = Testing.start(Support.Servers.Outbound, handle: handle)

    assert outbound_text(client, "sampling/createMessage") =~ "capability_not_supported"
    refute_received {:handle_called, _method}
  end

  test "gives method not found for a method the handle has no clause for" do
    handle = fn "roots/list", _params -> {:ok, %{}} end

    assert {:ok, client} =
             Testing.start(Support.Servers.Outbound,
               capabilities: %{"sampling" => %{}},
               handle: handle
             )

    assert outbound_text(client, "sampling/createMessage") =~ "-32601"
  end

  test "gives an internal error when the handle raises and keeps the client alive" do
    handle = fn "sampling/createMessage", _params -> raise "boom" end

    assert {:ok, client} =
             Testing.start(Support.Servers.Outbound,
               capabilities: %{"sampling" => %{}},
               handle: handle
             )

    assert outbound_text(client, "sampling/createMessage") =~ "-32603"

    assert {:ok, %{"content" => _content}} =
             Testing.call_tool(client, "outbound", %{"feature" => "text"})
  end

  test "gives an internal error for a clause error inside the handle" do
    handle = fn "sampling/createMessage", _params -> missing(String.to_atom("nope")) end

    assert {:ok, client} =
             Testing.start(Support.Servers.Outbound,
               capabilities: %{"sampling" => %{}},
               handle: handle
             )

    assert outbound_text(client, "sampling/createMessage") =~ "-32603"
  end

  test "posts the error of the handle" do
    handle = fn "sampling/createMessage", _params ->
      {:error, %{"code" => -1, "message" => "no"}}
    end

    assert {:ok, client} =
             Testing.start(Support.Servers.Outbound,
               capabilities: %{"sampling" => %{}},
               handle: handle
             )

    text = outbound_text(client, "sampling/createMessage")
    assert text =~ ~s("code" => -1)
    assert text =~ ~s("message" => "no")
  end

  test "answers ping without the handle" do
    assert {:ok, client} = Testing.start(Support.Servers.Outbound)

    assert outbound_text(client, "ping") == "{:ok, %{}}"
  end

  test "a call that times out gives -32603 and the client goes on" do
    test_pid = self()

    handle = fn "sampling/createMessage", _params ->
      send(test_pid, {:handle_waits, self()})

      receive do
        :go -> {:error, %{"code" => -1, "message" => "late"}}
      end
    end

    assert {:ok, client} =
             Testing.start(Support.Servers.Outbound,
               capabilities: %{"sampling" => %{}},
               handle: handle
             )

    call =
      Task.async(fn ->
        Testing.call_tool(client, "outbound", %{"method" => "sampling/createMessage"},
          timeout: 500
        )
      end)

    # The handle must block before the timeout of the call: under load,
    # a short timeout can elapse before the server sends the request.
    #
    assert_receive {:handle_waits, pid}
    assert {:error, %{"code" => -32603}} = Task.await(call)
    send(pid, :go)

    assert outbound_text(client, "ping") == "{:ok, %{}}"
  end

  test "gives an internal error when the handle throws or exits" do
    handle = fn
      "sampling/createMessage", _params -> throw(:boom)
      "roots/list", _params -> exit(:boom)
    end

    assert {:ok, client} =
             Testing.start(Support.Servers.Outbound,
               capabilities: %{"sampling" => %{}, "roots" => %{}},
               handle: handle
             )

    assert outbound_text(client, "sampling/createMessage") =~ "-32603"
    assert outbound_text(client, "roots/list") =~ "-32603"
    assert Process.alive?(client)
  end

  test "stop/1 ends the calls that still run" do
    test_pid = self()

    handle = fn "sampling/createMessage", _params ->
      send(test_pid, {:handle_waits, self()})
      receive do: (:go -> {:ok, %{}})
    end

    assert {:ok, client} =
             Testing.start(Support.Servers.Outbound,
               capabilities: %{"sampling" => %{}},
               handle: handle
             )

    call =
      Task.async(fn ->
        Testing.call_tool(client, "outbound", %{"method" => "sampling/createMessage"})
      end)

    assert_receive {:handle_waits, handle_pid}
    assert :ok = Testing.stop(client)

    assert {:error, %{"code" => -32603}} = Task.await(call)
    assert Utils.eventually(fn -> not Process.alive?(handle_pid) end)
  end

  test "the counter skips an id in use and a pending id is refused" do
    test_pid = self()

    handle = fn "sampling/createMessage", _params ->
      send(test_pid, {:handle_waits, self()})
      receive do: (:go -> {:error, %{"code" => -1, "message" => "late"}})
    end

    assert {:ok, client} =
             Testing.start(Support.Servers.Outbound,
               capabilities: %{"sampling" => %{}},
               handle: handle
             )

    # The initialize took the id 1, so the next id of the counter is 2.
    #
    blocked =
      Task.async(fn ->
        Testing.call_tool(client, "outbound", %{"method" => "sampling/createMessage"}, id: 2)
      end)

    assert_receive {:handle_waits, handle_pid}

    assert outbound_text(client, "ping") == "{:ok, %{}}"

    assert {:error, %{"code" => -32603, "message" => message}} =
             Testing.call_tool(client, "outbound", %{"method" => "ping"}, id: 2)

    assert message =~ "in use"

    send(handle_pid, :go)
    assert {:ok, %{"content" => [%{"text" => text}]}} = Task.await(blocked)
    assert text =~ "late"
  end

  test "matches a string id with its answer" do
    assert {:ok, client} = Testing.start(Support.Servers.Outbound)

    assert {:ok, %{"content" => [%{"text" => "{:ok, %{}}"}]}} =
             Testing.call_tool(client, "outbound", %{"method" => "ping"}, id: "s1")
  end

  test "the cursor option reaches the server" do
    assert {:ok, client} = Testing.start(Support.Servers.Outbound)

    assert {:error, %{"code" => -32602}} = Testing.list(client, :tools, cursor: "bad")
  end

  test "a resource update reaches the test on the GET stream" do
    assert {:ok, client} = Testing.start(Support.Servers.ResourcesMultipleSubscribed)
    {instance, _session_id, _get_pid} = client_state(client)

    assert {:ok, _result} =
             Testing.request(client, "resources/subscribe", %{"uri" => "file:///marketing.md"})

    OzMcp.Notify.resource_updated(instance, "file:///marketing.md")

    assert_receive {:oz_mcp_notification, "notifications/resources/updated",
                    %{"uri" => "file:///marketing.md"}}
  end

  test "the log of the session reaches the test on the GET stream" do
    assert {:ok, client} = Testing.start(Support.Servers.WithLogging)
    {instance, session_id, _get_pid} = client_state(client)

    assert {:ok, _result} = Testing.request(client, "logging/setLevel", %{"level" => "info"})
    OzMcp.Notify.log_session(instance, session_id, :info, "hello")

    assert_receive {:oz_mcp_notification, "notifications/message",
                    %{"level" => "info", "data" => "hello"}}
  end

  test "stop/1 ends the session and the GET stream" do
    assert {:ok, client} = Testing.start(Support.Servers.Outbound)
    {instance, session_id, get_pid} = client_state(client)

    assert :ok = Testing.stop(client)

    refute Process.alive?(client)
    assert {:error, :no_session} = OzMcp.Sessions.delivery(instance, session_id)
    assert Utils.eventually(fn -> not Process.alive?(get_pid) end)
    assert {:ok, _config} = OzMcp.Instance.config(instance)

    assert {:ok, other} = Testing.start(Support.Servers.Outbound)
    assert is_pid(other)
  end

  test "a notification is accepted" do
    assert {:ok, client} = Testing.start(Support.Servers.Outbound)

    assert :ok = Testing.notify(client, "notifications/cancelled", %{"requestId" => 7})
  end

  # The GET stream needs no wait: an event sent before the stream is open
  # waits in the session and is replayed when it opens.
  #
  defp client_state(client) do
    %{session_id: session_id, get_pid: get_pid} = :sys.get_state(client)

    assert is_binary(session_id)
    assert is_pid(get_pid)

    {Testing.instance(client), session_id, get_pid}
  end

  defp outbound_text(client, method) do
    assert {:ok, %{"content" => [%{"text" => text}]}} =
             Testing.call_tool(client, "outbound", %{"method" => method})

    text
  end

  defp missing(:name), do: :ok
end
