defmodule OzMcp.Session.StreamsTest do
  use ExUnit.Case, async: true

  alias OzMcp.Session.{Core, EventLog, Streams}

  defp core(attrs \\ %{}) do
    struct!(
      %Core{
        instance: __MODULE__,
        id: "session",
        pid: self(),
        opts: %{sse_resume_window_ms: 50},
        log: EventLog.new(10, 1_024)
      },
      attrs
    )
  end

  test "event_id/2 builds the id of an event" do
    assert Streams.event_id("st", 0) == "st:0"
    assert Streams.event_id("st", 12) == "st:12"
  end

  test "log/3 appends the event to the ring of its stream" do
    core = Streams.log(core(), "st", {"st:1", "one"})

    assert EventLog.events(core.log, "st") == [{"st:1", "one"}]
  end

  test "retire_log/2 drops the ring at once with a window of 0" do
    core = core(%{opts: %{sse_resume_window_ms: 0}})
    core = Streams.log(core, "st", {"st:1", "one"})

    assert {%Core{log: log}, []} = Streams.retire_log(core, "st")
    refute EventLog.logged?(log, "st")
  end

  test "retire_log/2 gives the timer of the resume window" do
    core = Streams.log(core(), "st", {"st:1", "one"})

    assert {^core, [{:timeout, {:timeout, {:log, "st"}}, 50, :drop_log}]} =
             Streams.retire_log(core, "st")
  end

  test "warn_resume/4 gives the warning of a gap" do
    replay = %{events: [], gap: true, response: true}

    assert [{:log, :warning, text}] = Streams.warn_resume(replay, "POST", false, true)
    assert text =~ "the event log caps removed events of a resumed POST stream"
  end

  test "warn_resume/4 gives the warning of a missing response" do
    replay = %{events: [], gap: false, response: false}

    assert [{:log, :warning, text}] = Streams.warn_resume(replay, "POST", true, true)
    assert text =~ "a resumed POST stream is over and its response is not in the event log"
  end

  test "warn_resume/4 says nothing for a complete replay" do
    replay = %{events: [], gap: false, response: true}

    assert Streams.warn_resume(replay, "GET", false, true) == []
  end
end
