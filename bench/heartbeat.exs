# Measures the cost of the SSE heartbeat with many idle streams.
#
#     MIX_ENV=test mix run bench/heartbeat.exs [--quick]
#
# The script is not part of `mix bench` and not part of CI: the scenarios
# of `mix bench` run the plug through `Plug.Test`, with no HTTP server
# and a heartbeat over `Plug.Test` measures no socket write.
#
# For each case the script starts one instance and one listener, opens N
# sessions with one idle `GET` stream each over raw `:gen_tcp` sockets
# and samples the node for one window. It reports the scheduler
# utilization, the memory of the node and the number of heartbeat
# writes that the sockets received for each second.
#
# `--quick` runs a short window with fewer streams, to check the script
# itself.
#

default_window_ms = 60_000
{opts, _argv, _errors} = OptionParser.parse(System.argv(), strict: [quick: :boolean])

# The runs of the script are quiet: the debug logs of thousands of
# sessions would slow the setup and hide the table.
#
Logger.configure(level: :warning)

quick? = Keyword.get(opts, :quick, false)
window_ms = if quick?, do: 10_000, else: default_window_ms

cases =
  if quick? do
    [{:bandit, 30_000, 100}, {:bandit, 5_000, 100}]
  else
    for heartbeat <- [30_000, 15_000, 5_000], streams <- [1_000, 5_000] do
      {:bandit, heartbeat, streams}
    end ++ [{:cowboy, 15_000, 5_000}]
  end

max_streams = cases |> Enum.map(fn {_, _, streams} -> streams end) |> Enum.max()

# One run holds the sockets of the client and of the server: about
# `2 * max_streams` handles. The script stops when the limit of open
# files is lower, instead of failing in the middle of a case.
#
{limit_text, 0} = System.cmd("sh", ["-c", "ulimit -n"])
file_limit = String.trim(limit_text) |> String.to_integer()

if file_limit < 2 * max_streams + 1_000 do
  IO.puts("""
  The limit of open files is too low: #{file_limit}.
  The measure needs at least #{2 * max_streams + 1_000} handles for #{max_streams} streams.
  Raise it before the run, for example:  ulimit -n #{2 * max_streams + 2_000}
  """)

  System.halt(1)
end

#
# Owns the idle stream sockets in active mode, drops their data and
# counts the heartbeat comments. A ticker sends `:tick` each second;
# the reader then reports the count of the last second and resets it.
#
# A heartbeat comment can be split over two reads, so the reader keeps
# the tail of the last read (one byte shorter than the pattern) in the
# count of the next chunk.
#
defmodule HeartbeatBench.Reader do
  @pattern ": heartbeat"

  def loop(total, this_second, tail) do
    receive do
      {:tcp, _socket, data} ->
        window = tail <> data
        count = count(window, 0)
        loop(total + count, this_second + count, new_tail(window))

      {:tcp_closed, _socket} ->
        loop(total, this_second, tail)

      {:tcp_error, _socket, _reason} ->
        loop(total, this_second, tail)

      :tick ->
        send(self_total(), {:heartbeats_per_second, this_second})
        loop(total, 0, tail)
    end
  end

  defp count(window, acc) do
    case :binary.split(window, @pattern) do
      [_only] -> acc
      [_left, right] -> count(right, acc + 1)
    end
  end

  # A tail that is one byte shorter than the pattern cannot hold the whole
  # pattern, so a heartbeat that spans two reads counts once.
  #
  defp new_tail(window) when byte_size(window) < 10, do: window
  defp new_tail(window), do: binary_part(window, byte_size(window) - 10, 10)

  # The reader is the only process that sends the per-second counts and
  # it knows the collector from the start: the collector started it and
  # made itself the parent. The pid travels in the process dictionary
  # once, at the start.
  #
  defp self_total do
    Process.get(:collector) || self()
  end
end

