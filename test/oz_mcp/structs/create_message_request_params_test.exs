defmodule OzMcp.Structs.CreateMessageRequestParamsTest do
  use ExUnit.Case, async: true

  alias OzMcp.Structs.{
    CreateMessageRequestParams,
    ModelPreferences,
    SamplingMessage,
    TaskMetadata,
    TextContent,
    Tool,
    ToolChoice,
    ToolResultContent,
    ToolUseContent
  }

  defp params(messages \\ [SamplingMessage.user("Hello")]) do
    %CreateMessageRequestParams{}
    |> CreateMessageRequestParams.messages(messages)
    |> CreateMessageRequestParams.max_tokens(100)
  end

  defp build(params), do: CreateMessageRequestParams.build(params)

  defp assistant_tool_use(id),
    do: %SamplingMessage{role: :assistant, content: %ToolUseContent{id: id, name: "n"}}

  defp user_tool_result(ids),
    do: %SamplingMessage{content: Enum.map(ids, &%ToolResultContent{toolUseId: &1})}

  test "builds the minimal request" do
    assert build(params()) == %{
             messages: [%{role: "user", content: %{type: "text", text: "Hello"}}],
             maxTokens: 100
           }
  end

  test "builds every field" do
    tool = %Tool{} |> Tool.name("weather") |> Tool.input_schema(%{type: "object"})

    result =
      params()
      |> CreateMessageRequestParams.model_preferences(
        %ModelPreferences{}
        |> ModelPreferences.hints(["c"])
      )
      |> CreateMessageRequestParams.system_prompt("Be brief")
      |> CreateMessageRequestParams.include_context(:this_server)
      |> CreateMessageRequestParams.temperature(0.2)
      |> CreateMessageRequestParams.stop_sequences(["END"])
      |> CreateMessageRequestParams.metadata(%{"k" => "v"})
      |> CreateMessageRequestParams.tools([tool, %{name: "raw", inputSchema: %{}}])
      |> CreateMessageRequestParams.tool_choice(%ToolChoice{mode: :required})
      |> CreateMessageRequestParams._meta(%{"m" => 1})
      |> build()

    assert %{
             modelPreferences: %{hints: [%{name: "c"}]},
             systemPrompt: "Be brief",
             includeContext: "thisServer",
             temperature: 0.2,
             stopSequences: ["END"],
             metadata: %{"k" => "v"},
             tools: [%{name: "weather"}, %{name: "raw"}],
             toolChoice: %{mode: "required"},
             _meta: %{"m" => 1}
           } = result
  end

  test "accepts maps for messages and preferences; a mode atom for the tool choice" do
    result =
      params([%{role: "user", content: %{type: "text", text: "x"}}])
      |> CreateMessageRequestParams.model_preferences(%{speedPriority: 1})
      |> CreateMessageRequestParams.tool_choice(:none)
      |> build()

    assert result.modelPreferences == %{speedPriority: 1}
    assert result.toolChoice == %{mode: "none"}
  end

  test "include_context accepts the three values" do
    for {value, wire} <- [none: "none", this_server: "thisServer", all_servers: "allServers"] do
      assert %{includeContext: ^wire} =
               params() |> CreateMessageRequestParams.include_context(value) |> build()
    end

    assert %{includeContext: "allServers"} =
             params() |> CreateMessageRequestParams.include_context("allServers") |> build()
  end

  test "an empty tools list is not sent" do
    refute Map.has_key?(params() |> CreateMessageRequestParams.tools([]) |> build(), :tools)
  end

  test "sends the task metadata" do
    params = params() |> CreateMessageRequestParams.task(%TaskMetadata{ttl: 60_000})
    assert build(params).task == %{ttl: 60_000}
  end

  test "does not send task when it is nil" do
    refute Map.has_key?(build(params()), :task)
  end

  test "raises when task is not a TaskMetadata struct" do
    message = "The 'task' field must be a OzMcp.Structs.TaskMetadata struct or nil"

    assert_raise ArgumentError, message, fn ->
      build(%{params() | task: %{ttl: 1}})
    end
  end

  test "requires messages and a positive maxTokens" do
    assert_raise ArgumentError, ~r/'messages'/, fn -> build(params([])) end
    assert_raise ArgumentError, ~r/'maxTokens'/, fn -> build(%{params() | maxTokens: nil}) end
    assert_raise ArgumentError, ~r/'maxTokens'/, fn -> build(%{params() | maxTokens: 0}) end
  end

  test "rejects invalid fields" do
    assert_raise ArgumentError, ~r/includeContext/, fn ->
      params() |> CreateMessageRequestParams.include_context(:everything) |> build()
    end

    assert_raise ArgumentError, ~r/'temperature'/, fn ->
      params() |> CreateMessageRequestParams.temperature("hot") |> build()
    end

    assert_raise ArgumentError, ~r/'messages' elements/, fn -> build(params(["hello"])) end

    assert_raise ArgumentError, ~r/'modelPreferences'/, fn ->
      params() |> CreateMessageRequestParams.model_preferences("fast") |> build()
    end

    assert_raise ArgumentError, ~r/'tools' elements/, fn ->
      params() |> CreateMessageRequestParams.tools(["t"]) |> build()
    end

    assert_raise ArgumentError, ~r/'toolChoice'/, fn ->
      params() |> CreateMessageRequestParams.tool_choice("auto") |> build()
    end
  end

  describe "tool use rules" do
    test "a tool use followed by its tool result is valid" do
      messages = [
        SamplingMessage.user("Weather?"),
        assistant_tool_use("a"),
        user_tool_result(["a"]),
        SamplingMessage.assistant("Sunny")
      ]

      assert %{messages: [_, _, _, _]} = build(params(messages))
    end

    test "parallel tool uses need one result each, in any order" do
      use_both = %SamplingMessage{
        role: :assistant,
        content: [%ToolUseContent{id: "a", name: "n"}, %ToolUseContent{id: "b", name: "n"}]
      }

      assert %{} = build(params([use_both, user_tool_result(["b", "a"])]))

      assert_raise ArgumentError, ~r/for each/, fn ->
        build(params([use_both, user_tool_result(["a"])]))
      end
    end

    test "a tool use needs a message after it" do
      assert_raise ArgumentError, ~r/must be followed/, fn ->
        build(params([SamplingMessage.user("x"), assistant_tool_use("a")]))
      end
    end

    test "the message after a tool use must answer its id" do
      assert_raise ArgumentError, ~r/for each/, fn ->
        build(params([assistant_tool_use("a"), SamplingMessage.user("no")]))
      end

      assert_raise ArgumentError, ~r/for each/, fn ->
        build(params([assistant_tool_use("a"), user_tool_result(["z"])]))
      end
    end

    test "a message with a tool result has only tool results" do
      mixed = %SamplingMessage{
        content: [%ToolResultContent{toolUseId: "a"}, %TextContent{} |> TextContent.text("x")]
      }

      assert_raise ArgumentError, ~r/only 'tool_result'/, fn ->
        build(params([assistant_tool_use("a"), mixed]))
      end
    end

    test "a tool result needs the tool use it answers right before it" do
      assert_raise ArgumentError, ~r/right after/, fn ->
        build(params([user_tool_result(["a"])]))
      end

      assert_raise ArgumentError, ~r/right after/, fn ->
        build(params([assistant_tool_use("a"), user_tool_result(["a"]), user_tool_result(["a"])]))
      end
    end

    test "a tool result is a user message and a tool use an assistant message" do
      assistant_result = %SamplingMessage{
        role: :assistant,
        content: [%ToolResultContent{toolUseId: "a"}]
      }

      assert_raise ArgumentError, ~r/'tool_result' content must have the role 'user'/, fn ->
        build(params([assistant_tool_use("a"), assistant_result]))
      end

      user_use = %SamplingMessage{content: %ToolUseContent{id: "a", name: "n"}}

      assert_raise ArgumentError, ~r/'tool_use' content must have the role 'assistant'/, fn ->
        build(params([user_use, user_tool_result(["a"])]))
      end
    end

    test "the roles of messages given as maps are checked, as strings or atoms" do
      use_block = %{"type" => "tool_use", "id" => "a", "name" => "n", "input" => %{}}
      result_block = %{"type" => "tool_result", "toolUseId" => "a", "content" => []}

      assert %{} =
               build(
                 params([
                   %{role: :assistant, content: use_block},
                   %{role: :user, content: [result_block]}
                 ])
               )

      assert_raise ArgumentError, ~r/the role 'user'/, fn ->
        build(
          params([
            %{"role" => "assistant", "content" => use_block},
            %{"role" => "assistant", "content" => [result_block]}
          ])
        )
      end
    end

    test "rules apply to messages given as maps" do
      use_block = %{"type" => "tool_use", "id" => "a", "name" => "n", "input" => %{}}
      result_block = %{"type" => "tool_result", "toolUseId" => "a", "content" => []}

      messages = [
        %{"role" => "assistant", "content" => use_block},
        %{"role" => "user", "content" => [result_block]}
      ]

      assert %{} = build(params(messages))

      assert_raise ArgumentError, ~r/must be followed/, fn ->
        build(params(Enum.take(messages, 1)))
      end
    end
  end
end
