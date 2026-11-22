defmodule OzMcp.Session.CoreTest do
  use ExUnit.Case, async: true

  alias OzMcp.Session.{Core, EventLog, View}
  alias OzMcp.Session.Snapshot.None
  alias Support.Helpers.{NoClock, StepClock}

  defp core(attrs \\ %{}) do
    struct!(
      %Core{
        instance: __MODULE__,
        id: "session",
        opts: %{session_timeout_ms: 30_000}
      },
      attrs
    )
  end

  defp decode(encoded), do: encoded |> IO.iodata_to_binary() |> :json.decode()

  defp ending_core(attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          view: %View{principal_key: nil},
          opts: %{session_timeout_ms: 30_000, session_snapshot: None}
        },
        attrs
      )

    core(attrs)
  end

  test "open_request registers a plain request" do
    owner = spawn(fn -> :ok end)

    assert {%Core{requests: requests, streams: streams}, effects} =
             Core.handle({:call, {:open_request, 7, owner, nil}}, :ready, core())

    assert requests == %{7 => %{owner: owner, runner: nil, stream_id: nil, progress: nil}}
    assert streams == %{}
    assert effects == [{:monitor, owner, {:request, 7}}, :idle_check, {:reply, :ok}]
  end

  test "open_request registers a request and makes its stream" do
    owner = spawn(fn -> :ok end)

    assert {%Core{requests: %{7 => %{stream_id: "st1"}}, streams: streams}, effects} =
             Core.handle({:call, {:open_request, 7, owner, {"st1", :sse}}}, :ready, core())

    assert %{owner: ^owner, request_id: 7, mode: :sse, resumer: nil, seq: 0} = streams["st1"]

    assert effects == [
             {:monitor, owner, {:request, 7}},
             :idle_check,
             {:monitor, owner, {:owner, "st1"}},
             {:reply, :ok}
           ]
  end

  test "open_request refuses a duplicate id and makes no stream" do
    owner = spawn(fn -> :ok end)
    core = core(requests: %{7 => %{owner: owner, runner: nil, stream_id: nil}})

    assert {%Core{requests: %{7 => %{stream_id: nil}}, streams: %{}}, effects} =
             Core.handle({:call, {:open_request, 7, self(), {"st1", :sse}}}, :ready, core)

    assert effects == [
             {:log, :warning, "request id 7 is already in use"},
             {:reply, {:error, :duplicate}}
           ]
  end

  test "open_request in :closing gives no_session and stores nothing" do
    assert {%Core{requests: %{}, streams: %{}}, effects} =
             Core.handle({:call, {:open_request, 7, self(), nil}}, :closing, core())

    assert effects == [
             {:log, :debug, "session call :open_request refused: the session is closing"},
             {:reply, {:error, :no_session}}
           ]
  end

  test "open_request with a bad mode gives badarg and stores nothing" do
    assert {%Core{requests: %{}, streams: %{}}, effects} =
             Core.handle({:call, {:open_request, 7, self(), {"st1", :bad}}}, :ready, core())

    assert effects == [
             {:log, :warning, "session call :open_request has no clause in :ready"},
             {:reply, {:error, :badarg}}
           ]
  end

  test "open_request with two owners registers and monitors each owner" do
    request_owner = spawn(fn -> :ok end)
    stream_owner = spawn(fn -> :ok end)

    assert {%Core{requests: requests, streams: streams}, effects} =
             Core.handle(
               {:call, {:open_request, 7, request_owner, {"st1", :sse}, stream_owner}},
               :ready,
               core()
             )

    assert requests == %{
             7 => %{owner: request_owner, runner: nil, stream_id: "st1", progress: nil}
           }

    assert %{owner: ^stream_owner, request_id: 7, mode: :sse, resumer: nil, seq: 0} =
             streams["st1"]

    assert effects == [
             {:monitor, request_owner, {:request, 7}},
             :idle_check,
             {:monitor, stream_owner, {:owner, "st1"}},
             {:reply, :ok}
           ]
  end

  test "with two owners a cancel goes to the request owner and an event to the stream owner" do
    request_owner = spawn(fn -> :ok end)
    stream_owner = spawn(fn -> :ok end)

    {core, _effects} =
      Core.handle(
        {:call, {:open_request, 7, request_owner, {"st1", :sse}, stream_owner}},
        :ready,
        core()
      )

    assert {^core, [{:send, ^request_owner, {:oz_mcp_cancel, 7, :late}}]} =
             Core.handle({:cast, {:cancel, 7, :late}}, :ready, core)

    assert {_core, [{:send, ^stream_owner, {:oz_mcp_stream, "st1", {:event, "st1:1", "x"}}}]} =
             Core.handle({:cast, {:emit, {:request, 7}, "x"}}, :ready, core)
  end

  test "promote_stream and hand_off_stream answer :ok one time, then :gone" do
    owner = spawn(fn -> :ok end)

    {core, _effects} =
      Core.handle({:call, {:open_request, 7, owner, {"st1", :sse}, owner}}, :ready, core())

    {core, [{:reply, :ok}]} = Core.handle({:call, {:promote_stream, 7, "st1"}}, :ready, core)
    assert core.streams["st1"].started == true

    {_core, [{:demonitor, {:owner, "st1"}}, {:reply, :ok}]} =
      Core.handle({:call, {:hand_off_stream, 7, "st1"}}, :ready, core)

    {core, _effects} =
      Core.handle({:call, {:close_request, 7, "st1", :detach}}, :ready, core)

    assert {^core, [{:reply, :gone}]} =
             Core.handle({:call, {:promote_stream, 7, "st1"}}, :ready, core)

    assert {^core, [{:reply, :gone}]} =
             Core.handle({:call, {:hand_off_stream, 7, "st1"}}, :ready, core)
  end

  test "a promoted stream with no event answers the response as an event of the stream" do
    owner = spawn(fn -> :ok end)

    core =
      core(%{
        opts: %{session_timeout_ms: 30_000, sse_resume_window_ms: 10_000},
        requests: %{7 => %{owner: owner, runner: nil, stream_id: "st1"}},
        streams: %{
          "st1" => %{
            owner: owner,
            resumer: nil,
            request_id: 7,
            seq: 0,
            mode: :sse,
            started: false
          }
        }
      })

    assert {core, [{:reply, :ok}]} =
             Core.handle({:call, {:promote_stream, 7, "st1"}}, :ready, core)

    assert {%Core{requests: %{}, streams: %{}}, effects} =
             Core.handle(
               {:call, {:close_request, 7, "st1", {:response, "done", false}}},
               :ready,
               core
             )

    assert effects == [
             {:demonitor, {:owner, "st1"}},
             {:timeout, {:timeout, {:log, "st1"}}, 10_000, :drop_log},
             {:reply, {:sse, "st1:1"}},
             {:demonitor, {:request, 7}},
             :idle_check
           ]
  end

  test "after the hand-off an event goes to the log only and the response is an event" do
    owner = spawn(fn -> :ok end)

    core =
      core(%{
        opts: %{session_timeout_ms: 30_000, sse_resume_window_ms: 10_000},
        requests: %{7 => %{owner: owner, runner: nil, stream_id: "st1"}},
        streams: %{
          "st1" => %{
            owner: owner,
            resumer: nil,
            request_id: 7,
            seq: 0,
            mode: :sse,
            started: false
          }
        }
      })

    assert {core, [{:demonitor, {:owner, "st1"}}, {:reply, :ok}]} =
             Core.handle({:call, {:hand_off_stream, 7, "st1"}}, :ready, core)

    assert core.streams["st1"].owner == nil

    assert {core, []} = Core.handle({:cast, {:emit, {:request, 7}, "x"}}, :ready, core)
    assert EventLog.events(core.log, "st1") == [{"st1:1", "x"}]

    assert {%Core{requests: %{}, streams: %{}} = core, effects} =
             Core.handle(
               {:call, {:close_request, 7, "st1", {:response, "done", false}}},
               :ready,
               core
             )

    assert {:reply, {:sse, "st1:2"}} in effects
    assert EventLog.events(core.log, "st1") == [{"st1:1", "x"}, {"st1:2", "done"}]
  end

  test "after the hand-off stream_owner answers the nil owner of the entry" do
    owner = spawn(fn -> :ok end)

    core =
      core(%{
        requests: %{7 => %{owner: owner, runner: nil, stream_id: "st1"}},
        streams: %{
          "st1" => %{
            owner: owner,
            resumer: nil,
            request_id: 7,
            seq: 0,
            mode: :sse,
            started: false
          }
        }
      })

    assert {core, [{:demonitor, {:owner, "st1"}}, {:reply, :ok}]} =
             Core.handle({:call, {:hand_off_stream, 7, "st1"}}, :ready, core)

    assert {^core, [{:reply, {:ok, {nil, "st1"}}}]} =
             Core.handle({:call, {:stream_owner, 7}}, :ready, core)
  end

  test "after the hand-off a resumer takes the stream over and gets the later events" do
    resumer = spawn(fn -> :ok end)

    core =
      core(%{
        opts: %{session_timeout_ms: 30_000, sse_resume_window_ms: 10_000},
        requests: %{7 => %{owner: self(), runner: nil, stream_id: "st1"}},
        streams: %{
          "st1" => %{
            owner: self(),
            resumer: nil,
            request_id: 7,
            seq: 0,
            mode: :sse,
            started: false
          }
        }
      })

    assert {core, [{:demonitor, {:owner, "st1"}}, {:reply, :ok}]} =
             Core.handle({:call, {:hand_off_stream, 7, "st1"}}, :ready, core)

    assert {core, []} = Core.handle({:cast, {:emit, {:request, 7}, "x"}}, :ready, core)

    assert {core, effects} =
             Core.handle({:call, {:open_stream, :get, resumer, "st1:0"}}, :ready, core)

    assert effects == [
             {:monitor, resumer, {:resumer, "st1"}},
             {:reply,
              {:ok,
               %{
                 mode: :resume,
                 stream_id: "st1",
                 replay: [{"st1:1", "x"}],
                 ended: false,
                 session_pid: core.pid
               }}},
             :idle_check
           ]

    {core, [{:send, ^resumer, {:oz_mcp_stream, "st1", {:event, "st1:2", "y"}}}]} =
      Core.handle({:cast, {:emit, {:request, 7}, "y"}}, :ready, core)

    assert {_core, effects} =
             Core.handle(
               {:call, {:close_request, 7, "st1", {:response, "done", false}}},
               :ready,
               core
             )

    assert Enum.any?(
             effects,
             &match?({:send, ^resumer, {:oz_mcp_stream, "st1", {:event, "st1:3", "done"}}}, &1)
           )

    assert Enum.any?(effects, &match?({:send, ^resumer, {:oz_mcp_stream, "st1", :end}}, &1))
    assert {:reply, {:sse, "st1:3"}} in effects
  end

  test "the death of the owner of a stream with another owner of the request hands the stream off" do
    request_owner = spawn(fn -> :ok end)
    stream_owner = spawn(fn -> :ok end)

    {core, _effects} =
      Core.handle(
        {:call, {:open_request, 7, request_owner, {"st1", :sse}, stream_owner}},
        :ready,
        core()
      )

    assert {core, []} = Core.handle({:down, {:owner, "st1"}, stream_owner}, :ready, core)

    # The callback goes on: the request keeps its entry and the stream is
    # a hand-off whose events and response go to the log and a resumer.
    #
    assert %{owner: ^request_owner} = core.requests[7]
    assert %{owner: nil, started: true} = core.streams["st1"]
  end

  test "the death of the owner of a stream with a resumer and another owner of the request keeps the resumer" do
    resumer = spawn(fn -> :ok end)
    request_owner = spawn(fn -> :ok end)
    stream_owner = spawn(fn -> :ok end)

    core =
      core(%{
        opts: %{session_timeout_ms: 30_000, sse_resume_window_ms: 10_000},
        requests: %{7 => %{owner: request_owner, runner: nil, stream_id: "st1"}},
        streams: %{
          "st1" => %{
            owner: stream_owner,
            resumer: resumer,
            request_id: 7,
            seq: 1,
            mode: :sse,
            started: false
          }
        },
        log: %OzMcp.Session.EventLog{}
      })

    assert {core, []} = Core.handle({:down, {:owner, "st1"}, stream_owner}, :ready, core)

    # The resumer stays: the events of the callback and the response reach it.
    #
    assert %{owner: nil, resumer: ^resumer} = core.streams["st1"]
  end

  test "the death of the owner of a request that owns its stream adds no exit" do
    owner = spawn(fn -> :ok end)

    {core, _effects} =
      Core.handle({:call, {:open_request, 7, owner, {"st1", :sse}, owner}}, :ready, core())

    assert {_core, effects} = Core.handle({:down, {:owner, "st1"}, owner}, :ready, core)

    refute Enum.any?(effects, &match?({:exit, _, _}, &1))
  end

  test "the death of the owner of a request with another stream owner frees the stream" do
    resumer = spawn(fn -> :ok end)
    request_owner = spawn(fn -> :ok end)
    stream_owner = spawn(fn -> :ok end)

    core =
      core(%{
        opts: %{session_timeout_ms: 30_000, sse_resume_window_ms: 10_000},
        requests: %{7 => %{owner: request_owner, runner: nil, stream_id: "st1"}},
        streams: %{
          "st1" => %{
            owner: stream_owner,
            resumer: resumer,
            request_id: 7,
            seq: 1,
            mode: :sse,
            started: false
          }
        },
        log: %OzMcp.Session.EventLog{}
      })

    core = OzMcp.Session.Streams.log(core, "st1", {"st1:1", "x"})

    assert {%Core{requests: %{}, streams: %{}}, effects} =
             Core.handle({:down, {:request, 7}, request_owner}, :ready, core)

    assert Enum.any?(effects, &match?({:send, ^resumer, {:oz_mcp_stream, "st1", :end}}, &1))
    assert {:demonitor, {:owner, "st1"}} in effects
    assert {:demonitor, {:resumer, "st1"}} in effects
    assert {:timeout, {:timeout, {:log, "st1"}}, 10_000, :drop_log} in effects
    assert :idle_check in effects
  end

  test "the death of the owner of a request that owns its stream leaves the stream" do
    owner = spawn(fn -> :ok end)

    core =
      core(%{
        requests: %{7 => %{owner: owner, runner: nil, stream_id: "st1"}},
        streams: %{
          "st1" => %{
            owner: owner,
            resumer: nil,
            request_id: 7,
            seq: 0,
            mode: :sse,
            started: false
          }
        }
      })

    assert {%Core{requests: %{}}, [:idle_check]} =
             Core.handle({:down, {:request, 7}, owner}, :ready, core)

    assert Map.has_key?(core.streams, "st1")
  end

  test "close_request with a response numbers the final event and frees the request" do
    core =
      core(%{
        opts: %{session_timeout_ms: 30_000, sse_resume_window_ms: 10_000},
        requests: %{7 => %{owner: self(), runner: nil, stream_id: "st1"}},
        streams: %{
          "st1" => %{owner: self(), resumer: nil, request_id: 7, seq: 1, mode: :sse}
        }
      })

    assert {%Core{requests: %{}, streams: %{}}, effects} =
             Core.handle(
               {:call, {:close_request, 7, "st1", {:response, "done", false}}},
               :ready,
               core
             )

    assert effects == [
             {:demonitor, {:owner, "st1"}},
             {:timeout, {:timeout, {:log, "st1"}}, 10_000, :drop_log},
             {:reply, {:sse, "st1:2"}},
             {:demonitor, {:request, 7}},
             :idle_check
           ]
  end

  test "close_request with a response that never started answers plain and frees the request" do
    core =
      core(%{
        requests: %{7 => %{owner: self(), runner: nil, stream_id: "st1"}},
        streams: %{
          "st1" => %{
            owner: self(),
            resumer: nil,
            request_id: 7,
            seq: 0,
            mode: :sse,
            started: false
          }
        }
      })

    assert {%Core{requests: %{}, streams: %{}}, effects} =
             Core.handle(
               {:call, {:close_request, 7, "st1", {:response, "done", false}}},
               :ready,
               core
             )

    assert effects == [
             {:demonitor, {:owner, "st1"}},
             {:reply, :plain},
             {:demonitor, {:request, 7}},
             :idle_check
           ]
  end

  test "close_request with a response and no stream entry answers gone and frees the request" do
    core = core(requests: %{7 => %{owner: self(), runner: nil, stream_id: "st1"}})

    assert {%Core{requests: %{}}, effects} =
             Core.handle(
               {:call, {:close_request, 7, "st1", {:response, "done", false}}},
               :ready,
               core
             )

    assert effects == [{:reply, :gone}, {:demonitor, {:request, 7}}, :idle_check]
  end

  test "close_request with a detach answers :ok one time, then :gone" do
    core =
      core(%{
        requests: %{7 => %{owner: self(), runner: nil, stream_id: "st1"}},
        streams: %{
          "st1" => %{owner: self(), resumer: nil, request_id: 7, seq: 0, mode: :sink}
        }
      })

    assert {%Core{requests: %{}, streams: %{}} = core, effects} =
             Core.handle({:call, {:close_request, 7, "st1", :detach}}, :ready, core)

    assert effects == [
             {:demonitor, {:owner, "st1"}},
             {:reply, :ok},
             {:demonitor, {:request, 7}},
             :idle_check
           ]

    assert {^core, [{:reply, :gone}]} =
             Core.handle({:call, {:close_request, 7, "st1", :detach}}, :ready, core)
  end

  test "close_request with an old stream id does not free the new request of that id" do
    core = core(requests: %{7 => %{owner: self(), runner: nil, stream_id: "st2"}})

    assert {^core, [{:reply, :gone}]} =
             Core.handle({:call, {:close_request, 7, "st1", :detach}}, :ready, core)
  end

  test "end_request of a request with a stream drops the entry and ends its resumer" do
    resumer = spawn(fn -> :ok end)

    core =
      core(%{
        requests: %{7 => %{owner: self(), runner: nil, stream_id: "st1"}},
        streams: %{
          "st1" => %{owner: self(), resumer: resumer, request_id: 7, seq: 0, mode: :sse}
        }
      })

    assert {%Core{requests: %{}, streams: %{}}, effects} =
             Core.handle({:cast, {:end_request, 7}}, :ready, core)

    assert effects == [
             {:send, resumer, {:oz_mcp_stream, "st1", :end}},
             {:demonitor, {:owner, "st1"}},
             {:demonitor, {:resumer, "st1"}},
             {:demonitor, {:request, 7}},
             :idle_check
           ]
  end

  test "end_request of an unknown request does nothing" do
    core = core()

    assert {^core, []} = Core.handle({:cast, {:end_request, 7}}, :ready, core)
  end

  test "a progress cast emits an increasing value and drops the others" do
    core =
      core(%{
        requests: %{7 => %{owner: self(), runner: nil, stream_id: "st1", progress: nil}},
        streams: %{
          "st1" => %{owner: self(), resumer: nil, request_id: 7, seq: 0, mode: :sse}
        }
      })

    assert {core, [{:send, pid, {:oz_mcp_stream, "st1", {:event, "st1:1", first}}}]} =
             Core.handle(
               {:cast, {:progress, {:request_or_session, 7}, "tok", 1, "one"}},
               :ready,
               core
             )

    assert pid == self()
    assert first == "one"

    assert {core, [{:send, ^pid, {:oz_mcp_stream, "st1", {:event, "st1:2", "two"}}}]} =
             Core.handle(
               {:cast, {:progress, {:request_or_session, 7}, "tok", 2, "two"}},
               :ready,
               core
             )

    assert {core, [{:log, :debug, text}]} =
             Core.handle(
               {:cast, {:progress, {:request_or_session, 7}, "tok", 2, "two"}},
               :ready,
               core
             )

    assert text == "a progress value that does not increase was dropped"
    refute text =~ "tok"
    refute text =~ "two"

    assert {^core, [{:log, :debug, ^text}]} =
             Core.handle(
               {:cast, {:progress, {:request_or_session, 7}, "tok", 1, "one"}},
               :ready,
               core
             )
  end

  test "a progress cast to the session checks by token" do
    core = core(get_streams: [%{id: "g.1", pid: self(), kind: :get, seq: 0}])

    assert {core, [{:send, pid, {:oz_mcp_stream, "g.1", {:event, "g.1:1", "one"}}}]} =
             Core.handle({:cast, {:progress, :session, "tok", 1, "one"}}, :ready, core)

    assert pid == self()

    assert {core, [{:send, ^pid, {:oz_mcp_stream, "g.1", {:event, "g.1:2", "two"}}}]} =
             Core.handle({:cast, {:progress, :session, "tok", 2, "two"}}, :ready, core)

    assert {core, [{:log, :debug, text}]} =
             Core.handle({:cast, {:progress, :session, "tok", 2, "two"}}, :ready, core)

    assert text == "a progress value that does not increase was dropped"

    assert {^core, [{:log, :debug, ^text}]} =
             Core.handle({:cast, {:progress, :session, "tok", 1, "one"}}, :ready, core)
  end

  test "a late progress report with no request entry is checked by token" do
    core = core(get_streams: [%{id: "g.1", pid: self(), kind: :get, seq: 0}])

    assert {core, [{:send, pid, {:oz_mcp_stream, "g.1", {:event, "g.1:1", "one"}}}]} =
             Core.handle(
               {:cast, {:progress, {:request_or_session, 99}, "tok", 1, "one"}},
               :ready,
               core
             )

    assert pid == self()

    assert {^core, [{:log, :debug, text}]} =
             Core.handle(
               {:cast, {:progress, {:request_or_session, 99}, "tok", 1, "one"}},
               :ready,
               core
             )

    assert text == "a progress value that does not increase was dropped"
  end

  describe "idle_timer/1" do
    test "each holder cancels the timer and the step that ends it arms it again" do
      holders = [
        {"a GET stream",
         fn ->
           opts = %{
             session_timeout_ms: 30_000,
             max_streams_per_session: nil,
             sse_resume_window_ms: 0
           }

           {core, _effects} =
             Core.handle(
               {:call, {:open_stream, :get, self(), nil}},
               :ready,
               core(view: %View{}, opts: opts)
             )

           core
         end, fn core -> Core.handle({:call, {:close_stream, self()}}, :ready, core) end},
        {"a request",
         fn ->
           {core, _effects} =
             Core.handle({:call, {:open_request, 7, self(), nil}}, :ready, core())

           core
         end, fn core -> Core.handle({:cast, {:end_request, 7}}, :ready, core) end},
        {"a POST stream",
         fn ->
           {core, _effects} =
             Core.handle(
               {:call, {:open_request, 7, self(), {"st1", :sse}, self()}},
               :ready,
               core()
             )

           core
         end,
         fn core ->
           {core, _effects} = Core.handle({:down, {:request, 7}, self()}, :ready, core)
           Core.handle({:down, {:owner, "st1"}, self()}, :ready, core)
         end},
        {"a request to the client",
         fn ->
           opts = %{session_timeout_ms: 30_000, sse_resume_window_ms: 0}

           {core, _effects} =
             Core.handle(
               {:call, {:request_client, self(), {:request, "req"}, "ping", nil}},
               :ready,
               core(opts: opts)
             )

           core
         end,
         fn core ->
           assert [out_id] = Map.keys(core.outbound)
           Core.handle({:cast, {:deliver_outbound, out_id, {:ok, %{}}}}, :ready, core)
         end},
        {"a tracked task that follows the session",
         fn ->
           opts = %{session_timeout_ms: 30_000, tasks_follow_session: true}

           {core, _effects} =
             Core.handle({:cast, {:track_task, "task-1", self()}}, :ready, core(opts: opts))

           core
         end,
         fn core ->
           {core, _effects} = Core.handle({:cast, {:untrack_task, "task-1"}}, :ready, core)
           Core.handle({:down, {:task, "task-1"}, self()}, :ready, core)
         end}
      ]

      for {name, holder, end_step} <- holders do
        assert {{:timeout, :idle}, :cancel} = Core.idle_timer(holder.()),
               "#{name}: the holder cancels the idle timer"

        {core, effects} = end_step.(holder.())

        assert :idle_check in effects, "#{name}: the step that ends it gives :idle_check"
        assert Core.idle?(core), "#{name}: no holder is left"

        assert {{:timeout, :idle}, 30_000, :idle} = Core.idle_timer(core),
               "#{name}: the end of the holder arms the idle timer"
      end
    end

    test "a tracked task leaves the timer armed when the tasks do not follow the session" do
      assert {{:timeout, :idle}, 30_000, :idle} =
               Core.idle_timer(core(tasks: MapSet.new(["task-1"])))
    end
  end

  describe "idle?/1" do
    test "a new session is idle" do
      assert Core.idle?(core())
    end

    test "a GET stream or a stdio stream keeps the session busy" do
      refute Core.idle?(core(get_streams: [%{id: "g.1", pid: self(), kind: :get, seq: 0}]))
      refute Core.idle?(core(get_streams: [%{id: "s.1", pid: self(), kind: :stdio, seq: 0}]))
    end

    test "a POST stream keeps the session busy" do
      refute Core.idle?(core(streams: %{"st1" => %{owner: self(), request_id: 7}}))
    end

    test "a request in flight keeps the session busy" do
      refute Core.idle?(core(requests: %{7 => %{owner: self(), runner: nil, stream_id: nil}}))
    end

    test "a request to the client keeps the session busy" do
      refute Core.idle?(core(outbound: %{"out-1" => %{waiter: self()}}))
    end

    test "a tracked task keeps the session busy when the tasks follow it" do
      opts = %{session_timeout_ms: 30_000, tasks_follow_session: true}
      core = core(opts: opts, tasks: MapSet.new(["task-1"]))

      refute Core.idle?(core)
    end

    test "a tracked task leaves the session idle when the tasks do not follow it" do
      assert Core.idle?(core(tasks: MapSet.new(["task-1"])))
    end
  end

  describe "the end of a holder gives :idle_check" do
    test "a POST stream that its request owner made ends with the DOWN of the owner" do
      owner = spawn(fn -> :ok end)

      {core, effects} =
        Core.handle({:call, {:open_request, 7, owner, {"st1", :sse}, owner}}, :ready, core())

      assert :idle_check in effects

      {core, effects} = Core.handle({:down, {:request, 7}, owner}, :ready, core)
      assert :idle_check in effects
      assert Map.has_key?(core.streams, "st1")

      {core, effects} = Core.handle({:down, {:owner, "st1"}, owner}, :ready, core)

      assert :idle_check in effects
      assert core.streams == %{}
    end

    test "a request to the client is held by request_client and released by each of its ends" do
      waiter = spawn(fn -> :ok end)
      core = core(get_streams: [%{id: "g.1", pid: self(), kind: :get, seq: 0}])

      {core, effects} =
        Core.handle(
          {:call, {:request_client, waiter, {:request, "req-1"}, "ping", nil}},
          :ready,
          core
        )

      assert :idle_check in effects
      assert [out_id] = Map.keys(core.outbound)

      {core, effects} =
        Core.handle({:cast, {:deliver_outbound, out_id, {:ok, %{}}}}, :ready, core)

      assert :idle_check in effects
      assert core.outbound == %{}

      {core, _effects} =
        Core.handle(
          {:call, {:request_client, waiter, {:request, "req-2"}, "ping", nil}},
          :ready,
          core
        )

      assert [out_id] = Map.keys(core.outbound)

      {core, effects} = Core.handle({:call, {:cancel_outbound, out_id}}, :ready, core)

      assert :idle_check in effects
      assert core.outbound == %{}

      {core, _effects} =
        Core.handle(
          {:call, {:request_client, waiter, {:request, "req-3"}, "ping", nil}},
          :ready,
          core
        )

      {core, effects} = Core.handle({:call, {:abandon_waiter, waiter, "gone"}}, :ready, core)

      assert :idle_check in effects
      assert core.outbound == %{}

      {core, _effects} =
        Core.handle(
          {:call, {:request_client, waiter, {:request, "req-4"}, "ping", nil}},
          :ready,
          core
        )

      assert [out_id] = Map.keys(core.outbound)

      {core, effects} = Core.handle({:down, {:outbound, out_id}, waiter}, :ready, core)

      assert :idle_check in effects
      assert core.outbound == %{}
    end

    test "a tracked task is held by track_task and released by untrack_task" do
      {core, effects} = Core.handle({:cast, {:track_task, "task-1", self()}}, :ready, core())

      assert effects == [{:monitor, self(), {:task, "task-1"}}, :idle_check]
      assert MapSet.member?(core.tasks, "task-1")

      {core, effects} = Core.handle({:cast, {:untrack_task, "task-1"}}, :ready, core)

      assert effects == [{:demonitor, {:task, "task-1"}}, :idle_check]
      assert core.tasks == MapSet.new()
    end

    test "the DOWN of a tracked task frees it and arms the idle timer" do
      opts = %{session_timeout_ms: 30_000, tasks_follow_session: true}

      {core, _effects} =
        Core.handle({:cast, {:track_task, "task-1", self()}}, :ready, core(opts: opts))

      assert {{:timeout, :idle}, :cancel} = Core.idle_timer(core)

      {core, effects} = Core.handle({:down, {:task, "task-1"}, self()}, :ready, core)

      assert effects == [:idle_check]
      assert core.tasks == MapSet.new()

      assert {{:timeout, :idle}, 30_000, :idle} = Core.idle_timer(core)
    end
  end

  test "an evict call in :closing gives no_session" do
    assert {%Core{}, effects} = Core.handle({:call, :evict}, :closing, core())

    assert effects == [
             {:log, :debug, "session call :evict refused: the session is closing"},
             {:reply, {:error, :no_session}}
           ]
  end

  test "an evict call on a busy session gives busy and keeps it" do
    core = core(get_streams: [%{id: "g.1", pid: self(), kind: :get, seq: 0}])

    assert {%Core{retired: false} = core, effects} = Core.handle({:call, :evict}, :ready, core)
    assert effects == [{:reply, {:error, :busy}}]
    assert core.get_streams != []
  end

  test "an evict call on an idle session retires it and stops it" do
    assert {%Core{retired: true} = core, effects} =
             Core.handle({:call, :evict}, :ready, ending_core())

    assert {:reply, :ok} in effects
    assert {:next_state, :closing} in effects
    assert {:next_event, :internal, {:close, :evicted}} in effects

    assert {_core, [{:stop, {:shutdown, :evicted}}]} =
             Core.handle({:internal, {:close, :evicted}}, :closing, core)
  end

  test "new/4 takes the view and its pid" do
    pid = spawn(fn -> :ok end)
    view = %View{pid: pid, protocol_version: "2025-06-18"}
    attrs = %{session_id: "session", subscriptions: ["file:///a.md"]}

    opts = %{
      sse_event_log_size: 10,
      sse_event_log_bytes: 1_024,
      sse_event_log_session_bytes: nil,
      sse_event_log_max_streams: nil
    }

    core = Core.new(__MODULE__, attrs, opts, view)

    assert core.view == view
    assert core.pid == pid
    assert core.id == "session"
    assert core.subscriptions == MapSet.new(["file:///a.md"])
  end

  test "a call with no clause in :ready warns and gives badarg" do
    assert {%Core{}, effects} = Core.handle({:call, :unknown}, :ready, core())

    assert effects == [
             {:log, :warning, "session call :unknown has no clause in :ready"},
             {:reply, {:error, :badarg}}
           ]
  end

  test "a call with no clause in :closing logs and gives no_session" do
    assert {%Core{}, effects} = Core.handle({:call, :unknown}, :closing, core())

    assert effects == [
             {:log, :debug, "session call :unknown refused: the session is closing"},
             {:reply, {:error, :no_session}}
           ]
  end

  test "a terminate call replies before the internal stop" do
    {core, effects} = Core.handle({:call, {:terminate, :done}}, :ready, ending_core())

    reply = Enum.find_index(effects, &match?({:reply, :ok}, &1))
    close = Enum.find_index(effects, &match?({:next_event, :internal, {:close, :done}}, &1))

    assert is_integer(reply)
    assert is_integer(close)
    assert reply < close

    assert {_core, [{:stop, {:shutdown, :done}}]} =
             Core.handle({:internal, {:close, :done}}, :closing, core)
  end

  test "the end of the session stops the span first" do
    assert {_core, [{:span_stop, %{reason: :terminated}} | effects]} =
             Core.terminate(ending_core(), {:shutdown, :terminated})

    assert effects == [{:unregister, :names}]
  end

  test "the DOWN of an owner with no callback only frees the id" do
    core = core(requests: %{7 => %{owner: self(), runner: nil, stream_id: nil}})

    assert {%Core{requests: %{}}, [:idle_check]} =
             Core.handle({:down, {:request, 7}, self()}, :ready, core)
  end

  test "the DOWN of an unknown request does nothing" do
    assert {%Core{requests: %{}}, []} =
             Core.handle({:down, {:request, 7}, self()}, :ready, core())
  end

  test "the DOWN of an owner of a running request stops the callback in order" do
    runner = self()

    core =
      core(%{
        requests: %{7 => %{owner: self(), runner: runner, stream_id: nil}},
        outbound: %{"out-1" => %{waiter: runner, route: {:request, "req-1"}}},
        opts: %{session_timeout_ms: 30_000, request_cancel_grace_ms: 10},
        get_streams: [%{id: "g.1", pid: self(), kind: :get, seq: 0}]
      })

    assert {%Core{requests: %{}, outbound: %{}}, effects} =
             Core.handle({:down, {:request, 7}, self()}, :ready, core)

    assert [
             {:log, :warning, "the caller of a running request went away, stopping the callback"},
             {:demonitor, {:outbound, "out-1"}},
             {:send, pid, {:oz_mcp_stream, "g.1", {:event, "g.1:1", encoded}}},
             {:exit, ^runner, :shutdown},
             {:send_after, 10, {:kill_callback, ^runner}},
             :idle_check
           ] = effects

    assert pid == self()
    assert decode(encoded)["method"] == "notifications/cancelled"
  end

  test "the end of the session stops the tasks with the option" do
    core =
      ending_core(%{
        opts: %{session_timeout_ms: 30_000, session_snapshot: None, tasks_follow_session: true},
        tasks: MapSet.new(["task-1"])
      })

    assert {_core, effects} = Core.terminate(core, :normal)
    assert List.last(effects) == {:end_tasks, MapSet.new(["task-1"])}
  end

  describe "the last activity time" do
    defp stamp_core(attrs \\ %{}) do
      core(Map.merge(%{clock: StepClock, view: %View{last_active_ms: 0}}, attrs))
    end

    test "a new view holds the time of its last activity" do
      assert %View{last_active_ms: 123} = View.new(nil, %{}, 123)
    end

    test "a step with idle_check inside the same second gives no view" do
      set_now(500)

      assert {_core, effects} = Core.handle({:cast, {:touch, nil}}, :ready, stamp_core())

      assert :idle_check in effects
      refute Enum.any?(effects, &match?({:view, _}, &1))
    end

    test "one second later gives a view with the new stamp" do
      set_now(1_000)

      assert {%Core{view: view}, effects} =
               Core.handle({:cast, {:touch, nil}}, :ready, stamp_core())

      assert {:view, ^view} = List.last(effects)
      assert view.last_active_ms == 1_000
    end

    test "an untrack_task cast one second later gives a view and an idle_check" do
      set_now(1_500)

      assert {%Core{view: view}, effects} =
               Core.handle({:cast, {:untrack_task, "task-1"}}, :ready, stamp_core())

      assert :idle_check in effects
      assert {:view, ^view} = List.last(effects)
      assert view.last_active_ms == 1_500
    end

    test "a nested event stamps one time" do
      set_now(2_000)
      owner = spawn(fn -> :ok end)

      assert {%Core{view: view}, effects} =
               Core.handle({:call, {:open_request, 7, owner, nil}}, :ready, stamp_core())

      assert [{:view, ^view}] = Enum.filter(effects, &match?({:view, _}, &1))
      assert view.last_active_ms == 2_000
    end

    test "a core with no view is not stamped" do
      set_now(1_000)

      assert {%Core{}, effects} = Core.handle({:cast, {:touch, nil}}, :ready, core())

      assert :idle_check in effects
      refute Enum.any?(effects, &match?({:view, _}, &1))
    end
  end

  describe "the rate of the log notifications" do
    defp set_now(now), do: Process.put(:step_clock_now, now)

    defp log_core(extra \\ %{}) do
      core(
        Map.merge(
          %{
            clock: StepClock,
            view: %View{initialized: true, log_level: :error},
            opts: %{session_timeout_ms: 30_000, max_log_rate: 2},
            get_streams: [%{id: "g.1", pid: self(), kind: :get, seq: 0}]
          },
          extra
        )
      )
    end

    test "a log cast emits at the rate and the first drop arms the report timer" do
      set_now(0)
      core = log_core()

      assert {core, [{:send, pid, {:oz_mcp_stream, "g.1", {:event, "g.1:1", "one"}}}]} =
               Core.handle({:cast, {:log, :session, "one"}}, :ready, core)

      assert pid == self()

      assert {core, [{:send, ^pid, {:oz_mcp_stream, "g.1", {:event, "g.1:2", "two"}}}]} =
               Core.handle({:cast, {:log, :session, "two"}}, :ready, core)

      assert {%Core{log_dropped: 1}, [{:timeout, {:timeout, :log_drops}, 1_000, :report}]} =
               Core.handle({:cast, {:log, :session, "three"}}, :ready, core)

      set_now(500)

      assert {_core, [{:send, ^pid, {:oz_mcp_stream, "g.1", {:event, "g.1:3", "four"}}}]} =
               Core.handle({:cast, {:log, :session, "four"}}, :ready, core)
    end

    test "a drop after a report arms the timer again" do
      set_now(0)
      core = log_core(%{opts: %{session_timeout_ms: 30_000, max_log_rate: 1}})

      assert {core, [{:send, _, {:oz_mcp_stream, "g.1", {:event, "g.1:1", "one"}}}]} =
               Core.handle({:cast, {:log, :session, "one"}}, :ready, core)

      assert {core, [{:timeout, {:timeout, :log_drops}, 1_000, :report}]} =
               Core.handle({:cast, {:log, :session, "two"}}, :ready, core)

      assert {core,
              [
                {:telemetry, :log_dropped, %{count: 1}, %{}},
                {:log, :warning, "1 log notifications were dropped by max_log_rate"}
              ]} =
               Core.handle({{:timeout, :log_drops}, :report}, :ready, core)

      assert %Core{log_dropped: 0} = core

      assert {core, [{:timeout, {:timeout, :log_drops}, 1_000, :report}]} =
               Core.handle({:cast, {:log, :session, "three"}}, :ready, core)

      assert {_core, []} = Core.handle({:cast, {:log, :session, "four"}}, :ready, core)
    end

    test "the report of the window gives one event and one line with the count" do
      core = %{log_core() | log_dropped: 5}

      assert {%Core{log_dropped: 0}, effects} =
               Core.handle({{:timeout, :log_drops}, :report}, :ready, core)

      assert effects == [
               {:telemetry, :log_dropped, %{count: 5}, %{}},
               {:log, :warning, "5 log notifications were dropped by max_log_rate"}
             ]
    end

    test "a report with no drop gives no effect" do
      assert {core, []} = Core.handle({{:timeout, :log_drops}, :report}, :ready, log_core())
      assert core.log_dropped == 0
    end

    test "a rate of nil reads no clock and makes no bucket" do
      core = log_core(%{clock: NoClock, opts: %{session_timeout_ms: 30_000, max_log_rate: nil}})

      assert {core, [{:send, _, {:oz_mcp_stream, "g.1", {:event, "g.1:1", "one"}}}]} =
               Core.handle({:cast, {:log, :session, "one"}}, :ready, core)

      assert {core, [{:send, _, {:oz_mcp_stream, "g.1", {:event, "g.1:2", "two"}}}]} =
               Core.handle({:cast, {:log, :session, "two"}}, :ready, core)

      assert {%Core{log_bucket: nil, log_dropped: 0},
              [{:send, _, {:oz_mcp_stream, "g.1", {:event, "g.1:3", "three"}}}]} =
               Core.handle({:cast, {:log, :session, "three"}}, :ready, core)
    end

    test "a broadcast with a level that the session refuses uses no token" do
      set_now(0)
      core = log_core()

      assert {^core, []} =
               Core.handle(
                 {:info, {:oz_mcp_broadcast, {:session_event, {:log, :debug}, "debug"}}},
                 :ready,
                 core
               )

      assert core.log_bucket == nil
      assert core.log_dropped == 0

      assert {_core, [{:send, _, {:oz_mcp_stream, "g.1", {:event, "g.1:1", "error"}}}]} =
               Core.handle(
                 {:info, {:oz_mcp_broadcast, {:session_event, {:log, :error}, "error"}}},
                 :ready,
                 core
               )
    end

    test "a log over the rate does not hold back a progress report or a response" do
      set_now(0)

      core =
        log_core(%{
          opts: %{session_timeout_ms: 30_000, max_log_rate: 1},
          requests: %{7 => %{owner: self(), runner: nil, stream_id: "st1", progress: nil}},
          streams: %{
            "st1" => %{owner: self(), resumer: nil, request_id: 7, seq: 0, mode: :sse}
          }
        })

      assert {core, [{:send, _, {:oz_mcp_stream, "g.1", {:event, "g.1:1", "one"}}}]} =
               Core.handle({:cast, {:log, :session, "one"}}, :ready, core)

      assert {core, [{:timeout, {:timeout, :log_drops}, 1_000, :report}]} =
               Core.handle({:cast, {:log, :session, "two"}}, :ready, core)

      assert {core, [{:send, _, {:oz_mcp_stream, "st1", {:event, "st1:1", "one"}}}]} =
               Core.handle(
                 {:cast, {:progress, {:request_or_session, 7}, "tok", 1, "one"}},
                 :ready,
                 core
               )

      assert {_core, [{:send, _, {:oz_mcp_stream, "g.1", {:event, "g.1:2", "{}"}}}]} =
               Core.handle({:cast, {:emit, :session, "{}"}}, :ready, core)
    end
  end
end
