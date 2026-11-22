defmodule OzMcp.Structs.PromptTest do
  use ExUnit.Case, async: true

  alias OzMcp.Structs.{Icon, Prompt, PromptArgument}

  describe "struct defaults" do
    test "has correct defaults for all fields" do
      prompt = %Prompt{}

      assert prompt.name == ""
      assert prompt.title == nil
      assert prompt.description == nil
      assert prompt.arguments == nil
      assert prompt.icons == nil
      assert prompt._meta == nil
      assert prompt.extras == nil
    end
  end

  describe "name/2" do
    test "sets name field" do
      prompt = Prompt.name(%Prompt{}, "code_review")

      assert prompt.name == "code_review"
    end
  end

  describe "title/2" do
    test "sets title field" do
      prompt = Prompt.title(%Prompt{}, "Code review")

      assert prompt.title == "Code review"
    end
  end

  describe "description/2" do
    test "sets description field" do
      prompt = Prompt.description(%Prompt{}, "Reviews code")

      assert prompt.description == "Reviews code"
    end
  end

  describe "arguments/2" do
    test "sets arguments field" do
      arguments = [%PromptArgument{name: "language", required: true}]
      prompt = Prompt.arguments(%Prompt{}, arguments)

      assert prompt.arguments == arguments
    end
  end

  describe "icons/2" do
    test "sets icons field" do
      icons = [%Icon{src: "https://example.com/icon.png"}]
      prompt = Prompt.icons(%Prompt{}, icons)

      assert prompt.icons == icons
    end
  end

  describe "_meta/2" do
    test "sets _meta field" do
      prompt = Prompt._meta(%Prompt{}, %{"key" => "value"})

      assert prompt._meta == %{"key" => "value"}
    end
  end

  describe "extras/2" do
    test "sets extras field" do
      prompt = Prompt.extras(%Prompt{}, %{"vendor" => 1})

      assert prompt.extras == %{"vendor" => 1}
    end
  end

  describe "required_scopes/2" do
    test "sets required_scopes field" do
      prompt = Prompt.required_scopes(%Prompt{}, ["files:write"])

      assert prompt.required_scopes == ["files:write"]
    end

    test "raises for a scope that is not a scope-token" do
      assert_raise ArgumentError, fn ->
        Prompt.required_scopes(%Prompt{}, ["a b"])
      end
    end
  end

  describe "build/1" do
    test "builds with name only" do
      prompt = %Prompt{name: "code_review"}
      result = Prompt.build(prompt)

      assert result == %{name: "code_review"}
    end

    test "raises when name is empty" do
      prompt = %Prompt{name: ""}

      assert_raise ArgumentError, "The 'name' field cannot be an empty string", fn ->
        Prompt.build(prompt)
      end
    end

    test "raises when name is not a string" do
      prompt = struct(Prompt, name: 123)

      assert_raise ArgumentError, "The 'name' field is required and must be a string", fn ->
        Prompt.build(prompt)
      end
    end

    test "includes title when set" do
      prompt = %Prompt{name: "code_review", title: "Code review"}
      result = Prompt.build(prompt)

      assert result == %{name: "code_review", title: "Code review"}
    end

    test "raises when title is empty" do
      prompt = %Prompt{name: "code_review", title: ""}

      assert_raise ArgumentError, "The 'title' field cannot be an empty string", fn ->
        Prompt.build(prompt)
      end
    end

    test "includes description when set" do
      prompt = %Prompt{name: "code_review", description: "Reviews code"}
      result = Prompt.build(prompt)

      assert result == %{name: "code_review", description: "Reviews code"}
    end

    test "raises when description is not a string or nil" do
      prompt = struct(Prompt, name: "code_review", description: 42)

      assert_raise ArgumentError, "The 'description' field must be a string or nil", fn ->
        Prompt.build(prompt)
      end
    end

    test "includes arguments built through PromptArgument" do
      prompt = %Prompt{
        name: "code_review",
        arguments: [
          %PromptArgument{name: "language", required: true},
          %PromptArgument{name: "focus"}
        ]
      }

      result = Prompt.build(prompt)

      assert result == %{
               name: "code_review",
               arguments: [
                 %{name: "language", required: true},
                 %{name: "focus"}
               ]
             }
    end

    test "does not include arguments when nil" do
      prompt = %Prompt{name: "code_review", arguments: nil}
      result = Prompt.build(prompt)

      assert result == %{name: "code_review"}
    end

    test "raises when arguments is not a list or nil" do
      prompt = struct(Prompt, name: "code_review", arguments: "not a list")

      assert_raise ArgumentError, "The 'arguments' field must be a list or nil", fn ->
        Prompt.build(prompt)
      end
    end

    test "includes icons when set" do
      prompt = %Prompt{
        name: "code_review",
        icons: [%Icon{src: "https://example.com/icon.png"}]
      }

      result = Prompt.build(prompt)

      assert result == %{
               name: "code_review",
               icons: [%{src: "https://example.com/icon.png"}]
             }
    end

    test "does not include icons when nil" do
      prompt = %Prompt{name: "code_review", icons: nil}
      result = Prompt.build(prompt)

      assert result == %{name: "code_review"}
    end

    test "raises when icons is not a list" do
      prompt = %Prompt{name: "code_review", icons: "x"}

      assert_raise ArgumentError, "The 'icons' field must be a list or nil", fn ->
        Prompt.build(prompt)
      end
    end

    test "includes _meta when set" do
      prompt = %Prompt{name: "code_review", _meta: %{"key" => "val"}}
      result = Prompt.build(prompt)

      assert result == %{name: "code_review", _meta: %{"key" => "val"}}
    end

    test "does not include _meta when nil" do
      prompt = %Prompt{name: "code_review", _meta: nil}
      result = Prompt.build(prompt)

      refute Map.has_key?(result, :_meta)
    end

    test "does not include required_scopes" do
      prompt = Prompt.required_scopes(%Prompt{name: "code_review"}, ["a"])
      result = Prompt.build(prompt)

      refute Map.has_key?(result, :required_scopes)
    end

    test "merges extras into result" do
      prompt = %Prompt{name: "code_review", extras: %{"vendor" => 1}}
      result = Prompt.build(prompt)

      assert result["vendor"] == 1
    end

    test "does not include extras when nil" do
      prompt = %Prompt{name: "code_review", extras: nil}
      result = Prompt.build(prompt)

      refute Map.has_key?(result, "vendor")
    end

    test "extras do not override existing result keys" do
      prompt = %Prompt{
        name: "code_review",
        extras: %{name: "should not override"}
      }

      result = Prompt.build(prompt)

      assert result[:name] == "code_review"
    end

    test "builds with all fields" do
      prompt = %Prompt{
        name: "code_review",
        title: "Code review",
        description: "Reviews code with a focus on safety",
        arguments: [%PromptArgument{name: "language", required: true}],
        icons: [%Icon{src: "https://example.com/icon.png"}],
        _meta: %{"key" => "val"}
      }

      result = Prompt.build(prompt)

      assert result == %{
               name: "code_review",
               title: "Code review",
               description: "Reviews code with a focus on safety",
               arguments: [%{name: "language", required: true}],
               icons: [%{src: "https://example.com/icon.png"}],
               _meta: %{"key" => "val"}
             }
    end

    test "does not include nil optional fields" do
      prompt = %Prompt{
        name: "code_review",
        title: nil,
        description: nil,
        arguments: nil,
        icons: nil,
        _meta: nil
      }

      result = Prompt.build(prompt)

      assert result == %{name: "code_review"}
    end
  end
end
