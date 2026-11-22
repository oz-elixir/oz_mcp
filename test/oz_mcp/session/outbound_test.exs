defmodule OzMcp.Session.OutboundTest do
  use ExUnit.Case, async: true

  alias OzMcp.Session.{Core, Outbound}

  defmodule SequentialIds do
    def request_id do
      n = Process.get(:session_outbound_ids, 0) + 1
      Process.put(:session_outbound_ids, n)
      "out-#{n}"
    end
  end

  defmodule QueuedIds do
    def request_id do
      [id | rest] = Process.get(:session_outbound_ids)
      Process.put(:session_outbound_ids, rest)
      id
    end
  end

  defp core(attrs \\ %{}) do
    struct!(
      %Core{
        instance: __MODULE__,
        id: "session",
        opts: %{},
        pid: self(),
        ids: SequentialIds,
        get_streams: [%{id: "g.1", pid: self(), kind: :get, seq: 0}]
      },
      attrs
    )
  end

  defp decode(encoded), do: encoded |> IO.iodata_to_binary() |> :json.decode()

  test "a request stores its entry and routes its first message" do
    waiter = spawn(fn -> :ok end)

    assert {core, effects} =
             Outbound.request(core(), waiter, {:request, "req-1"}, "ping", %{"a" => 1})

    assert core.outbound == %{"out-1" => %{waiter: waiter, route: {:request, "req-1"}}}

    assert [
             {:send, pid, {:oz_mcp_stream, "g.1", {:event, "g.1:1", encoded}}},
             {:monitor, ^waiter, {:outbound, "out-1"}},
             {:reply, {:ok, "out-1", pid}},
             :idle_check
           ] = effects

    assert pid == self()

    assert decode(encoded) == %{
             "jsonrpc" => "2.0",
             "id" => "out-1",
             "method" => "ping",
             "params" => %{"a" => 1}
           }
  end

  test "a message that JSON cannot encode stores nothing" do
    assert {%Core{outbound: outbound}, [{:reply, {:error, :not_encodable}}]} =
             Outbound.request(core(), self(), {:request, "req-1"}, "ping", %{"pid" => self()})

    assert outbound == %{}
  end

  test "the id of a request avoids the pending ones" do
    Process.put(:session_outbound_ids, ["out-1", "out-1", "out-2"])
    core = core(ids: QueuedIds)

    {core, _effects} = Outbound.request(core, self(), {:request, "req-1"}, "ping", nil)

    assert Map.keys(core.outbound) == ["out-1"]

    {core, effects} = Outbound.request(core, self(), {:request, "req-1"}, "ping", nil)
    assert Map.keys(core.outbound) == ["out-1", "out-2"]
    assert {:reply, {:ok, "out-2", _pid}} = Enum.at(effects, -2)
    assert :idle_check in effects
  end

  test "an answer goes to the waiter and ends the monitor" do
    waiter = spawn(fn -> :ok end)
    core = core(outbound: %{"out-1" => %{waiter: waiter, route: {:request, "req-1"}}})

    assert {%Core{outbound: %{}}, effects} = Outbound.deliver(core, "out-1", {:ok, %{"r" => 1}})

    assert effects == [
             {:demonitor, {:outbound, "out-1"}},
             {:send, waiter, {:oz_mcp_client_answer, "out-1", {:ok, %{"r" => 1}}}},
             :idle_check
           ]
  end

  test "an answer for an unknown id does nothing" do
    assert {%Core{outbound: %{}}, []} = Outbound.deliver(core(), "out-1", {:ok, %{}})
  end

  test "a cancel tells the client to forget the request" do
    waiter = spawn(fn -> :ok end)
    core = core(outbound: %{"out-1" => %{waiter: waiter, route: {:request, "req-1"}}})

    assert {%Core{outbound: %{}}, effects} = Outbound.cancel(core, "out-1", "request timed out")

    assert [
             {:demonitor, {:outbound, "out-1"}},
             {:send, pid, {:oz_mcp_stream, "g.1", {:event, "g.1:1", encoded}}},
             {:reply, :ok},
             :idle_check
           ] = effects

    assert pid == self()

    assert decode(encoded) == %{
             "jsonrpc" => "2.0",
             "method" => "notifications/cancelled",
             "params" => %{"requestId" => "out-1", "reason" => "request timed out"}
           }
  end

  test "a cancel of an unknown id answers ok with no effect" do
    assert {%Core{outbound: %{}}, [{:reply, :ok}]} = Outbound.cancel(core(), "out-1", "reason")
  end

  test "an abandon gives a demonitor and a notice for each entry of the waiter" do
    waiter = self()
    other = spawn(fn -> :ok end)

    core =
      core(
        outbound: %{
          "out-1" => %{waiter: waiter, route: {:request, "req-1"}},
          "out-2" => %{waiter: waiter, route: {:request, "req-1"}},
          "out-3" => %{waiter: other, route: {:request, "req-2"}}
        }
      )

    assert {%Core{outbound: outbound}, effects} =
             Outbound.abandon(core, &(&1.waiter == waiter), "the request ended")

    assert Map.keys(outbound) == ["out-3"]

    assert [
             {:demonitor, {:outbound, "out-1"}},
             {:send, pid, {:oz_mcp_stream, "g.1", {:event, "g.1:1", first}}},
             {:demonitor, {:outbound, "out-2"}},
             {:send, pid, {:oz_mcp_stream, "g.1", {:event, "g.1:2", second}}}
           ] = effects

    assert pid == self()

    assert decode(first)["params"] == %{"requestId" => "out-1", "reason" => "the request ended"}
    assert decode(second)["params"] == %{"requestId" => "out-2", "reason" => "the request ended"}
  end

  test "the DOWN of a waiter abandons its requests" do
    waiter = spawn(fn -> :ok end)
    core = core(outbound: %{"out-1" => %{waiter: waiter, route: {:request, "req-1"}}})

    assert {%Core{outbound: %{}}, effects} = Outbound.waiter_down(core, waiter)

    assert [{:demonitor, {:outbound, "out-1"}}, {:send, pid, _notice}, :idle_check] = effects
    assert pid == self()
  end

  test "the end of the session gives one message to each waiter" do
    one = spawn(fn -> :ok end)
    two = spawn(fn -> :ok end)

    core =
      core(
        outbound: %{
          "out-1" => %{waiter: one, route: {:request, "req-1"}},
          "out-2" => %{waiter: one, route: {:request, "req-1"}},
          "out-3" => %{waiter: two, route: {:request, "req-2"}}
        }
      )

    assert {%Core{}, [first, second, third]} = Outbound.end_all(core)

    assert [
             {:send, ^one, {:oz_mcp_client_answer, "out-1", {:error, :session_terminated}}},
             {:send, ^one, {:oz_mcp_client_answer, "out-2", {:error, :session_terminated}}},
             {:send, ^two, {:oz_mcp_client_answer, "out-3", {:error, :session_terminated}}}
           ] = [first, second, third]
  end
end
