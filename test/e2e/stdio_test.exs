#
# The stdio transport as a real operating system process: the server
# answers `initialize`, `tools/list` and `tools/call` on stdout, one
# JSON-RPC message per line, every line is valid UTF-8 and every message
# conforms to the official schema.
#
defmodule OzMcp.E2E.StdioTest do
  #
  # Sync: the test starts the server as an operating system process over a FIFO with a fixed path.
  #

  use ExUnit.Case, async: false

  alias OzMcp.E2E.Conformance
  alias Support.Helpers.Utils
  alias Support.Servers

  @moduletag :e2e
  @moduletag timeout: 180_000

  @version "2025-11-25"
  @server OzMcp.E2E.Server
  @fifo "tmp/e2e_stdio_stdin.fifo"
  @stderr_log "tmp/e2e_stdio_stderr.log"

  setup do
    File.mkdir_p!("tmp")

    for path <- [@fifo, @stderr_log], do: File.rm(path)

    on_exit(fn ->
      File.rm(@fifo)
      File.rm(@stderr_log)
    end)

    :ok
  end

  test "initialize, tools/list and tools/call over the stdio of a real process" do
    %{port: port, stdin: stdin} = start_server()

    send_line(
      stdin,
      request(1, "initialize", %{
        "protocolVersion" => @version,
        "capabilities" => %{},
        "clientInfo" => %{"name" => "oz-mcp-e2e-stdio", "version" => "0.0.0"}
      })
    )

    assert {%{"result" => %{"protocolVersion" => @version}}, _line} =
             recv_result(port, 1, "initialize")

    send_line(stdin, %{"jsonrpc" => "2.0", "method" => "notifications/initialized"})

    send_line(stdin, request(2, "tools/list"))

    {%{"result" => %{"tools" => tools}}, _line} = recv_result(port, 2, "tools/list")

    assert %{"description" => description} =
             Enum.find(tools, &(&1["name"] == "get_temperature"))

    assert is_binary(description)

    send_line(
      stdin,
      request(3, "tools/call", %{
        "name" => "get_temperature",
        "arguments" => %{"location" => "Paris"}
      })
    )

    {call, call_line} = recv_result(port, 3, "tools/call")

    # The bytes of the answer are UTF-8, also under the `C` locale.
    #
    assert String.valid?(call_line)

    assert [%{"type" => "text", "text" => "Temperature in Paris is 24°C"}] =
             call["result"]["content"]

    # The end of stdin ends the process with the exit code 0.
    #
    File.close(stdin)
    assert_receive {^port, {:exit_status, 0}}, 60_000

    # Every line of stdout was one valid JSON-RPC message (each recv above
    # decoded one), with no stray print and no raw newline in a line.
    #
    for line <- all_lines() do
      assert String.valid?(line)
      assert %{"jsonrpc" => "2.0"} = JSON.decode!(line)
    end
  end

  test "a tools/call reports only the progress values that increase over stdio" do
    %{port: port, stdin: stdin} = start_server()

    send_line(
      stdin,
      request(1, "initialize", %{
        "protocolVersion" => @version,
        "capabilities" => %{},
        "clientInfo" => %{"name" => "oz-mcp-e2e-stdio", "version" => "0.0.0"}
      })
    )

    assert {%{"result" => %{"protocolVersion" => @version}}, _line} =
             recv_result(port, 1, "initialize")

    send_line(stdin, %{"jsonrpc" => "2.0", "method" => "notifications/initialized"})

    send_line(
      stdin,
      request(2, "tools/call", %{
        "name" => "progress",
        "arguments" => %{"repeat" => true},
        "_meta" => %{"progressToken" => "p1"}
      })
    )

    assert {[1, 2], %{"result" => %{"content" => [%{"text" => "progress done"}]}}} =
             recv_progress_until_result(port, 2, "tools/call")

    File.close(stdin)
    assert_receive {^port, {:exit_status, 0}}, 60_000
  end

  test "a flood of log messages over stdio is rate limited and the result is last" do
    %{port: port, stdin: stdin} = start_server()

    send_line(
      stdin,
      request(1, "initialize", %{
        "protocolVersion" => @version,
        "capabilities" => %{},
        "clientInfo" => %{"name" => "oz-mcp-e2e-stdio", "version" => "0.0.0"}
      })
    )

    assert {%{"result" => %{"protocolVersion" => @version}}, _line} =
             recv_result(port, 1, "initialize")

    send_line(stdin, %{"jsonrpc" => "2.0", "method" => "notifications/initialized"})

    send_line(stdin, request(2, "logging/setLevel", %{"level" => "info"}))
    assert {%{"result" => %{}}, _line} = recv_result(port, 2, "logging/setLevel")

    send_line(
      stdin,
      request(3, "tools/call", %{
        "name" => "log",
        "arguments" => %{"count" => 500}
      })
    )

    # The session of the request accepts only the messages under
    # `max_log_rate` (the default, 100 for each second) and the result
    # of the call is the last message of the stream.
    #
    {logs, message} = recv_logs_until_result(port, 3, "tools/call")

    assert logs > 0
    assert logs < 500
    assert [%{"text" => "log done"}] = message["result"]["content"]

    File.close(stdin)
    assert_receive {^port, {:exit_status, 0}}, 60_000
  end

  test "a client task over stdio: create, poll and result" do
    %{port: port, stdin: stdin} = start_server(Servers.Outbound, %{client_tasks: true})

    capabilities = %{
      "sampling" => %{},
      "tasks" => %{
        "cancel" => %{},
        "requests" => %{"sampling" => %{"createMessage" => %{}}}
      }
    }

    send_line(
      stdin,
      request(1, "initialize", %{
        "protocolVersion" => @version,
        "capabilities" => capabilities,
        "clientInfo" => %{"name" => "oz-mcp-e2e-stdio", "version" => "0.0.0"}
      })
    )

    assert {%{"result" => %{"protocolVersion" => @version}}, _line} =
             recv_result(port, 1, "initialize")

    send_line(stdin, %{"jsonrpc" => "2.0", "method" => "notifications/initialized"})

    send_line(
      stdin,
      request(2, "tools/call", %{
        "name" => "outbound",
        "arguments" => %{"feature" => "sample_task", "timeout" => 5_000, "poll_interval" => 50}
      })
    )

    {create, _line} = recv_message(port, &(&1["method"] == "sampling/createMessage"))
    assert %{"method" => "sampling/createMessage"} = create
    assert is_map(create["params"]["task"])

    task = %{
      "taskId" => "c1",
      "status" => "working",
      "pollInterval" => 100,
      "createdAt" => "2026-01-01T00:00:00Z",
      "lastUpdatedAt" => "2026-01-01T00:00:00Z",
      "ttl" => 60_000
    }

    send_line(stdin, %{
      "jsonrpc" => "2.0",
      "id" => create["id"],
      "result" => %{"task" => task}
    })

    {get, _line} = recv_message(port, &(&1["method"] == "tasks/get"))
    assert %{"params" => %{"taskId" => "c1"}} = get

    send_line(stdin, %{
      "jsonrpc" => "2.0",
      "id" => get["id"],
      "result" => Map.put(task, "status", "completed")
    })

    {result, _line} = recv_message(port, &(&1["method"] == "tasks/result"))
    assert %{"params" => %{"taskId" => "c1"}} = result

    send_line(stdin, %{
      "jsonrpc" => "2.0",
      "id" => result["id"],
      "result" => %{
        "role" => "assistant",
        "model" => "m",
        "content" => %{"type" => "text", "text" => "ok"}
      }
    })

    {call, _line} = recv_result(port, 2, "tools/call")

    assert [%{"text" => text}] = call["result"]["content"]
    assert text =~ "\"ok\""

    File.close(stdin)
    assert_receive {^port, {:exit_status, 0}}, 60_000
  end

  test "a tools/call with a _meta that is not an object gets a -32602 error on stdout" do
    %{port: port, stdin: stdin} = start_server()

    send_line(
      stdin,
      request(1, "initialize", %{
        "protocolVersion" => @version,
        "capabilities" => %{},
        "clientInfo" => %{"name" => "oz-mcp-e2e-stdio", "version" => "0.0.0"}
      })
    )

    assert {%{"result" => %{"protocolVersion" => @version}}, _line} =
             recv_result(port, 1, "initialize")

    send_line(stdin, %{"jsonrpc" => "2.0", "method" => "notifications/initialized"})

    send_line(
      stdin,
      request(2, "tools/call", %{"name" => "get_temperature", "_meta" => "x"})
    )

    {message, line} = recv_result(port, 2, "tools/call")

    assert message["error"] == %{"code" => -32602, "message" => "invalid _meta"}

    # The bytes of the answer are UTF-8, also under the `C` locale.
    #
    assert String.valid?(line)

    # The end of stdin ends the process with the exit code 0.
    #
    File.close(stdin)
    assert_receive {^port, {:exit_status, 0}}, 60_000
  end

  @tag :capture_log
  test "a tools/call result with a string that is not valid UTF-8 gets a -32603 error" do
    %{port: port, stdin: stdin} = start_server(OzMcp.E2E.BadShapeServer)

    send_line(
      stdin,
      request(1, "initialize", %{
        "protocolVersion" => @version,
        "capabilities" => %{},
        "clientInfo" => %{"name" => "oz-mcp-e2e-stdio", "version" => "0.0.0"}
      })
    )

    assert {%{"result" => %{"protocolVersion" => @version}}, _line} =
             recv_result(port, 1, "initialize")

    send_line(stdin, %{"jsonrpc" => "2.0", "method" => "notifications/initialized"})

    send_line(
      stdin,
      request(2, "tools/call", %{
        "name" => "task_bad_shape",
        "arguments" => %{"shape" => "bad_utf8"}
      })
    )

    {message, line} = recv_result(port, 2, "tools/call")

    assert message["id"] == 2
    assert message["error"] == %{"code" => -32603, "message" => "internal error"}
    assert String.valid?(line)

    File.close(stdin)
    assert_receive {^port, {:exit_status, 0}}, 60_000
  end

  @tag :capture_log
  test "a task over stdio whose result has a bad string fails and tasks/result gives -32603" do
    %{port: port, stdin: stdin} = start_server(OzMcp.E2E.BadShapeServer)

    send_line(
      stdin,
      request(1, "initialize", %{
        "protocolVersion" => @version,
        "capabilities" => %{},
        "clientInfo" => %{"name" => "oz-mcp-e2e-stdio", "version" => "0.0.0"}
      })
    )

    assert {%{"result" => %{"protocolVersion" => @version}}, _line} =
             recv_result(port, 1, "initialize")

    send_line(stdin, %{"jsonrpc" => "2.0", "method" => "notifications/initialized"})

    send_line(
      stdin,
      request(2, "tools/call", %{
        "name" => "task_bad_shape",
        "arguments" => %{"shape" => "bad_utf8"},
        "task" => %{}
      })
    )

    {%{"result" => %{"task" => %{"taskId" => task_id}}}, _line} =
      recv_result(port, 2, "tools/call")

    assert eventually_failed(port, stdin, task_id)

    send_line(stdin, request(3, "tasks/result", %{"taskId" => task_id}))

    {message, _line} = recv_result(port, 3, "tasks/result", 5_000)
    assert message["error"]["code"] == -32603

    File.close(stdin)
    assert_receive {^port, {:exit_status, 0}}, 60_000
  end

  defp eventually_failed(port, stdin, task_id, tries \\ 50)

  defp eventually_failed(_port, _stdin, _task_id, 0), do: false

  defp eventually_failed(port, stdin, task_id, tries) do
    send_line(stdin, request(100, "tasks/get", %{"taskId" => task_id}))
    {message, _line} = recv_result(port, 100, "tasks/get", 5_000)

    if get_in(message, ["result", "status"]) == "failed" do
      true
    else
      receive do
      after
        50 -> :ok
      end

      eventually_failed(port, stdin, task_id, tries - 1)
    end
  end

  # The command of the stdio test support: the server reads a FIFO as its
  # stdin and writes its logs on a file, so stdout carries the JSON-RPC
  # messages only.
  #
  defp start_server(server \\ @server, server_opts \\ %{}) do
    {_, 0} = System.cmd("mkfifo", [@fifo])
    mix = System.find_executable("mix")

    command = server_command(mix, server, server_opts)

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

  # The Mix task takes no runtime option. When the test needs one, the
  # process starts the transport with the same `:server_opts` that the
  # task would pass.
  #
  defp server_command(mix, server, server_opts) when map_size(server_opts) == 0 do
    ~s(exec env MIX_ENV=test LC_ALL=C LANG=C "#{mix}" oz_mcp.stdio #{inspect(server)} ) <>
      " <#{@fifo} 2>#{@stderr_log}"
  end

  defp server_command(mix, server, server_opts) do
    code =
      "io = OzMcp.Transport.Stdio.Console.open(); " <>
        "{:ok, _} = Application.ensure_all_started(:oz_mcp); " <>
        "OzMcp.Transport.Stdio.run(#{inspect(server)}, " <>
        "read: io.read, write: io.write, server_opts: #{inspect(server_opts)})"

    ~s(exec env MIX_ENV=test LC_ALL=C LANG=C "#{mix}" run --no-start -e '#{code}' ) <>
      " <#{@fifo} 2>#{@stderr_log}"
  end

  defp send_line(stdin, message) when is_map(message),
    do: IO.binwrite(stdin, [Utils.encode_json(message), "\n"])

  defp request(id, method, params \\ %{}) do
    %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}
  end

  # The next JSON-RPC response for `id` on stdout. The result is
  # validated against the result type of `method`, an error against the
  # error response definition.
  #
  defp recv_result(port, id, method, timeout \\ 30_000) do
    {message, line} = recv_line(port, timeout)

    cond do
      match?(%{"id" => ^id}, message) and Map.has_key?(message, "result") ->
        Conformance.assert_result!(method, message["result"])
        {message, line}

      match?(%{"id" => ^id}, message) and Map.has_key?(message, "error") ->
        Conformance.assert_error_response!(message)
        {message, line}

      true ->
        recv_result(port, id, method, timeout)
    end
  end

  # The progress values of the notifications before the result of `id`
  # and the result itself. The value of a notification that does not
  # increase never arrives, so it is not in the list.
  #
  defp recv_progress_until_result(port, id, method, progress \\ [], timeout \\ 30_000) do
    {message, _line} = recv_line(port, timeout)

    cond do
      match?(%{"id" => ^id}, message) and Map.has_key?(message, "result") ->
        Conformance.assert_result!(method, message["result"])
        {Enum.reverse(progress), message}

      match?(%{"method" => "notifications/progress"}, message) ->
        recv_progress_until_result(
          port,
          id,
          method,
          [message["params"]["progress"] | progress],
          timeout
        )

      true ->
        recv_progress_until_result(port, id, method, progress, timeout)
    end
  end

  # The log notifications before the result of `id` and the result
  # itself. The session drops the notifications over `max_log_rate`, so
  # the count of the logs stays under the number the tool sent.
  #
  defp recv_logs_until_result(port, id, method, logs \\ 0, timeout \\ 30_000) do
    {message, _line} = recv_line(port, timeout)

    cond do
      match?(%{"id" => ^id}, message) and Map.has_key?(message, "result") ->
        Conformance.assert_result!(method, message["result"])
        {logs, message}

      match?(%{"method" => "notifications/message"}, message) ->
        recv_logs_until_result(port, id, method, logs + 1, timeout)

      true ->
        recv_logs_until_result(port, id, method, logs, timeout)
    end
  end

  # The next line on stdout whose message satisfies the predicate: a
  # notification can come before the request the test waits for.
  #
  defp recv_message(port, pred, timeout \\ 30_000) do
    {message, line} = recv_line(port, timeout)

    if pred.(message) do
      {message, line}
    else
      recv_message(port, pred, timeout)
    end
  end

  defp recv_line(port, timeout) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        Process.put(:stdout_lines, [line | Process.get(:stdout_lines) || []])
        {JSON.decode!(line), line}
    after
      timeout -> flunk("no line on stdout within #{timeout} ms")
    end
  end

  defp all_lines, do: Enum.reverse(Process.get(:stdout_lines) || [])
end
