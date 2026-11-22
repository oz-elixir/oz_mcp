defmodule OzMcp.Handler.ReplyTest do
  use ExUnit.Case, async: true

  alias OzMcp.Context
  alias OzMcp.Handler.Reply
  alias OzMcp.Utils.Error

  defp context do
    %Context{rpc_id: "req-1"}
  end

  describe "success/3" do
    test "wraps the result in a rpc_success response with the id of the context" do
      assert Reply.success(context(), %{"a" => 1}, nil) ==
               {{:rpc_success, %{"jsonrpc" => "2.0", "id" => "req-1", "result" => %{"a" => 1}}},
                nil}
    end

    test "passes the stream back unchanged" do
      stream = %{marker: true}
      {{:rpc_success, _}, returned} = Reply.success(context(), %{}, stream)
      assert returned == stream
    end
  end

  describe "error/4 and error/5" do
    test "wraps the code and the message in a rpc_error response" do
      assert Reply.error(context(), -32601, "method not found", nil) ==
               {{:rpc_error,
                 %{
                   "jsonrpc" => "2.0",
                   "id" => "req-1",
                   "error" => %{"code" => -32601, "message" => "method not found"}
                 }}, nil}
    end

    test "error/5 puts the data in the error object" do
      data = %{"reason" => "timeout"}

      assert Reply.error(context(), -32603, "internal error", data, nil) ==
               {{:rpc_error,
                 %{
                   "jsonrpc" => "2.0",
                   "id" => "req-1",
                   "error" => %{
                     "code" => -32603,
                     "message" => "internal error",
                     "data" => data
                   }
                 }}, nil}
    end

    test "error/4 gives the same map as error/5 with nil data" do
      {{:rpc_error, without_data}, _} = Reply.error(context(), -32602, "bad", nil)
      {{:rpc_error, with_nil_data}, _} = Reply.error(context(), -32602, "bad", nil, nil)
      assert without_data == with_nil_data
      refute Map.has_key?(without_data["error"], "data")
    end
  end

  describe "invalid_params/3" do
    test "answers with the code -32602" do
      {{:rpc_error, response}, nil} = Reply.invalid_params(context(), "invalid cursor", nil)
      assert response["error"]["code"] == -32602
      assert response["error"]["message"] == "invalid cursor"
      assert response["id"] == "req-1"
    end
  end

  describe "internal/2" do
    test "answers with the standard internal error" do
      assert Reply.internal(context(), nil) ==
               {{:rpc_error,
                 %{
                   "jsonrpc" => "2.0",
                   "id" => "req-1",
                   "error" => %{"code" => -32603, "message" => "internal server error"}
                 }}, nil}
    end
  end

  describe "outcome/3" do
    test "maps {:ok, result} to a rpc_success response" do
      assert Reply.outcome(context(), {:ok, %{"b" => 2}}, nil) ==
               {{:rpc_success, %{"jsonrpc" => "2.0", "id" => "req-1", "result" => %{"b" => 2}}},
                nil}
    end

    test "maps {:error, err} to a rpc_error response with the fields of the error struct" do
      err = Error.new(-32002, "Resource not found", %{"uri" => "file:///a"})

      assert Reply.outcome(context(), {:error, err}, nil) ==
               {{:rpc_error,
                 %{
                   "jsonrpc" => "2.0",
                   "id" => "req-1",
                   "error" => %{
                     "code" => -32002,
                     "message" => "Resource not found",
                     "data" => %{"uri" => "file:///a"}
                   }
                 }}, nil}
    end

    test "maps an error struct without data to a rpc_error response with no data key" do
      err = Error.new(-32603, "callback failed")

      {{:rpc_error, response}, nil} = Reply.outcome(context(), {:error, err}, nil)
      refute Map.has_key?(response["error"], "data")
    end
  end
end
