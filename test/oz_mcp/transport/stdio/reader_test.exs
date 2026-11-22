defmodule OzMcp.Transport.Stdio.ReaderTest do
  use ExUnit.Case, async: true

  alias OzMcp.Transport.Stdio.Reader

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  test "each line goes to the transport in order, one after the reply of the call" do
    transport = start_fake_transport(:gated)
    {:ok, reader} = start_reader(transport, [{:ok, "one\n"}, {:ok, "two\n"}, :eof])

    assert_receive {:line, "one\n", _}, 5_000
    refute_receive {:line, "two\n", _}, 100
    release(transport)
    assert_receive {:line, "two\n", _}, 5_000
    assert_receive :eof, 5_000
    assert_reader_ends(reader)
  end

  test ":eof gives one eof cast and the reader ends" do
    transport = start_fake_transport(:open)
    {:ok, reader} = start_reader(transport, [:eof])

    assert_receive :eof, 5_000
    assert_reader_ends(reader)
  end

  test "a read error is not the end of the input: the reader exits with a text" do
    transport = start_fake_transport(:open)
    {:ok, reader} = start_reader(transport, [{:error, :terminated}])

    assert_receive {:EXIT, ^reader, {:read_failed, text}}, 5_000
    assert text =~ "cannot read stdin"
    assert text =~ ":terminated"

    # No cast of the end of the input reached the transport: the reader
    # failed, it did not read the end of the stream.
    #
    refute_receive :eof, 100
  end

  describe "a failed read function" do
    test "a raise ends the reader with the type of the exception" do
      transport = start_fake_transport(:open)
      {:ok, reader} = start_failing_reader(transport, fn -> raise "SECRET" end)

      assert_receive {:EXIT, ^reader, {:read_failed, "raised RuntimeError"}}, 5_000
    end

    test "a VM error is named, not shown as an exit" do
      transport = start_fake_transport(:open)
      {:ok, reader} = start_failing_reader(transport, fn -> :erlang.error(:badarith) end)

      assert_receive {:EXIT, ^reader, {:read_failed, "raised ArithmeticError"}}, 5_000
    end

    test "a value that is not a read result ends the reader" do
      transport = start_fake_transport(:open)
      {:ok, reader} = start_failing_reader(transport, fn -> nil end)

      assert_receive {:EXIT, ^reader, {:read_failed, "read returned an unexpected value"}}, 5_000
    end

    test "a throw and an exit give no value" do
      transport = start_fake_transport(:open)
      {:ok, thrower} = start_failing_reader(transport, fn -> throw("SECRET") end)
      {:ok, exiter} = start_failing_reader(transport, fn -> exit({:boom, "SECRET"}) end)

      assert_receive {:EXIT, ^thrower, {:read_failed, thrown}}, 5_000
      assert_receive {:EXIT, ^exiter, {:read_failed, exited}}, 5_000
      assert thrown =~ "throw"
      assert exited =~ "exit"
      refute thrown =~ "SECRET"
      refute exited =~ "SECRET"
    end
  end

  defp start_failing_reader(transport, read),
    do: Reader.start_link(transport: transport, read: read)

  defp start_reader(transport, input) do
    {:ok, agent} = Agent.start_link(fn -> input end)
    read = fn -> Agent.get_and_update(agent, fn [item | rest] -> {item, rest} end) end
    {:ok, reader} = Reader.start_link(transport: transport, read: read)
    {:ok, reader}
  end

  defp start_fake_transport(mode) do
    parent = self()
    spawn_link(fn -> fake_loop(parent, mode) end)
  end

  defp fake_loop(parent, mode) do
    receive do
      {:"$gen_call", from, {:line, line}} ->
        send(parent, {:line, line, self()})

        if mode == :gated do
          receive do
            :release -> :ok
          end
        end

        GenServer.reply(from, :ok)
        fake_loop(parent, :open)

      {:"$gen_cast", :eof} ->
        send(parent, :eof)
    end
  end

  defp release(transport), do: send(transport, :release)

  # The suite runs these tests in parallel with the others: a loaded
  # scheduler can delay the exit signal for a moment.
  #
  defp assert_reader_ends(reader), do: assert_receive({:EXIT, ^reader, :normal}, 5_000)
end
