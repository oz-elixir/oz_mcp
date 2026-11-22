defmodule OzMcp.Structs.ToolChoiceTest do
  use ExUnit.Case, async: true
  alias OzMcp.Structs.ToolChoice

  test "builds each mode" do
    for mode <- [:auto, :required, :none] do
      assert ToolChoice.build(ToolChoice.mode(%ToolChoice{}, mode)) == %{mode: to_string(mode)}
    end

    assert ToolChoice.build(ToolChoice.mode(%ToolChoice{}, "required")) == %{mode: "required"}
  end

  test "no mode builds an empty map" do
    assert ToolChoice.build(%ToolChoice{}) == %{}
  end

  test "rejects an unknown mode" do
    assert_raise ArgumentError, ~r/'mode'/, fn ->
      ToolChoice.build(ToolChoice.mode(%ToolChoice{}, :any))
    end
  end
end