#
# The cases of the measure: each case starts one instance and one
# listener, opens the idle streams over raw sockets, samples the
# heartbeats each second and gives the report of the case.
#
defmodule HeartbeatBench do
  alias OzMcp.E2E.HttpServer

  @protocol_version "2025-11-25"

  # ---- One case ----

  # Runs one case: starts the instance and the listener, opens the idle
  # streams, samples for `window_ms` and returns the report of the case.
  #
  def run({kind, heartbeat, streams}, window_ms) do
    instance = Module.concat(OzMcp.E2E.Server, "HB#{System.unique_integer([:positive])}")

    {:ok, sup} =
      Supervisor.start_link([{OzMcp, instance_opts(instance, streams, heartbeat)}],
        strategy: :one_for_one
      )

    {spec, port_fun} = listener_child(kind, instance)
    {:ok, listener} = Supervisor.start_child(sup, spec)
    port = port_fun.(listener)

    {reader, ticker} = start_reader()

    {open_seconds, sockets} =
      :timer.tc(fn -> open_idle_streams(port, streams, reader) end)

    :erlang.system_flag(:scheduler_wall_time, true)

    # The first sample after the flag comes back empty on some versions:
    # take one and drop it.
    #
    _ = :erlang.statistics(:scheduler_wall_time)
    first = :erlang.statistics(:scheduler_wall_time)

    flush_samples()
    per_second = sample_seconds(truncate(window_ms), [])

    second = :erlang.statistics(:scheduler_wall_time)
    memory = :erlang.memory(:total)

    close_all(sockets)
    stop_reader(reader, ticker)
    Supervisor.stop(sup, :normal)

    %{
      kind: kind,
      heartbeat_ms: heartbeat,
      streams: streams,
      open_seconds: open_seconds / 1_000_000,
      utilization: utilization(first, second),
      memory_bytes: memory,
      per_second: per_second
    }
  end

  # The idle timeout of Cowboy closes a connection with no bytes from the
  # client after 60 s, also while a response streams. The window is short
  # next to it, but the option keeps the case independent of it.
  #
  defp instance_opts(instance, streams, heartbeat) do
    [
      server: OzMcp.E2E.Server,
      name: instance,
      allowed_origins: ["http://localhost"],
      sse_heartbeat_ms: heartbeat,
      max_sessions: streams,
      max_sessions_per_principal: nil,
      session_init_timeout_ms: 600_000
    ]
  end

  defp listener_child(:bandit, instance) do
    HttpServer.child(:bandit, {OzMcp.E2E.Router, instance: instance}, [])
  end

  defp listener_child(:cowboy, instance) do
    HttpServer.child(:cowboy, {OzMcp.E2E.Router, instance: instance},
      protocol_options: [idle_timeout: 300_000]
    )
  end

  # ---- The sockets ----

  defp open_idle_streams(port, count, reader) do
    uri = URI.parse("http://127.0.0.1:#{port}/mcp")

    sockets =
      for _i <- 1..count do
        {:ok, socket} = open_idle_stream(uri, reader)
        socket
      end

    sockets
  end

  # One session over one connection: `initialize`, the notification, then
  # the `GET` stream. The socket stays open and goes to the reader in
  # active mode.
  #
  defp open_idle_stream(uri, reader) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", uri.port, [:binary, active: false])

    initialize = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => @protocol_version,
        "capabilities" => %{},
        "clientInfo" => %{"name" => "oz-mcp-heartbeat-bench", "version" => "0.0.0"}
      }
    }

    {status, headers, _body} = post(socket, uri, initialize, [])

    if status != 200 do
      raise "initialize failed with status #{status}"
    end

    session_id = fetch_header(headers, "mcp-session-id")

    notification = %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}

    {status, _headers, _body} =
      post(socket, uri, notification,
        "mcp-session-id": session_id,
        "mcp-protocol-version": @protocol_version
      )

    if status != 202 do
      raise "notifications/initialized failed with status #{status}"
    end

    head =
      "GET #{uri.path} HTTP/1.1\r\n" <>
        "host: #{uri.host}:#{uri.port}\r\n" <>
        "accept: text/event-stream\r\n" <>
        "origin: http://localhost\r\n" <>
        "mcp-session-id: #{session_id}\r\n" <>
        "mcp-protocol-version: #{@protocol_version}\r\n" <>
        "\r\n"

    :ok = :gen_tcp.send(socket, head)
    {:ok, _head, _rest} = read_until(socket, "data: \n\n", [])
    :ok = :inet.setopts(socket, active: true)
    :ok = :gen_tcp.controlling_process(socket, reader)
    {:ok, socket}
  catch
    :exit, reason -> raise "open_idle_stream failed: #{inspect(reason)}"
  end

  defp post(socket, uri, message, extra_headers) do
    body = JSON.encode!(message)

    headers =
      [
        {"content-type", "application/json"},
        {"accept", "application/json, text/event-stream"},
        {"origin", "http://localhost"}
      ] ++
        for {name, value} <- extra_headers, do: {to_string(name), value}

    head =
      "POST #{uri.path} HTTP/1.1\r\n" <>
        "host: #{uri.host}:#{uri.port}\r\n" <>
        Enum.map_join(headers, "", fn {name, value} -> "#{name}: #{value}\r\n" end) <>
        "content-length: #{byte_size(body)}\r\n" <>
        "\r\n"

    :ok = :gen_tcp.send(socket, head <> body)
    read_message(socket)
  end

  # One HTTP message with a JSON body or no body: the head, then the
  # number of bytes of the `content-length` header.
  #
  defp read_message(socket) do
    {:ok, head, rest} = read_until(socket, "\r\n\r\n", [])
    headers = parse_headers(head)
    length = content_length(headers)
    body = rest <> read_exact(socket, length - byte_size(rest))
    {status_of(head), headers, body}
  end

  defp read_until(socket, pattern, acc) do
    case :gen_tcp.recv(socket, 0, 15_000) do
      {:ok, data} ->
        buffer = IO.iodata_to_binary([acc, data])

        case :binary.split(buffer, pattern) do
          [_only] -> read_until(socket, pattern, [buffer])
          [left, right] -> {:ok, left, right}
        end

      {:error, reason} ->
        raise "socket read failed while waiting for #{inspect(pattern)}: #{inspect(reason)}"
    end
  end

  defp read_exact(_socket, more) when more <= 0, do: <<>>

  defp read_exact(socket, more) do
    case :gen_tcp.recv(socket, more, 15_000) do
      {:ok, data} when byte_size(data) == more -> data
      {:ok, data} -> data <> read_exact(socket, more - byte_size(data))
      {:error, reason} -> raise "socket read failed: #{inspect(reason)}"
    end
  end

  defp parse_headers(head) do
    [_status_line | lines] = String.split(head, "\r\n")

    for line <- lines, line != "" do
      case :binary.split(line, ":") do
        [name, value] -> {String.downcase(String.trim(name)), String.trim(value)}
        _ -> nil
      end
    end
    |> Enum.reject(&is_nil/1)
  end

  defp content_length(headers) do
    case List.keyfind(headers, "content-length", 0) do
      {_, value} -> String.to_integer(value)
      nil -> 0
    end
  end

  defp status_of(head) do
    case Regex.run(~r"HTTP/1\.[01] (\d{3})", head) do
      [_, code] -> String.to_integer(code)
      _ -> raise "no status line in the response head: #{inspect(head)}"
    end
  end

  defp fetch_header(headers, name) do
    {_name, value} = List.keyfind(headers, name, 0) || raise "no header #{name}"
    value
  end

  # ---- The sampling ----

  # The window is a whole number of seconds.
  #
  defp truncate(ms), do: div(ms, 1_000) * 1_000

  defp sample_seconds(0, acc), do: Enum.reverse(acc)

  defp sample_seconds(remaining, acc) do
    receive do
      {:heartbeats_per_second, count} -> sample_seconds(remaining - 1_000, [count | acc])
    after
      30_000 -> raise "no sample from the reader in 30 s"
    end
  end

  # The ticks that arrived while the streams opened hold counts of a
  # partial second: drop them before the window starts.
  #
  defp flush_samples do
    receive do
      {:heartbeats_per_second, _count} -> flush_samples()
    after
      0 -> :ok
    end
  end

  defp start_reader do
    parent = self()

    reader =
      spawn_link(fn ->
        Process.put(:collector, parent)
        HeartbeatBench.Reader.loop(0, 0, <<>>)
      end)

    ticker = spawn_link(fn -> tick(reader) end)

    {reader, ticker}
  end

  defp tick(reader) do
    Process.sleep(1_000)
    send(reader, :tick)
    tick(reader)
  end

  defp stop_reader(reader, ticker) do
    #
    # The links go first: the exit of a linked process would stop the
    # caller.
    #
    Process.unlink(ticker)
    Process.unlink(reader)
    Process.exit(ticker, :kill)
    Process.exit(reader, :kill)
    :ok
  end

  defp close_all(sockets) do
    for socket <- sockets, do: :ok = :gen_tcp.close(socket)
    Process.sleep(200)
    :ok
  end

  # The scheduler utilization over the window: the change of the active
  # time over the change of the total time of all schedulers.
  #
  defp utilization(first, second) do
    {active1, total1} = totals(first)
    {active2, total2} = totals(second)
    total = total2 - total1

    if total > 0, do: (active2 - active1) / total * 100, else: 0.0
  end

  defp totals(samples) when is_list(samples) do
    Enum.reduce(samples, {0, 0}, fn {_id, active, total}, {a, t} -> {a + active, t + total} end)
  end
