defmodule OzMcp.Structs.CompleteResultTest do
  use ExUnit.Case, async: true
  alias OzMcp.Structs.{CompleteResult, Completion}

  describe "struct defaults" do
    test "has correct defaults for all fields" do
      result = %CompleteResult{}

      assert result.completion == nil
      assert result._meta == nil
    end
  end

  describe "completion/2" do
    test "sets completion field" do
      completion = %Completion{values: ["a"]}
      result = CompleteResult.completion(%CompleteResult{}, completion)

      assert result.completion == completion
    end
  end

  describe "_meta/2" do
    test "sets _meta field" do
      result = CompleteResult._meta(%CompleteResult{}, %{"key" => "value"})

      assert result._meta == %{"key" => "value"}
    end
  end

  describe "build/1" do
    test "builds a Completion struct" do
      completion = %Completion{values: ["python"], total: 1, hasMore: false}
      result = CompleteResult.build(%CompleteResult{completion: completion})

      assert result == %{completion: %{values: ["python"], total: 1, hasMore: false}}
    end

    test "passes a plain map completion through" do
      result =
        CompleteResult.build(%CompleteResult{
          completion: %{"values" => ["python"]}
        })

      assert result == %{completion: %{"values" => ["python"]}}
    end

    test "raises when a plain map completion has more than 100 values" do
      values = Enum.map(1..101, &Integer.to_string/1)

      assert_raise ArgumentError, "The 'values' field must contain at most 100 items", fn ->
        CompleteResult.build(%CompleteResult{completion: %{"values" => values}})
      end
    end

    test "raises when a plain map completion has a value that is not a string" do
      assert_raise ArgumentError, "The 'values' field must be a list of strings, got: 1", fn ->
        CompleteResult.build(%CompleteResult{completion: %{"values" => ["a", 1]}})
      end
    end

    test "raises when a plain map completion has no values list" do
      for completion <- [%{}, %{"values" => "a"}, %{values: 1}] do
        assert_raise ArgumentError, "The 'values' field must be a list", fn ->
          CompleteResult.build(%CompleteResult{completion: completion})
        end
      end
    end

    test "raises when a plain map completion has a total that is not a non-negative integer" do
      for total <- ["x", -1, 1.5, true] do
        completion = %{"values" => ["a"], "total" => total}

        assert_raise ArgumentError,
                     "The 'total' field must be a non-negative integer or nil",
                     fn ->
                       CompleteResult.build(%CompleteResult{completion: completion})
                     end
      end
    end

    test "raises when a plain map completion has a hasMore that is not a boolean" do
      completion = %{"values" => ["a"], "hasMore" => "yes"}

      assert_raise ArgumentError, "The 'hasMore' field must be a boolean or nil", fn ->
        CompleteResult.build(%CompleteResult{completion: completion})
      end
    end

    test "accepts a plain map completion with total and hasMore" do
      completion = %{"values" => ["a"], "total" => 2, "hasMore" => true}

      assert %{completion: ^completion} =
               CompleteResult.build(%CompleteResult{completion: completion})
    end

    test "accepts a plain map completion with atom keys" do
      result = CompleteResult.build(%CompleteResult{completion: %{values: ["a"]}})

      assert result == %{completion: %{values: ["a"]}}
    end

    test "includes _meta when set" do
      completion = %Completion{values: ["a"]}

      result =
        %CompleteResult{completion: completion, _meta: %{"progressToken" => 1}}
        |> CompleteResult.build()

      assert result[:_meta] == %{"progressToken" => 1}
    end

    test "does not include _meta when nil" do
      result = CompleteResult.build(%CompleteResult{completion: %Completion{}})

      refute Map.has_key?(result, :_meta)
    end

    test "raises when completion is nil" do
      assert_raise ArgumentError,
                   "The 'completion' field is required and must be a OzMcp.Structs.Completion struct or a map",
                   fn -> CompleteResult.build(%CompleteResult{}) end
    end

    test "raises when _meta is not a map or nil" do
      completion = %Completion{values: ["a"]}

      assert_raise ArgumentError, "The '_meta' field must be a map or nil", fn ->
        CompleteResult.build(%CompleteResult{completion: completion, _meta: "nope"})
      end
    end
  end
end
