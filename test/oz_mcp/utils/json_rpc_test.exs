defmodule OzMcp.Utils.JsonRpcTest do
  use ExUnit.Case, async: true

  describe "success/2" do
    test "with id returns map with jsonrpc, id and result" do
      assert OzMcp.Utils.JsonRpc.success(1, %{"key" => "value"}) == %{
               "jsonrpc" => "2.0",
               "id" => 1,
               "result" => %{"key" => "value"}
             }
    end

    test "with nil id omits the id member" do
      assert OzMcp.Utils.JsonRpc.success(nil, %{}) == %{
               "jsonrpc" => "2.0",
               "result" => %{}
             }
    end

    test "with string id" do
      assert OzMcp.Utils.JsonRpc.success("abc", :ok) == %{
               "jsonrpc" => "2.0",
               "id" => "abc",
               "result" => :ok
             }
    end
  end

  describe "error/3" do
    test "with id returns map with jsonrpc, id and error" do
      assert OzMcp.Utils.JsonRpc.error(1, -32600, "invalid request") == %{
               "jsonrpc" => "2.0",
               "id" => 1,
               "error" => %{"code" => -32600, "message" => "invalid request"}
             }
    end

    test "with nil id omits the id member" do
      assert OzMcp.Utils.JsonRpc.error(nil, -32601, "method not found") == %{
               "jsonrpc" => "2.0",
               "error" => %{"code" => -32601, "message" => "method not found"}
             }
    end
  end

  describe "error/4" do
    test "with id and data returns map with jsonrpc, id, error and data" do
      assert OzMcp.Utils.JsonRpc.error(1, -32602, "Bad argument", [
               "missing required argument: 'location'"
             ]) == %{
               "jsonrpc" => "2.0",
               "id" => 1,
               "error" => %{
                 "code" => -32602,
                 "message" => "Bad argument",
                 "data" => ["missing required argument: 'location'"]
               }
             }
    end

    test "with nil id and data omits the id member and carries data" do
      assert OzMcp.Utils.JsonRpc.error(nil, -32602, "Bad argument", %{"details" => "info"}) == %{
               "jsonrpc" => "2.0",
               "error" => %{
                 "code" => -32602,
                 "message" => "Bad argument",
                 "data" => %{"details" => "info"}
               }
             }
    end

    test "with nil data omits data field" do
      assert OzMcp.Utils.JsonRpc.error(1, -32600, "invalid request", nil) == %{
               "jsonrpc" => "2.0",
               "id" => 1,
               "error" => %{"code" => -32600, "message" => "invalid request"}
             }
    end
  end

  describe "notification/2" do
    test "returns map with jsonrpc, method and params" do
      assert OzMcp.Utils.JsonRpc.notification("test/method", %{"foo" => "bar"}) == %{
               "jsonrpc" => "2.0",
               "method" => "test/method",
               "params" => %{"foo" => "bar"}
             }
    end

    test "omits params field when not provided" do
      assert OzMcp.Utils.JsonRpc.notification("test/method") == %{
               "jsonrpc" => "2.0",
               "method" => "test/method"
             }
    end

    test "with explicit nil params omits params field" do
      assert OzMcp.Utils.JsonRpc.notification("test/method", nil) == %{
               "jsonrpc" => "2.0",
               "method" => "test/method"
             }
    end
  end

  describe "request/3" do
    test "builds a request without params" do
      assert OzMcp.Utils.JsonRpc.request("abc", "ping") ==
               %{"jsonrpc" => "2.0", "id" => "abc", "method" => "ping"}
    end

    test "builds a request with params and an integer id" do
      assert OzMcp.Utils.JsonRpc.request(7, "roots/list", %{"a" => 1}) ==
               %{"jsonrpc" => "2.0", "id" => 7, "method" => "roots/list", "params" => %{"a" => 1}}
    end

    test "refuses an id that is not a string or an integer" do
      assert_raise FunctionClauseError, fn -> OzMcp.Utils.JsonRpc.request(nil, "ping") end
      assert_raise FunctionClauseError, fn -> OzMcp.Utils.JsonRpc.request(1.5, "ping") end
    end
  end

  describe "kind/1" do
    test "a map with a method and a string id is a request" do
      assert OzMcp.Utils.JsonRpc.kind(%{"method" => "ping", "id" => "abc"}) == :request
    end

    test "a map with a method and an integer id is a request" do
      assert OzMcp.Utils.JsonRpc.kind(%{"method" => "ping", "id" => 1}) == :request
      assert OzMcp.Utils.JsonRpc.kind(%{"method" => "ping", "id" => 0}) == :request
      assert OzMcp.Utils.JsonRpc.kind(%{"method" => "ping", "id" => -5}) == :request
    end

    test "a map with a method and no id is a notification" do
      assert OzMcp.Utils.JsonRpc.kind(%{"method" => "notifications/initialized"}) ==
               :notification
    end

    test "a map with a method and a null id is invalid" do
      assert OzMcp.Utils.JsonRpc.kind(%{"method" => "ping", "id" => nil}) == :invalid
    end

    test "a map with a method and a boolean id is invalid" do
      assert OzMcp.Utils.JsonRpc.kind(%{"method" => "ping", "id" => true}) == :invalid
      assert OzMcp.Utils.JsonRpc.kind(%{"method" => "ping", "id" => false}) == :invalid
    end

    test "a map with a method and a float id is invalid" do
      assert OzMcp.Utils.JsonRpc.kind(%{"method" => "ping", "id" => 1.5}) == :invalid
    end

    test "a map with a method and an array or object id is invalid" do
      assert OzMcp.Utils.JsonRpc.kind(%{"method" => "ping", "id" => []}) == :invalid
      assert OzMcp.Utils.JsonRpc.kind(%{"method" => "ping", "id" => %{}}) == :invalid
    end

    test "a map with a result and no method is a response" do
      assert OzMcp.Utils.JsonRpc.kind(%{"result" => %{"roots" => []}}) == :response
      assert OzMcp.Utils.JsonRpc.kind(%{"id" => 1, "result" => %{}}) == :response
    end

    test "a map with an error and no method is a response" do
      assert OzMcp.Utils.JsonRpc.kind(%{"error" => %{"code" => -32601, "message" => "x"}}) ==
               :response

      assert OzMcp.Utils.JsonRpc.kind(%{"id" => "abc", "error" => %{}}) == :response
    end

    test "a map with both a result and an error is a response" do
      assert OzMcp.Utils.JsonRpc.kind(%{"result" => %{}, "error" => %{}}) == :response
    end

    test "an empty map is invalid" do
      assert OzMcp.Utils.JsonRpc.kind(%{}) == :invalid
    end

    test "a map with no method, no result and no error is invalid" do
      assert OzMcp.Utils.JsonRpc.kind(%{"id" => 1}) == :invalid
      assert OzMcp.Utils.JsonRpc.kind(%{"jsonrpc" => "2.0"}) == :invalid
    end

    test "a list is invalid" do
      assert OzMcp.Utils.JsonRpc.kind([]) == :invalid
      assert OzMcp.Utils.JsonRpc.kind([%{"method" => "ping"}]) == :invalid
    end

    test "a scalar is invalid" do
      assert OzMcp.Utils.JsonRpc.kind("ping") == :invalid
      assert OzMcp.Utils.JsonRpc.kind(42) == :invalid
      assert OzMcp.Utils.JsonRpc.kind(true) == :invalid
    end

    test "nil is invalid" do
      assert OzMcp.Utils.JsonRpc.kind(nil) == :invalid
    end
  end
end
