defmodule OzMcp.Transport.Stdio.WriterTest do
  use ExUnit.Case, async: true

  alias OzMcp.Transport.Stdio.Writer
  alias Support.Helpers.Utils

  @stream_id "writer-stream"

  setup do
    tid = :ets.new(:writer_lines, [:ordered_set, :public])
    :ets.insert(tid, {:count, 0})

    write = fn iodata ->
      line = IO.iodata_to_binary(iodata)
      count = :ets.update_counter(tid, :count, 1)
      :ets.insert(tid, {count, line})
      :ok
    end

    {:ok, writer} = Writer.start_link(write: write, owner: self(), max_queue: 10_000)
    Writer.attach(writer, @stream_id)
    on_exit(fn -> Process.exit(writer, :kill) end)

    %{writer: writer, tid: tid, write: write}
  end

  test "write/2 writes one line that ends with a newline and is valid JSON", %{
    writer: writer,
    tid: tid
  } do
    Writer.write(writer, ~s({"jsonrpc":"2.0","method":"ping"}))
    [line] = await_lines(tid, 1)

    assert String.ends_with?(line, "\n")

    assert :json.decode(String.trim_trailing(line, "\n")) == %{
             "jsonrpc" => "2.0",
             "method" => "ping"
           }
  end

  test "write/2 accepts iodata and writes it as it is", %{writer: writer, tid: tid} do
    Writer.write(writer, [~s({"a":), ["null", "}"]])
    [line] = await_lines(tid, 1)

    assert line == ~s({"a":null}\n)
  end

  test "a text with a newline and a non-ASCII character stays one valid UTF-8 line", %{
    writer: writer,
    tid: tid
  } do
    Writer.write(writer, Utils.encode_json(%{"text" => "a\nb", "name" => "é"}))
    [line] = await_lines(tid, 1)

    assert String.valid?(line)
    assert line =~ "é"
    assert line =~ ~s("text":"a\\nb")
    trimmed = String.trim_trailing(line, "\n")
    refute String.contains?(trimmed, "\n")
  end

  test "two messages from one process keep their order", %{writer: writer, tid: tid} do
    Writer.write(writer, ~s({"n":1}))
    Writer.write(writer, ~s({"n":2}))
    lines = await_lines(tid, 2)

    assert lines == [~s({"n":1}\n), ~s({"n":2}\n)]
  end

  test "an event of the session writes the message", %{writer: writer, tid: tid} do
    send(writer, {:oz_mcp_stream, @stream_id, {:event, "event-1", ~s({"from":"stream"})}})
    [line] = await_lines(tid, 1)

    assert :json.decode(String.trim_trailing(line, "\n")) == %{"from" => "stream"}
  end

  test "a message of another stream is dropped", %{writer: writer, tid: tid} do
    send(writer, {:oz_mcp_stream, "stream-1", {:event, "event-1", ~s({"from":"stream"})}})
    send(writer, {:oz_mcp_stream, "stream-1", {:event, "event-2", ~s({"from":"other"})}})
    send(writer, {:oz_mcp_stream, "stream-1", :terminate})
    send(writer, {:oz_mcp_stream, @stream_id, {:event, "event-2", ~s({"after":true})}})

    [line] = await_lines(tid, 1)

    assert :json.decode(String.trim_trailing(line, "\n")) == %{"after" => true}
    refute_receive {:stdio_session_ended, ^writer}, 100
  end

  test "a message that comes before the stream id waits for it", %{write: write, tid: tid} do
    {:ok, writer} = Writer.start_link(write: write, owner: self(), max_queue: 10_000)

    send(writer, {:oz_mcp_stream, "late", {:event, "e1", ~s({"n":1})}})
    send(writer, {:oz_mcp_stream, "other", {:event, "e2", ~s({"n":2})}})
    send(writer, {:oz_mcp_stream, "late", {:event, "e3", ~s({"n":3})}})
    assert lines(tid) == []

    Writer.attach(writer, "late")

    assert await_lines(tid, 2) == [~s({"n":1}\n), ~s({"n":3}\n)]
  end

  test "the terminate of the session notifies the owner and the writer stays alive", %{
    writer: writer
  } do
    send(writer, {:oz_mcp_stream, @stream_id, :terminate})

    assert_receive {:stdio_session_ended, ^writer}, 5_000
    assert Process.alive?(writer)
  end

  test "a write function that returns an error stops the writer", %{tid: tid} do
    Process.flag(:trap_exit, true)

    {:ok, writer} =
      Writer.start_link(
        write: fn _iodata -> {:error, :epipe} end,
        owner: self(),
        max_queue: 10_000
      )

    ref = Process.monitor(writer)

    Writer.write(writer, ~s({"x":1}))

    # The cast is async: a loaded scheduler can delay the stop for a moment.
    #
    assert_receive {:DOWN, ^ref, :process, ^writer, {:shutdown, {:write_failed, :epipe}}}, 5_000
    assert lines(tid) == []
  end

  test "flush/2 returns after the earlier messages are written", %{writer: writer, tid: tid} do
    Writer.write(writer, ~s({"n":1}))

    assert Writer.flush(writer) == :ok
    assert lines(tid) == [~s({"n":1}\n)]
  end

  # -------------------------------------------------------------------
  # The queue bound
  # -------------------------------------------------------------------

  describe "the queue bound" do
    test "a slow write makes the writer stop at the bound" do
      Process.flag(:trap_exit, true)
      test_pid = self()

      write = fn _iodata ->
        send(test_pid, {:sink, self()})

        receive do
          :release -> :ok
        end
      end

      {:ok, writer} = Writer.start_link(write: write, owner: self(), max_queue: 3)
      ref = Process.monitor(writer)

      # The first message goes into the sink and blocks it; the next
      # three fill the queue; the one over the bound stops the writer.
      #
      Writer.write(writer, "1")
      assert_receive {:sink, sink}
      sink_ref = Process.monitor(sink)

      for n <- 2..4, do: Writer.write(writer, "#{n}")
      Writer.write(writer, "5")

      assert_receive {:DOWN, ^ref, :process, ^writer, {:shutdown, {:output_overflow, 3}}}, 5_000

      # The blocked sink died with the writer: no process leaks.
      #
      assert_receive {:DOWN, ^sink_ref, :process, ^sink, {:shutdown, {:output_overflow, 3}}},
                     5_000
    end

    test "a queue under the bound writes every line, in order" do
      Process.flag(:trap_exit, true)
      test_pid = self()

      write = fn iodata ->
        send(test_pid, {:wrote, IO.iodata_to_binary(iodata), self()})

        receive do
          :release -> :ok
        end
      end

      {:ok, writer} = Writer.start_link(write: write, owner: self(), max_queue: 5)

      Writer.write(writer, "1")
      Writer.write(writer, "2")
      Writer.write(writer, "3")

      # The first write is in the sink; the queue holds the other two.
      #
      assert_receive {:wrote, "1\n", sink}

      flush_task = Task.async(fn -> Writer.flush(writer, 5_000) end)
      refute Task.yield(flush_task, 50)

      send(sink, :release)
      assert_receive {:wrote, "2\n", ^sink}

      send(sink, :release)
      assert_receive {:wrote, "3\n", ^sink}

      send(sink, :release)
      assert :ok = Task.await(flush_task)
    end

    test "flush/2 returns at once on an idle writer" do
      {:ok, writer} = Writer.start_link(write: fn _iodata -> :ok end, owner: self(), max_queue: 5)
      assert Writer.flush(writer) == :ok
    end

    test "a write function that raises stops the writer" do
      Process.flag(:trap_exit, true)

      {:ok, writer} =
        Writer.start_link(write: fn _iodata -> raise "boom" end, owner: self(), max_queue: 10_000)

      ref = Process.monitor(writer)

      Writer.write(writer, ~s({"x":1}))

      assert_receive {:DOWN, ^ref, :process, ^writer,
                      {:shutdown, {:write_failed, %RuntimeError{message: "boom"}}}},
                     5_000
    end

    test "a write function that returns a value other than :ok or an error stops the writer" do
      Process.flag(:trap_exit, true)

      {:ok, writer} =
        Writer.start_link(write: fn _iodata -> {:ok, 12} end, owner: self(), max_queue: 10_000)

      ref = Process.monitor(writer)

      Writer.write(writer, ~s({"x":1}))

      assert_receive {:DOWN, ^ref, :process, ^writer,
                      {:shutdown, {:write_failed, {:bad_return, {:ok, 12}}}}},
                     5_000
    end

    test "the flush caller gets the exit of a writer with a bad write function" do
      Process.flag(:trap_exit, true)
      test_pid = self()

      write = fn _iodata ->
        send(test_pid, {:sink, self()})

        receive do
          :release -> {:ok, 12}
        end
      end

      {:ok, writer} = Writer.start_link(write: write, owner: self(), max_queue: 10_000)
      ref = Process.monitor(writer)

      Writer.write(writer, ~s({"x":1}))
      assert_receive {:sink, sink}

      flush_task = Task.async(fn -> Writer.flush(writer, 5_000) end)
      flush_pid = flush_task.pid
      refute Task.yield(flush_task, 50)

      send(sink, :release)

      assert_receive {:DOWN, ^ref, :process, ^writer,
                      {:shutdown, {:write_failed, {:bad_return, {:ok, 12}}}}},
                     5_000

      # The flush caller got the exit of the writer: it does not wait
      # until its own timeout.
      #
      assert_receive {:EXIT, ^flush_pid,
                      {{:shutdown, {:write_failed, {:bad_return, {:ok, 12}}}}, _}},
                     5_000
    end

    # The producer of the transport (the session and the request
    # processes) writes messages as they come and the client reads them
    # in the same rhythm. The batches stay far under the bound: a writer
    # that stops here would stop a healthy transport.
    #
    test "a fast write never hits the bound" do
      Process.flag(:trap_exit, true)
      counter = :counters.new(1, [:atomics])

      write = fn _iodata ->
        :counters.add(counter, 1, 1)
        :ok
      end

      {:ok, writer} = Writer.start_link(write: write, owner: self(), max_queue: 1_000)
      ref = Process.monitor(writer)

      for n <- 1..100_000 do
        Writer.write(writer, "#{n}")
        if rem(n, 100) == 0, do: Writer.flush(writer)
      end

      refute_received {:DOWN, ^ref, :process, ^writer, _reason}
      assert :counters.get(counter, 1) == 100_000
    end
  end

  defp await_lines(tid, expected, timeout \\ 10_000) do
    if Utils.eventually(fn -> length(lines(tid)) >= expected end, timeout) do
      lines(tid)
    else
      flunk("timed out waiting for #{expected} lines")
    end
  end

  defp lines(tid) do
    tid
    |> :ets.tab2list()
    |> Enum.filter(fn {key, _} -> is_integer(key) end)
    |> Enum.sort()
    |> Enum.map(&elem(&1, 1))
  end
end
