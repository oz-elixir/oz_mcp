defmodule OzMcp.Structs.CompletionTest do
  use ExUnit.Case, async: true
  alias OzMcp.Structs.Completion

  describe "struct defaults" do
    test "has correct defaults for all fields" do
      completion = %Completion{}

      assert completion.values == []
      assert completion.total == nil
      assert completion.hasMore == nil
    end
  end

  describe "values/2" do
    test "sets values field" do
      completion = Completion.values(%Completion{}, ["python", "pytorch"])

      assert completion.values == ["python", "pytorch"]
    end
  end

  describe "total/2" do
    test "sets total field" do
      completion = Completion.total(%Completion{}, 10)

      assert completion.total == 10
    end
  end

  describe "has_more/2" do
    test "sets hasMore field" do
      completion = Completion.has_more(%Completion{}, true)

      assert completion.hasMore == true
    end
  end

  describe "build/1" do
    test "builds with default empty values" do
      result = Completion.build(%Completion{})

      assert result == %{values: []}
    end

    test "includes total when set" do
      result = Completion.build(%Completion{values: ["a"], total: 1})

      assert result == %{values: ["a"], total: 1}
    end

    test "includes hasMore when set" do
      result = Completion.build(%Completion{values: ["a"], hasMore: true})

      assert result == %{values: ["a"], hasMore: true}
    end

    test "does not include total nor hasMore when nil" do
      result = Completion.build(%Completion{values: ["a"]})

      refute Map.has_key?(result, :total)
      refute Map.has_key?(result, :hasMore)
    end

    test "raises when values is not a list" do
      completion = struct(%Completion{}, values: "nope")

      assert_raise ArgumentError, "The 'values' field must be a list", fn ->
        Completion.build(completion)
      end
    end

    test "raises when a value is not a string" do
      completion = struct(%Completion{}, values: ["ok", 42])

      assert_raise ArgumentError,
                   "The 'values' field must be a list of strings, got: 42",
                   fn -> Completion.build(completion) end
    end

    test "raises when there are more than 100 values" do
      completion = struct(%Completion{}, values: Enum.map(1..101, &"v#{&1}"))

      assert_raise ArgumentError,
                   "The 'values' field must contain at most 100 items",
                   fn -> Completion.build(completion) end
    end

    test "raises when total is not a non-negative integer or nil" do
      completion = struct(%Completion{}, total: -1)

      assert_raise ArgumentError,
                   "The 'total' field must be a non-negative integer or nil",
                   fn -> Completion.build(completion) end
    end

    test "raises when hasMore is not a boolean or nil" do
      completion = struct(%Completion{}, hasMore: "yes")

      assert_raise ArgumentError, "The 'hasMore' field must be a boolean or nil", fn ->
        Completion.build(completion)
      end
    end
  end
end
