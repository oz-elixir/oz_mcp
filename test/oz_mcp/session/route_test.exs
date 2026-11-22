defmodule OzMcp.Session.RouteTest do
  use ExUnit.Case, async: true

  alias OzMcp.Session.{Core, EventLog, Route, View}

  defp core(attrs) do
    struct!(
      %Core{
        instance: __MODULE__,
        id: "session",
        pid: self(),
        view: %View{initialized: true, pid: self()},
        opts: %{sse_resume_window_ms: 10_000},
        log: EventLog.new(100, 10_000)
      },
      attrs
    )
  end

  defp sse_request(owner, request_id, stream_id) do
    %{
      requests: %{request_id => %{owner: owner, runner: nil, stream_id: stream_id}},
      streams: %{
        stream_id => %{
          owner: owner,
          resumer: nil,
          request_id: request_id,
          seq: 0,
          mode: :sse
        }
      }
    }
  end

  test "a request with a stream sends the message to its owner" do
    owner = spawn(fn -> :ok end)

    core =
      core(sse_request(owner, "req-1", "st1"))

    assert {%Core{} = core, effects} = Route.request_or_session(core, "req-1", "message")

    assert effects == [{:send, owner, {:oz_mcp_stream, "st1", {:event, "st1:1", "message"}}}]
    assert core.streams["st1"].seq == 1
  end

  test "a sink stream sends the message with no id" do
    owner = spawn(fn -> :ok end)

    core =
      core(%{
        requests: %{"req-1" => %{owner: owner, runner: nil, stream_id: "st1"}},
        streams: %{
          "st1" => %{
            owner: owner,
            resumer: nil,
            request_id: "req-1",
            seq: 0,
            mode: :sink
          }
        }
      })

    assert {%Core{}, effects} = Route.request_or_session(core, "req-1", "message")
    assert effects == [{:send, owner, {:oz_mcp_stream, "st1", {:event, nil, "message"}}}]
  end

  test "a request with no stream sends the message to the GET stream" do
    pid = spawn(fn -> :ok end)

    core =
      core(%{
        requests: %{"req-1" => %{owner: pid, runner: nil, stream_id: nil}},
        get_streams: [%{id: "g.1", pid: pid, kind: :get, seq: 0}]
      })

    assert {%Core{} = core, effects} = Route.request_or_session(core, "req-1", "message")

    assert effects == [{:send, pid, {:oz_mcp_stream, "g.1", {:event, "g.1:1", "message"}}}]
    assert hd(core.get_streams).seq == 1
  end

  test "an unknown request sends the message to the GET stream" do
    pid = spawn(fn -> :ok end)

    core = core(%{get_streams: [%{id: "g.1", pid: pid, kind: :get, seq: 0}]})

    assert {%Core{}, effects} = Route.request_or_session(core, "req-1", "message")
    assert effects == [{:send, pid, {:oz_mcp_stream, "g.1", {:event, "g.1:1", "message"}}}]
  end
end
