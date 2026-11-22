defmodule OzMcp.Testing.SseTest do
  use ExUnit.Case, async: true

  alias OzMcp.Testing.Sse

  test "parses one event" do
    assert Sse.parse("", "id: 1\ndata: {\"a\":1}\n\n") ==
             {[%{id: "1", data: "{\"a\":1}"}], ""}
  end

  test "parses two events of one chunk" do
    assert Sse.parse("", "id: 1\ndata: one\n\nid: 2\ndata: two\n\n") ==
             {[%{id: "1", data: "one"}, %{id: "2", data: "two"}], ""}
  end

  test "keeps the end of an event for the next chunk" do
    assert {[], "id: 1\ndata: hel"} = Sse.parse("", "id: 1\ndata: hel")
    assert {[%{id: "1", data: "hello"}], ""} = Sse.parse("id: 1\ndata: hel", "lo\n\n")
  end

  test "skips a comment and a retry line" do
    assert Sse.parse("", ": heartbeat\nretry: 1000\ndata: text\n\n") ==
             {[%{id: nil, data: "text"}], ""}

    assert Sse.parse("", "retry: 1000\n\n") == {[], ""}
  end

  test "skips the priming event" do
    assert Sse.parse("", "id: abc:0\ndata: \n\n") == {[], ""}
  end

  test "joins a data of two lines" do
    assert Sse.parse("", "data: one\ndata: two\n\n") == {[%{id: nil, data: "one\ntwo"}], ""}
  end
end
