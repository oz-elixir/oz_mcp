defmodule OzMcp.ClientTest do
  use ExUnit.Case, async: true

  alias OzMcp.{Client, Outbound}
  alias OzMcp.Structs.{BooleanSchema, ElicitationSchema, ModelPreferences, SamplingMessage}
  alias OzMcp.Structs.{NumberSchema, StringSchema, ToolChoice}
  alias OzMcp.Utils.Error
  alias Support.Helpers.SessionProbe
  alias Support.Helpers.Utils
  alias Support.Servers

  @server_module Servers.Default

  @server Module.concat(@server_module, __MODULE__)
  setup do
    Utils.start_instance(@server_module, name: @server, client_tasks: true)
    :ok
  end

  # A session whose GET stream is the test process.
  #
  defp session(capabilities) do
    Utils.create_session(
      @server,
      initialized: true,
      streams: [self()],
      client_capabilities: capabilities
    )
  end

  defp ctx(session_id, extra \\ %{}) do
    capabilities = Map.get(extra, :client_capabilities)

    base = %{
      instance: @server,
      server: @server_module,
      session_id: session_id,
      request_id: nil,
      task_id: nil,
      principal: nil
    }

    base = if capabilities, do: Map.put(base, :client_capabilities, capabilities), else: base
    Map.merge(base, Map.delete(extra, :client_capabilities))
  end

  # Runs `fun` in a process, waits for the request it sends, answers it and
  # returns {the request, the outcome of fun}.
  #
  defp ask(session_id, answer, fun) do
    task = Task.async(fn -> fun.(ctx(session_id)) end)
    {_, %{"id" => id} = request} = Utils.receive_event(5_000)
    :ok = Outbound.deliver(@server, session_id, id, answer)
    {request, Task.await(task, 30_000)}
  end

  defp name_schema do
    %ElicitationSchema{}
    |> ElicitationSchema.property("name", %StringSchema{} |> StringSchema.title("Name"))
    |> ElicitationSchema.property(
      "age",
      %NumberSchema{} |> NumberSchema.type(:integer) |> NumberSchema.minimum(0)
    )
    |> ElicitationSchema.required(["name"])
  end

  describe "elicit/3 - form" do
    test "a schema that holds a term JSON cannot encode is refused, nothing is sent" do
      session_id = session(%{"elicitation" => %{"form" => %{}}})
      schema = %{"type" => "object", "properties" => %{"x" => %{"default" => self()}}}

      assert {:error, :not_encodable} =
               Client.elicit(ctx(session_id), schema, message: "Who?")

      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 50
      assert SessionProbe.pending_outbound_ids(@server, session_id) == []
    end

    test "the defaults of the schema are not added to the accepted content" do
      session_id = session(%{"elicitation" => %{"form" => %{}}})

      schema =
        %ElicitationSchema{}
        |> ElicitationSchema.property("name", %StringSchema{})
        |> ElicitationSchema.property("nick", %StringSchema{} |> StringSchema.default("none"))

      answer = {:ok, %{"action" => "accept", "content" => %{"name" => "Ana"}}}

      assert {_request, {:ok, %{content: content}}} =
               ask(session_id, answer, &Client.elicit(&1, schema, message: "Who?"))

      assert content == %{"name" => "Ana"}
    end

    test "sends the form and returns the accepted content" do
      session_id = session(%{"elicitation" => %{"form" => %{}}})
      answer = {:ok, %{"action" => "accept", "content" => %{"name" => "Ana", "age" => 30}}}

      {request, outcome} =
        ask(session_id, answer, &Client.elicit(&1, name_schema(), message: "Who?"))

      assert request["method"] == "elicitation/create"

      assert %{
               "mode" => "form",
               "message" => "Who?",
               "requestedSchema" => %{"type" => "object", "required" => ["name"]}
             } = request["params"]

      assert outcome == {:ok, %{action: :accept, content: %{"name" => "Ana", "age" => 30}}}
    end

    test "an empty elicitation capability means form only" do
      session_id = session(%{"elicitation" => %{}})
      answer = {:ok, %{"action" => "accept", "content" => %{"name" => "x"}}}

      assert {_request, {:ok, %{action: :accept}}} =
               ask(session_id, answer, &Client.elicit(&1, name_schema(), message: "Who?"))
    end

    test "decline and cancel carry no content" do
      session_id = session(%{"elicitation" => %{}})

      for action <- ["decline", "cancel"] do
        answer = {:ok, %{"action" => action, "content" => %{"name" => "ignored"}}}

        assert {_request, {:ok, %{action: parsed, content: nil}}} =
                 ask(session_id, answer, &Client.elicit(&1, name_schema(), message: "Who?"))

        assert parsed == String.to_existing_atom(action)
      end
    end

    test "content that does not match the schema is an error" do
      session_id = session(%{"elicitation" => %{}})
      answer = {:ok, %{"action" => "accept", "content" => %{"age" => -1}}}

      {_request, outcome} =
        ask(session_id, answer, &Client.elicit(&1, name_schema(), message: "Who?"))

      assert {:error, {:invalid_content, messages}} = outcome
      assert is_list(messages) and messages != []
    end

    test "validate: false returns the content as it is" do
      session_id = session(%{"elicitation" => %{}})
      answer = {:ok, %{"action" => "accept", "content" => %{"age" => -1}}}

      {_request, outcome} =
        ask(
          session_id,
          answer,
          &Client.elicit(&1, name_schema(), message: "Who?", validate: false)
        )

      assert outcome == {:ok, %{action: :accept, content: %{"age" => -1}}}
    end

    test "a schema that is a map is sent as it is and validated" do
      session_id = session(%{"elicitation" => %{}})
      schema = %{"type" => "object", "properties" => %{"ok" => %{"type" => "boolean"}}}
      answer = {:ok, %{"action" => "accept", "content" => %{"ok" => "yes"}}}

      {request, outcome} = ask(session_id, answer, &Client.elicit(&1, schema, message: "Sure?"))

      assert request["params"]["requestedSchema"] == schema
      assert {:error, {:invalid_content, _messages}} = outcome
    end

    test "defaults of the schema are part of the request" do
      session_id = session(%{"elicitation" => %{}})

      schema =
        %ElicitationSchema{}
        |> ElicitationSchema.property("ok", %BooleanSchema{} |> BooleanSchema.default(true))

      {request, _outcome} =
        ask(
          session_id,
          {:ok, %{"action" => "decline"}},
          &Client.elicit(&1, schema, message: "Sure?")
        )

      assert request["params"]["requestedSchema"]["properties"]["ok"] == %{
               "type" => "boolean",
               "default" => true
             }
    end

    test "_meta is sent" do
      session_id = session(%{"elicitation" => %{"url" => %{}}})

      {request, _outcome} =
        ask(
          session_id,
          {:ok, %{"action" => "decline"}},
          &Client.elicit(&1, "https://x.example.com", message: "Open", _meta: %{"k" => "v"})
        )

      assert request["params"]["_meta"] == %{"k" => "v"}
    end

    test "a _meta key with the reserved prefix raises" do
      session_id = session(%{"elicitation" => %{"url" => %{}}})

      assert_raise ArgumentError,
                   "The '_meta' field the _meta prefix of \"dev.mcp/x\" is reserved",
                   fn ->
                     Client.elicit(ctx(session_id), "https://x.example.com",
                       message: "Open",
                       _meta: %{"dev.mcp/x" => 1}
                     )
                   end
    end

    test "a _meta key that is not valid raises" do
      session_id = session(%{"elicitation" => %{}})

      assert_raise ArgumentError, "The '_meta' field bad _meta key \"a b\": bad name", fn ->
        Client.elicit(ctx(session_id), name_schema(), message: "x", _meta: %{"a b" => 1})
      end
    end

    test "a malformed answer is an error" do
      session_id = session(%{"elicitation" => %{}})

      for bad <- [%{}, %{"action" => "maybe"}, %{"action" => "accept", "content" => "x"}] do
        assert {_request, {:error, {:invalid_response, ^bad}}} =
                 ask(session_id, {:ok, bad}, &Client.elicit(&1, name_schema(), message: "Who?"))
      end
    end

    test "an error answer of the client reaches the caller" do
      session_id = session(%{"elicitation" => %{}})
      error = %{"code" => -32601, "message" => "no"}

      assert {_request, {:error, {:rpc_error, ^error}}} =
               ask(session_id, {:error, error}, &Client.elicit(&1, name_schema(), message: "x"))
    end

    test "refuses a client without the form mode: nothing is sent" do
      for capabilities <- [%{}, %{"elicitation" => %{"url" => %{}}}] do
        session_id = session(capabilities)

        assert Client.elicit(ctx(session_id), name_schema(), message: "Who?") ==
                 {:error, :capability_not_supported}
      end

      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 50
    end

    test "the message is required" do
      session_id = session(%{"elicitation" => %{}})

      assert_raise ArgumentError, ~r/:message/, fn ->
        Client.elicit(ctx(session_id), name_schema(), [])
      end
    end

    test "an invalid schema raises before anything is sent" do
      session_id = session(%{"elicitation" => %{}})

      assert_raise ArgumentError, fn ->
        Client.elicit(ctx(session_id), %ElicitationSchema{}, message: "x")
      end

      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 50
    end
  end

  describe "elicit/3 - URL" do
    test "sends the URL and returns the id of the interaction" do
      session_id = session(%{"elicitation" => %{"url" => %{}}})

      {request, outcome} =
        ask(
          session_id,
          {:ok, %{"action" => "accept"}},
          &Client.elicit(&1, "https://example.com/auth",
            message: "Authorize",
            elicitation_id: "e-1"
          )
        )

      assert request["params"] == %{
               "mode" => "url",
               "message" => "Authorize",
               "url" => "https://example.com/auth",
               "elicitationId" => "e-1"
             }

      assert outcome == {:ok, %{action: :accept, content: nil, elicitation_id: "e-1"}}
    end

    test "generates the id of the interaction" do
      session_id = session(%{"elicitation" => %{"form" => %{}, "url" => %{}}})

      {request, {:ok, result}} =
        ask(
          session_id,
          {:ok, %{"action" => "decline"}},
          &Client.elicit(&1, "https://example.com/auth", message: "Authorize")
        )

      assert result.action == :decline
      assert byte_size(result.elicitation_id) == 20
      assert request["params"]["elicitationId"] == result.elicitation_id
    end

    test "refuses a client without the url mode: nothing is sent" do
      for capabilities <- [%{}, %{"elicitation" => %{}}, %{"elicitation" => %{"form" => %{}}}] do
        session_id = session(capabilities)

        assert Client.elicit(ctx(session_id), "https://example.com/auth", message: "x") ==
                 {:error, :capability_not_supported}
      end

      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 50
    end

    test "an invalid URL raises" do
      session_id = session(%{"elicitation" => %{"url" => %{}}})

      assert_raise ArgumentError, ~r/'url'/, fn ->
        Client.elicit(ctx(session_id), "not a url", message: "x")
      end
    end
  end

  describe "url_elicitation_required/2" do
    test "builds the -32042 error" do
      error =
        Client.url_elicitation_required([
          %{url: "https://example.com/connect", message: "Connect", elicitation_id: "e-1"}
        ])

      assert %Error{code: -32042, message: "This request requires more information."} = error

      assert error.data == %{
               "elicitations" => [
                 %{
                   "mode" => "url",
                   "message" => "Connect",
                   "url" => "https://example.com/connect",
                   "elicitationId" => "e-1"
                 }
               ]
             }
    end

    test "generates ids, accepts string keys and a custom message" do
      error =
        Client.url_elicitation_required(
          [
            %{"url" => "https://a.example/x", "message" => "A"},
            %{url: "https://b.example/y", message: "B"}
          ],
          "Link your accounts"
        )

      assert error.message == "Link your accounts"
      assert [first, second] = error.data["elicitations"]
      assert byte_size(first["elicitationId"]) == 20
      assert first["elicitationId"] != second["elicitationId"]
    end

    test "needs at least one elicitation with a url and a message" do
      assert_raise FunctionClauseError, fn -> Client.url_elicitation_required([]) end

      assert_raise ArgumentError, ~r/:url/, fn ->
        Client.url_elicitation_required([%{message: "x"}])
      end

      assert_raise ArgumentError, ~r/:message/, fn ->
        Client.url_elicitation_required([%{url: "https://a.example"}])
      end
    end
  end

  describe "sample/3" do
    @result %{
      "role" => "assistant",
      "content" => %{"type" => "text", "text" => "Hi!"},
      "model" => "model-1",
      "stopReason" => "endTurn"
    }

    test "sends the conversation and parses the answer" do
      session_id = session(%{"sampling" => %{}})

      {request, outcome} =
        ask(
          session_id,
          {:ok, @result},
          &Client.sample(&1, [SamplingMessage.user("Hello")],
            max_tokens: 50,
            system_prompt: "Be brief",
            temperature: 0.5,
            stop_sequences: ["END"],
            model_preferences: %ModelPreferences{} |> ModelPreferences.hints(["m"])
          )
        )

      assert request["method"] == "sampling/createMessage"

      assert request["params"] == %{
               "messages" => [
                 %{"role" => "user", "content" => %{"type" => "text", "text" => "Hello"}}
               ],
               "maxTokens" => 50,
               "systemPrompt" => "Be brief",
               "temperature" => 0.5,
               "stopSequences" => ["END"],
               "modelPreferences" => %{"hints" => [%{"name" => "m"}]}
             }

      assert outcome ==
               {:ok,
                %{
                  role: "assistant",
                  content: [%{"type" => "text", "text" => "Hi!"}],
                  model: "model-1",
                  stop_reason: "endTurn"
                }}
    end

    test "a content that is a list stays a list; stopReason is optional" do
      session_id = session(%{"sampling" => %{}})
      blocks = [%{"type" => "text", "text" => "a"}, %{"type" => "text", "text" => "b"}]
      answer = {:ok, %{"role" => "assistant", "content" => blocks, "model" => "m"}}

      assert {_request, {:ok, %{content: ^blocks, stop_reason: nil}}} =
               ask(
                 session_id,
                 answer,
                 &Client.sample(&1, [SamplingMessage.user("x")], max_tokens: 5)
               )
    end

    test "tools and tool choice need the sampling.tools capability" do
      session_id = session(%{"sampling" => %{}})

      outcome =
        Client.sample(ctx(session_id), [SamplingMessage.user("x")],
          max_tokens: 5,
          tools: [%{name: "t", inputSchema: %{}}]
        )

      assert outcome == {:error, :capability_not_supported}

      outcome =
        Client.sample(ctx(session_id), [SamplingMessage.user("x")],
          max_tokens: 5,
          tool_choice: %ToolChoice{mode: :auto}
        )

      assert outcome == {:error, :capability_not_supported}
      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 50
    end

    test "tools are sent to a client that supports them" do
      session_id = session(%{"sampling" => %{"tools" => %{}}})
      tool = %{"name" => "weather", "inputSchema" => %{"type" => "object"}}

      {request, outcome} =
        ask(
          session_id,
          {:ok, Map.put(@result, "stopReason", "toolUse")},
          &Client.sample(&1, [SamplingMessage.user("Weather?")],
            max_tokens: 50,
            tools: [tool],
            tool_choice: :required
          )
        )

      assert request["params"]["tools"] == [tool]
      assert request["params"]["toolChoice"] == %{"mode" => "required"}
      assert {:ok, %{stop_reason: "toolUse"}} = outcome
    end

    test "tool_use blocks in the answer need a request that offered tools" do
      use_block = %{"type" => "tool_use", "id" => "a", "name" => "weather", "input" => %{}}
      answer = {:ok, Map.merge(@result, %{"content" => [use_block], "stopReason" => "toolUse"})}

      session_id = session(%{"sampling" => %{}})

      assert {_request, {:error, {:invalid_response, _}}} =
               ask(
                 session_id,
                 answer,
                 &Client.sample(&1, [SamplingMessage.user("x")], max_tokens: 5)
               )

      tools_session = session(%{"sampling" => %{"tools" => %{}}})
      tool = %{"name" => "weather", "inputSchema" => %{"type" => "object"}}

      assert {_request, {:ok, %{content: [^use_block], stop_reason: "toolUse"}}} =
               ask(
                 tools_session,
                 answer,
                 &Client.sample(&1, [SamplingMessage.user("x")], max_tokens: 5, tools: [tool])
               )
    end

    test "include_context other than none needs the sampling.context capability" do
      session_id = session(%{"sampling" => %{}})

      assert Client.sample(ctx(session_id), [SamplingMessage.user("x")],
               max_tokens: 5,
               include_context: :this_server
             ) == {:error, :capability_not_supported}

      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 50

      context_session = session(%{"sampling" => %{"context" => %{}}})

      {request, _outcome} =
        ask(
          context_session,
          {:ok, @result},
          &Client.sample(&1, [SamplingMessage.user("x")],
            max_tokens: 5,
            include_context: :all_servers
          )
        )

      assert request["params"]["includeContext"] == "allServers"

      none_session = session(%{"sampling" => %{}})

      {request, _outcome} =
        ask(
          none_session,
          {:ok, @result},
          &Client.sample(&1, [SamplingMessage.user("x")], max_tokens: 5, include_context: :none)
        )

      assert request["params"]["includeContext"] == "none"
    end

    test "refuses a client without sampling" do
      session_id = session(%{"roots" => %{}})

      assert Client.sample(ctx(session_id), [SamplingMessage.user("x")], max_tokens: 5) ==
               {:error, :capability_not_supported}
    end

    test "a malformed answer is an error" do
      session_id = session(%{"sampling" => %{}})

      bad_answers = [
        %{},
        Map.delete(@result, "model"),
        Map.put(@result, "role", "system"),
        Map.put(@result, "content", "text"),
        Map.put(@result, "content", [%{"text" => "no type"}])
      ]

      for bad <- bad_answers do
        assert {_request, {:error, {:invalid_response, ^bad}}} =
                 ask(
                   session_id,
                   {:ok, bad},
                   &Client.sample(&1, [SamplingMessage.user("x")], max_tokens: 5)
                 )
      end
    end

    test "invalid input raises before anything is sent" do
      session_id = session(%{"sampling" => %{}})

      assert_raise ArgumentError, ~r/'maxTokens'/, fn ->
        Client.sample(ctx(session_id), [SamplingMessage.user("x")])
      end

      assert_raise ArgumentError, ~r/'messages'/, fn ->
        Client.sample(ctx(session_id), [], max_tokens: 5)
      end

      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 50
    end
  end

  describe "task: option" do
    defp task_capabilities do
      %{
        "sampling" => %{},
        "tasks" => %{"requests" => %{"sampling" => %{"createMessage" => %{}}}}
      }
    end

    defp elicitation_task_capabilities do
      %{
        "elicitation" => %{"url" => %{}},
        "tasks" => %{"requests" => %{"elicitation" => %{"create" => %{}}}}
      }
    end

    defp task_sample_result do
      %{"role" => "assistant", "content" => %{"type" => "text", "text" => "Hi!"}, "model" => "m"}
    end

    defp start(session_id, fun), do: Task.async(fn -> fun.(ctx(session_id)) end)

    defp next_request(method) do
      {_event_id, request} = Utils.receive_event(5_000)
      assert request["method"] == method
      request
    end

    defp answer(session_id, request, result) do
      assert :ok = Outbound.deliver(@server, session_id, request["id"], result)
    end

    defp answer_task(session_id, request, status) do
      task = %{"taskId" => "c1", "status" => status}
      answer(session_id, request, {:ok, %{"task" => task}})
    end

    test "task: true sets the ttl of the create request to the timeout of the method" do
      session_id = session(task_capabilities())

      task =
        start(
          session_id,
          &Client.sample(&1, [SamplingMessage.user("x")],
            max_tokens: 5,
            task: true,
            timeout: 3_000
          )
        )

      create = next_request("sampling/createMessage")
      assert create["params"]["task"] == %{"ttl" => 3_000}
      answer_task(session_id, create, "cancelled")

      assert Task.await(task, 30_000) == {:error, {:client_task_cancelled, "c1"}}
    end

    test "task: %{ttl: ms} sets its own ttl" do
      session_id = session(task_capabilities())

      task =
        start(
          session_id,
          &Client.sample(&1, [SamplingMessage.user("x")],
            max_tokens: 5,
            task: %{ttl: 5_000}
          )
        )

      create = next_request("sampling/createMessage")
      assert create["params"]["task"] == %{"ttl" => 5_000}
      answer_task(session_id, create, "cancelled")

      assert Task.await(task, 30_000) == {:error, {:client_task_cancelled, "c1"}}
    end

    test "the result of the client task goes through the parser" do
      session_id = session(task_capabilities())

      task =
        start(
          session_id,
          &Client.sample(&1, [SamplingMessage.user("x")], max_tokens: 5, task: true)
        )

      answer_task(session_id, next_request("sampling/createMessage"), "completed")
      answer(session_id, next_request("tasks/result"), {:ok, task_sample_result()})

      assert Task.await(task, 30_000) ==
               {:ok,
                %{
                  role: "assistant",
                  content: [%{"type" => "text", "text" => "Hi!"}],
                  model: "m",
                  stop_reason: nil
                }}
    end

    test "task: on a client without the task capability sends a plain request" do
      session_id = session(%{"sampling" => %{}})

      task =
        start(
          session_id,
          &Client.sample(&1, [SamplingMessage.user("x")], max_tokens: 5, task: true)
        )

      create = next_request("sampling/createMessage")
      refute Map.has_key?(create["params"], "task")
      answer(session_id, create, {:ok, task_sample_result()})

      assert {:ok, %{content: [%{"text" => "Hi!"}]}} = Task.await(task, 30_000)
    end

    test "task_required: true gives an error and sends nothing" do
      session_id = session(%{"sampling" => %{}})

      assert Client.sample(ctx(session_id), [SamplingMessage.user("x")],
               max_tokens: 5,
               task: true,
               task_required: true
             ) == {:error, :capability_not_supported}

      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 50
    end

    test "an elicitation in URL mode with task: true sends params.task" do
      session_id = session(elicitation_task_capabilities())

      task =
        start(
          session_id,
          &Client.elicit(&1, "https://example.com/auth", message: "Authorize", task: true)
        )

      create = next_request("elicitation/create")
      assert create["params"]["task"] == %{"ttl" => 300_000}
      answer_task(session_id, create, "cancelled")

      assert Task.await(task, 30_000) == {:error, {:client_task_cancelled, "c1"}}
    end

    test "task: %{ttl: 0} raises" do
      session_id = session(task_capabilities())

      assert_raise ArgumentError, ~r/invalid :task option/, fn ->
        Client.sample(ctx(session_id), [SamplingMessage.user("x")],
          max_tokens: 5,
          task: %{ttl: 0}
        )
      end

      assert_raise ArgumentError, ~r/invalid :task option/, fn ->
        Client.elicit(ctx(session_id), "https://example.com/auth",
          message: "x",
          task: %{ttl: "soon"}
        )
      end

      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 50
    end

    test "task: true gives :client_tasks_disabled when the option is off" do
      off = Module.concat(@server, "Off")
      Utils.start_instance(@server_module, name: off)

      session_id =
        Utils.create_session(off,
          initialized: true,
          streams: [self()],
          client_capabilities: task_capabilities()
        )

      assert {:error, :client_tasks_disabled} =
               Client.sample(ctx(session_id, %{instance: off}), [SamplingMessage.user("x")],
                 max_tokens: 5,
                 task: true
               )

      assert SessionProbe.pending_outbound_ids(off, session_id) == []
      refute_receive {:oz_mcp_stream, _, _}, 100
    end

    test "a client with no task capability gets the error too when the option is off" do
      off = Module.concat(@server, "Off")
      Utils.start_instance(@server_module, name: off)

      session_id =
        Utils.create_session(off,
          initialized: true,
          streams: [self()],
          client_capabilities: %{"sampling" => %{}}
        )

      assert {:error, :client_tasks_disabled} =
               Client.sample(ctx(session_id, %{instance: off}), [SamplingMessage.user("x")],
                 max_tokens: 5,
                 task: true
               )

      assert SessionProbe.pending_outbound_ids(off, session_id) == []
      refute_receive {:oz_mcp_stream, _, _}, 100
    end

    test "task_required: true does not change the error when the option is off" do
      off = Module.concat(@server, "Off")
      Utils.start_instance(@server_module, name: off)

      session_id =
        Utils.create_session(off,
          initialized: true,
          streams: [self()],
          client_capabilities: task_capabilities()
        )

      assert {:error, :client_tasks_disabled} =
               Client.sample(ctx(session_id, %{instance: off}), [SamplingMessage.user("x")],
                 max_tokens: 5,
                 task: true,
                 task_required: true
               )

      assert SessionProbe.pending_outbound_ids(off, session_id) == []
      refute_receive {:oz_mcp_stream, _, _}, 100
    end

    test "a call with no task: option is a plain request when the option is off" do
      off = Module.concat(@server, "Off")
      Utils.start_instance(@server_module, name: off)

      session_id =
        Utils.create_session(off,
          initialized: true,
          streams: [self()],
          client_capabilities: %{"sampling" => %{}}
        )

      task =
        Task.async(fn ->
          Client.sample(ctx(session_id, %{instance: off}), [SamplingMessage.user("x")],
            max_tokens: 5
          )
        end)

      {_event_id, request} = Utils.receive_event(5_000)
      assert request["method"] == "sampling/createMessage"
      refute Map.has_key?(request["params"], "task")

      assert :ok = Outbound.deliver(off, session_id, request["id"], {:ok, task_sample_result()})
      assert {:ok, %{content: [%{"text" => "Hi!"}]}} = Task.await(task, 30_000)
    end

    test "a bad task: value raises ArgumentError when the option is off" do
      off = Module.concat(@server, "Off")
      Utils.start_instance(@server_module, name: off)

      session_id =
        Utils.create_session(off,
          initialized: true,
          streams: [self()],
          client_capabilities: task_capabilities()
        )

      assert_raise ArgumentError, ~r/invalid :task option/, fn ->
        Client.sample(ctx(session_id, %{instance: off}), [SamplingMessage.user("x")],
          max_tokens: 5,
          task: %{ttl: 0}
        )
      end

      assert SessionProbe.pending_outbound_ids(off, session_id) == []
      refute_receive {:oz_mcp_stream, _, _}, 100
    end
  end

  describe "list_roots/2" do
    test "returns the roots of the client" do
      session_id = session(%{"roots" => %{"listChanged" => true}})

      roots = [
        %{"uri" => "file:///home/user/a", "name" => "A"},
        %{"uri" => "file:///home/user/b"}
      ]

      {request, outcome} =
        ask(session_id, {:ok, %{"roots" => roots}}, &Client.list_roots/1)

      assert request["method"] == "roots/list"
      refute Map.has_key?(request, "params")
      assert outcome == {:ok, roots}
    end

    test "an empty list of roots is valid" do
      session_id = session(%{"roots" => %{}})

      assert {_request, {:ok, []}} =
               ask(session_id, {:ok, %{"roots" => []}}, &Client.list_roots/1)
    end

    test "a root that is not a file:// uri is an error" do
      session_id = session(%{"roots" => %{}})

      for bad <- [
            %{"roots" => [%{"uri" => "https://example.com"}]},
            %{"roots" => [%{"uri" => "file:///a", "name" => 1}]},
            %{"roots" => ["file:///a"]},
            %{"roots" => "none"},
            %{}
          ] do
        assert {_request, {:error, {:invalid_response, ^bad}}} =
                 ask(session_id, {:ok, bad}, &Client.list_roots/1)
      end
    end

    test "refuses a client without roots" do
      session_id = session(%{"sampling" => %{}})
      assert Client.list_roots(ctx(session_id)) == {:error, :capability_not_supported}
      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 50
    end

    test "passes the timeout to the request" do
      session_id = session(%{"roots" => %{}})

      assert Client.list_roots(ctx(session_id), timeout: 50) == {:error, :timeout}
      assert SessionProbe.pending_outbound_ids(@server, session_id) == []
    end
  end
end
