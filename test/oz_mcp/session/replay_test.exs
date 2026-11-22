defmodule OzMcp.Session.ReplayTest do
  use ExUnit.Case, async: true

  alias OzMcp.Session.Replay

  @log [
    {"g.A:1", ~s({"n":1})},
    {"s1:1", ~s({"p":1})},
    {"g.A:2", ~s({"n":2})},
    {"s1:2", ~s({"p":2})},
    {"s2:1", ~s({"q":1})}
  ]

  test "target gives fresh for nil" do
    assert :fresh = Replay.target(nil)
  end

  test "target gives a post tuple for a POST stream id" do
    assert {:post, "s1", 3} = Replay.target("s1:3")
    assert {:post, "s1", 0} = Replay.target("s1:0")
  end

  test "target gives a get tuple for the id of a GET stream" do
    assert {:get, "g.A", 3} = Replay.target("g.A:3")
    assert {:get, "g.A", 0} = Replay.target("g.A:0")
  end

  test "target gives invalid for any other text" do
    assert :invalid = Replay.target(":3")
    assert :invalid = Replay.target("s1:abc")
    assert :invalid = Replay.target("nocolon")
  end

  test "after_stream gives the events of the stream after the sequence number" do
    log = [{"s1:1", ~s({"p":1})}, {"s1:2", ~s({"p":2})}, {"s1:3", ~s({"p":3})}]

    assert %{events: [{"s1:2", _}, {"s1:3", _}], gap: false} =
             Replay.after_stream(log, "s1", 1)
  end

  test "after_stream finds a gap when the first kept event is above seq + 1" do
    log = [{"s1:4", ~s({"p":4})}, {"s1:5", ~s({"p":5})}]

    assert %{events: [{"s1:4", _}, {"s1:5", _}], gap: true} =
             Replay.after_stream(log, "s1", 1)
  end

  test "after_stream finds no gap when the first kept event is seq + 1" do
    log = [{"s1:2", ~s({"p":2})}, {"s1:4", ~s({"p":4})}]

    assert %{gap: false} = Replay.after_stream(log, "s1", 1)
  end

  test "after_stream ignores the events of the other streams" do
    log = [
      {"s1:1", ~s({"p":1})},
      {"s2:1", ~s({"q":1})},
      {"g.A:1", ~s({"n":1})},
      {"s1:2", ~s({"p":2})}
    ]

    assert %{events: [{"s1:2", _}], gap: false} = Replay.after_stream(log, "s1", 1)
  end

  test "after_stream gives the events of a GET stream after the sequence number" do
    log = [{"g.A:1", ~s({"n":1})}, {"s1:1", ~s({"p":1})}, {"g.A:2", ~s({"n":2})}]

    assert %{events: [{"g.A:2", _}], gap: false} = Replay.after_stream(log, "g.A", 1)

    assert %{events: [{"g.A:1", _}, {"g.A:2", _}], gap: false} =
             Replay.after_stream(log, "g.A", 0)
  end

  test "after_stream finds the response of the request" do
    log = [{"s1:1", ~s({"jsonrpc":"2.0","id":5,"result":{}})}]

    assert %{response: true} = Replay.after_stream(log, "s1", 0)
  end

  test "after_stream finds an error response as the response of the request" do
    log = [{"s1:1", ~s({"jsonrpc":"2.0","id":7,"error":{"code":-32603,"message":"x"}})}]

    assert %{response: true} = Replay.after_stream(log, "s1", 0)
  end

  test "after_stream does not take a request for the response" do
    log = [{"s1:1", ~s({"jsonrpc":"2.0","id":1,"method":"ping"})}]

    assert %{response: false} = Replay.after_stream(log, "s1", 0)
  end

  test "after_stream does not take a notification for the response" do
    log = [{"s1:1", ~s({"jsonrpc":"2.0","method":"cancel"})}]

    assert %{response: false} = Replay.after_stream(log, "s1", 0)
  end

  test "after_stream gives no response for data that does not decode" do
    log = [{"s1:1", "{not json"}]

    assert %{response: false} = Replay.after_stream(log, "s1", 0)
  end

  test "after_stream with no event after the sequence number gives an empty replay" do
    assert %{events: [], gap: false, response: false} = Replay.after_stream(@log, "s1", 2)
    assert %{events: [], gap: false, response: false} = Replay.after_stream([], "s1", 0)
    assert %{events: [], gap: false, response: false} = Replay.after_stream(@log, "g.A", 2)
  end
end
