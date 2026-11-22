defmodule OzMcp.Session.Streams.GetTest do
  use ExUnit.Case, async: true

  alias OzMcp.Session.{Core, EventLog, Streams, View}
  alias OzMcp.Session.Streams.Get

  defmodule Counter do
    def get_stream_id do
      n = Process.get(:stream_id, 0) + 1
      Process.put(:stream_id, n)
      "st#{n}"
    end

    def request_id, do: get_stream_id()
  end

  defp core(attrs \\ %{}) do
    struct!(
      %Core{
        instance: __MODULE__,
        id: "session",
        pid: self(),
        ids: Counter,
        view: %View{initialized: true},
        opts: %{
          sse_resume_window_ms: 50,
          max_streams_per_session: nil,
          session_timeout_ms: 30_000
        },
        log: EventLog.new(10, 1_024)
      },
      attrs
    )
  end

  defp stream(attrs \\ %{}) do
    Map.merge(%{id: "st1", pid: self(), kind: :get, seq: 0}, attrs)
  end

  test "open/4 takes over a live stream with the same id" do
    live = stream(%{seq: 3})
    pid = spawn(fn -> :ok end)
    core = core(%{get_streams: [live]})

    assert {core, effects} = Get.open(core, :get, {:get, "st1", 3}, pid)

    assert [
             {:send, live_pid, {:oz_mcp_stream, "st1", :terminate}},
             {:demonitor, {:get, "st1"}},
             {:monitor, ^pid, {:get, "st1"}},
             {:view, %View{streams: 1}},
             {:reply, {:ok, reply}},
             :idle_check
           ] = effects

    assert live_pid == live.pid
    assert %{mode: :get, stream_id: "st1", priming_id: nil, replay: []} = reply
    assert [%{id: "st1", pid: ^pid, seq: 3}] = core.get_streams
  end

  test "open/4 resumes a closed stream with its id and its counter" do
    with_event = Streams.log(core(), "st1", {"st1:1", "one"})
    core = %{with_event | closed_gets: [%{id: "st1", seq: 2, opened?: true}]}
    pid = spawn(fn -> :ok end)

    assert {core, effects} = Get.open(core, :get, {:get, "st1", 2}, pid)

    assert [
             {:monitor, ^pid, {:get, "st1"}},
             {:view, %View{streams: 1}},
             {:reply, {:ok, reply}},
             {:timeout, {:timeout, {:log, "st1"}}, :cancel, nil},
             :idle_check
           ] = effects

    assert %{mode: :get, stream_id: "st1", replay: [], priming_id: nil} = reply
    assert core.closed_gets == []
    assert [%{id: "st1", pid: ^pid, seq: 2}] = core.get_streams
  end

  test "open/4 makes a fresh GET stream with the next id and a priming event" do
    pid = spawn(fn -> :ok end)

    assert {core, effects} = Get.open(core(), :get, :fresh, pid)

    assert [
             {:monitor, ^pid, {:get, "st1"}},
             {:view, %View{streams: 1}},
             {:reply, {:ok, reply}},
             :idle_check
           ] = effects

    assert %{mode: :get, stream_id: "st1", replay: [], priming_id: "st1:0"} = reply
    assert [%{id: "st1", pid: ^pid, kind: :get, seq: 0}] = core.get_streams
  end

  test "open/4 makes a fresh stdio stream with no priming event" do
    pid = spawn(fn -> :ok end)

    assert {core, effects} = Get.open(core(), :stdio, :fresh, pid)

    assert {:reply, {:ok, %{mode: :get, stream_id: "st1", priming_id: nil}}} =
             Enum.find(effects, &match?({:reply, _}, &1))

    assert [%{id: "st1", pid: ^pid, kind: :stdio, seq: 0}] = core.get_streams
  end

  test "a fresh GET stream takes a virtual stream with its id and its ring" do
    core = core(%{closed_gets: [%{id: "stv", seq: 2, opened?: false}]})
    core = Streams.log(core, "stv", {"stv:1", "one"})
    core = Streams.log(core, "stv", {"stv:2", "two"})
    pid = spawn(fn -> :ok end)

    assert {core, effects} = Get.open(core, :get, :fresh, pid)

    assert {:reply, {:ok, reply}} = Enum.find(effects, &match?({:reply, _}, &1))
    assert %{stream_id: "stv", replay: [{"stv:1", "one"}, {"stv:2", "two"}]} = reply
    assert {:timeout, {:timeout, {:log, "stv"}}, :cancel, nil} in effects
    assert [%{id: "stv", pid: ^pid, seq: 2}] = core.get_streams
    assert core.closed_gets == []
  end

  test "a fresh GET stream replaces a virtual stream with no ring" do
    core = core(%{closed_gets: [%{id: "stv", seq: 0, opened?: false}]})
    pid = spawn(fn -> :ok end)

    assert {core, effects} = Get.open(core, :get, :fresh, pid)

    assert {:reply, {:ok, %{stream_id: "st1", replay: [], priming_id: "st1:0"}}} =
             Enum.find(effects, &match?({:reply, _}, &1))

    assert {:timeout, {:timeout, {:log, "stv"}}, :cancel, nil} in effects
    assert core.closed_gets == []
  end

  test "open/4 with an unknown id over the limit replaces the oldest stream" do
    live = stream()

    core =
      core(%{
        opts: %{sse_resume_window_ms: 50, max_streams_per_session: 1, session_timeout_ms: 30_000},
        get_streams: [live]
      })

    pid = spawn(fn -> :ok end)

    assert {core, effects} = Get.open(core, :get, {:get, "other", 0}, pid)

    assert [
             {:log, :warning,
              "Last-Event-ID is not in the event log of the session: " <>
                "the GET stream starts fresh, the client can miss events"},
             {:limit, :max_streams_per_session, 1, :replaced},
             {:demonitor, {:get, "st1"}},
             {:send, live_pid, {:oz_mcp_stream, "st1", :terminate}},
             {:timeout, {:timeout, {:log, "st1"}}, 50, :drop_log},
             {:monitor, ^pid, {:get, "st1"}},
             {:view, %View{streams: 1}},
             {:reply, {:ok, %{mode: :get, stream_id: "st1", priming_id: "st1:0"}}},
             :idle_check
           ] = effects

    assert live_pid == live.pid
    assert [%{id: "st1", pid: ^pid, seq: 0}] = core.get_streams
    assert [%{id: "st1", opened?: true}] = core.closed_gets
  end

  test "open/4 refuses a fresh GET when only a stdio stream is live" do
    core =
      core(%{
        opts: %{sse_resume_window_ms: 50, max_streams_per_session: 1, session_timeout_ms: 30_000},
        get_streams: [stream(%{kind: :stdio})]
      })

    assert {^core, effects} = Get.open(core, :get, {:get, "other", 0}, self())

    assert effects == [
             {:log, :warning,
              "Last-Event-ID is not in the event log of the session: " <>
                "the GET stream starts fresh, the client can miss events"},
             {:limit, :max_streams_per_session, 1},
             {:reply, {:error, :too_many_streams}}
           ]
  end

  test "open/4 replaces a live stream over the limit one time" do
    live = stream(%{pid: spawn(fn -> :ok end)})

    core =
      core(%{
        opts: %{sse_resume_window_ms: 50, max_streams_per_session: 1, session_timeout_ms: 30_000},
        get_streams: [live]
      })

    pid = spawn(fn -> :ok end)

    assert {core, effects} = Get.open(core, :get, {:get, "st1", 0}, pid)
    refute Enum.any?(effects, &match?({:limit, _, _}, &1))
    assert [%{id: "st1", pid: ^pid}] = core.get_streams
  end

  test "a fresh GET over the limit replaces the oldest stream" do
    live = stream()

    core =
      core(%{
        opts: %{sse_resume_window_ms: 50, max_streams_per_session: 1, session_timeout_ms: 30_000},
        get_streams: [live]
      })

    pid = spawn(fn -> :ok end)

    assert {core, effects} = Get.open(core, :get, :fresh, pid)

    assert [
             {:limit, :max_streams_per_session, 1, :replaced},
             {:demonitor, {:get, "st1"}},
             {:send, live_pid, {:oz_mcp_stream, "st1", :terminate}},
             {:timeout, {:timeout, {:log, "st1"}}, 50, :drop_log},
             {:monitor, ^pid, {:get, "st1"}},
             {:view, %View{streams: 1}},
             {:reply, {:ok, %{mode: :get, stream_id: "st1", priming_id: "st1:0"}}},
             :idle_check
           ] = effects

    assert live_pid == live.pid
    assert [%{id: "st1", pid: ^pid, kind: :get, seq: 0}] = core.get_streams
    assert [%{id: "st1", opened?: true}] = core.closed_gets
  end

  test "a fresh GET over the limit is refused when only a stdio stream is live" do
    core =
      core(%{
        opts: %{sse_resume_window_ms: 50, max_streams_per_session: 1, session_timeout_ms: 30_000},
        get_streams: [stream(%{kind: :stdio})]
      })

    assert {^core, effects} = Get.open(core, :get, :fresh, self())

    assert effects == [
             {:limit, :max_streams_per_session, 1},
             {:reply, {:error, :too_many_streams}}
           ]
  end

  test "the third fresh GET over the limit ends the first stream" do
    opts = %{sse_resume_window_ms: 50, max_streams_per_session: 2, session_timeout_ms: 30_000}
    core = core(%{opts: opts})

    pid1 = spawn(fn -> :ok end)
    pid2 = spawn(fn -> :ok end)
    pid3 = spawn(fn -> :ok end)

    assert {core, _} = Get.open(core, :get, :fresh, pid1)
    assert {core, _} = Get.open(core, :get, :fresh, pid2)

    assert {core, effects} = Get.open(core, :get, :fresh, pid3)

    assert {:limit, :max_streams_per_session, 2, :replaced} in effects
    assert {:send, pid1, {:oz_mcp_stream, "st1", :terminate}} in effects
    assert [%{id: "st3"}, %{id: "st2"}] = core.get_streams
    assert [%{id: "st1", opened?: true}] = core.closed_gets
  end

  test "an invalid id over the limit replaces the oldest stream too" do
    live = stream()

    core =
      core(%{
        opts: %{sse_resume_window_ms: 50, max_streams_per_session: 1, session_timeout_ms: 30_000},
        get_streams: [live]
      })

    pid = spawn(fn -> :ok end)

    assert {core, effects} = Get.open(core, :get, :invalid, pid)

    assert {:limit, :max_streams_per_session, 1, :replaced} in effects
    assert {:send, live.pid, {:oz_mcp_stream, "st1", :terminate}} in effects
    assert [%{id: "st1", pid: ^pid}] = core.get_streams
    assert [%{id: "st1", opened?: true}] = core.closed_gets
  end

  test "a resume of a closed stream over the limit replaces the oldest live stream" do
    live = stream()

    core =
      core(%{
        opts: %{sse_resume_window_ms: 50, max_streams_per_session: 1, session_timeout_ms: 30_000},
        get_streams: [live],
        closed_gets: [%{id: "st9", seq: 4, opened?: true}]
      })

    core = Streams.log(core, "st9", {"st9:3", "one"})
    core = Streams.log(core, "st9", {"st9:4", "two"})
    pid = spawn(fn -> :ok end)

    assert {core, effects} = Get.open(core, :get, {:get, "st9", 3}, pid)

    assert {:limit, :max_streams_per_session, 1, :replaced} in effects
    assert {:send, live.pid, {:oz_mcp_stream, "st1", :terminate}} in effects

    assert {:reply, {:ok, %{stream_id: "st9", replay: [{"st9:4", "two"}], priming_id: nil}}} =
             Enum.find(effects, &match?({:reply, _}, &1))

    assert [%{id: "st9", pid: ^pid, seq: 4}] = core.get_streams
    assert [%{id: "st1", opened?: true}] = core.closed_gets
  end

  test "a resume of the last closed stream over the limit keeps its ring" do
    live = stream()
    closed = for n <- 1..16, do: %{id: "c#{n}", seq: n, opened?: true}

    core =
      core(%{
        opts: %{sse_resume_window_ms: 50, max_streams_per_session: 1, session_timeout_ms: 30_000},
        get_streams: [live],
        closed_gets: closed
      })

    core = Streams.log(core, "c16", {"c16:16", "one"})
    pid = spawn(fn -> :ok end)

    assert {core, effects} = Get.open(core, :get, {:get, "c16", 15}, pid)

    assert {:limit, :max_streams_per_session, 1, :replaced} in effects

    assert {:reply, {:ok, %{stream_id: "c16", replay: [{"c16:16", "one"}]}}} =
             Enum.find(effects, &match?({:reply, _}, &1))

    assert [%{id: "c16", pid: ^pid, seq: 16}] = core.get_streams
    assert length(core.closed_gets) == 16
    assert Enum.any?(core.closed_gets, &(&1.id == "st1"))
    assert EventLog.events(core.log, "c16") == [{"c16:16", "one"}]
  end

  test "a replacement with a resume window of 0 keeps no closed stream" do
    live = stream()

    core =
      core(%{
        opts: %{sse_resume_window_ms: 0, max_streams_per_session: 1, session_timeout_ms: 30_000},
        get_streams: [live]
      })

    pid = spawn(fn -> :ok end)

    assert {core, effects} = Get.open(core, :get, :fresh, pid)

    assert {:send, live.pid, {:oz_mcp_stream, "st1", :terminate}} in effects
    assert {:limit, :max_streams_per_session, 1, :replaced} in effects
    assert core.closed_gets == []
    refute EventLog.logged?(core.log, "st1")
    assert [%{id: "st1", pid: ^pid}] = core.get_streams
  end

  test "close/2 ends each stream of the process" do
    pid = spawn(fn -> :ok end)
    core = core(%{get_streams: [stream(%{pid: pid})]})

    assert {core, effects} = Get.close(core, pid)

    assert effects == [
             {:demonitor, {:get, "st1"}},
             {:reply, :ok},
             {:timeout, {:timeout, {:log, "st1"}}, 50, :drop_log},
             :idle_check
           ]

    assert core.get_streams == []
    assert [%{id: "st1", opened?: true}] = core.closed_gets
  end

  test "close/2 keeps no closed stream with a window of 0" do
    pid = spawn(fn -> :ok end)

    core =
      core(%{
        opts: %{sse_resume_window_ms: 0, max_streams_per_session: nil, session_timeout_ms: 30_000},
        get_streams: [stream(%{pid: pid})]
      })

    assert {core, effects} = Get.close(core, pid)

    assert effects == [{:demonitor, {:get, "st1"}}, {:reply, :ok}, :idle_check]
    assert core.closed_gets == []
    refute EventLog.logged?(core.log, "st1")
  end

  test "down/2 ends the stream of the id and keeps no reply" do
    pid = spawn(fn -> :ok end)
    core = core(%{get_streams: [stream(%{pid: pid})]})

    assert {core, effects} = Get.down(core, "st1")

    assert effects == [
             {:timeout, {:timeout, {:log, "st1"}}, 50, :drop_log},
             :idle_check
           ]

    assert core.get_streams == []
    assert [%{id: "st1", opened?: true}] = core.closed_gets
  end

  test "emit/2 gives the event to the newest live stream" do
    pid = spawn(fn -> :ok end)
    core = core(%{get_streams: [stream(%{pid: pid, seq: 2})]})

    assert {core, effects} = Get.emit(core, "message")

    assert effects == [{:send, pid, {:oz_mcp_stream, "st1", {:event, "st1:3", "message"}}}]
    assert [%{seq: 3}] = core.get_streams
    assert EventLog.events(core.log, "st1") == [{"st1:3", "message"}]
  end

  test "emit/2 gives the event to the ring of the newest closed stream" do
    core = core(%{closed_gets: [%{id: "st1", seq: 1, opened?: true}]})

    assert {core, []} = Get.emit(core, "message")
    assert [%{id: "st1", seq: 2}] = core.closed_gets
    assert EventLog.events(core.log, "st1") == [{"st1:2", "message"}]
  end

  test "emit/2 makes a virtual stream when none is open" do
    assert {core, effects} = Get.emit(core(), "message")

    assert effects == [{:timeout, {:timeout, {:log, "st1"}}, 50, :drop_log}]
    assert [%{id: "st1", seq: 1, opened?: false}] = core.closed_gets
    assert EventLog.events(core.log, "st1") == [{"st1:1", "message"}]
  end

  test "emit/2 drops the event with a window of 0 and no stream" do
    core =
      core(%{
        opts: %{sse_resume_window_ms: 0, max_streams_per_session: nil, session_timeout_ms: 30_000}
      })

    assert {^core, []} = Get.emit(core, "message")
  end

  test "emit/2 gives nothing before the initialization" do
    core = core(%{view: %View{initialized: false}})

    assert {^core, []} = Get.emit(core, "message")
  end

  test "window_over/2 keeps the ring of a live stream" do
    core = core(%{get_streams: [stream()]})
    core = Streams.log(core, "st1", {"st1:1", "one"})

    assert {^core, []} = Get.window_over(core, "st1")
    assert EventLog.logged?(core.log, "st1")
  end

  test "window_over/2 keeps the ring of a live POST stream" do
    core =
      core(%{
        streams: %{"st1" => %{owner: self(), resumer: nil, request_id: 7, seq: 1, mode: :sse}},
        log: EventLog.new(10, 1_024)
      })

    core = Streams.log(core, "st1", {"st1:1", "one"})

    assert {^core, []} = Get.window_over(core, "st1")
    assert EventLog.logged?(core.log, "st1")
  end

  test "window_over/2 drops the ring and the closed GET entry after the window" do
    core = core(%{closed_gets: [%{id: "st1", seq: 1, opened?: true}]})
    core = Streams.log(core, "st1", {"st1:1", "one"})

    assert {%Core{closed_gets: [], log: log}, []} = Get.window_over(core, "st1")
    refute EventLog.logged?(log, "st1")
  end

  test "end_all/1 ends each live stream" do
    core = core(%{get_streams: [stream(), stream(%{id: "st2"})]})

    assert {^core, effects} = Get.end_all(core)

    assert effects == [
             {:send, self(), {:oz_mcp_stream, "st1", :terminate}},
             {:send, self(), {:oz_mcp_stream, "st2", :terminate}}
           ]
  end
end
