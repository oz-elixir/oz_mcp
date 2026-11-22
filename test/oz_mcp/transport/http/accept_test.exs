defmodule OzMcp.Transport.Http.AcceptTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias OzMcp.Transport.Http.Accept

  defp conn_with_accept(value) do
    case value do
      [] ->
        conn(:get, "/")

      values when is_list(values) ->
        conn(:get, "/") |> Map.put(:req_headers, for(v <- values, do: {"accept", v}))

      value ->
        conn(:get, "/") |> put_req_header("accept", value)
    end
  end

  describe "ranges/1" do
    test "parses one media range" do
      ranges = Accept.ranges(conn_with_accept("application/json"))

      assert [%Accept{type: "application", subtype: "json", q: 1.0}] = ranges
    end

    test "parses several media ranges of one header" do
      ranges = Accept.ranges(conn_with_accept("application/json, text/event-stream;q=0.5"))

      assert [%{type: "application", subtype: "json", q: 1.0}, %{q: 0.5}] = ranges
    end

    test "reads all the accept headers of the request" do
      ranges = Accept.ranges(conn_with_accept(["application/json", "text/event-stream"]))

      assert [%{subtype: "json"}, %{subtype: "event-stream"}] = ranges
    end

    test "reads the type wildcard" do
      assert [%{type: "*", subtype: "*"}] = Accept.ranges(conn_with_accept("*/*"))

      assert [%{type: "application", subtype: "*"}] =
               Accept.ranges(conn_with_accept("application/*"))

      assert [%{type: "*", subtype: "json"}] = Accept.ranges(conn_with_accept("*/json"))
    end

    test "the compare is case insensitive" do
      assert [%{type: "text", subtype: "event-stream"}] =
               Accept.ranges(conn_with_accept("TEXT/Event-Stream"))
    end

    test "spaces around the media type and the parameters are trimmed" do
      assert [%{type: "text", subtype: "event-stream", q: 0.25}] =
               Accept.ranges(conn_with_accept("  text/event-stream ; q = 0.25 "))
    end

    test "the other parameters of a range are ignored" do
      assert [%{type: "text", subtype: "event-stream", q: 1.0}] =
               Accept.ranges(conn_with_accept("text/event-stream;level=2;foo=bar"))
    end

    test "drops an unparsable range" do
      assert [] = Accept.ranges(conn_with_accept("garbage"))
      assert [] = Accept.ranges(conn_with_accept("application"))
      assert [] = Accept.ranges(conn_with_accept("/json"))
      assert [] = Accept.ranges(conn_with_accept("text/"))
    end

    test "drops a range with a q above one, below zero or not a number" do
      assert [] = Accept.ranges(conn_with_accept("text/event-stream;q=1.5"))
      assert [] = Accept.ranges(conn_with_accept("text/event-stream;q=-0.1"))
      assert [] = Accept.ranges(conn_with_accept("text/event-stream;q=abc"))
      assert [] = Accept.ranges(conn_with_accept("text/event-stream;q="))
      assert [] = Accept.ranges(conn_with_accept("text/event-stream;q=0.5junk"))
    end

    test "a q of zero is kept" do
      assert [%{q: q}] = Accept.ranges(conn_with_accept("text/event-stream;q=0"))
      assert q == 0
    end

    test "an empty header gives no range" do
      assert [] = Accept.ranges(conn_with_accept(""))
    end

    test "a request without an accept header gives no range" do
      assert [] = Accept.ranges(conn_with_accept([]))
    end

    test "keeps the other ranges when one range is unparsable" do
      ranges = Accept.ranges(conn_with_accept("garbage, application/json"))

      assert [%{type: "application", subtype: "json"}] = ranges
    end
  end

  describe "accepts?/2" do
    test "an exact media type matches" do
      assert Accept.accepts?(
               Accept.ranges(conn_with_accept("application/json")),
               "application/json"
             )
    end

    test "a different media type does not match" do
      refute Accept.accepts?(Accept.ranges(conn_with_accept("application/json")), "text/html")
    end

    test "the type wildcard matches every subtype" do
      assert Accept.accepts?(Accept.ranges(conn_with_accept("application/*")), "application/json")

      refute Accept.accepts?(
               Accept.ranges(conn_with_accept("application/*")),
               "text/event-stream"
             )
    end

    test "the subtype wildcard matches every type" do
      assert Accept.accepts?(
               Accept.ranges(conn_with_accept("*/event-stream")),
               "text/event-stream"
             )

      refute Accept.accepts?(
               Accept.ranges(conn_with_accept("*/event-stream")),
               "application/json"
             )
    end

    test "the full wildcard matches every media type" do
      ranges = Accept.ranges(conn_with_accept("*/*"))

      assert Accept.accepts?(ranges, "application/json")
      assert Accept.accepts?(ranges, "text/event-stream")
    end

    test "a range with a q of zero matches nothing" do
      ranges = Accept.ranges(conn_with_accept("text/event-stream;q=0, */*;Q=0"))

      refute Accept.accepts?(ranges, "text/event-stream")
      refute Accept.accepts?(ranges, "application/json")
    end

    test "the most specific range decides over a wildcard" do
      ranges = Accept.ranges(conn_with_accept("text/event-stream;q=0, */*"))

      refute Accept.accepts?(ranges, "text/event-stream")
      assert Accept.accepts?(ranges, "application/json")

      ranges = Accept.ranges(conn_with_accept("*/*;q=0, text/event-stream"))

      assert Accept.accepts?(ranges, "text/event-stream")
      refute Accept.accepts?(ranges, "application/json")
    end

    test "an exact range beats a type wildcard" do
      ranges = Accept.ranges(conn_with_accept("text/*;q=0, text/event-stream;q=0.5"))

      assert Accept.accepts?(ranges, "text/event-stream")
    end

    test "ranges of the same specificity: the highest q wins" do
      ranges = Accept.ranges(conn_with_accept("text/event-stream;q=0, text/event-stream"))

      assert Accept.accepts?(ranges, "text/event-stream")
    end

    test "a q below one still matches" do
      assert Accept.accepts?(
               Accept.ranges(conn_with_accept("text/event-stream;q=0.01")),
               "text/event-stream"
             )
    end

    test "no range matches nothing" do
      refute Accept.accepts?([], "application/json")
    end
  end
end
