#
# The target of the loop for the tests: every callback tells the test
# process what it got and the halt config of the state decides between
# a cont and a halt.
#
defmodule OzMcp.Stream.LoopTest.Target do
  @behaviour OzMcp.Stream.Loop

  defstruct [:pid, :conn, :halt_on, :halt_value]

  @impl true
  def stream(payload, target), do: step(:stream, payload, target)

  @impl true
  def idle(target), do: step(:idle, nil, target)

  @impl true
  def timer(reason, target), do: step(:timer, reason, target)

  @impl true
  def session_down(target), do: step(:session_down, nil, target)

  @impl true
  def message(payload, target), do: step(:message, payload, target)

  @impl true
  def aux_down(reason, target), do: step(:aux_down, reason, target)

  defp step(name, value, %{pid: pid} = target) do
    send(pid, {:target, name, value})

    if halt?(name, value, target) do
      {:halt, target.conn}
    else
      {:cont, target}
    end
  end

  defp halt?(name, value, %{halt_on: halt_on, halt_value: halt_value}) do
    name == halt_on and (is_nil(halt_value) or halt_value == value)
  end
end

#
# The unit tests of the shared receive loop of an SSE connection: each
# message of the loop reaches the target of the loop and each result of
# a target ends or continues the loop. The target of the tests tells the
# test process what it got, so the test asserts on the callbacks and not
# on writes.
#
defmodule OzMcp.Stream.LoopTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias OzMcp.Auth.Principal
  alias OzMcp.Stream.Loop
  alias OzMcp.Stream.Timers

  describe "the messages of the loop" do
    test "a message of the own stream reaches the target and a halt returns the conn" do
      conn = chunked_conn()
      send(self(), {:oz_mcp_stream, "s1", {:event, "e1", "{}"}})
      send(self(), {:oz_mcp_stream, "s1", :terminate})

      result =
        Loop.run(loop(conn: conn, stream_id: "s1", halt_on: :stream, halt_value: :terminate))

      assert_received {:target, :stream, {:event, "e1", "{}"}}
      assert_received {:target, :stream, :terminate}
      assert result == conn
    end

    test "a message for another stream is dropped" do
      send(self(), {:oz_mcp_stream, "other999", {:event, "e0", "{}"}})
      send(self(), {:oz_mcp_stream, "other999", :terminate})

      # A dropped message does not end the loop and the target never sees
      # it: the next message of this stream is still given to the target.
      #
      send(self(), {:oz_mcp_stream, "s1", {:event, "e1", "{}"}})
      send(self(), {:oz_mcp_stream, "s1", :terminate})

      Loop.run(loop(stream_id: "s1", halt_on: :stream, halt_value: :terminate))

      assert_received {:target, :stream, {:event, "e1", "{}"}}
      assert_received {:target, :stream, :terminate}
      refute_received {:target, :stream, {:event, "e0", "{}"}}

      # The messages of the other stream are gone from the mailbox.
      #
      refute_received {:oz_mcp_stream, "other999", _payload}
    end

    test "the poll close reaches the target as a timer" do
      handle = Timers.arm_poll(1)

      Loop.run(loop(poll_timer: handle, halt_on: :timer, halt_value: :poll))

      assert_received {:target, :timer, :poll}
    end

    test "an expired principal reaches the target as a timer" do
      principal = Principal.new!(subject: "alice", expires_at: System.system_time(:second) - 10)
      token = make_ref()
      send(self(), {:principal_expired, token})

      Loop.run(
        loop(
          principal: principal,
          expiry_timer: {token, make_ref()},
          halt_on: :timer,
          halt_value: :expired
        )
      )

      assert_received {:target, :timer, :expired}
    end

    test "a live principal is waited for again and the target gets nothing" do
      principal =
        Principal.new!(subject: "alice", expires_at: System.system_time(:second) + 3_600)

      token = make_ref()
      send(self(), {:principal_expired, token})
      send(self(), {:oz_mcp_stream, "s1", {:event, "e1", "{}"}})
      send(self(), {:oz_mcp_stream, "s1", :terminate})

      Loop.run(
        loop(
          stream_id: "s1",
          principal: principal,
          expiry_timer: {token, make_ref()},
          halt_on: :stream,
          halt_value: :terminate
        )
      )

      assert_received {:target, :stream, {:event, "e1", "{}"}}
      assert_received {:target, :stream, :terminate}
      refute_received {:target, :timer, :expired}
    end

    test "a stray expiry message of a loop with no principal is dropped" do
      send(self(), {:principal_expired, make_ref()})
      send(self(), {:oz_mcp_stream, "s1", {:event, "e1", "{}"}})
      send(self(), {:oz_mcp_stream, "s1", :terminate})

      Loop.run(loop(stream_id: "s1", halt_on: :stream, halt_value: :terminate))

      assert_received {:target, :stream, {:event, "e1", "{}"}}
      assert_received {:target, :stream, :terminate}
      refute_received {:target, :timer, _}
      refute_received {:principal_expired, _}
    end

    test "a poll message with another reference is dropped and the loop goes on" do
      handle = Timers.arm_poll(60_000)

      send(self(), {:sse_poll_close, make_ref()})
      send(self(), {:oz_mcp_stream, "s1", {:event, "e1", "{}"}})
      send(self(), {:oz_mcp_stream, "s1", :terminate})

      Loop.run(
        loop(stream_id: "s1", poll_timer: handle, halt_on: :stream, halt_value: :terminate)
      )

      assert_received {:target, :stream, {:event, "e1", "{}"}}
      assert_received {:target, :stream, :terminate}
      refute_received {:target, :timer, _}
      refute_received {:sse_poll_close, _}
    end

    test "an expiry message with another reference is dropped, even for an expired principal" do
      principal = Principal.new!(subject: "alice", expires_at: System.system_time(:second) - 10)
      handle = {make_ref(), make_ref()}

      send(self(), {:principal_expired, make_ref()})
      send(self(), {:oz_mcp_stream, "s1", :terminate})

      Loop.run(
        loop(
          stream_id: "s1",
          principal: principal,
          expiry_timer: handle,
          halt_on: :stream,
          halt_value: :terminate
        )
      )

      refute_received {:target, :timer, :expired}
      refute_received {:principal_expired, _}
    end

    test "a loop with no timer drops a timer message with any reference, also nil" do
      send(self(), {:sse_poll_close, make_ref()})
      send(self(), {:sse_poll_close, nil})
      send(self(), {:principal_expired, make_ref()})
      send(self(), {:principal_expired, nil})
      send(self(), {:oz_mcp_stream, "s1", :terminate})

      Loop.run(loop(stream_id: "s1", halt_on: :stream, halt_value: :terminate))

      refute_received {:target, :timer, _}
      refute_received {:sse_poll_close, _}
      refute_received {:principal_expired, _}
    end

    test "a poll message of an earlier timer of the same process does not close the next loop" do
      _first = Timers.arm_poll(1)
      stale = assert_receive({:sse_poll_close, _}, 100)
      send(self(), stale)

      second = Timers.arm_poll(60_000)
      send(self(), {:oz_mcp_stream, "s1", :terminate})

      Loop.run(
        loop(stream_id: "s1", poll_timer: second, halt_on: :stream, halt_value: :terminate)
      )

      refute_received {:target, :timer, :poll}
      refute_received {:sse_poll_close, _}
    end

    test "the stop of the session process reaches the target" do
      server_ref = monitor_and_kill()

      Loop.run(loop(server_ref: server_ref, halt_on: :session_down))

      assert_received {:target, :session_down, nil}
    end

    test "a message of the extra process reaches the target" do
      aux_ref = make_ref()
      send(self(), {:oz_mcp_loop, aux_ref, {:answer, :mine}})

      Loop.run(loop(aux_ref: aux_ref, halt_on: :message, halt_value: {:answer, :mine}))

      assert_received {:target, :message, {:answer, :mine}}
    end

    test "a message of another extra process is dropped" do
      aux_ref = make_ref()
      send(self(), {:oz_mcp_loop, make_ref(), {:answer, :late}})
      send(self(), {:oz_mcp_loop, aux_ref, {:answer, :mine}})

      Loop.run(loop(aux_ref: aux_ref, halt_on: :message, halt_value: {:answer, :mine}))

      assert_received {:target, :message, {:answer, :mine}}
      refute_received {:target, :message, {:answer, :late}}
    end

    test "the stop of the extra process reaches the target" do
      aux_ref = monitor_and_kill()

      Loop.run(loop(aux_ref: aux_ref, halt_on: :aux_down))

      assert_received {:target, :aux_down, :killed}
    end

    test "a message of the host server stays in the mailbox" do
      send(self(), {:plug_conn, :sent})
      send(self(), {:bandit, :close})
      send(self(), {:oz_mcp_stream, "s1", {:event, "e1", "{}"}})
      send(self(), {:oz_mcp_stream, "s1", :terminate})

      Loop.run(loop(stream_id: "s1", halt_on: :stream, halt_value: :terminate))

      assert_received {:plug_conn, :sent}
      assert_received {:bandit, :close}
    end
  end

  describe "the idle wake" do
    test "an empty mailbox wakes the target and a halt ends the loop" do
      parent = self()
      conn = chunked_conn()

      child =
        spawn(fn ->
          result = Loop.run(loop(conn: conn, pid: parent, heartbeat_ms: 10, halt_on: :idle))
          send(parent, {:loop_done, self(), result})
        end)

      assert_receive {:target, :idle, nil}, 1_000
      assert_receive {:loop_done, ^child, ^conn}, 1_000
    end

    test "the idle wake keeps the loop running" do
      parent = self()
      conn = chunked_conn()

      child =
        spawn(fn ->
          result =
            Loop.run(
              loop(
                conn: conn,
                pid: parent,
                heartbeat_ms: 10,
                stream_id: "s1",
                halt_on: :stream,
                halt_value: :terminate
              )
            )

          send(parent, {:loop_done, self(), result})
        end)

      assert_receive {:target, :idle, nil}, 1_000
      send(child, {:oz_mcp_stream, "s1", :terminate})

      assert_receive {:loop_done, ^child, ^conn}, 1_000
      assert_received {:target, :stream, :terminate}
    end
  end

  describe "the code of the stream modules" do
    test "the stream modules name no HTTP server" do
      files = Path.wildcard("lib/oz_mcp/stream/*.ex")
      assert files != []

      for file <- files do
        refute File.read!(file) =~ ~r/\b(bandit|cowboy|thousand_?island|ranch)\b/i,
               "#{file} names a server"
      end
    end
  end

  # A stopped process and its monitor reference: the DOWN message of the
  # monitor reaches the mailbox of the caller before the loop runs.
  #
  defp monitor_and_kill do
    victim =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    ref = Process.monitor(victim)
    Process.exit(victim, :kill)
    ref
  end

  # The state of the loop for the tests: the target tells the test process
  # what each callback got and the halt config decides between a cont and
  # a halt.
  #
  defp loop(opts) do
    %Loop{
      target: OzMcp.Stream.LoopTest.Target,
      state: %{
        pid: Keyword.get_lazy(opts, :pid, &self/0),
        conn: Keyword.get(opts, :conn, chunked_conn()),
        halt_on: opts[:halt_on],
        halt_value: Keyword.get(opts, :halt_value)
      },
      stream_id: opts[:stream_id],
      heartbeat_ms: Keyword.get(opts, :heartbeat_ms, 5_000),
      principal: opts[:principal],
      server_ref: opts[:server_ref],
      aux_ref: opts[:aux_ref],
      poll_timer: opts[:poll_timer],
      expiry_timer: opts[:expiry_timer]
    }
  end

  defp chunked_conn do
    conn(:get, "/")
    |> put_resp_header("content-type", "text/event-stream")
    |> send_chunked(200)
  end
end
