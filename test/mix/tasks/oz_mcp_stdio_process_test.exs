#
# These tests start the Mix task as a real operating system process.
# They check what no in-memory test can check: the real stdout and
# stderr, the UTF-8 encoding under a `C` locale and the exit code.
# They run only with `mix test --include stdio_process`.
#
defmodule Mix.Tasks.OzMcpStdioProcessTest do
  #
  # Sync: the tests start the Mix task as an operating system process over a FIFO with a fixed path.
  #
  use ExUnit.Case, async: false
  alias Support.Helpers.Utils

  @moduletag :stdio_process
  @moduletag timeout: 120_000

  @fifo "tmp/stdio_process_stdin.fifo"
  @input_file "tmp/stdio_process_input.txt"
  @stderr_log "tmp/stdio_process_stderr.log"
  @stderr_quiet "tmp/stdio_process_stderr_quiet.log"
  @stderr_drain "tmp/stdio_process_stderr_drain.log"
  @stderr_compile "tmp/stdio_process_stderr_compile.log"
  @version "2025-11-25"

  setup do
    File.mkdir_p!("tmp")

    for path <- [@fifo, @input_file, @stderr_log, @stderr_quiet, @stderr_drain, @stderr_compile],
        do: File.rm(path)

    on_exit(fn ->
      for path <- [@fifo, @input_file, @stderr_log, @stderr_quiet, @stderr_drain, @stderr_compile],
          do: File.rm(path)
    end)

    :ok
  end

  test "serves a session over a real pipe, with UTF-8 and a clean stdout" do
    %{port: port, stdin: stdin} = start_server(@stderr_log, ["--log-level", "debug"])

    send_line(stdin, initialize_request(%{"sampling" => %{}}))

    assert {%{
              "result" => %{
                "protocolVersion" => @version,
                "serverInfo" => %{"name" => "ts-outbound-test"}
              }
            }, _line} = recv(port)

    send_line(stdin, %{"jsonrpc" => "2.0", "method" => "notifications/initialized"})

    send_line(stdin, request(2, "ping"))
    assert {%{"id" => 2, "result" => _}, _line} = recv(port)

    send_line(
      stdin,
      request(3, "tools/call", %{"name" => "outbound", "arguments" => %{"feature" => "sample"}})
    )

    {sampling, _line} =
      recv_matching(port, &match?(%{"method" => "sampling/createMessage"}, &1))

    assert sampling["params"]["maxTokens"] == 50

    # The reader is free while the callback waits for the client.
    #
    send_line(stdin, request(4, "ping"))
    assert {%{"id" => 4, "result" => _}, _line} = recv(port)

    send_line(
      stdin,
      response(sampling["id"], %{
        "role" => "assistant",
        "content" => %{"type" => "text", "text" => "première\nligne"},
        "model" => "model-1",
        "stopReason" => "endTurn"
      })
    )

    {call, call_line} = recv_matching(port, &match?(%{"id" => 3, "result" => _}, &1))

    # The bytes of the answer are UTF-8, also under the `C` locale: a
    # line that is not valid UTF-8 fails the two assertions below.
    #
    assert String.valid?(call_line)
    assert call_line =~ "première"

    assert [%{"text" => text}] = call["result"]["content"]
    assert text =~ "première"
    assert text =~ "\\nligne"

    # A text of the server itself: its bytes are UTF-8 on stdout, also
    # under the `C` locale.
    #
    send_line(
      stdin,
      request(5, "tools/call", %{"name" => "outbound", "arguments" => %{"feature" => "text"}})
    )

    {text_call, text_line} = recv_matching(port, &match?(%{"id" => 5, "result" => _}, &1))
    assert String.valid?(text_line)
    assert [%{"text" => server_text}] = text_call["result"]["content"]
    assert server_text =~ "première"

    # A stray IO.puts of the callback goes to stderr, never to stdout.
    #
    send_line(
      stdin,
      request(6, "tools/call", %{
        "name" => "outbound",
        "arguments" => %{"puts" => "stray print"}
      })
    )

    {server_ping, _line} = recv_matching(port, &match?(%{"method" => "ping"}, &1))
    send_line(stdin, response(server_ping["id"], %{}))
    assert {%{"id" => 6, "result" => _}, _line} = recv_matching(port, &match?(%{"id" => 6}, &1))

    # The end of stdin ends the process with the exit code 0.
    #
    File.close(stdin)
    assert_receive {^port, {:exit_status, 0}}, 30_000

    # Every line of stdout was one valid JSON-RPC line (each recv above
    # decoded one), with no stray print and no raw newline in a line.
    #
    drain_lines(port)
    lines = all_lines()
    assert length(lines) >= 8

    Enum.each(lines, fn line ->
      assert %{"jsonrpc" => "2.0"} = :json.decode(line)
      assert String.valid?(line)
    end)

    refute Enum.any?(lines, &String.contains?(&1, "stray print"))

    # The log lines are on stderr:
    #
    stderr = File.read!(@stderr_log)
    assert stderr =~ "Call JsonRpc method"
    assert stderr =~ "stray print"
  end

  test "--log-level error keeps the info lines out of stderr" do
    %{port: port, stdin: stdin} = start_server(@stderr_quiet, ["--log-level", "error"])

    send_line(stdin, initialize_request())
    assert {%{"result" => _}, _line} = recv(port)

    send_line(stdin, %{"jsonrpc" => "2.0", "method" => "notifications/initialized"})

    send_line(stdin, request(2, "ping"))
    assert {%{"id" => 2, "result" => _}, _line} = recv(port)

    File.close(stdin)
    assert_receive {^port, {:exit_status, 0}}, 30_000
    drain_lines(port)

    refute File.read!(@stderr_quiet) =~ "Call JsonRpc method"
  end

  # A script that pipes its lines and closes stdin right away gets every
  # answer: the end of stdin waits for the requests in flight, up to the
  # default drain time, instead of dropping them. The input is a regular
  # file that the command reads as stdin: the server gets all the lines
  # and then the end of the input, as from a piped script. (A fifo that
  # the test fills and closes before the server reads can lose the lines
  # that are still buffered, so a file holds the input here.)
  # The delay on the tool call keeps it in flight after the end of the
  # input: the answer can arrive only if the transport waits for it.
  #
  test "a piped script gets every answer before the process exits" do
    %{port: port} =
      start_piped_server(@stderr_drain, [
        initialize_request(),
        %{"jsonrpc" => "2.0", "method" => "notifications/initialized"},
        request(2, "tools/list"),
        request(3, "tools/call", %{
          "name" => "outbound",
          "arguments" => %{"feature" => "text", "delay" => 500}
        })
      ])

    assert {%{"id" => 1, "result" => _}, _line} =
             recv_matching(port, &match?(%{"id" => 1, "result" => _}, &1))

    assert {%{"id" => 2, "result" => %{"tools" => _}}, _line} =
             recv_matching(port, &match?(%{"id" => 2, "result" => _}, &1))

    assert {%{"id" => 3, "result" => _}, _line} =
             recv_matching(port, &match?(%{"id" => 3, "result" => _}, &1))

    assert_receive {^port, {:exit_status, 0}}, 30_000
  end

  # The `>&2` of the prefix writes to the stderr of the shell, not to the
  # stderr file of the task: the port of the test reads stdout only, so
  # the output of the prefix cannot reach the lines that the test reads.
  # The project is already compiled when the test runs, so the compile of
  # the prefix does nothing: the test checks the form of the command, not
  # a real compile.
  #
  test "the sh -c form keeps stdout clean and exits with code 0" do
    %{port: port, stdin: stdin} = start_server(@stderr_compile, [], "mix compile >&2 && ")

    send_line(stdin, initialize_request())
    assert {%{"result" => _}, _line} = recv(port)

    File.close(stdin)
    assert_receive {^port, {:exit_status, 0}}, 60_000
    drain_lines(port)

    Enum.each(all_lines(), fn line -> assert %{"jsonrpc" => "2.0"} = :json.decode(line) end)
  end

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  defp start_server(stderr_file, flags, prefix \\ "") do
    {_, 0} = System.cmd("mkfifo", [@fifo])
    mix = System.find_executable("mix")

    command =
      ~s(#{prefix}exec env MIX_ENV=test LC_ALL=C LANG=C "#{mix}" oz_mcp.stdio Support.Servers.Outbound ) <>
        Enum.join(flags, " ") <>
        " <#{@fifo} 2>#{stderr_file}"

    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        {:line, 1_000_000},
        args: ["-c", command]
      ])

    # A FIFO opened for reading and writing does not block, while the
    # server has not opened its end yet. The server sees the end of its
    # input when this handle closes.
    #
    stdin = File.open!(@fifo, [:read, :write, :binary])

    %{port: port, stdin: stdin}
  end

  # Starts the task with one input file as stdin: the server reads all
  # the lines of the script and then reaches the end of its input.
  #
  defp start_piped_server(stderr_file, input_lines) do
    input =
      input_lines
      |> Enum.map_join("\n", &Utils.encode_json/1)
      |> Kernel.<>("\n")

    File.write!(@input_file, input)
    mix = System.find_executable("mix")

    command =
      ~s(exec env MIX_ENV=test LC_ALL=C LANG=C "#{mix}" oz_mcp.stdio Support.Servers.Outbound ) <>
        " <#{@input_file} 2>#{stderr_file}"

    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        {:line, 1_000_000},
        args: ["-c", command]
      ])

    %{port: port}
  end

  defp send_line(stdin, message) when is_map(message),
    do: IO.binwrite(stdin, [Utils.encode_json(message), "\n"])

  defp recv(port, timeout \\ 30_000) do
    line = recv_line(port, timeout)
    {:json.decode(line), line}
  end

  defp recv_matching(port, fun, timeout \\ 30_000) do
    line = recv_line(port, timeout)
    message = :json.decode(line)

    if fun.(message) do
      {message, line}
    else
      recv_matching(port, fun, timeout)
    end
  end

  # Every line that the test reads is kept, so the check of stdout sees
  # the lines that the recv helpers consumed too.
  #
  defp recv_line(port, timeout) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        Process.put(:stdout_lines, [line | Process.get(:stdout_lines) || []])
        line
    after
      timeout -> flunk("no line on stdout within #{timeout} ms")
    end
  end

  defp drain_lines(port) do
    receive do
      {^port, {:data, {:eol, _line}}} -> drain_lines(port)
      {^port, {:exit_status, _status}} -> drain_lines(port)
    after
      0 -> :done
    end
  end

  defp all_lines, do: Enum.reverse(Process.get(:stdout_lines) || [])

  defp initialize_request(capabilities \\ %{}) do
    %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => @version,
        "clientInfo" => %{"name" => "stdio-process-test", "version" => "1.0.0"},
        "capabilities" => capabilities
      }
    }
  end

  defp request(id, method, params \\ %{}) do
    %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}
  end

  defp response(id, result) do
    %{"jsonrpc" => "2.0", "id" => id, "result" => result}
  end
end
