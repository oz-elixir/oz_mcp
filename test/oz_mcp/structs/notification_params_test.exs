defmodule OzMcp.Structs.NotificationParamsTest do
  use ExUnit.Case, async: true
  alias OzMcp.Structs.NotificationParams

  describe "struct defaults" do
    test "has correct defaults for all fields" do
      params = %NotificationParams{}

      assert params._meta == nil
    end
  end

  describe "_meta/2" do
    test "sets _meta field" do
      params = NotificationParams._meta(%NotificationParams{}, %{"progressToken" => 42})

      assert params._meta == %{"progressToken" => 42}
    end

    test "returns a struct" do
      params = NotificationParams._meta(%NotificationParams{}, %{"key" => "value"})

      assert %NotificationParams{} = params
    end
  end

  describe "build/1" do
    test "builds map with _meta when set" do
      params = %NotificationParams{_meta: %{"progressToken" => 42}}
      result = NotificationParams.build(params)

      assert result == %{"_meta" => %{"progressToken" => 42}}
    end

    test "raises when _meta is nil" do
      params = %NotificationParams{_meta: nil}

      assert_raise ArgumentError, "Meta fields is not defined, remove params declaration", fn ->
        NotificationParams.build(params)
      end
    end

    test "raises when _meta is empty map" do
      params = %NotificationParams{_meta: %{}}

      assert_raise ArgumentError, "Meta fields is not defined, remove params declaration", fn ->
        NotificationParams.build(params)
      end
    end

    test "builds with non-empty _meta map" do
      params = %NotificationParams{_meta: %{"key" => "value"}}
      result = NotificationParams.build(params)

      assert result == %{"_meta" => %{"key" => "value"}}
    end

    test "builds with multiple _meta entries" do
      params = %NotificationParams{_meta: %{"progressToken" => 1, "requestId" => "abc"}}
      result = NotificationParams.build(params)

      assert result == %{"_meta" => %{"progressToken" => 1, "requestId" => "abc"}}
    end
  end
end
