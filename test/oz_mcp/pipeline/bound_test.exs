defmodule OzMcp.Pipeline.BoundTest do
  use ExUnit.Case, async: true

  alias OzMcp.Pipeline.Bound

  test "the kind is required" do
    assert_raise ArgumentError, fn -> struct!(Bound) end
  end

  test "the defaults of the fields" do
    bound = %Bound{kind: :none}

    assert bound.name == nil
    assert bound.module == nil
    assert bound.entity == nil
    assert bound.params == %{}
    assert bound.arguments == %{}
    assert bound.uri_params == nil
    assert bound.input_errors == nil
    assert bound.required_scopes == []
    assert bound.task == nil
    assert bound.completion == nil
  end

  test "a bound of each kind is a struct with the kind set" do
    for kind <- [:tool, :resource, :template, :prompt, :completion, :task, :none] do
      assert %Bound{kind: ^kind} = %Bound{kind: kind}
    end
  end
end
