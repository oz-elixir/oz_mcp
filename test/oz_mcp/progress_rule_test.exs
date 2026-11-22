defmodule OzMcp.ProgressRuleTest do
  use ExUnit.Case, async: true

  alias OzMcp.ProgressRule

  describe "check/2" do
    test "a nil last value passes" do
      assert {:ok, 1} = ProgressRule.check(nil, 1)
      assert {:ok, 1.5} = ProgressRule.check(nil, 1.5)
    end

    test "a larger value passes" do
      assert {:ok, 2} = ProgressRule.check(1, 2)
    end

    test "an equal value drops" do
      assert :drop = ProgressRule.check(1, 1)
      assert :drop = ProgressRule.check(1.5, 1.5)
    end

    test "a smaller value drops" do
      assert :drop = ProgressRule.check(2, 1)
    end

    test "a float equal to an integer drops" do
      assert :drop = ProgressRule.check(1, 1.0)
    end

    test "a larger float passes" do
      assert {:ok, 2} = ProgressRule.check(1.5, 2)
    end

    test "a non-number passes and keeps the last number" do
      assert {:ok, 5} = ProgressRule.check(5, "ten")
      assert {:ok, nil} = ProgressRule.check(nil, :bad)
    end
  end

  describe "check_loose/3" do
    test "a new token is stored" do
      loose = ProgressRule.new_loose()

      assert {:ok, {values, _order}} = ProgressRule.check_loose(loose, "t", 1)
      assert values == %{"t" => 1}
    end

    test "a known token is checked" do
      {:ok, loose} = ProgressRule.check_loose(ProgressRule.new_loose(), "t", 1)

      assert {:ok, {values, _order} = loose} = ProgressRule.check_loose(loose, "t", 2)
      assert values == %{"t" => 2}

      assert {:drop, ^loose} = ProgressRule.check_loose(loose, "t", 2)
      assert {:drop, ^loose} = ProgressRule.check_loose(loose, "t", 1)
    end

    test "a non-number for a new token is not stored" do
      loose = ProgressRule.new_loose()
      assert {:ok, {values, _order}} = ProgressRule.check_loose(loose, "t", "nope")
      assert values == %{}
    end

    test "the oldest token is evicted when the map is full" do
      loose =
        Enum.reduce(1..256, ProgressRule.new_loose(), fn i, acc ->
          {:ok, loose} = ProgressRule.check_loose(acc, i, i)
          loose
        end)

      {values, _order} = loose
      assert map_size(values) == 256
      assert values[1] == 1

      assert {:ok, loose} = ProgressRule.check_loose(loose, 257, 257)
      {values, _order} = loose
      assert map_size(values) == 256
      refute Map.has_key?(values, 1)
      assert values[257] == 257

      assert {:ok, {values, _order}} = ProgressRule.check_loose(loose, 1, 1)
      assert values[1] == 1
      assert map_size(values) == 256
    end
  end
end
