defmodule OzMcp.Utils.ErrorTest do
  use ExUnit.Case, async: true

  alias OzMcp.Utils.Error

  describe "invalid_params/2" do
    test "builds a -32602 error with the message" do
      assert Error.invalid_params("bad team") ==
               %Error{code: -32602, message: "bad team", data: nil}
    end

    test "keeps the data" do
      assert %Error{code: -32602, data: %{"team" => "ops"}} =
               Error.invalid_params("bad team", %{"team" => "ops"})
    end
  end

  describe "resource_not_found/1" do
    test "builds a -32002 error with the uri in the data" do
      assert Error.resource_not_found("file:///a.md") ==
               %Error{
                 code: -32002,
                 message: "resource not found",
                 data: %{"uri" => "file:///a.md"}
               }
    end
  end

  describe "internal_error/2" do
    test "has a default message" do
      assert Error.internal_error() == %Error{code: -32603, message: "internal error", data: nil}
    end

    test "keeps the message and the data" do
      assert Error.internal_error("boom", %{"step" => 2}) ==
               %Error{code: -32603, message: "boom", data: %{"step" => 2}}
    end

    test "rejects a data in place of the message" do
      assert_raise FunctionClauseError, fn -> Error.internal_error(%{"step" => 2}) end
    end
  end
end
