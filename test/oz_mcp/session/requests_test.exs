defmodule OzMcp.Session.RequestsTest do
  use ExUnit.Case, async: true

  alias OzMcp.Session.{Core, Requests}

  defp core(attrs \\ %{}) do
    struct!(
      %Core{
        instance: __MODULE__,
        id: "session",
        opts: %{request_cancel_grace_ms: 10, session_timeout_ms: 30_000},
        pid: self()
      },
      attrs
    )
  end

  test "register/3 stores the entry, monitors the owner and checks the idle timer" do
    owner = spawn(fn -> :ok end)

    assert {:ok, %Core{requests: requests}, effects} = Requests.register(core(), 7, owner)

    assert requests == %{7 => %{owner: owner, runner: nil, stream_id: nil, progress: nil}}

    assert effects == [{:monitor, owner, {:request, 7}}, :idle_check]
  end

  test "register/3 refuses a duplicate id with the warning and stores nothing" do
    owner = spawn(fn -> :ok end)
    core = core(requests: %{7 => %{owner: owner, runner: nil, stream_id: nil}})

    assert {:error, :duplicate, effects} = Requests.register(core, 7, self())

    assert effects == [{:log, :warning, "request id 7 is already in use"}]
  end

  test "a callback attaches to a request with no callback" do
    runner = spawn(fn -> :ok end)
    core = core(requests: %{7 => %{owner: self(), runner: nil, stream_id: nil}})

    assert {%Core{requests: %{7 => %{runner: ^runner}}}, [{:reply, :ok}]} =
             Requests.attach_runner(core, 7, runner)
  end

  test "a second callback keeps the first one" do
    runner = spawn(fn -> :ok end)
    core = core(requests: %{7 => %{owner: self(), runner: runner, stream_id: nil}})

    assert {^core, [{:reply, :ok}]} = Requests.attach_runner(core, 7, self())
  end

  test "a callback for an unknown request is refused" do
    assert {%Core{requests: %{}}, [{:reply, {:error, :no_request}}]} =
             Requests.attach_runner(core(), 7, self())
  end

  test "the owner of a request with a stream is answered" do
    owner = spawn(fn -> :ok end)
    core = core(requests: %{7 => %{owner: owner, runner: nil, stream_id: "st1"}})

    assert {^core, [{:reply, {:ok, {^owner, "st1"}}}]} = Requests.owner(core, 7)
  end

  test "the owner of the entry of the stream is answered, also nil" do
    owner = spawn(fn -> :ok end)

    core =
      core(
        requests: %{7 => %{owner: owner, runner: nil, stream_id: "st1"}},
        streams: %{"st1" => %{owner: nil, resumer: nil, request_id: 7, seq: 1, mode: :sse}}
      )

    assert {^core, [{:reply, {:ok, {nil, "st1"}}}]} = Requests.owner(core, 7)
  end

  test "the owner of the entry of the stream is another process than the owner of the request" do
    owner = spawn(fn -> :ok end)
    stream_owner = spawn(fn -> :ok end)

    core =
      core(
        requests: %{7 => %{owner: owner, runner: nil, stream_id: "st1"}},
        streams: %{
          "st1" => %{owner: stream_owner, resumer: nil, request_id: 7, seq: 0, mode: :sse}
        }
      )

    assert {^core, [{:reply, {:ok, {^stream_owner, "st1"}}}]} = Requests.owner(core, 7)
  end

  test "a request with no stream has no owner" do
    core = core(requests: %{7 => %{owner: self(), runner: nil, stream_id: nil}})

    assert {^core, [{:reply, :none}]} = Requests.owner(core, 7)
  end

  test "an unknown request has no owner" do
    assert {%Core{requests: %{}}, [{:reply, :none}]} = Requests.owner(core(), 7)
  end

  test "the end of a request frees the id and checks the idle timer" do
    core = core(requests: %{7 => %{owner: self(), runner: nil, stream_id: nil}})

    assert {%Core{requests: %{}}, [{:demonitor, {:request, 7}}, :idle_check]} =
             Requests.finish(core, 7)
  end

  test "the end of an unknown request does nothing" do
    assert {%Core{requests: %{}}, []} = Requests.finish(core(), 7)
  end

  test "a cancel goes to the owner of the request" do
    owner = spawn(fn -> :ok end)
    core = core(requests: %{7 => %{owner: owner, runner: nil, stream_id: nil}})

    assert {^core, [{:send, ^owner, {:oz_mcp_cancel, 7, :session_terminated}}]} =
             Requests.cancel(core, 7, :session_terminated)
  end

  test "a cancel for an unknown request does nothing" do
    assert {%Core{requests: %{}}, []} = Requests.cancel(core(), 7, :session_terminated)
  end

  test "a new request has no last progress value" do
    owner = spawn(fn -> :ok end)

    assert {:ok, %Core{requests: %{7 => %{progress: nil}}}, _effects} =
             Requests.register(core(), 7, owner)
  end

  test "check_progress/4 accepts an increasing value and drops the others" do
    core = core(requests: %{7 => %{owner: self(), runner: nil, stream_id: nil, progress: nil}})

    assert {:ok, %Core{requests: %{7 => %{progress: 1}}} = core} =
             Requests.check_progress(core, {:request_or_session, 7}, "tok", 1)

    assert {:ok, %Core{requests: %{7 => %{progress: 2}}} = core} =
             Requests.check_progress(core, {:request_or_session, 7}, "tok", 2)

    assert {:drop, ^core} = Requests.check_progress(core, {:request_or_session, 7}, "tok", 2)
    assert {:drop, ^core} = Requests.check_progress(core, {:request_or_session, 7}, "tok", 1)
  end

  test "check_progress/4 accepts a first value when the entry has no progress key" do
    core = core(requests: %{7 => %{owner: self(), runner: nil, stream_id: nil}})

    assert {:ok, %Core{requests: %{7 => %{progress: 1}}}} =
             Requests.check_progress(core, {:request_or_session, 7}, "tok", 1)
  end

  test "check_progress/4 of a request with no entry is checked by token" do
    core = core()

    assert {:ok, %Core{progress: {%{"tok" => 1}, _order}} = core} =
             Requests.check_progress(core, {:request_or_session, 7}, "tok", 1)

    assert {:drop, ^core} = Requests.check_progress(core, {:request_or_session, 7}, "tok", 1)
    assert {:drop, ^core} = Requests.check_progress(core, {:request_or_session, 7}, "tok", 0)

    assert {:ok, %Core{progress: {%{"tok" => 2}, _order}}} =
             Requests.check_progress(core, {:request_or_session, 7}, "tok", 2)
  end

  test "check_progress/4 of the session target is checked by token" do
    core = core()

    assert {:ok, %Core{progress: {%{"tok" => 1}, _order}} = core} =
             Requests.check_progress(core, :session, "tok", 1)

    assert {:drop, ^core} = Requests.check_progress(core, :session, "tok", 1)
  end

  test "check_progress/4 keeps one value per token in the bounded map" do
    core = core()

    assert {:ok, core} = Requests.check_progress(core, :session, "tok-a", 1)
    assert {:ok, core} = Requests.check_progress(core, :session, "tok-b", 10)

    assert {:ok, %Core{progress: {%{"tok-a" => 2, "tok-b" => 10}, _order}} = core} =
             Requests.check_progress(core, :session, "tok-a", 2)

    assert {:drop, ^core} = Requests.check_progress(core, :session, "tok-a", 2)
  end

  test "pop_owner/2 gives the runner and the stream of the request" do
    runner = spawn(fn -> :ok end)
    core = core(requests: %{7 => %{owner: self(), runner: runner, stream_id: "st1"}})

    assert {%Core{requests: %{}}, ^runner, "st1"} = Requests.pop_owner(core, 7)
  end

  test "pop_owner/2 of a request with no runner and no stream gives nils" do
    core = core(requests: %{7 => %{owner: self(), runner: nil, stream_id: nil}})

    assert {%Core{requests: %{}}, :no_runner, nil} = Requests.pop_owner(core, 7)
  end

  test "pop_owner/2 of an unknown request gives nils" do
    assert {%Core{requests: %{}}, nil, nil} = Requests.pop_owner(core(), 7)
  end

  test "a request keeps its stream until the stream ends" do
    core = core(requests: %{7 => %{owner: self(), runner: nil, stream_id: "st1"}})

    assert %Core{requests: %{7 => %{stream_id: nil}}} = Requests.clear_stream(core, 7)
  end

  test "a request with no stream or an unknown request does not change" do
    core = core(requests: %{7 => %{owner: self(), runner: nil, stream_id: nil}})

    assert ^core = Requests.clear_stream(core, 7)
    assert ^core = Requests.clear_stream(core, 8)
  end

  test "the end of the session cancels each owner" do
    one = spawn(fn -> :ok end)
    two = spawn(fn -> :ok end)

    core =
      core(
        requests: %{
          7 => %{owner: one, runner: nil, stream_id: nil},
          8 => %{owner: two, runner: nil, stream_id: nil}
        }
      )

    assert {^core, effects} = Requests.end_all(core)

    assert effects == [
             {:send, one, {:oz_mcp_cancel, 7, :session_terminated}},
             {:send, two, {:oz_mcp_cancel, 8, :session_terminated}}
           ]
  end

  test "the end of the session with no request sends nothing" do
    assert {%Core{requests: %{}}, []} = Requests.end_all(core())
  end
end
