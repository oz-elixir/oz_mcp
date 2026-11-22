#
# The protocol data: the methods of the client and the shape of a
# decoded message, as the telemetry of the transports reports it.
#
# The list of the methods comes from `OzMcp.Method.Table`: the test of
# the table checks that every row points to a function that the handler
# runs. A method that the table does not hold would be reported by the
# telemetry as `:unknown`.
#
defmodule OzMcp.ProtocolTest do
  use ExUnit.Case, async: true

  alias OzMcp.Protocol

  # -------------------------------------------------------------------
  # The methods of the client
  # -------------------------------------------------------------------

  test "each row of the table points to a function that exists" do
    for %OzMcp.Method{name: name, run: {module, fun}} <- OzMcp.Method.Table.all() do
      Code.ensure_loaded!(module)
      assert function_exported?(module, fun, 2), "#{name} -> #{inspect(module)}.#{fun}/2"
    end
  end

  test "client_methods/0 holds no duplicate" do
    methods = Protocol.client_methods()
    assert Enum.uniq(methods) == methods
  end

  test "client_methods/0 holds notifications/tasks/status" do
    assert "notifications/tasks/status" in Protocol.client_methods()
  end

  # -------------------------------------------------------------------
  # The method of a message
  # -------------------------------------------------------------------

  test "bound_method/1 gives a method that the server serves" do
    assert Protocol.bound_method(%{"method" => "ping"}) == "ping"
    assert Protocol.bound_method(%{"method" => "tools/call"}) == "tools/call"

    assert Protocol.bound_method(%{"method" => "notifications/tasks/status"}) ==
             "notifications/tasks/status"
  end

  test "bound_method/1 gives :unknown for a method that the server does not serve" do
    assert Protocol.bound_method(%{"method" => "x/y"}) == :unknown
    assert Protocol.bound_method(%{"method" => ""}) == :unknown
  end

  test "bound_method/1 gives :unknown for a method that is not a string" do
    assert Protocol.bound_method(%{"method" => 42}) == :unknown
  end

  test "bound_method/1 gives nil when the message has no method" do
    assert Protocol.bound_method(%{"id" => 1, "result" => %{}}) == nil
    assert Protocol.bound_method(%{}) == nil
    assert Protocol.bound_method(nil) == nil
  end
end
