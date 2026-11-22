defmodule OzMcp.Structs.PromptArgumentTest do
  use ExUnit.Case, async: true

  alias OzMcp.Structs.PromptArgument

  describe "struct defaults" do
    test "has correct defaults for all fields" do
      argument = %PromptArgument{}

      assert argument.name == ""
      assert argument.title == nil
      assert argument.description == nil
      assert argument.required == nil
    end
  end

  describe "name/2" do
    test "sets name field" do
      argument = PromptArgument.name(%PromptArgument{}, "language")

      assert argument.name == "language"
    end
  end

  describe "title/2" do
    test "sets title field" do
      argument = PromptArgument.title(%PromptArgument{}, "Language")

      assert argument.title == "Language"
    end
  end

  describe "description/2" do
    test "sets description field" do
      argument = PromptArgument.description(%PromptArgument{}, "Programming language")

      assert argument.description == "Programming language"
    end
  end

  describe "required/2" do
    test "sets required field" do
      argument = PromptArgument.required(%PromptArgument{}, true)

      assert argument.required == true
    end
  end

  describe "build/1" do
    test "builds with name only" do
      argument = %PromptArgument{name: "language"}
      result = PromptArgument.build(argument)

      assert result == %{name: "language"}
    end

    test "raises when name is empty" do
      argument = %PromptArgument{name: ""}

      assert_raise ArgumentError, "The 'name' field cannot be an empty string", fn ->
        PromptArgument.build(argument)
      end
    end

    test "raises when name is not a string" do
      argument = struct(PromptArgument, name: 123)

      assert_raise ArgumentError, "The 'name' field is required and must be a string", fn ->
        PromptArgument.build(argument)
      end
    end

    test "includes title when set" do
      argument = %PromptArgument{name: "language", title: "Language"}
      result = PromptArgument.build(argument)

      assert result == %{name: "language", title: "Language"}
    end

    test "includes description when set" do
      argument = %PromptArgument{name: "language", description: "Programming language"}
      result = PromptArgument.build(argument)

      assert result == %{name: "language", description: "Programming language"}
    end

    test "raises when title is empty" do
      argument = %PromptArgument{name: "language", title: ""}

      assert_raise ArgumentError, "The 'title' field cannot be an empty string", fn ->
        PromptArgument.build(argument)
      end
    end

    test "raises when description is not a string or nil" do
      argument = struct(PromptArgument, name: "language", description: 42)

      assert_raise ArgumentError, "The 'description' field must be a string or nil", fn ->
        PromptArgument.build(argument)
      end
    end

    test "includes required when true" do
      argument = %PromptArgument{name: "language", required: true}
      result = PromptArgument.build(argument)

      assert result == %{name: "language", required: true}
    end

    test "does not include required when false" do
      argument = %PromptArgument{name: "language", required: false}
      result = PromptArgument.build(argument)

      assert result == %{name: "language"}
    end

    test "does not include required when nil" do
      argument = %PromptArgument{name: "language", required: nil}
      result = PromptArgument.build(argument)

      assert result == %{name: "language"}
    end

    test "raises when required is not a boolean or nil" do
      argument = struct(PromptArgument, name: "language", required: "yes")

      assert_raise ArgumentError, "The 'required' field must be a boolean or nil", fn ->
        PromptArgument.build(argument)
      end
    end

    test "builds with all fields" do
      argument = %PromptArgument{
        name: "language",
        title: "Language",
        description: "Programming language",
        required: true
      }

      result = PromptArgument.build(argument)

      assert result == %{
               name: "language",
               title: "Language",
               description: "Programming language",
               required: true
             }
    end

    test "does not include nil optional fields" do
      argument = %PromptArgument{
        name: "language",
        title: nil,
        description: nil,
        required: nil
      }

      result = PromptArgument.build(argument)

      assert result == %{name: "language"}
    end
  end
end
