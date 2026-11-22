defmodule OzMcp.Stream.SseTest do
  use ExUnit.Case, async: true

  describe "make/3" do
    test "with binary data" do
      event = OzMcp.Stream.Sse.make("id-1", "message", "hello")
      assert %OzMcp.Stream.Sse{id: "id-1", event: "message", data: "hello", retry: nil} = event
    end
  end

  describe "encode/1" do
    test "encodes full event" do
      event = %OzMcp.Stream.Sse{id: "42", event: "message", data: "hello", retry: 1000}
      encoded = OzMcp.Stream.Sse.encode(event)
      assert encoded == "id: 42\nevent: message\ndata: hello\nretry: 1000\n\n"
    end

    test "encodes event without id" do
      event = %OzMcp.Stream.Sse{id: nil, event: "message", data: "hello", retry: nil}
      encoded = OzMcp.Stream.Sse.encode(event)
      assert encoded == "event: message\ndata: hello\n\n"
    end

    test "encodes event with empty string fields" do
      event = %OzMcp.Stream.Sse{id: "", event: "", data: "hello", retry: ""}
      encoded = OzMcp.Stream.Sse.encode(event)
      assert encoded == "data: hello\n\n"
    end

    test "encodes minimal event with only data" do
      event = %OzMcp.Stream.Sse{id: nil, event: nil, data: "text", retry: nil}
      encoded = OzMcp.Stream.Sse.encode(event)
      assert encoded == "data: text\n\n"
    end
  end

  describe "priming/1" do
    test "is an event id with an empty data field" do
      assert OzMcp.Stream.Sse.priming("abc:0") == "id: abc:0\ndata: \n\n"
    end
  end
end
