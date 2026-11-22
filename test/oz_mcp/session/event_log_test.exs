defmodule OzMcp.Session.EventLogTest do
  use ExUnit.Case, async: true

  alias OzMcp.Session.EventLog
  alias Support.Helpers.EventLogProbe

  defp ids(events), do: Enum.map(events, &elem(&1, 0))

  test "returns all events when there is no last id" do
    log =
      EventLog.new(10, 1000)
      |> EventLog.append("s", {"1", "a"})
      |> EventLog.append("s", {"2", "b"})

    assert {:ok, events} = EventLogProbe.after_id(log, "s", nil)
    assert ids(events) == ["1", "2"]
  end

  test "returns the events after a known id" do
    log =
      EventLog.new(10, 1000)
      |> EventLog.append("s", {"1", "a"})
      |> EventLog.append("s", {"2", "b"})
      |> EventLog.append("s", {"3", "c"})

    assert {:ok, [{"3", "c"}]} = EventLogProbe.after_id(log, "s", "2")
    assert {:ok, []} = EventLogProbe.after_id(log, "s", "3")
  end

  test "gives :gap for an unknown stream or an unknown id" do
    log = EventLog.new(10, 1000) |> EventLog.append("s", {"1", "a"})

    assert EventLogProbe.after_id(log, "other", nil) == :gap
    assert EventLogProbe.after_id(log, "s", "zzz") == :gap
  end

  test "the event limit drops the oldest event" do
    log =
      Enum.reduce(1..5, EventLog.new(3, 1000), fn n, acc ->
        EventLog.append(acc, "s", {"#{n}", "x"})
      end)

    assert {:ok, events} = EventLogProbe.after_id(log, "s", nil)
    assert ids(events) == ["3", "4", "5"]
    assert EventLogProbe.after_id(log, "s", "1") == :gap
  end

  test "the byte limit drops the oldest events" do
    log =
      Enum.reduce(1..5, EventLog.new(100, 10), fn n, acc ->
        EventLog.append(acc, "s", {"#{n}", "1234"})
      end)

    assert {:ok, events} = EventLogProbe.after_id(log, "s", nil)
    assert ids(events) == ["4", "5"]
    assert EventLogProbe.size(log, "s") == {2, 8}
  end

  test "keeps the newest event when it alone is over the byte limit" do
    log =
      EventLog.new(100, 3)
      |> EventLog.append("s", {"1", "ab"})
      |> EventLog.append("s", {"2", "abcdefgh"})

    assert {:ok, events} = EventLogProbe.after_id(log, "s", nil)
    assert ids(events) == ["2"]
  end

  test "counts the bytes of iodata" do
    log = EventLog.new(100, 1000) |> EventLog.append("s", {"1", ["ab", ["cd"], "e"]})
    assert EventLogProbe.size(log, "s") == {1, 5}
  end

  test "the streams have separate logs" do
    log =
      EventLog.new(1, 1000)
      |> EventLog.append("a", {"1", "x"})
      |> EventLog.append("b", {"1", "y"})

    assert {:ok, [{"1", "x"}]} = EventLogProbe.after_id(log, "a", nil)
    assert {:ok, [{"1", "y"}]} = EventLogProbe.after_id(log, "b", nil)
    assert EventLogProbe.size(log, "none") == {0, 0}
  end

  test "drop/2 removes the ring and its bytes" do
    log =
      EventLog.new(10, 1000)
      |> EventLog.append("s", {"s:1", "abc"})
      |> EventLog.append("g.A", {"g.A:1", "de"})

    log = EventLog.drop(log, "s")

    assert EventLog.streams(log) == ["g.A"]
    assert EventLogProbe.total_bytes(log) == 2
    assert EventLogProbe.after_id(log, "s", nil) == :gap
  end

  test "drop/2 of an unknown stream does nothing" do
    log = EventLog.new(10, 1000)
    assert EventLog.drop(log, "none") == log
  end

  test "the total follows the trim of the event limit" do
    log =
      Enum.reduce(1..5, EventLog.new(2, 1000), fn n, acc ->
        EventLog.append(acc, "s", {"s:#{n}", "xx"})
      end)

    assert EventLogProbe.total_bytes(log) == 4
  end

  test "the budget evicts the ring with the oldest newest event first" do
    log =
      EventLog.new(10, 4, 10)
      |> EventLog.append("a", {"a:1", "1234"})
      |> EventLog.append("b", {"b:1", "1234"})
      |> EventLog.append("c", {"c:1", "1234"})

    assert MapSet.new(EventLog.streams(log)) == MapSet.new(["b", "c"])
    assert EventLogProbe.total_bytes(log) == 8
  end

  test "one append can evict several rings, the oldest first" do
    log =
      EventLog.new(10, 8, 8)
      |> EventLog.append("a", {"a:1", "12"})
      |> EventLog.append("b", {"b:1", "12"})
      |> EventLog.append("c", {"c:1", "12"})
      |> EventLog.append("d", {"d:1", "12345678"})

    assert EventLog.streams(log) == ["d"]
    assert EventLogProbe.total_bytes(log) == 8
  end

  test "a new event in an old ring makes it the newest" do
    log =
      EventLog.new(10, 8, 10)
      |> EventLog.append("a", {"a:1", "12"})
      |> EventLog.append("b", {"b:1", "1234"})
      |> EventLog.append("a", {"a:2", "12"})
      |> EventLog.append("c", {"c:1", "1234"})

    assert MapSet.new(EventLog.streams(log)) == MapSet.new(["a", "c"])
  end

  test "the budget evicts the ring of a GET stream; the ring that got the append stays" do
    log =
      EventLog.new(10, 4, 6)
      |> EventLog.append("g.A", {"g.A:1", "1234"})
      |> EventLog.append("a", {"a:1", "1234"})

    assert EventLog.streams(log) == ["a"]
    assert EventLogProbe.total_bytes(log) == 4
  end

  test "a ring that the budget evicted shows a gap after a new append" do
    log =
      EventLog.new(10, 4, 5)
      |> EventLog.append("a", {"a:1", "1234"})
      |> EventLog.append("b", {"b:1", "1234"})
      |> EventLog.append("a", {"a:2", "1234"})

    assert %{gap: true, events: [{"a:2", _}]} =
             OzMcp.Session.Replay.after_stream(EventLog.events(log, "a"), "a", 0)
  end

  test "the total is the sum of the bytes of the rings after appends and drops" do
    log =
      EventLog.new(10, 1000, 100)
      |> EventLog.append("a", {"a:1", "123"})
      |> EventLog.append("b", {"b:1", "12"})
      |> EventLog.append("g.A", {"g.A:1", "1"})
      |> EventLog.drop("a")

    sum =
      log.streams
      |> Map.values()
      |> Enum.map(&elem(&1, 1))
      |> Enum.sum()

    assert EventLogProbe.total_bytes(log) == sum
  end

  describe "the cap on the number of rings" do
    test "four appends to four streams with a cap of three leave three rings" do
      log =
        EventLog.new(10, 1000, nil, 3)
        |> EventLog.append("a", {"a:1", "1"})
        |> EventLog.append("b", {"b:1", "1"})
        |> EventLog.append("c", {"c:1", "1"})
        |> EventLog.append("d", {"d:1", "1"})

      assert MapSet.new(EventLog.streams(log)) == MapSet.new(["b", "c", "d"])
      assert EventLogProbe.after_id(log, "a", nil) == :gap
    end

    test "the ring of the current stream always stays" do
      log =
        EventLog.new(10, 1000, nil, 2)
        |> EventLog.append("a", {"a:1", "1"})
        |> EventLog.append("b", {"b:1", "1"})
        |> EventLog.append("a", {"a:2", "1"})
        |> EventLog.append("c", {"c:1", "1"})

      # "a" is the current stream of the last append: "b" holds the oldest
      # newest event and goes.
      #
      assert MapSet.new(EventLog.streams(log)) == MapSet.new(["a", "c"])
      assert {:ok, [{"a:1", "1"}, {"a:2", "1"}]} = EventLogProbe.after_id(log, "a", nil)
    end

    test "a cap of nil keeps every ring" do
      log =
        EventLog.new(10, 1000, nil, nil)
        |> EventLog.append("a", {"a:1", "1"})
        |> EventLog.append("b", {"b:1", "1"})
        |> EventLog.append("c", {"c:1", "1"})

      assert MapSet.new(EventLog.streams(log)) == MapSet.new(["a", "b", "c"])
    end

    test "a cap of one keeps only the ring of the current stream" do
      log =
        EventLog.new(10, 1000, nil, 1)
        |> EventLog.append("a", {"a:1", "1"})
        |> EventLog.append("b", {"b:1", "1"})

      assert EventLog.streams(log) == ["b"]

      log = EventLog.append(log, "a", {"a:2", "1"})
      assert EventLog.streams(log) == ["a"]
    end

    test "the total stays the sum of the bytes of the rings after the evictions" do
      log =
        EventLog.new(10, 1000, nil, 2)
        |> EventLog.append("a", {"a:1", "123"})
        |> EventLog.append("b", {"b:1", "12"})
        |> EventLog.append("c", {"c:1", "1"})

      assert EventLogProbe.total_bytes(log) == 3

      sum =
        log.streams
        |> Map.values()
        |> Enum.map(&elem(&1, 1))
        |> Enum.sum()

      assert EventLogProbe.total_bytes(log) == sum
    end

    test "the byte budget and the ring cap work together" do
      log =
        EventLog.new(10, 8, 10, 2)
        |> EventLog.append("a", {"a:1", "12345678"})
        |> EventLog.append("b", {"b:1", "12"})
        |> EventLog.append("c", {"c:1", "12"})
        |> EventLog.append("d", {"d:1", "12"})

      # The third append puts the total over the byte budget: the budget
      # evicts "a". The fourth append puts the number of rings over the
      # cap: the cap evicts "b", whose newest event is the oldest of the
      # rest.
      #
      assert MapSet.new(EventLog.streams(log)) == MapSet.new(["c", "d"])
      assert EventLogProbe.total_bytes(log) == 4
      assert EventLogProbe.after_id(log, "c", nil) == {:ok, [{"c:1", "12"}]}
      assert EventLogProbe.after_id(log, "d", nil) == {:ok, [{"d:1", "12"}]}
    end

    test "logged?/2 is true for a stream with a ring and false after drop/2" do
      log = EventLog.new(10, 1000) |> EventLog.append("s", {"s:1", "a"})

      assert EventLog.logged?(log, "s")
      refute EventLog.logged?(log, "other")

      log = EventLog.drop(log, "s")
      refute EventLog.logged?(log, "s")
    end
  end
end
