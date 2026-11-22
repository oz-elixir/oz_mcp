defmodule OzMcp.Structs.GetPromptResultTest do
  use ExUnit.Case, async: true
  alias OzMcp.Structs.{GetPromptResult, PromptMessage, TextContent}

  describe "struct defaults" do
    test "has correct defaults for all fields" do
      gpr = %GetPromptResult{}

      assert gpr.description == nil
      assert gpr.messages == []
      assert gpr._meta == nil
    end
  end

  describe "description/2" do
    test "sets description field" do
      gpr = GetPromptResult.description(%GetPromptResult{}, "Code review prompt")

      assert gpr.description == "Code review prompt"
    end

    test "accepts nil for description field" do
      gpr = GetPromptResult.description(%GetPromptResult{}, nil)

      assert gpr.description == nil
    end
  end

  describe "messages/2" do
    test "sets messages field" do
      messages = [%PromptMessage{role: :user, content: %TextContent{text: "hello"}}]
      gpr = GetPromptResult.messages(%GetPromptResult{}, messages)

      assert gpr.messages == messages
    end
  end

  describe "_meta/2" do
    test "sets _meta field" do
      gpr = GetPromptResult._meta(%GetPromptResult{}, %{"key" => "value"})

      assert gpr._meta == %{"key" => "value"}
    end

    test "accepts nil for _meta field" do
      gpr = GetPromptResult._meta(%GetPromptResult{}, nil)

      assert gpr._meta == nil
    end
  end

  describe "build/1" do
    test "builds with default empty messages" do
      result = GetPromptResult.build(%GetPromptResult{})

      assert result == %{messages: []}
    end

    test "raises when messages is not a list" do
      gpr = struct(%GetPromptResult{}, messages: "not a list")

      assert_raise ArgumentError, "The 'messages' field must be a list", fn ->
        GetPromptResult.build(gpr)
      end
    end

    test "raises when description is not a string or nil" do
      gpr = struct(%GetPromptResult{}, description: 42)

      assert_raise ArgumentError, "The 'description' field must be a string or nil", fn ->
        GetPromptResult.build(gpr)
      end
    end

    test "includes description when set" do
      gpr = %GetPromptResult{description: "Code review prompt"}
      result = GetPromptResult.build(gpr)

      assert result == %{description: "Code review prompt", messages: []}
    end

    test "does not include description when nil" do
      gpr = %GetPromptResult{description: nil}
      result = GetPromptResult.build(gpr)

      refute Map.has_key?(result, :description)
    end

    test "builds PromptMessage items in messages" do
      message = %PromptMessage{role: :user, content: %TextContent{text: "Review this code"}}
      gpr = %GetPromptResult{messages: [message]}
      result = GetPromptResult.build(gpr)

      assert result.messages == [
               %{"role" => "user", "content" => %{type: "text", text: "Review this code"}}
             ]
    end

    test "preserves messages order" do
      m1 = %PromptMessage{role: :user, content: %TextContent{text: "question"}}
      m2 = %PromptMessage{role: :assistant, content: %TextContent{text: "answer"}}
      gpr = %GetPromptResult{messages: [m1, m2]}
      result = GetPromptResult.build(gpr)

      assert result.messages == [
               %{"role" => "user", "content" => %{type: "text", text: "question"}},
               %{"role" => "assistant", "content" => %{type: "text", text: "answer"}}
             ]
    end

    test "handles plain maps in messages list" do
      plain_map = %{"role" => "user", "content" => %{type: "text", text: "hello"}}
      gpr = %GetPromptResult{messages: [plain_map]}
      result = GetPromptResult.build(gpr)

      assert result.messages == [plain_map]
    end

    test "raises when a plain-map message has a role outside user and assistant" do
      gpr = %GetPromptResult{messages: [%{"role" => "robot", "content" => %{type: "text"}}]}

      assert_raise ArgumentError,
                   ~s('role' elements must be "user" or "assistant", got: "robot"),
                   fn ->
                     GetPromptResult.build(gpr)
                   end
    end

    test "raises when a plain-map message has no content" do
      gpr = %GetPromptResult{messages: [%{"role" => "user"}]}

      assert_raise ArgumentError, ~r/The 'content' field is required/, fn ->
        GetPromptResult.build(gpr)
      end
    end

    test "a plain-map message with no role passes" do
      plain_map = %{"content" => %{type: "text", text: "hello"}}
      gpr = %GetPromptResult{messages: [plain_map]}

      assert %{messages: [^plain_map]} = GetPromptResult.build(gpr)
    end

    test "raises when the content block of a plain-map message has a bad member" do
      gpr = %GetPromptResult{messages: [%{"role" => "user", "content" => %{"type" => "text"}}]}

      assert_raise ArgumentError, ~r/The 'text' field cannot be an empty string/, fn ->
        GetPromptResult.build(gpr)
      end
    end

    test "handles mix of PromptMessage structs and plain maps in messages list" do
      message = %PromptMessage{role: :user, content: %TextContent{text: "hello"}}
      plain_map = %{"role" => "assistant", "content" => %{type: "text", text: "hi"}}
      gpr = %GetPromptResult{messages: [message, plain_map]}
      result = GetPromptResult.build(gpr)

      assert result.messages == [
               %{"role" => "user", "content" => %{type: "text", text: "hello"}},
               %{"role" => "assistant", "content" => %{type: "text", text: "hi"}}
             ]
    end

    test "raises when a message is not a map or a struct" do
      gpr = %GetPromptResult{messages: ["hello"]}

      assert_raise ArgumentError, ~r/each item must be a map/, fn ->
        GetPromptResult.build(gpr)
      end
    end

    test "includes _meta when set" do
      gpr = %GetPromptResult{_meta: %{"progressToken" => 5}}
      result = GetPromptResult.build(gpr)

      assert result[:_meta] == %{"progressToken" => 5}
    end

    test "does not include _meta when nil" do
      gpr = %GetPromptResult{_meta: nil}
      result = GetPromptResult.build(gpr)

      refute Map.has_key?(result, :_meta)
    end

    test "builds with all fields" do
      gpr = %GetPromptResult{
        description: "Code review prompt",
        messages: [%PromptMessage{role: :user, content: %TextContent{text: "Review this"}}],
        _meta: %{"progressToken" => 1}
      }

      result = GetPromptResult.build(gpr)

      assert result == %{
               description: "Code review prompt",
               messages: [
                 %{"role" => "user", "content" => %{type: "text", text: "Review this"}}
               ],
               _meta: %{"progressToken" => 1}
             }
    end
  end
end
