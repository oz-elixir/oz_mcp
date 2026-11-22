defmodule OzMcp.Session.Streams.PostTest do
  use ExUnit.Case, async: true

  alias OzMcp.Session.{Core, EventLog, Streams}
  alias OzMcp.Session.Streams.Post

  defp core(attrs \\ %{}) do
    struct!(
      %Core{
        instance: __MODULE__,
        id: "session",
        pid: self(),
        opts: %{sse_resume_window_ms: 10_000},
        log: EventLog.new(256, 1_048_576)
      },
      attrs
    )
  end

  defp entry(attrs \\ %{}) do
    Map.merge(
      %{owner: self(), resumer: nil, request_id: 7, seq: 0, mode: :sse, started: false},
      Map.new(attrs)
    )
  end

  test "new/5 stores the entry and monitors the owner" do
    owner = spawn(fn -> :ok end)
    core = core()

    assert {core, effects} = Post.new(core, "st1", owner, 7, :sse)

    assert effects == [{:monitor, owner, {:owner, "st1"}}]

    assert core.streams["st1"] == entry(owner: owner)
  end

  test "promote/2 marks the stream started and answers :ok one time" do
    core = core(%{streams: %{"st1" => entry()}})

    assert {%Core{streams: %{"st1" => %{started: true}}}, [{:reply, :ok}]} =
             Post.promote(core, "st1")

    assert {gone, [{:reply, :gone}]} = Post.promote(%{core | streams: %{}}, "st1")
    assert gone == %{core | streams: %{}}
  end

  test "hand_off/2 drops the owner, marks the stream started and answers :ok one time" do
    owner = spawn(fn -> :ok end)
    core = core(%{streams: %{"st1" => entry(owner: owner)}})

    assert {core, effects} = Post.hand_off(core, "st1")

    assert effects == [{:demonitor, {:owner, "st1"}}, {:reply, :ok}]
    assert core.streams["st1"].owner == nil
    assert core.streams["st1"].started == true

    assert {gone, [{:reply, :gone}]} = Post.hand_off(%{core | streams: %{}}, "st1")
    assert gone == %{core | streams: %{}}
  end

  test "finish/5 counts a promoted stream as started" do
    core =
      core(%{
        streams: %{"st1" => entry(seq: 0, started: true)},
        requests: %{7 => %{owner: self(), runner: nil, stream_id: "st1"}}
      })

    assert {core, effects} = Post.finish(core, 7, "st1", "done", false)

    assert {:reply, {:sse, "st1:1"}} in effects
    assert EventLog.events(core.log, "st1") == [{"st1:1", "done"}]
    assert core.streams == %{}
  end

  test "emit/3 of a stream with no owner logs the event and sends nothing" do
    core = core(%{streams: %{"st1" => entry(owner: nil)}})

    assert {core, []} = Post.emit(core, "st1", "x")

    assert core.streams["st1"].seq == 1
    assert EventLog.events(core.log, "st1") == [{"st1:1", "x"}]
  end

  test "take_over/3 of a stream with no owner sends no taken_over message" do
    new = spawn(fn -> :ok end)
    core = core(%{streams: %{"st1" => entry(owner: nil)}})

    assert {_core, [{:monitor, ^new, {:resumer, "st1"}}]} = Post.take_over(core, "st1", new)
  end

  test "finish/5 gives the final event to the resumer in order, then the reply" do
    owner = spawn(fn -> :ok end)
    resumer = spawn(fn -> :ok end)

    core =
      core(%{
        streams: %{"st1" => entry(owner: owner, resumer: resumer, seq: 1)},
        requests: %{7 => %{owner: owner, runner: nil, stream_id: "st1"}}
      })

    assert {core, effects} = Post.finish(core, 7, "st1", "done", false)

    assert effects == [
             {:send, resumer, {:oz_mcp_stream, "st1", {:event, "st1:2", "done"}}},
             {:send, resumer, {:oz_mcp_stream, "st1", :end}},
             {:demonitor, {:owner, "st1"}},
             {:demonitor, {:resumer, "st1"}},
             {:timeout, {:timeout, {:log, "st1"}}, 10_000, :drop_log},
             {:reply, {:sse, "st1:2"}}
           ]

    assert core.streams == %{}
    assert core.requests[7].stream_id == nil
    assert EventLog.events(core.log, "st1") == [{"st1:2", "done"}]
  end

  test "finish/5 answers :plain when the stream never started" do
    core =
      core(%{
        streams: %{"st1" => entry(seq: 0)},
        requests: %{7 => %{owner: self(), runner: nil, stream_id: "st1"}}
      })

    assert {core, effects} = Post.finish(core, 7, "st1", "done", false)

    assert effects == [{:demonitor, {:owner, "st1"}}, {:reply, :plain}]
    assert core.streams == %{}
    assert core.requests[7].stream_id == nil
  end

  test "finish/5 answers :gone for an unknown stream" do
    core = core(%{streams: %{"st1" => entry(request_id: 8)}})

    assert {^core, [{:reply, :gone}]} = Post.finish(core, 7, "st1", "done", false)
  end

  test "take_over/3 ends the old resumer and tells the owner before the monitor" do
    owner = self()
    old = spawn(fn -> :ok end)
    new = spawn(fn -> :ok end)
    core = core(%{streams: %{"st1" => entry(owner: owner, resumer: old, seq: 3)}})

    assert {core, effects} = Post.take_over(core, "st1", new)

    assert effects == [
             {:send, old, {:oz_mcp_stream, "st1", :end}},
             {:demonitor, {:resumer, "st1"}},
             {:send, owner, {:oz_mcp_stream, "st1", :taken_over}},
             {:monitor, new, {:resumer, "st1"}}
           ]

    assert core.streams["st1"].resumer == new
  end

  test "take_over/3 with no old resumer only tells the owner and monitors" do
    owner = self()
    new = spawn(fn -> :ok end)
    core = core(%{streams: %{"st1" => entry(owner: owner)}})

    assert {_core, effects} = Post.take_over(core, "st1", new)

    assert effects == [
             {:send, owner, {:oz_mcp_stream, "st1", :taken_over}},
             {:monitor, new, {:resumer, "st1"}}
           ]
  end

  test "detach/2 ends the resumer, drops the entry and retires the ring" do
    resumer = spawn(fn -> :ok end)
    core = core(%{streams: %{"st1" => entry(resumer: resumer, seq: 1)}})
    core = Streams.log(core, "st1", {"st1:1", "x"})

    assert {core, effects} = Post.detach(core, "st1")

    assert effects == [
             {:send, resumer, {:oz_mcp_stream, "st1", :end}},
             {:demonitor, {:owner, "st1"}},
             {:demonitor, {:resumer, "st1"}},
             {:timeout, {:timeout, {:log, "st1"}}, 10_000, :drop_log}
           ]

    assert core.streams == %{}
    assert EventLog.logged?(core.log, "st1")
  end

  test "detach/2 with no ring gives no timer" do
    core = core(%{streams: %{"st1" => entry()}})

    assert {core, [{:demonitor, {:owner, "st1"}}]} = Post.detach(core, "st1")
    assert core.streams == %{}
  end

  test "detach_resume/3 clears the resumer one time" do
    resumer = spawn(fn -> :ok end)
    core = core(%{streams: %{"st1" => entry(resumer: resumer)}})

    assert {core, [{:demonitor, {:resumer, "st1"}}]} =
             Post.detach_resume(core, "st1", resumer)

    assert core.streams["st1"].resumer == nil
    assert {^core, []} = Post.detach_resume(core, "st1", resumer)
    assert {^core, []} = Post.detach_resume(core, "missing", resumer)
  end

  test "resume/5 of a stream that is over and has no ring logs at debug level" do
    core = core()

    assert {^core, effects} = Post.resume(core, self(), "st1", 0, true)

    assert [
             {:log, :debug, "a resumed POST stream is over and its event log was dropped"},
             {:reply, {:error, :no_stream}},
             :idle_check
           ] = effects
  end

  test "resume/5 of a sink gives :no_stream" do
    core = core(%{streams: %{"st1" => entry(mode: :sink)}})

    assert {^core, [{:reply, {:error, :no_stream}}, :idle_check]} =
             Post.resume(core, self(), "st1", 0, false)
  end

  test "resume/5 of a live stream replays and takes it over" do
    owner = self()
    resumer = spawn(fn -> :ok end)
    core = core(%{streams: %{"st1" => entry(owner: owner, seq: 2)}})

    core =
      core
      |> Streams.log("st1", {"st1:1", "a"})
      |> Streams.log("st1", {"st1:2", "b"})

    assert {core, effects} = Post.resume(core, resumer, "st1", 1, false)

    assert effects == [
             {:send, owner, {:oz_mcp_stream, "st1", :taken_over}},
             {:monitor, resumer, {:resumer, "st1"}},
             {:reply,
              {:ok,
               %{
                 mode: :resume,
                 stream_id: "st1",
                 replay: [{"st1:2", "b"}],
                 ended: false,
                 session_pid: core.pid
               }}},
             :idle_check
           ]

    assert core.streams["st1"].resumer == resumer
  end

  test "resume/5 of an ended stream replays and does not take it over" do
    core = core()
    core = Streams.log(core, "st1", {"st1:1", "a"})

    assert {core, effects} = Post.resume(core, self(), "st1", 0, true)
    assert {:reply, {:ok, reply}} = Enum.find(effects, &match?({:reply, _}, &1))
    assert reply[:ended] == true
    assert reply[:replay] == [{"st1:1", "a"}]
    assert core.streams == %{}
  end

  test "owner_down/2 warns and ends a live resumer before the entry goes" do
    resumer = spawn(fn -> :ok end)
    core = core(%{streams: %{"st1" => entry(resumer: resumer, seq: 1)}})
    core = Streams.log(core, "st1", {"st1:1", "x"})

    assert {core, effects} = Post.owner_down(core, "st1")

    assert effects == [
             {:log, :warning,
              "the request of a resumed POST stream stopped before its response: " <>
                "the client does not get a response"},
             {:send, resumer, {:oz_mcp_stream, "st1", :end}},
             {:demonitor, {:owner, "st1"}},
             {:demonitor, {:resumer, "st1"}},
             {:timeout, {:timeout, {:log, "st1"}}, 10_000, :drop_log}
           ]

    assert core.streams == %{}
  end

  test "owner_down/2 with no resumer only forgets the stream" do
    core = core(%{streams: %{"st1" => entry()}})

    assert {core, [{:demonitor, {:owner, "st1"}}]} = Post.owner_down(core, "st1")
    assert core.streams == %{}
  end

  test "owner_down/2 of an unknown stream does nothing" do
    core = core()

    assert {^core, []} = Post.owner_down(core, "st1")
  end

  test "connection_down/2 makes the stream a hand-off and keeps a live resumer" do
    resumer = spawn(fn -> :ok end)
    core = core(%{streams: %{"st1" => entry(resumer: resumer, seq: 1)}})
    core = Streams.log(core, "st1", {"st1:1", "x"})

    assert {core, []} = Post.connection_down(core, "st1")

    # The callback goes on: the entry stays and its events and its
    # response go to the log and to the resumer.
    #
    assert %{owner: nil, started: true, resumer: ^resumer} = core.streams["st1"]
    assert EventLog.logged?(core.log, "st1")
  end

  test "connection_down/2 of an unknown stream does nothing" do
    core = core()

    assert {^core, []} = Post.connection_down(core, "st1")
  end

  test "resumer_down/2 clears the resumer with no send" do
    resumer = spawn(fn -> :ok end)
    core = core(%{streams: %{"st1" => entry(resumer: resumer)}})

    assert {core, []} = Post.resumer_down(core, "st1")
    assert core.streams["st1"].resumer == nil
    assert {^core, []} = Post.resumer_down(core, "missing")
  end

  test "emit/3 logs and sends a numbered event to the owner" do
    core = core(%{streams: %{"st1" => entry(seq: 0)}})

    assert {core, [{:send, owner, {:oz_mcp_stream, "st1", {:event, "st1:1", "x"}}}]} =
             Post.emit(core, "st1", "x")

    assert owner == self()
    assert core.streams["st1"].seq == 1
    assert EventLog.events(core.log, "st1") == [{"st1:1", "x"}]
  end

  test "emit/3 sends a numbered event to the resumer" do
    resumer = spawn(fn -> :ok end)
    core = core(%{streams: %{"st1" => entry(resumer: resumer)}})

    assert {_core, [{:send, ^resumer, {:oz_mcp_stream, "st1", {:event, "st1:1", "x"}}}]} =
             Post.emit(core, "st1", "x")
  end

  test "emit/3 of a sink has no id and no log" do
    core = core(%{streams: %{"st1" => entry(mode: :sink)}})

    assert {core, [{:send, owner, {:oz_mcp_stream, "st1", {:event, nil, "x"}}}]} =
             Post.emit(core, "st1", "x")

    assert owner == self()
    refute EventLog.logged?(core.log, "st1")
  end

  test "emit/3 of an unknown stream does nothing" do
    core = core()

    assert {^core, []} = Post.emit(core, "st1", "x")
  end

  test "emit_request/3 uses the stream of the request" do
    core =
      core(%{
        requests: %{7 => %{owner: self(), runner: nil, stream_id: "st1"}},
        streams: %{"st1" => entry()}
      })

    assert {core, [{:send, owner, {:oz_mcp_stream, "st1", {:event, "st1:1", "x"}}}]} =
             Post.emit_request(core, 7, "x")

    assert owner == self()
    assert {^core, []} = Post.emit_request(core, 8, "x")
  end

  test "end_all/1 ends each live resumer" do
    one = spawn(fn -> :ok end)
    two = spawn(fn -> :ok end)

    core =
      core(%{
        streams: %{
          "a" => entry(owner: self(), resumer: one),
          "b" => entry(owner: self(), resumer: two),
          "c" => entry(owner: self())
        }
      })

    assert {^core, effects} = Post.end_all(core)

    assert Enum.sort(effects) ==
             Enum.sort([
               {:send, one, {:oz_mcp_stream, "a", :terminate}},
               {:send, two, {:oz_mcp_stream, "b", :terminate}}
             ])
  end
end
