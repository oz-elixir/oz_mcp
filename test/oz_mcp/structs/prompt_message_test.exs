defmodule OzMcp.Structs.PromptMessageTest do
  use ExUnit.Case, async: true

  alias OzMcp.Structs.{
    Annotations,
    AudioContent,
    EmbeddedResource,
    ImageContent,
    PromptMessage,
    ResourceLink,
    TextContent,
    TextResourceContents
  }

  describe "struct defaults" do
    test "has correct defaults for all fields" do
      message = %PromptMessage{}

      assert message.role == :user
      assert message.content == nil
    end
  end

  describe "role/2" do
    test "sets role field" do
      message = PromptMessage.role(%PromptMessage{}, :assistant)

      assert message.role == :assistant
    end
  end

  describe "content/2" do
    test "sets content field" do
      content = %TextContent{text: "hello"}
      message = PromptMessage.content(%PromptMessage{}, content)

      assert message.content == content
    end
  end

  describe "build/1" do
    test "builds a user message with text content" do
      message = %PromptMessage{role: :user, content: %TextContent{text: "Review this code"}}
      result = PromptMessage.build(message)

      assert result == %{
               "role" => "user",
               "content" => %{type: "text", text: "Review this code"}
             }
    end

    test "serializes the assistant role as a string" do
      message = %PromptMessage{role: :assistant, content: %TextContent{text: "Sure"}}
      result = PromptMessage.build(message)

      assert result["role"] == "assistant"
    end

    test "builds content with annotations and _meta passthrough" do
      content = %TextContent{
        text: "hello",
        annotations: %Annotations{audience: [:assistant]},
        _meta: %{"key" => "val"}
      }

      message = %PromptMessage{role: :user, content: content}
      result = PromptMessage.build(message)

      assert result == %{
               "role" => "user",
               "content" => %{
                 type: "text",
                 text: "hello",
                 annotations: %{audience: [:assistant]},
                 _meta: %{"key" => "val"}
               }
             }
    end

    test "builds image content" do
      message = %PromptMessage{
        role: :user,
        content: %ImageContent{data: "aGVsbG8=", mimeType: "image/png"}
      }

      result = PromptMessage.build(message)

      assert result == %{
               "role" => "user",
               "content" => %{type: "image", data: "aGVsbG8=", mimeType: "image/png"}
             }
    end

    test "builds audio content" do
      message = %PromptMessage{
        role: :user,
        content: %AudioContent{data: "aGVsbG8=", mimeType: "audio/wav"}
      }

      result = PromptMessage.build(message)

      assert result == %{
               "role" => "user",
               "content" => %{type: "audio", data: "aGVsbG8=", mimeType: "audio/wav"}
             }
    end

    test "builds resource link content" do
      message = %PromptMessage{
        role: :user,
        content: %ResourceLink{uri: "file:///a/b/c.py", name: "c.py"}
      }

      result = PromptMessage.build(message)

      assert result == %{
               "role" => "user",
               "content" => %{type: "resource_link", uri: "file:///a/b/c.py", name: "c.py"}
             }
    end

    test "builds embedded resource content" do
      message = %PromptMessage{
        role: :user,
        content: %EmbeddedResource{
          resource: %TextResourceContents{uri: "file:///a/b/c.py", text: "print(1)"}
        }
      }

      result = PromptMessage.build(message)

      assert result == %{
               "role" => "user",
               "content" => %{
                 type: "resource",
                 resource: %{uri: "file:///a/b/c.py", text: "print(1)"}
               }
             }
    end

    test "raises when role is invalid" do
      message = %PromptMessage{role: :system, content: %TextContent{text: "hello"}}

      assert_raise ArgumentError,
                   ~s('role' elements must be "user" or "assistant", got: :system),
                   fn ->
                     PromptMessage.build(message)
                   end
    end

    test "raises when content is nil" do
      message = %PromptMessage{role: :user, content: nil}

      assert_raise ArgumentError,
                   ~r/The 'content' field is required and must be one of/,
                   fn ->
                     PromptMessage.build(message)
                   end
    end

    test "accepts a map as content and passes it through" do
      message = %PromptMessage{role: :user, content: %{type: "text", text: "hello"}}

      result = PromptMessage.build(message)

      assert result == %{
               "role" => "user",
               "content" => %{type: "text", text: "hello"}
             }
    end

    test "raises when a content map has no type" do
      message = %PromptMessage{role: :user, content: %{"text" => "hello"}}

      assert_raise ArgumentError, ~r/a content block map needs a 'type'/, fn ->
        PromptMessage.build(message)
      end
    end
  end

  describe "check/1" do
    test "returns :ok for a struct message" do
      message = %PromptMessage{role: :user, content: %TextContent{text: "hello"}}

      assert PromptMessage.check(message) == :ok
    end

    test "returns :ok for a map message with a valid role and content" do
      for role <- ["user", "assistant", :user, :assistant] do
        assert PromptMessage.check(%{
                 "role" => role,
                 "content" => %{"type" => "text", "text" => "x"}
               }) == :ok
      end

      assert PromptMessage.check(%{role: "user", content: %{type: "text", text: "x"}}) == :ok
    end

    test "returns :ok for a map message with no role" do
      assert PromptMessage.check(%{"content" => %{"type" => "text", "text" => "x"}}) == :ok
    end

    test "raises for a map message with a role outside user and assistant" do
      assert_raise ArgumentError,
                   ~s('role' elements must be "user" or "assistant", got: "robot"),
                   fn ->
                     PromptMessage.check(%{"role" => "robot", "content" => %{"type" => "text"}})
                   end
    end

    test "raises for a map message with no content" do
      assert_raise ArgumentError, ~r/The 'content' field is required/, fn ->
        PromptMessage.check(%{"role" => "user"})
      end
    end

    test "raises for a map message with a content block with no type" do
      assert_raise ArgumentError, ~r/a content block map needs a 'type'/, fn ->
        PromptMessage.check(%{role: "user", content: %{"text" => "x"}})
      end
    end

    test "raises for a map message with a content block with a bad member" do
      assert_raise ArgumentError, ~r/The 'text' field cannot be an empty string/, fn ->
        PromptMessage.check(%{role: "user", content: %{type: "text", text: ""}})
      end
    end

    test "ignores a value that is not a map or a struct" do
      assert PromptMessage.check("hello") == :ok
    end
  end
end