end

IO.puts("""
Heartbeat cost
Machine: #{:inet.gethostname() |> elem(1) |> List.to_string()}, #{:erlang.system_info(:schedulers_online)} schedulers
Elixir #{System.version()}, OTP #{System.otp_release()}
Window: #{window_ms} ms per case
""")

reports =
  for case = {kind, heartbeat, streams} <- cases do
    IO.puts("running: #{kind}, heartbeat #{heartbeat} ms, #{streams} streams ...")
    HeartbeatBench.run(case, window_ms)
  end

summary = fn %{per_second: per_second} ->
  mean = if per_second == [], do: 0.0, else: Enum.sum(per_second) / length(per_second)
  max = Enum.max(per_second ++ [0])
  {mean, max}
end

IO.puts("""
| Server | heartbeat ms | streams | open s | writes/s mean | writes/s max | scheduler % | memory MiB |
|---|---|---|---|---|---|---|---|
""")

for report <- reports do
  {mean, max} = summary.(report)

  IO.puts(
    "| #{report.kind} | #{report.heartbeat_ms} | #{report.streams} | " <>
      "#{Float.round(report.open_seconds, 1)} | #{Float.round(mean, 1)} | #{max} | " <>
      "#{Float.round(report.utilization, 2)} | #{div(report.memory_bytes, 1_048_576)} |"
  )
end

:ok
